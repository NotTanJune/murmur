import AVFoundation
import MurmurKit
import Observation
import OSLog
import UIKit

/// One keyboard's dictation: which engine hears a hold, the hold's lifecycle from touch-down
/// to inserted text, and the run it leaves in the log.
///
/// Bark Clean when it has finished loading, Apple's transcriber otherwise (still loading, not
/// downloaded, or the crash marker says Bark killed the keyboard last time), as the Mac's
/// `Utterance.standIn` does. The choice itself is `KeyboardEngineChoice`, tested on the Mac.
@MainActor
@Observable
final class KeyboardDictation {
    enum State: Equatable {
        case idle
        case recording(level: Float)
        case finishing
        case failed(Failure)
    }

    /// Why the last hold failed, for the key's message. The detail goes to the log, never to
    /// the key.
    enum Failure: Equatable {
        /// The microphone did not open or delivered no audio: permissions or Full Access.
        case microphone
        /// Anything else: the engine would not start, the audio could not be converted, or
        /// the hold stopped answering.
        case dictation
    }

    private(set) var state: State = .idle
    /// A short line for the talk key: which engine the next press uses and why.
    private(set) var engineNote = ""
    /// A quick tap locked recording on; the next tap ends it.
    private(set) var isLocked = false
    /// ⇧ was tapped: the next dictation starts with a capital.
    var shiftNext = false

    @ObservationIgnored private var gesture = HoldGesture()
    @ObservationIgnored private let microphone: WebMicrophone
    /// Nil once the view controller that owns the proxy is gone; nothing is typed then.
    @ObservationIgnored private let proxy: () -> UITextDocumentProxy?
    /// Read from the view controller at each appearance, never later: a Bark load or a finishing
    /// hold can outlive the controller.
    @ObservationIgnored private var hasFullAccess = false
    /// Between `keyboardAppeared` and `keyboardDisappeared`. A Bark load that finishes while the
    /// keyboard is hidden has no later disappearance to clear the crash marker.
    @ObservationIgnored private var isVisible = false
    /// One per process: a second keyboard instance in the same process must not read the marker
    /// this process armed itself as a sign that the last process died.
    @ObservationIgnored private static let marker = CrashMarker(directory: AppStorage.directory)
    /// Whether this process armed the marker. Only a marker this process armed is disarmed when
    /// the keyboard goes away; one found armed at launch stays until the app's "try Bark again"
    /// button clears it, or the next launch would load Bark into the same kill.
    @ObservationIgnored private static var armedByThisProcess = false
    /// The app's "Try Bark again" button deleted a marker this process found armed at launch.
    /// `wasArmedAtLaunch` is a per-process snapshot, so the live file is checked at each
    /// appearance (`noteMarkerClearedByApp`).
    @ObservationIgnored private static var markerClearedByApp = false
    /// Whether the marker found at launch still forbids loading Bark.
    private static var markerBlocksBark: Bool { marker.wasArmedAtLaunch && !markerClearedByApp }
    @ObservationIgnored private var barkState = KeyboardStatus.BarkState.off
    @ObservationIgnored private var barkReady = false
    @ObservationIgnored private var barkLoadStarted = false
    /// How this process's Bark load stands (`loading`, `ready` or `failed`), kept apart from
    /// `barkState` so that an engine setting that leaves Bark and returns can report it again.
    @ObservationIgnored private var barkLoadState: KeyboardStatus.BarkState?
    /// The engine setting `loadBarkIfAllowed` last acted on, so a press re-evaluates Bark only
    /// when the setting has changed since.
    @ObservationIgnored private var evaluatedEngine: SpeechEngineChoice?
    /// Bumped when a teardown is abandoned by its watchdog, so the late completion of that
    /// teardown does not clear the busy state of a later one.
    @ObservationIgnored private var teardownGeneration = 0
    @ObservationIgnored private var hold: Hold?
    /// True from an abandon until its engine has been wound down. A new press waits for it
    /// (it is treated as busy), so two holds never use the shared model at once.
    private var isTearingDown = false
    /// The longest a hold runs, in seconds. At the limit the hold finishes normally: what was
    /// said is typed and recorded, as if the key had come up. It bounds the audio kept in memory
    /// (the engine, the recording and the run log each hold a copy).
    static let maxHoldSeconds: TimeInterval = 300
    /// How long a release's finish or an abandon's teardown may run before the hold is dropped.
    /// A stuck engine would otherwise leave the talk key busy for the life of the process.
    static let teardownTimeoutSeconds: TimeInterval = 20
    @ObservationIgnored private static let log = Logger(subsystem: "ai.pivotstudio.murmur", category: "speech")

