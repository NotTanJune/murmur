import Foundation
import MurmurKit
import MurmurTyping
import OSLog
import os

/// Owns the keyboard's language model (`NextWordPredictor`): when it loads, where it runs, and
/// what happens when it cannot. The strip works without it, on the pair model, exactly as before
/// the model existed; everything here only ever adds a better answer a moment later.
///
/// **One per process (`shared`).** iOS makes a new input view controller, and with it a new
/// `TypingController`, at many appearances (a screenshot, a change of app or of field). The model
/// first belonged to the controller, so a controller replaced during a load threw the load away
/// and left the crash marker armed. A load or a prediction now outlives the controller that
/// asked, and each answer goes to the reply of the request it was made for.
///
/// **It loads when the keyboard appears, ahead of Bark.** The model first loaded at the first
/// key. On the owner's phone that load took 104.75 s, ending with Bark's 105.83 s Neural Engine
/// compile (2026-11-26, the first keyboard after an install; `keyboard-status.json`), and the
/// same file loads in 0.64 s when nothing else is loading (the app's self-test, same phone, same
/// day): the model's first load in a container, the one that compiles it, waited for Bark's
/// compile. That it waits is read off those times, not traced inside Core ML. Bark compiled
/// again in the first keyboard after each install the owner tried, so each of those builds
/// showed the pair model's words for its first two minutes. `prepare` therefore starts the load
/// at each appearance, and Bark's preparation waits in `waitForLoad` until this load has ended,
/// for at most `KeyboardDictation`'s limit. Measured the same day on the same phone, in the
/// first keyboard after an install: the model loaded and answered in 0.80 s and Bark then
/// compiled in 83.7 s; and in the app (a test since removed), a model loaded first
/// answered 160 times in a row through Bark's 84.1 s compile, median 5.8 ms, slowest 12.1 ms.
///
/// **`ready` means it has answered.** The load ends with one prediction on the background
/// queue. Only then is the state `ready`, so Setup's check mark is a model that has worked in
/// this process, and the model's memory has arrived before the crash marker is disarmed.
///
/// **The crash marker.** iOS kills a keyboard that uses too much memory, with no callback. The
/// marker (`CrashMarker.typingModel`) is armed before the load and disarmed after that first
/// prediction, about a second later. A marker already armed when this process first looks means
/// the last keyboard ended in that second. Once is not proof of a memory death (an install, or
/// iOS ending a suspended keyboard, leaves the same marker), so the first time only a second
/// marker (`CrashMarker.typingModelStrike`) is armed and the load is tried again. With both
/// armed, two processes in a row ended there: the state is `stoppedLastTime` and nothing loads
/// for `lockSeconds`, or until the app clears the markers (Setup's "Try again", or the Smart
/// predictions switch turned on). The lock lifts by itself because a model that silently never
/// comes back is worse than one more try. A load that throws disarms the first marker, because
/// the process survived.
///
/// **Requests never queue up.** One prediction runs at a time on a background queue, and only the
/// newest waiting request is kept, so a fast typist costs at most one pass per word and never
/// waits for any of them. An answer comes back on the main actor through its request's `reply`.
///
/// `state` goes to `KeyboardStatus` so the Setup tab shows what the phone does; `onChange` writes
/// that file at every change of state.
@MainActor
final class SmartPredictions {
    /// The process's one model. See the type's note for why it is not the controller's.
    static let shared = SmartPredictions()

    enum State: String {
        /// The setting is off.
        case off
        /// The build has no model (`ios/TypingLM` was empty when it was built).
        case missing
        /// The keyboard has not asked for the model yet.
        case waiting
        case loading
        /// Loaded, and it has answered once.
        case ready
        /// The load or a prediction threw. Stays for the life of the process.
        case failed
        /// Two keyboard processes in a row ended while loading the model.
        case stoppedLastTime
        /// Too little memory was left to load, or to keep, the model. Tried again at the next
        /// request.
        case lowMemory
    }

