import MurmurDictionary
import AVFoundation
import AppKit
import Foundation
import Observation

/// Builds the engine named by the current setting. It lives at file scope because a static
/// method of the main-actor controller would itself be main-actor isolated and so could not
/// be `@Sendable`. The setting is read each time an engine is needed, so a change in the
/// engine picker applies to the very next hold without a restart.
@Sendable
func engineForCurrentSetting() async -> any TranscriptionEngine {
    await MainActor.run {
        let choice: SpeechEngineChoice = Settings.shared.compareMode ? .apple : Settings.shared.engine
        return engine(for: choice)
    }
}

@MainActor
func engine(for choice: SpeechEngineChoice) -> any TranscriptionEngine {
    switch choice {
    case .apple: AppleSpeechEngine()
    case .parakeet:
        Settings.shared.transcribeTiming == .whileSpeaking
            ? IncrementalParakeetEngine(models: .shared) : ParakeetEngine()
    case .barkClean:
        Settings.shared.transcribeTiming == .whileSpeaking
            ? IncrementalParakeetEngine(models: .barkClean) : ParakeetEngine(models: .barkClean)
    case .parakeetEOU: StreamingEngines.parakeetEOU
    case .nemotron: StreamingEngines.nemotron
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
    /// Apple's transcriber standing in while the selected batch model is still preparing
    /// (its Neural Engine compile can take minutes after a cache purge). Nil otherwise.
    let standIn: SpeechEngineChoice?
    let isComparing: Bool
    /// Captured at press, so changing either mid-hold applies to the next hold, not this one.
    let cleanupEngine: CleanupEngine
    let cleanupProfile: CleanupProfile

    var engine: (any TranscriptionEngine)?
    /// Set once `engine.start()` returned. An engine that never started is never finished,
    /// because the streaming engines are shared and finishing one resets its session.
    var engineStarted = false
    var startupTask: Task<Void, Never>?
    /// Resolves to every chunk the feed task drained into the engine, in order, for every hold (the training recording needs it outside compare mode too).
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
    /// Cleans finished sentences while the key is held, when the engine reports a stable
    /// prefix and the cleanup pass is one worth overlapping. Nil otherwise.
    var cleanupPipeline: CleanupPipeline?
    /// Capture-order audio of the hold, filled at release from `feedTask`. Compare mode replays it through each engine and a finished run stores it as its recording; emptied once consumed.
    var recorded: [AudioChunk] = []
    var isAborted = false

    init(
        engineName: String,
        standIn: SpeechEngineChoice? = nil,
        isComparing: Bool,
        cleanupEngine: CleanupEngine = .rules,
        cleanupProfile: CleanupProfile = .general
    ) {
        self.engineName = engineName
        self.standIn = standIn
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

/// Runs push-to-talk dictation: hold the key, capture, transcribe, clean up and type.
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
    /// Smoothed microphone level from 0 to 1 that drives the waveform and level meter.
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

    /// Nil in production. Tests inject one, which overrides the per-utterance choice of cleanup engine.
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
        ModelResidency.shared.isBusy = { [weak self] in
            guard let self else { return false }
            return self.current != nil || !self.tails.isEmpty
        }
    }

    // MARK: - Lifecycle

    /// - Returns: `false` if the global keyboard monitor couldn't be installed.
    @discardableResult
    func activate() -> Bool {
        // The key must be set first: `start()` seeds its pressed flag from that key's hardware state.
        hotkey.key = Settings.shared.pushToTalkKey
        hotkey.onPress = { [weak self] in
            Task { @MainActor in self?.beginDictation() }
        }
        hotkey.onRelease = { [weak self] in
            Task { @MainActor in self?.endDictation() }
        }
        return hotkey.start()
    }

    /// Stops listening for the key, then abandons whatever is in flight.
    func deactivate() {
        hotkey.stop()
        cancelDictation()
    }

    /// Pins and initializes the capture unit while idle. This does not start microphone I/O.
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

    /// Starts a recording from an on-screen Record button instead of the hotkey. Wispr Flow's
    /// hotkey is pressed for the duration only in compare mode: pressing it during ordinary
    /// dictation would send every recording's audio to a third party's servers.
    func startButtonRecording() {
        guard current == nil else { return }
        let pressedWispr = Settings.shared.compareMode
        if pressedWispr { WisprTrigger.press() }
        if !beginDictation(), pressedWispr { WisprTrigger.release() }
    }

    /// Wispr is released first so its cloud upload starts while the local engines are still
    /// finishing, and a comparison does not wait a full extra round trip. Both calls are
    /// no-ops when there is nothing to release, so this is safe outside compare mode.
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
        // An installed batch model that isn't in memory yet must not hold the dictation:
        // after a cache purge its Neural Engine compile takes minutes. Apple's transcriber
        // takes this hold and the row says so; the model keeps loading in the background.
        let standIn: SpeechEngineChoice? =
            !comparing && choice.requiresPreparedModel && models.state(for: choice) != .ready ? .apple : nil
        let utterance = Utterance(
            engineName: comparing ? "Comparing…" : standIn.map { "\($0.displayName) · \(choice.displayName) preparing" } ?? choice.displayName,
            standIn: standIn,
            isComparing: comparing,
            cleanupEngine: Settings.shared.cleanupEngine,
            cleanupProfile: Settings.shared.cleanupProfile
        )
        current = utterance
        state = .starting
        transcript = ""

        let formatKey = comparing ? "compare" : (standIn ?? choice).rawValue

        // Attach to the microphone before anything else. With the mic kept open the hold
        // starts from a 0.3 s pre-roll, so every millisecond spent before this line comes
        // out of that margin; the sound and the model wake below measured up to 0.67 s
        // when they ran first. With the mic closed, this opens it right here in the key-down
        // handler whenever the format is already known (every press after the first for an
        // engine); anything else falls back to the startup task below.
        if Permissions.hasMicrophone, let format = inputFormats[formatKey] {
            do {
                try openCapture(for: utterance, format: format, key: formatKey)
            } catch {
                Log.audio.error("capture failed at press, retrying in startup: \(error.localizedDescription)")
            }
        }

        let afterCapture = Date()
        if Settings.shared.soundEnabled, let startSound {
            startSound.stop()
            startSound.play()
        }
        let afterSound = Date()
        // Models released while idle start loading now, alongside recording.
        if !comparing {
            ModelResidency.shared.wake(
                engine: choice,
                cleanup: Settings.shared.cleanupEnabled ? utterance.cleanupEngine : nil
            )
        }
        Log.performance.info(
            "press work after capture: sound \(afterSound.timeIntervalSince(afterCapture), format: .fixed(precision: 3))s, model wake \(Date().timeIntervalSince(afterSound), format: .fixed(precision: 3))s"
        )

        // Load the cleanup model while the user is still talking, not after release.
        // S1-mini is woken above by `ModelResidency`.
        if !comparing, formatter == nil, Settings.shared.cleanupEnabled,
           utterance.cleanupEngine == .appleIntelligence {
            FoundationModelFormatter.prewarm()
        }

        // Clean sentences as they land rather than all of them at release. Only the General
        // profile: Email and Notes place greetings and bullets from the whole text, and
        // Message drops the final period, which piecewise cleanup would scatter.
        if !comparing, Settings.shared.cleanupEnabled, utterance.cleanupEngine != .rules,
           utterance.cleanupProfile == .general {
            utterance.cleanupPipeline = CleanupPipeline(formatter: formatter(for: utterance))
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

            let engine: any TranscriptionEngine = if let standIn = utterance.standIn {
                Murmur.engine(for: standIn)
            } else {
                await makeEngine()
            }
            utterance.engine = engine

            // Compare mode captures in Apple's format: SpeechAnalyzer requires 16-bit signed
            // integer samples as a hard precondition and terminates the process, rather than
            // failing, when handed float32. Parakeet's `feed` converts int16, int32 and float32,
            // so the strict engine picks the format and the tolerant one adapts, and both still
            // replay identical buffers.
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

            // One task drains the stream strictly in order, both remembering each chunk and
            // feeding it to the engine. Spawning a task per buffer would lose ordering and
            // scramble the replayed audio in a comparison.
            // Kept for compare mode and for the training recording.
            utterance.feedTask = Task.detached(priority: .userInitiated) {
                var recording: [AudioChunk] = []
                for await chunk in audioStream {
                    recording.append(chunk)
                    await engine.feed(chunk)
                }
                return recording
            }

            utterance.consumeTask = Task { @MainActor in
                do {
                    for try await chunk in chunks {
                        utterance.transcript = chunk.text
                        if let stable = chunk.stable, !chunk.isFinal {
                            utterance.cleanupPipeline?.accept(stable: stable)
                        }
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

        let cleaned: String
        if !Settings.shared.cleanupEnabled {
            cleaned = raw
        } else if let pipeline = utterance.cleanupPipeline {
            cleaned = await pipeline.finish(transcript: raw) {
                await formatter(for: utterance).format(raw)
            }
            Log.speech.info("cleanup pipeline: \(pipeline.chunkCount) piece(s) cleaned while held")
        } else {
            cleaned = await formatter(for: utterance).format(raw)
        }

        // The dictionary always runs last, whatever the cleanup setting: engine biasing only
        // raises the odds of the right word, and this pass is what guarantees it.
        let applied = DictionaryStore.shared.corrector.apply(to: cleaned)
        let output = applied.text
        let corrections = applied.applied
        if !corrections.isEmpty {
            Log.speech.info("dictionary applied \(corrections.count, privacy: .public) correction(s)")
        }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            utterance.recorded.removeAll(keepingCapacity: false)
            return
        }
        let readyAt = Date()

        // Typed in the order spoken, even when this hold resolved before the one before it.
        await previous?.value
        guard !Task.isCancelled, !utterance.isAborted else { return }

        // Not typed and not filed: a dictated password would otherwise sit on the pasteboard
        // and in history in plain text.
        if TextInjector.focusIsSecureField() {
            Log.inject.notice("focused element is a password field; transcript discarded")
            report("Password field focused. Murmur does not type into password fields.")
            utterance.recorded.removeAll(keepingCapacity: false)
            return
        }

        // A push-to-talk key the system still thinks is held would turn the target's next
        // click into a ⌘-click; let it go before the text lands.
        HotkeyMonitor.releaseIfStuck(Settings.shared.pushToTalkKey)
        let delivered = await TextInjector.insert(output)
        let deliveredAt = delivered ? Date() : nil
        guard !Task.isCancelled else { return }
        recordRun(utterance, text: output, rawText: raw, corrections: corrections, readyAt: readyAt, deliveredAt: deliveredAt)
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

    /// Compare mode: one captured recording goes to each engine, and the results share a group id.
    /// Nothing is injected in this mode: the outputs are for reading side by side, and typing
    /// one of them into the focused app would surprise the user.
    private func runComparison(_ utterance: Utterance) async {
        let chunks = utterance.recorded
        utterance.recorded.removeAll(keepingCapacity: false)

        guard !chunks.isEmpty, let releasedAt = utterance.releasedAt else { return }
        let holdStarted = utterance.holdStarted

        transcript = "Running local engines…"
        let group = UUID().uuidString
        let heldSeconds = releasedAt.timeIntervalSince(holdStarted)

        // Dated at release, not now, so the rows of one recording sort together.
        func file(_ result: ComparisonResult) {
            RunLog.record(DictationRun(
                date: releasedAt,
                engine: result.engine,
                audioSeconds: heldSeconds,
                processSeconds: result.seconds,
                text: result.text,
                group: group
            ))
        }
        func logResult(_ result: ComparisonResult) {
            Log.speech.info("\(result.engine, privacy: .public): \(result.seconds, format: .fixed(precision: 2))s \(result.text, privacy: .public)")
        }

        let results = await EngineComparison.run(chunks: chunks) { result in
            file(result)
        }
        for result in results { logResult(result) }

        // Wispr is awaited after the local rows are filed so they are not held back by its
        // network round trip. Its timing is its own end-to-end latency and is not ranked
        // against the local ones.
        if WisprReader.isInstalled {
            transcript = "Waiting for Wispr Flow…"
            if let wispr = await WisprReader.result(after: holdStarted, timeout: 8) {
                file(wispr)
                logResult(wispr)
            } else {
                Log.speech.info("Wispr produced no result (its hotkey was not held, or it timed out)")
            }
        }

        if Settings.shared.soundEnabled { NSSound(named: "Glass")?.play() }
    }

    /// `processSeconds` is measured from key release, not from capture start: that is the
    /// wait the user actually experiences, and the only number on which a streaming engine
    /// and a batch engine can be compared fairly.
    private func recordRun(
        _ utterance: Utterance,
        text: String,
        rawText: String,
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
        let audio = utterance.recorded
        utterance.recorded.removeAll(keepingCapacity: false)
        var run = DictationRun(
            date: releasedAt,
            engine: utterance.engineName,
            audioSeconds: releasedAt.timeIntervalSince(utterance.holdStarted),
            processSeconds: processSeconds,
            text: text,
            corrections: corrections.isEmpty ? nil : corrections,
            deliverySeconds: deliverySeconds,
            cleanup: utterance.cleanupLabel
        )
        run.rawText = rawText
        RunLog.record(run, audio: audio)
    }

    /// Exponential smoothing: each update closes 35 percent of the gap to the new value. At
    /// the capture's cap of 30 updates a second this makes the waveform glide, not strobe.
    private func updateLevel(_ new: Float) {
        level += (new - level) * 0.35
    }

    /// Returns `state` to whatever is still running once a hold has fully finished.
    /// An error message keeps the display until its own timer clears it.
    private func settle() {
        guard current == nil else { return }
        if tails.isEmpty { ModelResidency.shared.idle() }
        if case .error = state { return }
        state = tails.isEmpty ? .idle : .finishing
        if tails.isEmpty { transcript = "" }
    }

    /// Stops an utterance and releases everything it holds, without reporting anything.
    private func abandon(_ utterance: Utterance) {
        utterance.isAborted = true
        utterance.cleanupPipeline?.cancel()
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
        // Strong implicit self: the controller lives for the whole process.
        Task { @MainActor [self] in
            try? await Task.sleep(for: .seconds(3))
            guard current == nil, state == .error(message) else { return }
            state = tails.isEmpty ? .idle : .finishing
            if tails.isEmpty { transcript = "" }
        }
    }
}
