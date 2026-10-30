import MurmurDictionary
import AVFoundation
import AppKit
import Foundation
import Observation

/// Builds the engine named by the current setting.
///
/// Deliberately at file scope rather than a static on `DictationController`: the class is
/// `@MainActor`, which would make a static method main-actor-isolated and therefore
/// ineligible to be `@Sendable`. Reading the setting per-utterance is what lets the menu's
/// engine picker take effect on the very next hold instead of needing a restart.
@Sendable
func engineForCurrentSetting() async -> any TranscriptionEngine {
    await MainActor.run {
        let choice: SpeechEngineChoice = Settings.shared.compareMode ? .apple : Settings.shared.engine
        return switch choice {
        case .apple: AppleSpeechEngine()
        case .parakeet: ParakeetEngine()
        case .barkClean: ParakeetEngine(models: .barkClean)
        case .parakeetEOU: StreamingEngines.parakeetEOU
        case .nemotron: StreamingEngines.nemotron
        }
    }
}

/// One hold of the key, from press to delivered text.
///
/// Everything an utterance owns lives here rather than on the controller, so a new hold can
/// start recording while the previous one is still transcribing, cleaning up and typing.
@MainActor
private final class Utterance {
    let holdStarted = Date()
    var releasedAt: Date?
    let engineName: String
    let isComparing: Bool
    /// Captured at press, so changing either mid-hold applies to the next hold, not this one.
    let cleanupEngine: CleanupEngine
    let cleanupProfile: CleanupProfile

    var engine: (any TranscriptionEngine)?
    /// Set once `engine.start()` returned. An engine that never started is never finished,
    /// because the streaming engines are shared and finishing one resets its session.
    var engineStarted = false
    var startupTask: Task<Void, Never>?
    /// Returns the ordered recording when compare mode is on, empty otherwise.
    var feedTask: Task<[AudioChunk], Never>?
    var consumeTask: Task<Void, Never>?
    var audioContinuation: AsyncStream<AudioChunk>.Continuation?
    /// Capture-order audio, buffered until the engine is ready to drain it.
    var audioStream: AsyncStream<AudioChunk>?
    /// True once the microphone opened for this hold — at the press itself when possible.
    var captureOpened = false
    /// The engine's `finish()` after an abort, so the next utterance can wait for it.
    var abortedEngineFinish: Task<Void, Never>?

    /// Latest text from the engine; final once transcription completes.
    var transcript = ""
    /// Compare mode only: the recording, kept so every engine sees identical audio.
    var recorded: [AudioChunk] = []
    var isAborted = false

    init(
        engineName: String,
        isComparing: Bool,
        cleanupEngine: CleanupEngine = .rules,
        cleanupProfile: CleanupProfile = .general
    ) {
        self.engineName = engineName
        self.isComparing = isComparing
        self.cleanupEngine = cleanupEngine
        self.cleanupProfile = cleanupProfile
    }

    /// History label for the pass that ran, e.g. "S1-mini · Email". Nil when none ran.
    var cleanupLabel: String? {
        guard Settings.shared.cleanupEnabled else { return nil }
        switch cleanupEngine {
        case .rules: return nil
        case .s1Mini: return "S1-mini · \(cleanupProfile.displayName)"
        case .appleIntelligence: return "Apple Intelligence"
        }
    }
}