    /// Everything one press owns. Audio flows microphone → `pending` (until both the page's
    /// rate and the engine's format are known) → converter → `audio` stream → engine, and
    /// every converted chunk is also kept in `recorded` for the run log.
    private final class Hold {
        let engine: any TranscriptionEngine
        let engineName: String
        let usesBark: Bool
        let pressed = Date()
        var released: Date?
        var captureRate: Double?
        var target: AVAudioFormat?
        var converter: PCMConverter?
        var pending: [[Float]] = []
        var recorded: [AudioChunk] = []
        let audio: AsyncStream<AudioChunk>
        let audioIn: AsyncStream<AudioChunk>.Continuation
        /// Asks the engine for its format and starts it; `feeder` and `reader` exist once it ends.
        var setup: Task<Void, Never>?
        var feeder: Task<Void, Never>?
        var reader: Task<String, Error>?
        /// Set when the hold was thrown away (failure, keyboard closed). Nothing from an
        /// abandoned hold is typed or recorded.
        var isAbandoned = false
        /// Set just before `finish` calls `engine.finish()`, so an abandon that comes later does
        /// not end the engine a second time (the batch engine would decode twice).
        var engineFinishStarted = false
        /// The release's `finish(_:)` task, which an abandon waits for before touching the engine.
        var finishTask: Task<Void, Never>?
        /// Ends the hold at `maxHoldSeconds` as if the key had come up.
        var limit: Task<Void, Never>?
        /// Drops the hold if the release's `finish` has not completed `teardownTimeoutSeconds`
        /// after release.
        var finishWatchdog: Task<Void, Never>?
        /// Drops the hold if its teardown has not completed `teardownTimeoutSeconds` after the
        /// abandon.
        var teardownWatchdog: Task<Void, Never>?
        /// Cleans finished sentences while the key is held; only with Apple Intelligence, as on
        /// the Mac.
        var pipeline: CleanupPipeline?

        init(engine: any TranscriptionEngine, engineName: String, usesBark: Bool) {
            self.engine = engine
            self.engineName = engineName
            self.usesBark = usesBark
            (audio, audioIn) = AsyncStream<AudioChunk>.makeStream()
        }

        /// Hands a converted buffer to the engine and keeps it for the recording.
        func send(_ buffer: AVAudioPCMBuffer) {
            let chunk = AudioChunk(buffer: buffer)
            recorded.append(chunk)
            audioIn.yield(chunk)
        }
    }

    init(
        microphone: WebMicrophone,
        proxy: @escaping () -> UITextDocumentProxy?
    ) {
        self.microphone = microphone
        self.proxy = proxy
        microphone.onStarted = { [weak self] rate in self?.captureStarted(rate: rate) }
        microphone.onSamples = { [weak self] samples, level in self?.received(samples, level: level) }
        microphone.onEnded = { [weak self] reason in self?.captureEnded(reason) }
    }

    // MARK: Keyboard lifecycle

    /// True while a press would be ignored: the last hold is finishing or its engine is being
    /// wound down. The talk key shows it as dimmed and not pressable.
    var isBusy: Bool {
        if case .finishing = state { return true }
        return isTearingDown
    }

    func keyboardAppeared(hasFullAccess: Bool) {
        // The app writes the settings and this process outlives the change: read them again.
        Settings.shared.reloadFromDefaults()
        // A keyboard that ran before the app ever launched has no working watcher on a
        // dictionary file the app seeds later.
        DictionaryStore.shared.reload()
        noteMarkerClearedByApp()
        self.hasFullAccess = hasFullAccess
        isVisible = true
        // A failure message belongs to the last time the keyboard was up.
        if case .failed = state { state = .idle }
        Task { await AppleSpeechEngine.prewarm() }
        loadBarkIfAllowed()
        writeStatus()
    }