    /// The memory that must be left before the extension's limit for a load to start. The phone
    /// reported no footprint gained by the load (the weights are mapped) with 131 MB left, so
    /// this is room for Bark, which loads afterwards.
    static let loadMarginMB = 60.0
    /// A loaded model is released when less than this is left.
    static let releaseBelowMB = 20.0
    /// How long two failed loads in a row keep the model off before one more try.
    static let lockSeconds: TimeInterval = 30 * 60
    /// What the load's first prediction is asked. Any text does; this one has a known answer.
    private static let warmupText = "my dog "

    private(set) var state = State.waiting {
        didSet { if state != oldValue { onChange?() } }
    }
    /// Called on the main actor when `state` changes. The view controller on screen sets it, to
    /// write the status file at once: Setup's check mark must not lag the keyboard by a poll.
    var onChange: (@MainActor () -> Void)?

    typealias Reply = @MainActor (WordPrediction) -> Void
    private struct Request {
        let boundary: String
        let reply: Reply
    }

    /// The model itself, touched only on `queue`.
    private final class Worker: @unchecked Sendable {
        var predictor: NextWordPredictor?
    }

    private static let log = Logger(subsystem: "ai.pivotstudio.murmur", category: "typing")
    private let queue = DispatchQueue(label: "ai.pivotstudio.murmur.typing-lm", qos: .userInitiated)
    private let worker = Worker()
    /// Made at the first use, after `PhoneEnvironment.configure()` has said where storage is.
    private lazy var marker = CrashMarker.typingModel
    private lazy var strike = CrashMarker.typingModelStrike
    /// The marker the last process left has been looked at, and counted as a strike if armed.
    private var launchMarkerHandled = false
    /// This process armed the marker and its load has not ended.
    private var markerArmedHere = false
    /// The newest boundary waiting for the model. Older ones are dropped unanswered.
    private var pending: Request?
    /// The reply of the prediction now running on `queue`.
    private var inFlight: Reply?
    private var isPredicting: Bool { inFlight != nil }

    private init() {}

    /// The keyboard appeared with the Smart predictions setting on: load the model now if it is
    /// not loaded, so it is ready before the first word and ahead of Bark.
    func prepare(words: TypingModel) {
        wake()
        if state == .waiting || state == .lowMemory { load(words: words, then: nil) }
    }

    /// Asks for the next-word prediction at `boundary` (`SuggestionEngine.boundary(before:)`).
    /// Returns at once; the answer, if one comes, arrives through `reply`. The caller
    /// reads the Smart predictions setting: it calls this with the setting on and `turnOff()`
    /// with it off.
    func request(_ boundary: String, words: TypingModel, reply: @escaping Reply) {
        let request = Request(boundary: boundary, reply: reply)
        wake()
        switch state {
        case .waiting, .lowMemory:
            load(words: words, then: request)
        case .loading:
            pending = request
        case .ready:
            pending = request
            predictNext()
        case .off, .missing, .failed, .stoppedLastTime:
            break
        }
    }

    /// The setting went off: the model is released and nothing is asked of it.
    func turnOff() {
        guard state != .off else { return }
        state = .off
        pending = nil
        release()
    }

    /// Returns once this process's load has ended, well or badly, or was never going to start
    /// (the setting off, no model in the build, the lock), and after `timeout` seconds whatever
    /// the state. Bark's preparation waits here before it loads, because a model load that
    /// starts during Bark's waits for the whole of it.
    func waitForLoad(timeout: Double) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while state == .waiting || state == .loading, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    static var availableMB: Double { Double(os_proc_available_memory()) / 1_048_576 }

    /// Two loads in a row ended their process, the second less than `lockSeconds` ago.
    private var isLocked: Bool {
        guard marker.isArmed, let since = strike.armedAt else { return false }
        return Date().timeIntervalSince(since) < Self.lockSeconds
    }

