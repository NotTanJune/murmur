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

    /// How far the microphone is from delivering audio, shown on the key before a press.
    enum MicState: Equatable {
        /// Not open: the setting is off, or the keyboard is not on screen.
        case off
        /// Opened, no samples yet.
        case warming
        /// Samples are flowing.
        case live
        /// The last open ended with an error, or never produced audio.
        case failed
    }

    private(set) var state: State = .idle
    /// The microphone's readiness. With "Keep microphone ready" on it opens at each appearance
    /// and stays open until the keyboard goes away; off, it opens at the press.
    private(set) var micState: MicState = .off
    /// The current hold has received its first samples (the pre-roll counts), so the key can
    /// tell "listening" from "pressed, but nothing heard yet".
    private(set) var heardAudio = false
    /// A short line for the talk key: which engine the next press uses and why. Empty when Bark
    /// is ready or not in use.
    private(set) var engineNote = ""
    /// A quick tap locked recording on; the next tap ends it.
    private(set) var isLocked = false
    /// Asked as a dictation is typed: whether its first letter is to be capital, which is the key
    /// plane's shift state. Asking spends a one-shot shift, as a typed capital does. Set by the
    /// view controller to `TypingController.takeShiftForDictation`.
    @ObservationIgnored var takeShift: () -> Bool = { false }
    /// Called right after a dictation is typed, so the shift key and the suggestion strip read
    /// the new text. Set by the view controller.
    @ObservationIgnored var onTextInserted: () -> Void = {}

    @ObservationIgnored private var gesture = HoldGesture()
    @ObservationIgnored private let microphone: WebMicrophone
    /// The start, typed and failed haptics. The view controller attaches them to its view.
    @ObservationIgnored let haptics = KeyboardHaptics()
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
    /// "Keep microphone ready", read at each appearance. A press after the setting changed uses
    /// the old value until the keyboard next appears.
    @ObservationIgnored private var keepsMicrophoneWarm = false
    /// The page's sample rate for the current open; nil until it reports `started`.
    @ObservationIgnored private var captureRate: Double?
    /// Audio from just before a press, kept only while no hold listens. It never leaves memory
    /// except as the start of the next hold's audio, and nothing older than the window is kept.
    @ObservationIgnored private var preRoll = PreRollBuffer(maxSeconds: KeyboardDictation.preRollSeconds)
    /// Touch-down to the first samples the last hold received, in ms (0 when the pre-roll
    /// supplied them). Reported to the Setup tab through `KeyboardStatus`.
    @ObservationIgnored private var lastStartLatencyMs: Int?
    /// This process's Bark load and the warm-up decode after it, in seconds, and the last
    /// delivered hold's release timings. Reported through `KeyboardStatus` and the log.
    @ObservationIgnored private var barkLoadSeconds: Double?
    @ObservationIgnored private var barkWarmupSeconds: Double?
    @ObservationIgnored private var lastReleaseEngineMs: Int?
    @ObservationIgnored private var lastReleaseCleanupMs: Int?
    @ObservationIgnored private var lastReleaseEngine: String?
    /// The keyboard's requested height and the height its view actually got, in points, as last
    /// reported by the view controller (named for the emoji panel, which once asked for more). Evidence for whether the
    /// system honoured the height constraint; written to `KeyboardStatus`.
    @ObservationIgnored private var emojiPanelRequestedHeight: Int?
    @ObservationIgnored private var emojiPanelShownHeight: Int?
    /// The process's physical footprint at the last sample and the largest sample seen, in MB.
    /// Sampled at each appearance, at each hold's end and every `memorySampleSeconds` while
    /// visible; reported through `KeyboardStatus`.
    @ObservationIgnored private var footprintMB: Double?
    @ObservationIgnored private var peakFootprintMB: Double?
    @ObservationIgnored private var memoryTimer: Timer?
    /// The key plane's counters since the keyboard appeared, asked for at each status write. Set
    /// by the view controller; nil until it is.
    @ObservationIgnored var typingReport: (() -> TypingStats)?
    /// When the microphone was last reopened automatically, newest last, for the loop breaker.
    @ObservationIgnored private var reopenTimes: [ContinuousClock.Instant] = []
    @ObservationIgnored private var reopenTask: Task<Void, Never>?
    /// Closes the warm microphone `warmIdleSeconds` after the last hold; restarted by every hold.
    @ObservationIgnored private var idleCloseTask: Task<Void, Never>?
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
    /// How often the footprint is sampled while the keyboard is visible.
    static let memorySampleSeconds: TimeInterval = 10
    /// How much audio before a press a hold starts from, as the Mac's `CaptureRouter` does.
    static let preRollSeconds: Double = 0.3
    /// A warm microphone that stopped after delivering audio is reopened after this long, at
    /// most `maxAutoReopens` times in `autoReopenWindow`.
    static let autoReopenDelay: Duration = .seconds(1)
    static let maxAutoReopens = 3
    static let autoReopenWindow: Duration = .seconds(30)
    /// With "Keep microphone ready" on, the microphone closes this long after the last hold
    /// finished (or after the keyboard appeared, if no hold has run), and the next press opens
    /// it cold. An open microphone keeps the Dynamic Island's indicator lit, so it does not stay
    /// open for as long as the keyboard is up.
    static let warmIdleSeconds: TimeInterval = 30
    @ObservationIgnored private static let log = Logger(subsystem: "ai.pivotstudio.murmur", category: "speech")

    /// Everything one press owns. Audio flows microphone → `pending` (until both the page's
    /// rate and the engine's format are known) → converter → `audio` stream → engine, and
    /// every converted chunk is also kept in `recorded` for the run log.
    private final class Hold {
        let engine: any TranscriptionEngine
        let engineName: String
        let usesBark: Bool
        /// The short name the Setup tab shows beside the release timings.
        var releaseLabel = ""
        let pressed = Date()
        /// Monotonic touch-down instant, taken before any settings or engine work, for the
        /// start latency; `pressed` is a wall-clock date for the run.
        let pressedAt: ContinuousClock.Instant
        /// The hold has received its first samples, from the pre-roll or live.
        var heardAudio = false
        /// The start tone has played (or sounds are off) for this hold.
        var startTonePlayed = false
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

        init(engine: any TranscriptionEngine, engineName: String, usesBark: Bool, pressedAt: ContinuousClock.Instant) {
            self.pressedAt = pressedAt
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
        microphone.onModeConfirmed = { [weak self] _ in self?.writeStatus() }
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
        // A new process starts with no measurement; keep the last one the Setup tab shows.
        if lastStartLatencyMs == nil || lastReleaseEngine == nil || barkLoadSeconds == nil {
            let previous = KeyboardStatus.read()
            if lastStartLatencyMs == nil { lastStartLatencyMs = previous?.lastStartLatencyMs }
            // The last known load stays on the Setup tab until this process's own load completes.
            if barkLoadSeconds == nil {
                barkLoadSeconds = previous?.barkLoadSeconds
                barkWarmupSeconds = previous?.barkWarmupSeconds
            }
            if lastReleaseEngine == nil {
                lastReleaseEngineMs = previous?.lastReleaseEngineMs
                lastReleaseCleanupMs = previous?.lastReleaseCleanupMs
                lastReleaseEngine = previous?.lastReleaseEngine
            }
        }
        self.hasFullAccess = hasFullAccess
        isVisible = true
        // A failure message belongs to the last time the keyboard was up.
        if case .failed = state { state = .idle }
        // The setting was just re-read above. On, the microphone opens now, ahead of the model
        // work below, so a press finds it already delivering audio; off, it opens at the press.
        keepsMicrophoneWarm = Settings.shared.alwaysOpenMic
        // Diagnostics only: which of the keyboard's extras ran under a typing test.
        TypingDiagnostics.log("appear", [
            "t": ProcessInfo.processInfo.systemUptime,
            "warmMic": keepsMicrophoneWarm, "haptics": Settings.shared.hapticsEnabled,
        ])
        if keepsMicrophoneWarm {
            openMicrophone()
            scheduleIdleClose()
        }
        Task { await AppleSpeechEngine.prewarm() }
        loadBarkIfAllowed()
        recordMemory()
        startMemorySampling()
        writeStatus()
    }

    /// The keyboard went away. A hold still in flight is thrown away: `abandonHold` clears
    /// `hold`, and `finish` types and records only while its hold is still the current one,
    /// so an abandoned hold leaves no text and no run.
    func keyboardDisappeared() {
        isVisible = false
        memoryTimer?.invalidate()
        memoryTimer = nil
        reopenTask?.cancel()
        idleCloseTask?.cancel()
        idleCloseTask = nil
        if hold != nil { abandonHold(reason: "keyboard closed") }
        gesture.reset()
        closeMicrophone()
        micState = .off
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
            do {
                // Every controller in this process waits for the same load and warm-up, so none
                // marks Bark ready, or runs a real hold on the shared models, while the
                // warm-up decode is still using them.
                let preparation = try await Self.barkPreparationTask().value
                barkLoadSeconds = preparation.loadSeconds
                barkWarmupSeconds = preparation.warmupSeconds
                barkReady = true
                reportLoad(.ready)
                // The keyboard went away mid-load and left the marker armed. The load has now
                // finished without killing the process, so nothing else would clear it.
                if !isVisible, Self.armedByThisProcess {
                    Self.marker.disarm()
                    Self.armedByThisProcess = false
                }
            } catch {
                Self.log.error("Bark is not ready: \(error.localizedDescription, privacy: .public)")
                reportLoad(.failed)
            }
        }
    }

    /// What one process's Bark preparation took: the model load and, when it ran, the warm-up
    /// decode after it.
    private struct BarkPreparation: Sendable {
        let loadSeconds: Double
        let warmupSeconds: Double?
    }

    private enum BarkPreparationError: LocalizedError {
        case warmupTimedOut

        var errorDescription: String? {
            "the warm-up decode did not finish within \(Int(KeyboardDictation.warmupTimeoutSeconds)) s"
        }
    }

    /// How long the warm-up decode may run before Bark is given up on for this process.
    nonisolated static let warmupTimeoutSeconds: Double = 15

    /// The process-wide preparation, created once. `ParakeetModels.isLoaded` turns true as soon
    /// as the load returns, before the warm-up ends, so a second controller cannot use it as the
    /// sign that Bark is ready; it waits on this task instead. Only this task arms the crash
    /// marker. A failed load clears it so a later controller may try again; a warm-up timeout
    /// stays cached, so a second warm-up never overlaps the one still running.
    @ObservationIgnored private static var barkPreparation: Task<BarkPreparation, Error>?

    private static func barkPreparationTask() -> Task<BarkPreparation, Error> {
        if let barkPreparation { return barkPreparation }
        let task = Task { () throws -> BarkPreparation in
            marker.arm()
            armedByThisProcess = true
            let loadStarted = ContinuousClock.now
            do {
                _ = try await ParakeetModels.barkClean.loadedModels()
            } catch {
                barkPreparation = nil
                marker.disarm()
                armedByThisProcess = false
                throw error
            }
            let loadSeconds = seconds(since: loadStarted)
            // `manager()` has already decoded a second of silence on these models, which is the
            // whole of the batch path, so the extra pass runs only for the windowed engine: it
            // is the one that goes through `OverlapWindowRecognizer`'s own `AsrManager`. It runs
            // with `barkReady` still false everywhere, so a press goes to Apple's transcriber
            // and nothing else touches the models. The marker stays armed through it.
            var warmupSeconds: Double?
            if Settings.shared.transcribeTiming == .whileSpeaking {
                let warmupStarted = ContinuousClock.now
                guard await warmUpBark(timeout: warmupTimeoutSeconds) else {
                    log.fault("Bark warm-up did not finish in \(Int(warmupTimeoutSeconds)) s; Bark stays off for this process")
                    marker.disarm()
                    armedByThisProcess = false
                    throw BarkPreparationError.warmupTimedOut
                }
                warmupSeconds = seconds(since: warmupStarted)
            }
            let warmupText = warmupSeconds.map { String(format: "%.2f s", $0) } ?? "skipped"
            log.info("Bark loaded in \(loadSeconds, format: .fixed(precision: 2))s, warm-up \(warmupText, privacy: .public)")
            return BarkPreparation(loadSeconds: loadSeconds, warmupSeconds: warmupSeconds)
        }
        barkPreparation = task
        return task
    }

    /// One throwaway decode of a second of silence through the engine a Bark hold would use
    /// (`makeBarkEngine`), so the first real hold finds its recognizer and the Neural Engine's
    /// compute plan already exercised. It goes through the hold's recognizer, which wraps the
    /// same `AsrModels` in a manager of its own. A failure is logged and does not stop Bark from
    /// being used: the first hold would then pay the cost, as it did before. Returns false only
    /// when the decode had not finished after `timeout` seconds; it is an unstructured task
    /// raced against a sleep, resumed once, because the decode does not honour cancellation.
    private static func warmUpBark(timeout: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let sleeper = Task {
                try? await Task.sleep(for: .seconds(timeout))
                // A cancelled sleep means the decode finished first.
                guard !Task.isCancelled else { return }
                once.resume(false)
            }
            Task {
                await decodeSilence()
                once.resume(true)
                sleeper.cancel()
            }
        }
    }

    private static func decodeSilence() async {
        let engine = makeBarkEngine(Settings.shared)
        do {
            let frames: AVAudioFrameCount = 16_000
            guard let format = await engine.preferredInputFormat(),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let channel = buffer.floatChannelData?[0] else {
                log.error("Bark warm-up skipped: no silence buffer")
                return
            }
            buffer.frameLength = frames
            channel.update(repeating: 0, count: Int(frames))
            let transcripts = try await engine.start()
            let reader = Task { for try await _ in transcripts {} }
            await engine.feed(AudioChunk(buffer: buffer))
            await engine.finish()
            try await reader.value
        } catch {
            await engine.finish()
            log.error("Bark warm-up failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Resumes a checked continuation at most once, from whichever of two tasks gets there first.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    /// The engine a Bark hold uses: windowed while speaking, or one decode at release.
    private static func makeBarkEngine(_ settings: Settings) -> any TranscriptionEngine {
        settings.transcribeTiming == .whileSpeaking
            ? IncrementalParakeetEngine(models: .barkClean) : ParakeetEngine(models: .barkClean)
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private static func note(for state: KeyboardStatus.BarkState) -> String {
        switch state {
        case .loading: "Loading Bark · Apple until ready"
        case .notDownloaded: "Bark not downloaded · using Apple"
        case .stoppedLastTime: "Bark stopped last time · using Apple"
        case .failed: "Bark failed to load · using Apple"
        case .ready, .off: ""
        }
    }

    /// The line under "Murmur" while idle: what is not ready yet, or nil when everything is.
    /// The microphone comes first because it decides whether the next press hears anything.
    var readinessCaption: String? {
        if micState == .warming { return "Starting microphone…" }
        if micState == .failed { return "Microphone paused · press to start" }
        return engineNote.isEmpty ? nil : engineNote
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
        let typing = typingReport?()
        KeyboardStatus(
            barkState: barkState.rawValue, hasFullAccess: hasFullAccess, lastSeen: Date(),
            lastStartLatencyMs: lastStartLatencyMs,
            barkLoadSeconds: barkLoadSeconds, barkWarmupSeconds: barkWarmupSeconds,
            lastReleaseEngineMs: lastReleaseEngineMs, lastReleaseCleanupMs: lastReleaseCleanupMs,
            lastReleaseEngine: lastReleaseEngine,
            captureMode: microphone.confirmedMode?.rawValue,
            emojiPanelRequestedHeight: emojiPanelRequestedHeight,
            emojiPanelShownHeight: emojiPanelShownHeight,
            footprintMB: footprintMB, peakFootprintMB: peakFootprintMB,
            typingTouchDowns: typing?.touchDowns, typingTyped: typing?.typed,
            typingCancelled: typing?.cancelled, typingOffKey: typing?.offKey,
            typingSlowestHandleMs: typing?.slowestHandleMs,
            typingMaxDeliveryMs: typing?.maxDeliveryMs,
            typingSlowestAutocorrectMs: typing?.slowestAutocorrectMs,
            predictionState: typing?.predictionState,
            predictionLoadSeconds: typing?.predictionLoadSeconds,
            predictionLastMs: typing?.predictionLastMs,
            predictionFootprintMB: typing?.predictionFootprintMB,
            predictionAnswers: typing?.predictionAnswers, predictionStale: typing?.predictionStale,
            stripPasses: typing?.stripPasses, stripPassesWithPrediction: typing?.stripPassesWithPrediction,
            predictionFreeMB: typing?.predictionFreeMB
        ).write()
    }

    /// Takes one footprint sample and keeps the peak. It does not write the status file; callers
    /// that are not about to write it use `sampleMemory`.
    private func recordMemory() {
        let current = MemoryProbe.footprintMB()
        guard current > 0 else { return }
        footprintMB = current
        peakFootprintMB = max(peakFootprintMB ?? 0, current)
    }

    private func sampleMemory() {
        recordMemory()
        writeStatus()
    }

    /// Samples every `memorySampleSeconds` while the keyboard is visible. A timer in the common
    /// run-loop modes, because the default mode stops while a `ScrollView` tracks a finger (the
    /// emoji and history panels), which is when the footprint matters most.
    private func startMemorySampling() {
        memoryTimer?.invalidate()
        let timer = Timer(timeInterval: Self.memorySampleSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleMemory() }
        }
        RunLoop.main.add(timer, forMode: .common)
        memoryTimer = timer
    }

    /// The view controller laid the keyboard out: `requested` is the height constraint's
    /// constant (the key page's height, which the emoji and history panels share), `shown` the
    /// height the keyboard actually has. Logged and written to the status file only when the
    /// pair changes, so the Setup tab shows the last one. (The field names keep "emojiPanel"
    /// because the status file already carries them.)
    func noteEmojiPanelHeight(requested: CGFloat, shown: CGFloat) {
        let requested = Int(requested.rounded())
        let shown = Int(shown.rounded())
        guard requested != emojiPanelRequestedHeight || shown != emojiPanelShownHeight else { return }
        emojiPanelRequestedHeight = requested
        emojiPanelShownHeight = shown
        Self.log.info("keyboard height: \(requested) pt requested, \(shown) pt shown")
        writeStatus()
    }

    // MARK: Touches on the talk key

    /// Touch down starts recording at once, so a hold loses nothing to the tap check.
    func touchDown() {
        let instant = ContinuousClock.now
        switch gesture.touchDown(at: Date(), busy: hold != nil || isTearingDown) {
        case .start: pressDown(at: instant)
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

    private func pressDown(at pressedAt: ContinuousClock.Instant) {
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
            engine = Self.makeBarkEngine(settings)
            name = SpeechEngineChoice.barkClean.displayName
        case .apple:
            engine = AppleSpeechEngine(dictionaryPhrases: { await MainActor.run { DictionaryStore.shared.biasPhrases } })
            name = Self.appleName(settings: settings, barkState: barkState)
        }
        let hold = Hold(engine: engine, engineName: name, usesBark: choice == .bark, pressedAt: pressedAt)
        hold.releaseLabel = choice == .bark ? "Bark" : (settings.engine == .barkClean ? "Apple (standing in for Bark)" : "Apple")
        // As the Mac: the pipeline only with Apple Intelligence on, and only in the General
        // profile (Email and Notes place greetings from the whole text).
        if Self.usesAppleIntelligence(settings), settings.cleanupProfile == .general {
            FoundationModelFormatter.prewarm()
            hold.pipeline = CleanupPipeline(formatter: FoundationModelFormatter())
        }
        self.hold = hold
        isLocked = false
        heardAudio = false
        state = .recording(level: 0)
        // A hold is in progress: the idle clock starts again when it is over.
        idleCloseTask?.cancel()
        idleCloseTask = nil
        // Listen first; the engine catches up from `pending`. A warm microphone hands over its
        // pre-roll here, a cold one opens now.
        let micWasLive = micState == .live
        attachMicrophone(to: hold)
        // Wakes the Taptic Engine for the start tap; after the attach, so capture comes first.
        haptics.prepareStart()
        // The start tone says "go ahead and talk", so it plays only once the microphone hears:
        // here when it was already live (a warm microphone, `.warming` has no audio yet and
        // waits), otherwise at the hold's first live samples (`noteHeard`). After the attach,
        // as on the Mac, and dispatched off the main actor so it cannot delay capture.
        if micWasLive || hold.heardAudio { playStartTone(hold) }

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
        releaseMicrophone()
        haptics.prepareOutcome()
        state = .finishing
        hold.finishWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.teardownTimeoutSeconds))
            guard !Task.isCancelled else { return }
            self?.holdTimedOut(hold, phase: "finishing")
        }
        hold.finishTask = Task { await finish(hold) }
    }

    private func captureStarted(rate: Double) {
        captureRate = rate
        // A released hold has its rate already; a reopen during `.finishing` (a route change
        // from 48 kHz to 16 kHz, say) must not relabel samples it has converted or pending.
        guard let hold, hold.released == nil else { return }
        hold.captureRate = rate
        makeConverterIfReady(hold)
    }

    /// One block from the page, which arrives whether or not a hold is listening. A hold in
    /// progress takes it; between holds it goes into the pre-roll, when the microphone is kept
    /// warm, and is otherwise dropped.
    private func received(_ samples: [Float], level: Float) {
        // The page reports its rate before any audio; without it the samples mean nothing.
        guard let rate = captureRate else { return }
        if micState != .live { micState = .live }
        guard let hold, hold.released == nil else {
            if keepsMicrophoneWarm { preRoll.append(samples, rate: rate) }
            return
        }
        state = .recording(level: level)
        if let converter = hold.converter {
            if let buffer = converter.convert(samples) { hold.send(buffer) }
        } else {
            hold.pending.append(samples)
        }
        if !hold.heardAudio { noteHeard(hold, fromPreRoll: false) }
    }

    /// The hold has its first samples. The key turns from waiting to listening, and the time
    /// from touch-down is recorded (0 when the pre-roll supplied them).
    private func noteHeard(_ hold: Hold, fromPreRoll: Bool) {
        hold.heardAudio = true
        if !fromPreRoll { playStartTone(hold) }
        heardAudio = true
        let elapsed = ContinuousClock.now - hold.pressedAt
        let milliseconds = fromPreRoll ? 0 : Int((elapsed / .milliseconds(1)).rounded())
        let source = fromPreRoll ? "pre-roll" : "live"
        Self.log.info("start latency \(milliseconds, privacy: .public) ms (\(source, privacy: .public))")
        // Written after the press has been handled, and only when the number changed: with a
        // warm microphone it is 0 every time.
        guard lastStartLatencyMs != milliseconds else { return }
        lastStartLatencyMs = milliseconds
        Task { writeStatus() }
    }

    /// The start tone and the start tap, once per hold, each when its setting is on.
    private func playStartTone(_ hold: Hold) {
        guard !hold.startTonePlayed else { return }
        hold.startTonePlayed = true
        if Settings.shared.soundEnabled { KeyboardSounds.play(.start) }
        haptics.started()
    }

    /// Gives a new hold the microphone. Open or opening: the hold takes the pre-roll now and
    /// live samples as they arrive, including ones that have not arrived yet. Not open (the
    /// setting is off, or an earlier open failed): it opens at this press.
    private func attachMicrophone(to hold: Hold) {
        switch micState {
        case .live, .warming:
            if let captureRate { hold.captureRate = captureRate }
            let preRollSeconds = preRoll.seconds
            let (samples, rate) = preRoll.drain()
            Self.log.info("attached to a \(self.micState == .live ? "live" : "warming", privacy: .public) microphone with \(preRollSeconds, format: .fixed(precision: 3)) s of pre-roll")
            if !samples.isEmpty, let rate {
                hold.captureRate = rate
                hold.pending.append(samples)
                noteHeard(hold, fromPreRoll: true)
            }
        case .off, .failed:
            openMicrophone()
        }
    }

    /// Opens the microphone from scratch. A fresh open starts with no rate and no pre-roll.
    private func openMicrophone() {
        guard micState == .off || micState == .failed else { return }
        reopenTask?.cancel()
        reopenTask = nil
        captureRate = nil
        _ = preRoll.drain()
        micState = .warming
        microphone.open()
    }

    /// Closes the microphone, whatever the setting, and drops the pre-roll with it. A failure
    /// the page reported stays visible in `micState` until the next open.
    private func closeMicrophone() {
        microphone.close()
        captureRate = nil
        _ = preRoll.drain()
        if micState != .failed { micState = .off }
    }

    /// A hold is over: the microphone stays open for the next press when it is kept warm.
    private func releaseMicrophone() {
        if !keepsMicrophoneWarm { closeMicrophone() }
    }

    /// Restarts the clock that closes a warm microphone `warmIdleSeconds` from now. Nothing
    /// is scheduled while a hold is in flight, with the setting off, or off screen; the end of
    /// each hold calls it again. The close is not a failure: the microphone goes to `off`, the
    /// caption shows nothing, and the next press opens it cold (`attachMicrophone`).
    private func scheduleIdleClose() {
        idleCloseTask?.cancel()
        idleCloseTask = nil
        guard keepsMicrophoneWarm, isVisible, hold == nil else { return }
        idleCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.warmIdleSeconds))
            guard !Task.isCancelled, let self else { return }
            self.closeIdleMicrophone()
        }
    }

    private func closeIdleMicrophone() {
        idleCloseTask = nil
        // Never reopen here and never close under a hold.
        guard isVisible, hold == nil else { return }
        // A hold's engine is still being wound down: the hold is over, so count from now again.
        if isTearingDown {
            scheduleIdleClose()
            return
        }
        // A pending automatic reopen would open the microphone with no idle clock behind it
        // (a microphone that ended just before this deadline leaves `failed` and a reopen).
        // The idle window is over, so the reopen goes; the failed state and its message stay
        // until a press.
        reopenTask?.cancel()
        reopenTask = nil
        guard micState == .live || micState == .warming else { return }
        Self.log.info("microphone idle for \(Int(Self.warmIdleSeconds)) s; closing it")
        closeMicrophone()
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
        // Had this open delivered audio? A microphone that worked and then stopped (a content
        // process kill, a call or Siri, a lapsed heartbeat, backgrounding) is transient; one
        // that never delivered audio is a permissions problem.
        let hadAudio = micState == .live
        // The page has already stopped; what it heard before is not worth keeping.
        micState = .failed
        captureRate = nil
        _ = preRoll.drain()
        if let hold, hold.released == nil {
            // A hold still listening cannot finish without its audio. The permissions message
            // is for a microphone that never delivered any; one that worked and stopped is a
            // generic failure, and the key reopens it as it does when idle.
            fail(hold, hadAudio ? .dictation : .microphone, message)
            if hadAudio { scheduleReopen() }
            return
        }
        Self.log.error("\(message, privacy: .public)")
        // A hold that is already released has its audio complete and `finish` is typing it, so
        // the microphone ending now must not abandon a dictation the user has finished.
        if hold == nil, !hadAudio {
            state = .failed(.microphone)
            return
        }
        if hadAudio { scheduleReopen() }
    }

    /// Reopens a warm microphone that stopped after working, once, a second later. At most
    /// `maxAutoReopens` times in `autoReopenWindow`, so something that keeps taking the
    /// microphone away is not fought in a loop (as the Mac's loop breaker); after that only a
    /// press reopens it.
    private func scheduleReopen() {
        guard keepsMicrophoneWarm, isVisible else { return }
        let now = ContinuousClock.now
        reopenTimes.removeAll { now - $0 > Self.autoReopenWindow }
        guard reopenTimes.count < Self.maxAutoReopens else {
            Self.log.error("microphone ended \(Self.maxAutoReopens) times in \(Int(Self.autoReopenWindow / .seconds(1))) s; waiting for a press")
            return
        }
        reopenTimes.append(now)
        reopenTask?.cancel()
        reopenTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autoReopenDelay)
            guard !Task.isCancelled, let self else { return }
            guard self.isVisible, self.keepsMicrophoneWarm, self.micState == .failed else { return }
            Self.log.info("reopening the microphone")
            self.openMicrophone()
            // A reopen after the idle clock ran out has no clock behind it otherwise.
            if self.idleCloseTask == nil { self.scheduleIdleClose() }
        }
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
        // Release to the engine's final text: the engine's tail, plus any setup the release
        // still waited on.
        let engineDoneAt = Date()
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
                if settings.soundEnabled { KeyboardSounds.play(.done) }
                haptics.typed()
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
                noteReleaseTimings(
                    engine: hold.releaseLabel,
                    engineSeconds: engineDoneAt.timeIntervalSince(released),
                    cleanupSeconds: readyAt.timeIntervalSince(engineDoneAt))
                if hold.usesBark {
                    Self.marker.disarm()
                    Self.armedByThisProcess = false
                }
            }
        } else if hold.converter == nil {
            // Released before any audio arrived: the microphone never opened for this hold.
            Self.log.error("no audio reached the hold; the microphone never opened")
            state = .failed(.microphone)
            haptics.failed()
        } else {
            Self.log.info("\(hold.engineName, privacy: .public): no speech")
        }
        hold.recorded.removeAll(keepingCapacity: false)
        self.hold = nil
        if case .failed = state {} else { state = .idle }
        sampleMemory()
        scheduleIdleClose()
    }

    /// Where a delivered hold's release time went: the engine, then cleanup and the dictionary.
    /// Written to the status file for the Setup tab and to the log.
    private func noteReleaseTimings(engine: String, engineSeconds: Double, cleanupSeconds: Double) {
        let engineMs = Int((engineSeconds * 1000).rounded())
        let cleanupMs = Int((cleanupSeconds * 1000).rounded())
        lastReleaseEngine = engine
        lastReleaseEngineMs = engineMs
        lastReleaseCleanupMs = cleanupMs
        Self.log.info("release: \(engineMs) ms speech (\(engine, privacy: .public)) + \(cleanupMs) ms cleanup")
        writeStatus()
    }

    private func fail(_ hold: Hold, _ kind: Failure, _ message: String) {
        guard self.hold === hold else { return }
        Self.log.error("hold failed: \(message, privacy: .public)")
        releaseMicrophone()
        state = .failed(kind)
        haptics.failed()
        abandonHold(reason: message)
        scheduleIdleClose()
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
            releaseMicrophone()
            self.hold = nil
            gesture.reset()
            isLocked = false
            state = .failed(.dictation)
            haptics.failed()
            scheduleIdleClose()
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
        if takeShift() {
            output = output.prefix(1).uppercased() + output.dropFirst()
        }
        if let last = proxy.documentContextBeforeInput?.last,
           last.isLetter || last.isNumber || ".,!?;:".contains(last) {
            output = " " + output
        }
        proxy.insertText(output)
        onTextInserted()
        return Date()
    }
}