    /// The keyboard went away. A hold still in flight is thrown away: `abandonHold` clears
    /// `hold`, and `finish` types and records only while its hold is still the current one,
    /// so an abandoned hold leaves no text and no run.
    func keyboardDisappeared() {
        isVisible = false
        if hold != nil { abandonHold(reason: "keyboard closed") }
        gesture.reset()
        microphone.stop()
        if case .failed = state {} else { state = .idle }
        // Going away normally means Bark did not kill this process, but only once it has loaded:
        // a keyboard that closes mid-load leaves the marker armed, since the load is the
        // riskiest window.
        if Self.armedByThisProcess, barkReady {
            Self.marker.disarm()
            Self.armedByThisProcess = false
        }
    }

    /// If this process found the marker armed at launch and did not arm it since, a missing file
    /// means the app's "Try Bark again" cleared it: Bark may load again, subject to the setting.
    private func noteMarkerClearedByApp() {
        guard Self.marker.wasArmedAtLaunch, !Self.markerClearedByApp,
              !Self.armedByThisProcess, !Self.marker.isArmed else { return }
        Self.markerClearedByApp = true
        Self.log.info("crash marker cleared by the app; Bark may load again")
    }

    private func loadBarkIfAllowed() {
        let setting = Settings.shared.engine
        evaluatedEngine = setting
        guard setting == .barkClean else {
            // A load in flight or a loaded model stays where it is; only the report changes.
            setBarkState(.off, note: "")
            return
        }
        guard !barkLoadStarted else {
            // Back on Bark after a spell on Apple: report how the earlier load stands.
            let state = barkLoadState ?? .loading
            setBarkState(state, note: Self.note(for: state))
            return
        }
        guard BarkModelStore.isDownloaded else {
            setBarkState(.notDownloaded, note: Self.note(for: .notDownloaded))
            return
        }
        guard !Self.markerBlocksBark else {
            setBarkState(.stoppedLastTime, note: Self.note(for: .stoppedLastTime))
            return
        }
        barkLoadStarted = true
        reportLoad(.loading)
        Task {
            // A second keyboard in this process finds Bark already loaded; arming again would
            // blame a later death on a load that is long finished.
            if await ParakeetModels.barkClean.isLoaded {
                barkReady = true
                reportLoad(.ready)
                return
            }
            Self.marker.arm()
            Self.armedByThisProcess = true
            do {
                _ = try await ParakeetModels.barkClean.loadedModels()
                barkReady = true
                reportLoad(.ready)
                // The keyboard went away mid-load and left the marker armed. The load has now
                // finished without killing the process, so nothing else would clear it.
                if !isVisible, Self.armedByThisProcess {
                    Self.marker.disarm()
                    Self.armedByThisProcess = false
                }
            } catch {
                Self.log.error("Bark failed to load: \(error.localizedDescription, privacy: .public)")
                reportLoad(.failed)
                Self.marker.disarm()
                Self.armedByThisProcess = false
            }
        }
    }

    private static func note(for state: KeyboardStatus.BarkState) -> String {
        switch state {
        case .loading: "Apple · Bark loading"
        case .notDownloaded: "Apple · Bark not downloaded"
        case .stoppedLastTime: "Apple · Bark stopped last time"
        case .failed: "Apple · Bark failed to load"
        case .ready, .off: ""
        }
    }

    /// Records how this process's Bark load stands. It is reported as `off` when the setting
    /// has meanwhile left Bark, because the keyboard then does not use it.
    private func reportLoad(_ state: KeyboardStatus.BarkState) {
        barkLoadState = state
        if Settings.shared.engine == .barkClean {
            setBarkState(state, note: Self.note(for: state))
        } else {
            setBarkState(.off, note: "")
        }
    }

    private func setBarkState(_ new: KeyboardStatus.BarkState, note: String) {
        barkState = new
        engineNote = note
        writeStatus()
    }

    private func writeStatus() {
        KeyboardStatus(barkState: barkState.rawValue, hasFullAccess: hasFullAccess, lastSeen: Date()).write()
    }

    // MARK: Touches on the talk key

    /// Touch down starts recording at once, so a hold loses nothing to the tap check.
    func touchDown() {
        switch gesture.touchDown(at: Date(), busy: hold != nil || isTearingDown) {
        case .start: pressDown()
        case .lock, .finish, .none: break
        }
    }

    /// A short touch locks recording on; a long one is a hold and ends it; a touch that
    /// began while locked ends it.
    func touchUp() {
        switch gesture.touchUp(at: Date()) {
        case .lock:
            if hold != nil { isLocked = true } else { gesture.reset() }
        case .finish: release()
        case .start, .none: break
        }
    }