    /// Leaves the states that a later call may leave: the setting came back on, or the lock was
    /// cleared by the app or has run out.
    private func wake() {
        if state == .off { state = .waiting }
        if state == .stoppedLastTime, !isLocked { state = .waiting }
    }

    private func load(words: TypingModel, then request: Request?) {
        guard let folder = Bundle.main.url(forResource: NextWordPredictor.Files.folderName, withExtension: nil),
            let files = NextWordPredictor.Files(folder: folder)
        else {
            state = .missing
            return
        }
        if marker.wasArmedAtLaunch, !launchMarkerHandled {
            // Still armed: the app has not cleared it since.
            if marker.isArmed {
                if isLocked {
                    if state != .stoppedLastTime {
                        Self.log.error("language model: two keyboards in a row ended loading it; not loading for now")
                    }
                    state = .stoppedLastTime
                    return
                }
                // The first strike, or a lock that has run out: one more try.
                strike.arm()
                Self.log.info("language model: the last keyboard ended while loading it; trying once more")
            }
            launchMarkerHandled = true
        }
        let available = Self.availableMB
        guard available >= Self.loadMarginMB else {
            if state != .lowMemory {
                Self.log.info("language model: \(Int(available), privacy: .public) MB left, not loading")
            }
            state = .lowMemory
            return
        }
        pending = request
        marker.arm()
        markerArmedHere = true
        state = .loading
        let warmup = Self.warmupText
        queue.async { [worker, weak self] in
            let started = ContinuousClock.now
            var failure: String?
            do {
                let predictor = try NextWordPredictor(files: files, words: words)
                // The load is not over until the model has answered: this is when its memory
                // arrives, and what `ready` promises.
                _ = try predictor.predict(before: warmup)
                worker.predictor = predictor
            } catch {
                failure = String(describing: error)
            }
            let seconds = (ContinuousClock.now - started) / .seconds(1)
            Task { @MainActor [weak self] in self?.loaded(failure: failure, seconds: seconds) }
        }
    }

    private func loaded(failure: String?, seconds: Double) {
        guard state == .loading else {
            // The setting went off during the load.
            release()
            return
        }
        if let failure {
            Self.log.error("language model did not load: \(failure, privacy: .public)")
            fail()
            return
        }
        // The process lived through the load and a prediction: nothing here was a death.
        marker.disarm()
        strike.disarm()
        markerArmedHere = false
        Self.log.info(
            "language model loaded and answered in \(String(format: "%.2f", seconds), privacy: .public) s")
        state = .ready
        predictNext()
    }

    private func predictNext() {
        guard state == .ready, !isPredicting, let request = pending else { return }
        guard Self.availableMB >= Self.releaseBelowMB else {
            Self.log.info("language model released: \(Int(Self.availableMB), privacy: .public) MB left")
            pending = nil
            release()
            state = .lowMemory
            return
        }
        pending = nil
        inFlight = request.reply
        let boundary = request.boundary
        queue.async { [worker, weak self] in
            var prediction: WordPrediction?
            var failure: String?
            do {
                prediction = try worker.predictor?.predict(before: boundary)
            } catch {
                failure = String(describing: error)
            }
            Task { @MainActor [weak self] in
                self?.predicted(prediction, failure: failure)
            }
        }
    }

    private func predicted(_ prediction: WordPrediction?, failure: String?) {
        let reply = inFlight
        inFlight = nil
        if let failure {
            Self.log.error("language model prediction failed: \(failure, privacy: .public)")
            if state == .ready { fail() }
            return
        }
        // Nil when the model was released while the request waited.
        guard let prediction, state == .ready else { return }
        reply?(prediction)
        predictNext()
    }

    private func fail() {
        pending = nil
        release()
        state = .failed
    }

    /// Drops the model. The marker goes with it: this process is alive, so whatever happened
    /// was not a death.
    private func release() {
        queue.async { [worker] in worker.predictor = nil }
        if markerArmedHere {
            marker.disarm()
            markerArmedHere = false
        }
    }
}