@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case finishing
        case error(String)

        var isActive: Bool {
            switch self {
            case .starting, .listening, .finishing: true
            case .idle, .error: false
            }
        }
    }

    /// The foreground state: a hold in progress wins over earlier holds still finishing.
    private(set) var state: State = .idle
    /// True while the microphone belongs to a hold. Record buttons use this rather than
    /// `state.isActive`, because a new recording may start while the last one finishes.
    var isRecording: Bool { state == .starting || state == .listening }
    private var blockedEngine: SpeechEngineChoice?
    var recordingNotice: String? {
        guard let blockedEngine, !Settings.shared.compareMode,
              Settings.shared.engine == blockedEngine else { return nil }
        return models.recordingBlocker(for: blockedEngine)
    }
    /// Live transcript, updated as the engine revises it. Drives the main and comparison views.
    private(set) var transcript = ""
    /// Smoothed 0…1 mic level for the waveform.
    private(set) var level: Float = 0
    /// The microphone capture is pinned to, for display. Nil when neither allowed one is
    /// available.
    private(set) var microphoneName: String?

    private let hotkey = HotkeyMonitor()
    private let capture = AudioCapture()
    /// Sends captured audio to the hold in progress, or to the pre-roll between holds.
    private let router = CaptureRouter()
    /// The format key capture is running with, or nil while the microphone is closed. With
    /// the always-open option this stays set between holds.
    private var captureKey: String?
    /// Loaded once, so the start tick plays the instant the key goes down rather than after
    /// a file load. It plays at the press, not when the microphone is confirmed open: a
    /// tick that trails the press by the mic's startup time makes people start talking
    /// before it, which reads as lag even when nothing is lost.
    private let startSound = NSSound(named: "Tink")
    private let makeEngine: @Sendable () async -> any TranscriptionEngine
    private let models: StreamingModelPreparation

    /// Injected only by tests; production reads the setting per-utterance below.
    private let formatter: (any TextFormatter)?

    /// Chosen per-utterance so a menu change applies to the very next hold.
    private func formatter(for utterance: Utterance) -> any TextFormatter {
        if let formatter { return formatter }
        switch utterance.cleanupEngine {
        case .rules: return RuleBasedFormatter()
        case .s1Mini: return S1MiniFormatter(profile: utterance.cleanupProfile)
        case .appleIntelligence: return FoundationModelFormatter()
        }
    }

    /// The hold that owns the microphone, if any.
    private var current: Utterance?
    /// Completes when the most recently released hold has finished with its engine. The
    /// next hold records immediately but opens its engine session only after this: the
    /// streaming engines are single shared sessions and Parakeet shares one model.
    private var engineIdle: Task<Void, Never>?
    /// Completes when the most recently released hold has delivered its text, so text is
    /// typed in the order it was spoken even when a short hold resolves first.
    private var deliveryTail: Task<Void, Never>?
    /// Released holds still transcribing or delivering, keyed by release order.
    private var tails: [Int: Task<Void, Never>] = [:]
    private var nextTailID = 0
    private var comparisonInFlight = false
    /// Capture formats already negotiated, keyed by engine. Asking a shared engine for its
    /// format can wait behind the previous hold's transcription, which would delay the mic.
    private var inputFormats: [String: AVAudioFormat] = [:]

    init(
        formatter: (any TextFormatter)? = nil,
        makeEngine: @escaping @Sendable () async -> any TranscriptionEngine = engineForCurrentSetting,
        models: StreamingModelPreparation = .shared
    ) {
        self.formatter = formatter
        self.makeEngine = makeEngine
        self.models = models
    }

    // MARK: - Lifecycle

    /// - Returns: `false` if the global keyboard monitor couldn't be installed.
    @discardableResult
    func activate() -> Bool {
        hotkey.key = Settings.shared.pushToTalkKey
        hotkey.onPress = { [weak self] in
            Task { @MainActor in self?.beginDictation() }
        }
        hotkey.onRelease = { [weak self] in
            Task { @MainActor in self?.endDictation() }
        }
        return hotkey.start()
    }

    func deactivate() {
        hotkey.stop()
        cancelDictation()
    }

    /// Prepares AVAudioEngine's graph while idle. This does not start microphone I/O.
    func prepareAudio() {
        guard Permissions.hasMicrophone else { return }
        capture.onDeviceChange = { [weak self] device in
            Task { @MainActor in self?.microphoneName = device?.name }
        }
        capture.onRepinNeeded = { [weak self] in
            Task { @MainActor in self?.repinWhenIdle() }
        }
        capture.prepare()
        observeMicSettings()
        prefetchInputFormat()
        syncOpenMicrophone()
    }

    // MARK: - Always-open microphone

    /// The format key the next hold would capture with.
    private var currentFormatKey: String {
        Settings.shared.compareMode ? "compare" : Settings.shared.engine.rawValue
    }

    /// Between holds, keeps the microphone open (or closed) to match the setting, in the
    /// format the selected engine wants. A hold in progress owns capture; its release
    /// calls this again.
    func syncOpenMicrophone() {
        guard current == nil else { return }
        guard Settings.shared.alwaysOpenMic, Permissions.hasMicrophone else {
            if captureKey != nil {
                capture.stop()
                captureKey = nil
                Log.audio.info("microphone closed between holds")
            }
            return
        }
        let key = currentFormatKey
        guard captureKey != key else { return }
        guard let format = inputFormats[key] else {
            prefetchInputFormat()
            return
        }
        if captureKey != nil { capture.stop() }
        captureKey = nil
        router.detach()
        do {
            try startCapture(format: format)
            captureKey = key
            Log.audio.info("microphone kept open between holds (\(key, privacy: .public))")
        } catch {
            Log.audio.error("couldn't keep the microphone open: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startCapture(format: AVAudioFormat) throws {
        let router = router
        try capture.start(
            outputFormat: format,
            onBuffer: { router.route($0) },
            onLevel: { router.level($0) },
            onInterruption: { [weak self] in
                Task { @MainActor in self?.captureDied() }
            }
        )
    }

    /// Ends a hold's use of the microphone. With the always-open option it keeps running
    /// for the next press; otherwise it closes.
    private func releaseCapture() {
        router.detach()
        if Settings.shared.alwaysOpenMic {
            syncOpenMicrophone()
        } else if captureKey != nil {
            capture.stop()
            captureKey = nil
        }
    }

    /// A route change the capture couldn't survive. A hold in progress finishes with what it
    /// recorded; an idle open microphone is reopened on whatever device is now allowed.
    private func captureDied() {
        captureKey = nil
        if let utterance = current {
            captureInterrupted(utterance)
        } else {
            syncOpenMicrophone()
        }
    }

    /// A microphone was connected or removed while capture is running. Between holds,
    /// reopen on the newly allowed device now; during a hold, the release handles it.
    private func repinWhenIdle() {
        guard current == nil, captureKey != nil else { return }
        capture.stop()
        captureKey = nil
        syncOpenMicrophone()
    }

    /// Re-syncs the open microphone when the option, engine or compare mode changes.
    private func observeMicSettings() {
        withObservationTracking {
            _ = Settings.shared.alwaysOpenMic
            _ = Settings.shared.engine
            _ = Settings.shared.compareMode
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.syncOpenMicrophone()
                self?.observeMicSettings()
            }
        }
    }

    /// Works out the selected engine's input format ahead of time, so even the first press
    /// can open the microphone directly from the key-down handler.
    private func prefetchInputFormat() {
        let comparing = Settings.shared.compareMode
        let key = comparing ? "compare" : Settings.shared.engine.rawValue
        guard inputFormats[key] == nil else { return }
        Task { @MainActor in
            let owner: any TranscriptionEngine = comparing ? AppleSpeechEngine() : await self.makeEngine()
            guard self.inputFormats[key] == nil, let format = await owner.preferredInputFormat() else { return }
            self.inputFormats[key] = format
            self.syncOpenMicrophone()
        }
    }

    /// Re-arms the keyboard monitors after the user picks a different push-to-talk key.
    @discardableResult
    func reloadHotkey() -> Bool {
        hotkey.stop()
        return activate()
    }

    // MARK: - Button-driven recording

    /// Starts a recording from a Record button rather than the hotkey.
    ///
    /// Wispr Flow's hotkey is held down for the duration **only in compare mode**. Reaching
    /// into another app is a comparison affordance; during ordinary dictation it would mean
    /// every recording silently shipped your audio to a third party's servers.
    func startButtonRecording() {
        guard current == nil else { return }
        let pressedWispr = Settings.shared.compareMode
        if pressedWispr { WisprTrigger.press() }
        if !beginDictation(), pressedWispr { WisprTrigger.release() }
    }

    /// Releases Wispr's hotkey first, so its upload starts while our own engines are still
    /// finishing — otherwise every run would wait the full round trip end to end.
    func stopButtonRecording() {
        WisprTrigger.release()
        endDictation()
    }

    // MARK: - Dictation

    /// - Returns: whether a recording started.
    @discardableResult
    private func beginDictation() -> Bool {
        guard current == nil else { return false }
        // Compare mode replays one recording through every engine and files the rows as one
        // group; overlapping another hold with that would interleave two utterances.
        if !tails.isEmpty, Settings.shared.compareMode || comparisonInFlight {
            Log.speech.notice("press ignored while a comparison finishes")
            return false
        }
        let choice = Settings.shared.engine
        if !Settings.shared.compareMode, let blocker = models.recordingBlocker(for: choice) {
            blockedEngine = choice
            Log.speech.notice("Recording blocked: \(blocker, privacy: .public)")
            return false
        }
        blockedEngine = nil

        let comparing = Settings.shared.compareMode
        let utterance = Utterance(
            engineName: comparing ? "Comparing…" : choice.displayName,
            isComparing: comparing,
            cleanupEngine: Settings.shared.cleanupEngine,
            cleanupProfile: Settings.shared.cleanupProfile
        )
        current = utterance
        state = .starting
        transcript = ""

        if Settings.shared.soundEnabled, let startSound {
            startSound.stop()
            startSound.play()
        }
        let formatKey = comparing ? "compare" : choice.rawValue

        // Open the microphone right here, in the key-down handler, whenever the format is
        // already known (every press after the first for an engine). Going through the
        // startup task first cost ~65 ms of permission checks, engine setup and scheduling
        // before the mic even began to start. Anything else falls back to the task below.
        if Permissions.hasMicrophone, let format = inputFormats[formatKey] {
            do {
                try openCapture(for: utterance, format: format, key: formatKey)
            } catch {
                Log.audio.error("capture failed at press, retrying in startup: \(error.localizedDescription)")
            }
        }

        // Load the cleanup model while the user is still talking, not after release.
        // S1-mini needs nothing here: it stays resident once loaded.
        if !comparing, formatter == nil, Settings.shared.cleanupEnabled,
           utterance.cleanupEngine == .appleIntelligence {
            FoundationModelFormatter.prewarm()
        }

        let previousEngine = engineIdle
        let startupInterval = Log.performanceSignposter.beginInterval("dictation startup")
        utterance.startupTask = Task { @MainActor in
            defer { Log.performanceSignposter.endInterval("dictation startup", startupInterval) }
            await self.start(utterance, formatKey: formatKey, after: previousEngine)
        }
        return true
    }

    private func start(
        _ utterance: Utterance,
        formatKey: String,
        after previousEngine: Task<Void, Never>?
    ) async {
        do {
            guard await Permissions.requestMicrophone() else {
                fail(utterance, "Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
                return
            }

            let engine = await makeEngine()
            utterance.engine = engine

            // Compare mode captures in *Apple's* format, not a format of our choosing.
            //
            // SpeechAnalyzer enforces `Audio sample data must be 16-bit signed integers`
            // as a hard precondition — feeding it float32 doesn't fail gracefully, it
            // kills the process. Parakeet is the flexible one (its `feed` converts
            // int16/int32/float32), so the strict engine picks the format and the
            // tolerant engine adapts. Both still replay the identical buffers.
            let format: AVAudioFormat
            if let cached = inputFormats[formatKey] {
                format = cached
            } else {
                let formatOwner: any TranscriptionEngine = utterance.isComparing ? AppleSpeechEngine() : engine
                let formatStartedAt = Date()
                guard let negotiated = await formatOwner.preferredInputFormat() else {
                    throw TranscriptionError.noAudioFormat
                }
                Log.performance.info(
                    "speech input format ready in \(Date().timeIntervalSince(formatStartedAt), format: .fixed(precision: 3))s"
                )
                inputFormats[formatKey] = negotiated
                format = negotiated
            }

            if !utterance.captureOpened {
                // Released or abandoned before the microphone opened: nothing to record. The
                // engine never started, so it is dropped rather than finished.
                guard !utterance.isAborted, !Task.isCancelled, current === utterance else {
                    utterance.engine = nil
                    return
                }
                try openCapture(for: utterance, format: format, key: formatKey)
            }
            guard let audioStream = utterance.audioStream else { return }

            // The microphone is live; audio queues in the stream while the previous hold
            // finishes with its engine.
            await previousEngine?.value
            guard !utterance.isAborted else { return }

            // The buffered audio stream is drained only after start() has installed the
            // engine's input stream, so no chunks are offered to an uninitialized recognizer.
            let chunks = try await engine.start()
            utterance.engineStarted = true

            guard !Task.isCancelled, !utterance.isAborted else {
                await engine.finish()
                return
            }

            // The recording is accumulated *inside* the ordered drain, not by spawning
            // a task per buffer. Unstructured tasks have no ordering guarantee, so
            // collecting them separately could assemble the replay audio out of order
            // and silently produce word-salad from the comparison.
            let comparing = utterance.isComparing
            utterance.feedTask = Task.detached(priority: .userInitiated) {
                var recording: [AudioChunk] = []
                for await chunk in audioStream {
                    if comparing { recording.append(chunk) }
                    await engine.feed(chunk)
                }
                return recording
            }

            utterance.consumeTask = Task { @MainActor in
                do {
                    for try await chunk in chunks {
                        utterance.transcript = chunk.text
                        // Earlier holds keep refining their text after release; only show
                        // it while no newer hold owns the display.
                        if self.current === utterance || self.current == nil {
                            self.transcript = chunk.text
                        }
                    }
                } catch {
                    self.fail(utterance, error.localizedDescription)
                }
            }
        } catch {
            fail(utterance, error.localizedDescription)
        }
    }

    /// Opens the microphone for `utterance`. Capture starts before the recognizer: model
    /// loading, analyzer startup and the previous hold's transcription can take long enough
    /// to lose the beginning of a short utterance, so the stream buffers capture-order audio
    /// until the engine drains it.
    private func openCapture(for utterance: Utterance, format: AVAudioFormat, key: String) throws {
        let (audioStream, audioContinuation) = AsyncStream<AudioChunk>.makeStream(
            bufferingPolicy: .bufferingOldest(2_048)
        )
        let openedAt = Date()
        // Attach first: with the microphone already open this is the whole job, and the
        // hold starts with the pre-roll from just before the press.
        router.attach(audioContinuation) { [weak self] level in
            Task { @MainActor in
                guard let self, self.current === utterance else { return }
                self.updateLevel(level)
            }
        }
        let wasOpen = captureKey == key
        if !wasOpen {
            if captureKey != nil { capture.stop() }
            captureKey = nil
            do {
                try startCapture(format: format)
            } catch {
                router.detach()
                throw error
            }
            captureKey = key
        }
        utterance.audioStream = audioStream
        utterance.audioContinuation = audioContinuation
        utterance.captureOpened = true
        Log.performance.info(
            "capture \(wasOpen ? "attached to open mic" : "opened", privacy: .public) \(Date().timeIntervalSince(utterance.holdStarted), format: .fixed(precision: 3))s after press (call \(Date().timeIntervalSince(openedAt), format: .fixed(precision: 3))s)"
        )
        if current === utterance, state == .starting {
            state = .listening
        }
    }

    private func endDictation() {
        guard let utterance = current else { return }
        current = nil
        utterance.releasedAt = Date()
        releaseCapture()
        level = 0
        state = .finishing
        if utterance.isComparing { comparisonInFlight = true }

        let transcribed = Task { @MainActor in await self.transcribe(utterance) }
        engineIdle = transcribed

        let previousDelivery = deliveryTail
        let id = nextTailID
        nextTailID += 1
        let tail = Task { @MainActor in
            await transcribed.value
            await self.deliver(utterance, after: previousDelivery)
            if utterance.isComparing { self.comparisonInFlight = false }
            self.tails[id] = nil
            self.settle()
        }
        tails[id] = tail
        deliveryTail = tail
    }

    /// Route change the capture could not survive. Finish with what was recorded rather
    /// than leave the HUD showing a live meter over a stopped microphone.
    private func captureInterrupted(_ utterance: Utterance) {
        guard current === utterance else { return }
        Log.audio.error("microphone stopped mid-recording; transcribing what was captured")
        endDictation()
    }

    /// Drains captured audio into the engine and waits for its final text.
    private func transcribe(_ utterance: Utterance) async {
        // If the recognizer is still loading, wait for the startup task to finish its
        // handoff. Finalizing concurrently would race the engine's input stream.
        await utterance.startupTask?.value
        utterance.startupTask = nil

        // Drain every captured buffer into the engine before asking it to finalize, or the
        // tail of the utterance gets dropped.
        utterance.audioContinuation?.finish()
        utterance.audioContinuation = nil
        utterance.recorded = await utterance.feedTask?.value ?? []
        utterance.feedTask = nil

        if let engine = utterance.engine {
            utterance.engine = nil
            if utterance.engineStarted { await engine.finish() }
        }
        await utterance.abortedEngineFinish?.value
        await utterance.consumeTask?.value
        utterance.consumeTask = nil
    }

    private func deliver(_ utterance: Utterance, after previous: Task<Void, Never>?) async {
        guard !utterance.isAborted, !Task.isCancelled else { return }

        if utterance.isComparing {
            await previous?.value
            await runComparison(utterance)
            return
        }

        let raw = utterance.transcript
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let cleaned = Settings.shared.cleanupEnabled
            ? await formatter(for: utterance).format(raw)
            : raw

        // The dictionary runs last, and runs regardless of the cleanup setting. Biasing
        // only raises the odds of the right word; this is the pass that guarantees it,
        // so it must not be something the user can accidentally switch off.
        let (output, corrections) = DictionaryStore.shared.corrector.apply(to: cleaned)
        if !corrections.isEmpty {
            Log.speech.info("dictionary · \(corrections.count, privacy: .public) correction(s) applied")
        }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let readyAt = Date()

        // Typed in the order spoken, even when this hold resolved before the one before it.
        await previous?.value
        guard !Task.isCancelled, !utterance.isAborted else { return }

        // Not typed and not filed: a dictated password would otherwise sit on the pasteboard
        // and in history in plain text.
        if TextInjector.focusIsSecureField() {
            Log.inject.notice("focused element is a password field; transcript discarded")
            report("Password field focused. Murmur does not type into password fields.")
            return
        }

        let delivered = await TextInjector.insert(output)
        let deliveredAt = delivered ? Date() : nil
        guard !Task.isCancelled else { return }
        recordRun(utterance, text: output, corrections: corrections, readyAt: readyAt, deliveredAt: deliveredAt)
        guard delivered else {
            report("Text insertion failed. Check transcription history to copy the result.")
            return
        }
        if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }
    }

    private func cancelDictation() {
        if let utterance = current {
            utterance.startupTask?.cancel()
            abandon(utterance)
        }
        for tail in tails.values { tail.cancel() }
        router.detach()
        capture.stop()
        captureKey = nil
        state = .idle
        transcript = ""
        level = 0
    }

    // MARK: - Helpers

    /// Replays the recording through every engine and files the results as one group.
    ///
    /// Nothing is injected in this mode — the point is to read the outputs side by side,
    /// and typing one of them into whatever had focus would be a surprise.
    private func runComparison(_ utterance: Utterance) async {
        let chunks = utterance.recorded
        utterance.recorded.removeAll(keepingCapacity: false)

        guard !chunks.isEmpty, let releasedAt = utterance.releasedAt else { return }
        let holdStarted = utterance.holdStarted

        transcript = "Running both engines…"

        let group = UUID().uuidString
        let held = releasedAt.timeIntervalSince(holdStarted)

        // Filed one at a time as each engine finishes, so the window fills in progressively
        // rather than snapping both rows into place at the end.
        let results = await EngineComparison.run(chunks: chunks) { result in
            RunLog.record(
                DictationRun(
                    date: releasedAt,
                    engine: result.engine,
                    audioSeconds: held,
                    processSeconds: result.seconds,
                    text: result.text,
                    group: group
                )
            )
        }

        for result in results {
            Log.speech.info("""
                compare · \(result.engine, privacy: .public): \
                \(result.seconds, format: .fixed(precision: 2))s — \
                \(result.text, privacy: .public)
                """)
        }

        // Wispr Flow, if its hotkey was held for this same utterance. It transcribes in the
        // cloud, so its row lands after both local engines have already finished — the wait
        // happens here rather than blocking the rows above from appearing.
        if WisprReader.isInstalled {
            transcript = "Waiting for Wispr Flow…"
            if let wispr = await WisprReader.result(after: holdStarted, timeout: 8) {
                RunLog.record(
                    DictationRun(
                        date: releasedAt,
                        engine: wispr.engine,
                        audioSeconds: held,
                        processSeconds: wispr.seconds,
                        text: wispr.text,
                        group: group
                    )
                )
                Log.speech.info("""
                    compare · \(wispr.engine, privacy: .public): \
                    \(wispr.seconds, format: .fixed(precision: 2))s — \
                    \(wispr.text, privacy: .public)
                    """)
            } else {
                Log.speech.info("compare · Wispr Flow: no result (hotkey not held, or timed out)")
            }
        }

        if Settings.shared.soundEnabled { NSSound(named: "Glass")?.play() }
    }

    /// Files the finished utterance for the dashboard.
    ///
    /// `processSeconds` is measured from key release, not from capture start — that's the
    /// wait the user actually experiences, and it's the only number on which a streaming
    /// engine and a batch engine can be compared honestly.
    private func recordRun(
        _ utterance: Utterance,
        text: String,
        corrections: [AppliedCorrection] = [],
        readyAt: Date,
        deliveredAt: Date?
    ) {
        guard let releasedAt = utterance.releasedAt else { return }
        let processSeconds = readyAt.timeIntervalSince(releasedAt)
        let deliverySeconds = deliveredAt?.timeIntervalSince(releasedAt)
        if let deliverySeconds {
            Log.performance.notice("\(utterance.engineName, privacy: .public): release to text ready \(processSeconds, format: .fixed(precision: 3))s; release to delivery event \(deliverySeconds, format: .fixed(precision: 3))s")
        }
        RunLog.record(
            DictationRun(
                date: releasedAt,
                engine: utterance.engineName,
                audioSeconds: releasedAt.timeIntervalSince(utterance.holdStarted),
                processSeconds: processSeconds,
                text: text,
                corrections: corrections.isEmpty ? nil : corrections,
                deliverySeconds: deliverySeconds,
                cleanup: utterance.cleanupLabel
            )
        )
    }

    /// Light smoothing so the waveform glides instead of strobing at buffer rate.
    private func updateLevel(_ new: Float) {
        level += (new - level) * 0.35
    }

    /// Returns `state` to whatever is still running once a hold has fully finished.
    /// An error message keeps the display until its own timer clears it.
    private func settle() {
        guard current == nil else { return }
        if case .error = state { return }
        state = tails.isEmpty ? .idle : .finishing
        if tails.isEmpty { transcript = "" }
    }

    /// Stops an utterance and releases everything it holds, without reporting anything.
    private func abandon(_ utterance: Utterance) {
        utterance.isAborted = true
        if current === utterance {
            current = nil
            releaseCapture()
            level = 0
        }
        utterance.audioContinuation?.finish()
        utterance.audioContinuation = nil
        utterance.feedTask?.cancel()
        utterance.feedTask = nil
        utterance.consumeTask?.cancel()
        utterance.consumeTask = nil

        guard let engine = utterance.engine else { return }
        utterance.engine = nil
        let started = utterance.engineStarted
        let finish = Task { if started { await engine.finish() } }
        utterance.abortedEngineFinish = finish
        // A hold that was never released has no tail to publish its engine's finish, so
        // chain it here; otherwise the next hold could open a session before it completes.
        if utterance.releasedAt == nil {
            let previous = engineIdle
            engineIdle = Task {
                await previous?.value
                await finish.value
            }
        }
    }

    private func fail(_ utterance: Utterance, _ message: String) {
        Log.app.error("\(message)")
        abandon(utterance)
        report(message)
    }

    /// Shows an error unless a newer hold is recording; that hold keeps the display, and the
    /// message stays in the log.
    private func report(_ message: String) {
        guard current == nil else { return }
        state = .error(message)
        level = 0

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard current == nil, state == .error(message) else { return }
            state = tails.isEmpty ? .idle : .finishing
            if tails.isEmpty { transcript = "" }
        }
    }
}