    /// A tap with no finger: what VoiceOver's double-tap does. It runs the same quick tap the
    /// gesture would, so it starts and locks dictation when idle and ends it when locked, and
    /// does nothing while the last hold is still finishing.
    func toggleDictation() {
        touchDown()
        touchUp()
    }

    // MARK: Hold

    private func pressDown() {
        guard hold == nil, !isTearingDown else { return }
        // The app may have changed a setting since the keyboard appeared (Training, engine).
        let settings = Settings.shared
        settings.reloadFromDefaults()
        // The engine setting may have left or returned to Bark since the keyboard appeared.
        if isVisible, settings.engine != evaluatedEngine { loadBarkIfAllowed() }
        let choice = KeyboardEngineChoice.choose(
            setting: settings.engine, barkReady: barkReady, markerArmed: Self.markerBlocksBark)
        let engine: any TranscriptionEngine
        let name: String
        switch choice {
        case .bark:
            engine = settings.transcribeTiming == .whileSpeaking
                ? IncrementalParakeetEngine(models: .barkClean) : ParakeetEngine(models: .barkClean)
            name = SpeechEngineChoice.barkClean.displayName
        case .apple:
            engine = AppleSpeechEngine(dictionaryPhrases: { await MainActor.run { DictionaryStore.shared.biasPhrases } })
            name = Self.appleName(settings: settings, barkState: barkState)
        }
        let hold = Hold(engine: engine, engineName: name, usesBark: choice == .bark)
        // As the Mac: the pipeline only with Apple Intelligence on, and only in the General
        // profile (Email and Notes place greetings from the whole text).
        if Self.usesAppleIntelligence(settings), settings.cleanupProfile == .general {
            FoundationModelFormatter.prewarm()
            hold.pipeline = CleanupPipeline(formatter: FoundationModelFormatter())
        }
        self.hold = hold
        isLocked = false
        state = .recording(level: 0)
        microphone.start()   // open the microphone first; the engine catches up from `pending`

        hold.limit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxHoldSeconds))
            guard !Task.isCancelled else { return }
            self?.holdLimitReached(hold)
        }
        hold.setup = Task {
            let format = await engine.preferredInputFormat()
            do {
                let transcripts = try await engine.start()
                let reader = Task {
                    var text = ""
                    for try await chunk in transcripts {
                        text = chunk.text
                        if let stable = chunk.stable, !chunk.isFinal {
                            hold.pipeline?.accept(stable: stable)
                        }
                        if chunk.isFinal { break }
                    }
                    return text
                }
                hold.reader = reader
                // `feed` only after `start` returned, one chunk at a time, in capture order.
                hold.feeder = Task {
                    for await chunk in hold.audio { await engine.feed(chunk) }
                }
                if hold.isAbandoned { reader.cancel() }
            } catch {
                self.fail(hold, .dictation, "\(hold.engineName) did not start: \(error.localizedDescription)")
                return
            }
            guard let format else {
                self.fail(hold, .dictation, "\(hold.engineName) has no usable audio format")
                return
            }
            hold.target = format
            self.makeConverterIfReady(hold)
        }
    }

    /// The history name: the engine the setting asks for, with the Mac's stand-in wording when
    /// Apple's transcriber took over for Bark.
    private static func appleName(settings: Settings, barkState: KeyboardStatus.BarkState) -> String {
        let apple = SpeechEngineChoice.apple.displayName
        guard settings.engine == .barkClean else { return apple }
        let reason = switch barkState {
        case .loading, .ready, .off: "preparing"
        case .notDownloaded: "not downloaded"
        case .stoppedLastTime: "stopped last time"
        case .failed: "failed to load"
        }
        return "\(apple) · \(SpeechEngineChoice.barkClean.displayName) \(reason)"
    }

    /// A hold that reached `maxHoldSeconds` ends like a release, and the touch that is still
    /// down or locked is forgotten so its eventual lift does not start or end anything.
    private func holdLimitReached(_ hold: Hold) {
        guard self.hold === hold, hold.released == nil else { return }
        Self.log.info("hold reached \(Self.maxHoldSeconds, format: .fixed(precision: 0)) s; finishing it")
        gesture.reset()
        release()
    }

    private func release() {
        guard let hold, hold.released == nil else { return }
        hold.released = Date()
        hold.limit?.cancel()
        isLocked = false
        microphone.stop()
        state = .finishing
        hold.finishWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.teardownTimeoutSeconds))
            guard !Task.isCancelled else { return }
            self?.holdTimedOut(hold, phase: "finishing")
        }
        hold.finishTask = Task { await finish(hold) }
    }

    private func captureStarted(rate: Double) {
        guard let hold else { return }
        hold.captureRate = rate
        makeConverterIfReady(hold)
    }

    private func received(_ samples: [Float], level: Float) {
        guard let hold, hold.released == nil else { return }
        state = .recording(level: level)
        if let converter = hold.converter {
            if let buffer = converter.convert(samples) { hold.send(buffer) }
        } else {
            hold.pending.append(samples)
        }
    }

    private func makeConverterIfReady(_ hold: Hold) {
        guard !hold.isAbandoned, hold.converter == nil, let rate = hold.captureRate, let target = hold.target else { return }
        guard let converter = PCMConverter(sourceRate: rate, target: target) else {
            fail(hold, .dictation, "cannot convert \(Int(rate)) Hz audio to \(target)")
            return
        }
        hold.converter = converter
        for samples in hold.pending {
            if let buffer = converter.convert(samples) { hold.send(buffer) }
        }
        hold.pending.removeAll()
    }

    private func captureEnded(_ reason: String) {
        let message = "microphone unavailable: \(reason)"
        guard let hold else {
            Self.log.error("\(message, privacy: .public)")
            state = .failed(.microphone)
            return
        }
        fail(hold, .microphone, message)
    }

    private func finish(_ hold: Hold) async {
        defer { hold.finishWatchdog?.cancel() }
        // Start must have returned before the first `feed`, and `finish` comes after the last.
        await hold.setup?.value
        guard self.hold === hold else { return }
        if let tail = hold.converter?.flush() { hold.send(tail) }
        hold.audioIn.finish()
        await hold.feeder?.value
        hold.engineFinishStarted = true
        await hold.engine.finish()
        let released = hold.released ?? Date()

        var raw = ""
        do {
            raw = try await hold.reader?.value ?? ""
        } catch {
            Self.log.error("\(hold.engineName, privacy: .public) transcription failed: \(error.localizedDescription, privacy: .public)")
        }
        guard self.hold === hold else { return }

        let settings = Settings.shared
        let usesAppleIntelligence = Self.usesAppleIntelligence(settings)
        // As the Mac: whitespace-only raw text never reaches the finisher, and the output is
        // typed and filed only when it holds more than whitespace.
        var finished: FinishedText?
        if !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // S1-mini never runs on the phone: that setting reads as the rule pass.
            let formatter: any TextFormatter = usesAppleIntelligence ? FoundationModelFormatter() : RuleBasedFormatter()
            finished = await TranscriptFinisher.finish(
                raw: raw, cleanupEnabled: settings.cleanupEnabled, formatter: formatter,
                pipeline: usesAppleIntelligence ? hold.pipeline : nil, corrector: DictionaryStore.shared.corrector)
            if let pipeline = hold.pipeline, usesAppleIntelligence {
                Self.log.info("cleanup pipeline: \(pipeline.chunkCount) piece(s) cleaned while held")
            }
        }
        let readyAt = Date()

        // The last check before anything leaves this hold: no suspension point lies between it
        // and the insert and the run-log write, so a keyboard that closed during the awaits
        // above has already cleared `self.hold` and nothing is typed or recorded.
        guard self.hold === hold else { return }
        if let finished, !finished.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A gone proxy (its view controller was deallocated) means nowhere to type: the
            // hold is dropped, not filed as delivered.
            if let deliveredAt = insert(finished.text) {
                var run = DictationRun(
                    date: released,
                    engine: hold.engineName,
                    audioSeconds: released.timeIntervalSince(hold.pressed),
                    processSeconds: readyAt.timeIntervalSince(released),
                    text: finished.text,
                    corrections: finished.applied.isEmpty ? nil : finished.applied,
                    deliverySeconds: deliveredAt.timeIntervalSince(released),
                    cleanup: usesAppleIntelligence ? CleanupEngine.appleIntelligence.displayName : nil
                )
                run.rawText = raw
                run.source = .phone
                RunLog.record(run, audio: hold.recorded)
                if hold.usesBark {
                    Self.marker.disarm()
                    Self.armedByThisProcess = false
                }
            }
        } else if hold.converter == nil {
            // Released before any audio arrived: the microphone never opened for this hold.
            Self.log.error("no audio reached the hold; the microphone never opened")
            state = .failed(.microphone)
        } else {
            Self.log.info("\(hold.engineName, privacy: .public): no speech")
        }
        hold.recorded.removeAll(keepingCapacity: false)
        self.hold = nil
        if case .failed = state {} else { state = .idle }
    }

    private func fail(_ hold: Hold, _ kind: Failure, _ message: String) {
        guard self.hold === hold else { return }
        Self.log.error("hold failed: \(message, privacy: .public)")
        microphone.stop()
        state = .failed(kind)
        abandonHold(reason: message)
    }

    /// Whether this hold's text goes through Apple Intelligence: cleanup on, the engine chosen
    /// and the model available. S1-mini never runs on the phone; that setting reads as the rule pass.
    private static func usesAppleIntelligence(_ settings: Settings) -> Bool {
        settings.cleanupEnabled
            && settings.cleanupEngine == .appleIntelligence
            && FoundationModelFormatter.unavailableReason == nil
    }

    /// The release's finish or an abandon's teardown did not complete in time. The hold is
    /// dropped without typing or filing anything, and the key is released. The stuck engine
    /// may still be running; that is the lesser harm next to a key that stays dead until the
    /// process ends.
    private func holdTimedOut(_ hold: Hold, phase: String) {
        Self.log.fault("hold \(hold.engineName, privacy: .public) did not finish \(phase, privacy: .public) within \(Self.teardownTimeoutSeconds, format: .fixed(precision: 0)) s; dropping it")
        hold.isAbandoned = true
        hold.limit?.cancel()
        hold.finishWatchdog?.cancel()
        hold.teardownWatchdog?.cancel()
        hold.setup?.cancel()
        hold.feeder?.cancel()
        hold.reader?.cancel()
        hold.finishTask?.cancel()
        hold.pipeline?.cancel()
        hold.audioIn.finish()
        hold.pending.removeAll()
        hold.recorded.removeAll()
        // A teardown still waiting on this hold must not clear a later one's busy flag.
        teardownGeneration += 1
        isTearingDown = false
        if self.hold === hold {
            microphone.stop()
            self.hold = nil
            gesture.reset()
            isLocked = false
            state = .failed(.dictation)
        }
    }

    /// Throws a hold away. After this `hold` no longer matches the hold's own tasks, which is
    /// what stops `finish` from typing it or recording it.
    private func abandonHold(reason: String) {
        guard let hold else { return }
        self.hold = nil
        hold.isAbandoned = true
        hold.limit?.cancel()
        gesture.reset()
        isLocked = false
        hold.pending.removeAll()
        hold.recorded.removeAll()
        hold.audioIn.finish()
        hold.reader?.cancel()
        hold.pipeline?.cancel()
        Self.log.info("abandoned \(hold.engineName, privacy: .public): \(reason, privacy: .public)")
        // The engine is wound down only after its `start` returned, its feeder drained and, when
        // the release's `finish` is already running, that task is done; `finish` calling
        // `engine.finish()` first is not repeated. Until then a new press counts as busy, so the
        // abandoned hold and the next one never use the shared model together.
        isTearingDown = true
        teardownGeneration += 1
        let generation = teardownGeneration
        hold.teardownWatchdog?.cancel()
        hold.teardownWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.teardownTimeoutSeconds))
            guard !Task.isCancelled else { return }
            self?.holdTimedOut(hold, phase: "teardown")
        }
        Task {
            await hold.setup?.value
            await hold.finishTask?.value
            await hold.feeder?.value
            if !hold.engineFinishStarted {
                hold.engineFinishStarted = true
                await hold.engine.finish()
            }
            hold.teardownWatchdog?.cancel()
            // A watchdog that dropped this hold has already moved the generation on.
            if teardownGeneration == generation { isTearingDown = false }
        }
    }

    /// Types `text`, with a space first when it would otherwise run into the word before.
    /// Returns when it was typed, or nil when the text proxy is gone.
    private func insert(_ text: String) -> Date? {
        guard let proxy = proxy() else { return nil }
        var output = text
        if shiftNext {
            output = output.prefix(1).uppercased() + output.dropFirst()
            shiftNext = false
        }
        if let last = proxy.documentContextBeforeInput?.last,
           last.isLetter || last.isNumber || ".,!?;:".contains(last) {
            output = " " + output
        }
        proxy.insertText(output)
        return Date()
    }
}
