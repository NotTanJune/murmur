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
/// and left the crash marker armed, and every keyboard after it read that marker as a death and
/// never loaded the model again: the owner saw the pair model's words while Setup said the model
/// was fine (2026-11-26, marker found armed on the phone from the minute of the test). A load or
/// a prediction now outlives the controller that asked, and each answer goes to the reply of the
/// request it was made for.
///
/// **Loading is lazy and guarded.** Nothing loads until the first request, which the controller
/// sends only after a key has been touched, so a keyboard used only for dictation never pays for
/// it. A load needs the Smart predictions setting on, the model's files in the bundle
/// (`ios/TypingLM`, which a checkout without the model does not have), `loadMarginMB` of memory
/// left before the extension's limit, and no crash marker from a previous process.
///
/// **The crash marker.** iOS kills a keyboard that uses too much memory, with no callback. The
/// marker (`CrashMarker.typingModel`) is armed before the load and disarmed after the first
/// prediction, the window in which the model's memory arrives. A marker already armed when this
/// process first looks means the last keyboard ended in that window. Once is not proof of a
/// memory death (an install, or iOS ending a suspended keyboard, leaves the same marker), so
/// the first time only a second marker (`CrashMarker.typingModelStrike`) is armed and the load
/// is tried again. With both armed, two processes in a row ended there: the state is
/// `stoppedLastTime` and nothing loads until the app clears the markers (its Smart predictions
/// switch, turned on, does). The first prediction disarms both. A load that throws disarms the
/// first, because the process survived.
///
/// **Requests never queue up.** One prediction runs at a time on a background queue, and only the
/// newest waiting request is kept, so a fast typist costs at most one pass per word and never
/// waits for any of them. An answer comes back on the main actor through its request's `reply`.
///
/// On a Mac the model, its tokenizer and its word tables added 25 MB of footprint at the first
/// load and 14 MB at later ones, loaded in 0.55 s and 0.29 s, and predicted in 3.5 ms
/// (2026-11-25, `training/typing-lm/README.md`). None of that is measured on a phone; `state`,
/// `loadSeconds`, `lastPredictionMs` and `footprintMB` go to `KeyboardStatus` so the Setup tab
/// shows what the phone does.
@MainActor
final class SmartPredictions {
    /// The process's one model. See the type's note for why it is not the controller's.
    static let shared = SmartPredictions()

    enum State: String {
        /// The setting is off.
        case off
        /// The build has no model (`ios/TypingLM` was empty when it was built).
        case missing
        /// Nothing has asked for a prediction yet.
        case waiting
        case loading
        case ready
        /// The load or a prediction threw. Stays for the life of the process.
        case failed
        /// The last keyboard process died between loading the model and its first prediction.
        case stoppedLastTime
        /// Too little memory was left to load, or to keep, the model. Tried again at the next
        /// request.
        case lowMemory
    }

    /// The memory that must be left before the extension's limit for a load to start. The model
    /// should need well under half of it; the rest is room for Bark, which may load afterwards.
    /// A guess until a phone has reported `footprintMB`.
    static let loadMarginMB = 60.0
    /// A loaded model is released when less than this is left.
    static let releaseBelowMB = 20.0

    private(set) var state = State.waiting
    /// This process's model load, in seconds.
    private(set) var loadSeconds: Double?
    /// The last prediction's time on the background queue, in milliseconds.
    private(set) var lastPredictionMs: Double?
    /// The footprint gained from just before the load to just after the first prediction.
    private(set) var footprintMB: Double?
    /// Predictions delivered since the process started. Not reset when the keyboard reappears,
    /// so Setup still shows them after a screenshot has replaced the controller.
    private(set) var answers = 0

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
    /// Made at the first request, after `PhoneEnvironment.configure()` has said where storage is.
    private lazy var marker = CrashMarker.typingModel
    private lazy var strike = CrashMarker.typingModelStrike
    /// The marker the last process left has been looked at, and counted as a strike if armed.
    private var launchMarkerHandled = false
    /// This process armed the marker and has not yet seen a prediction.
    private var markerArmedHere = false
    private var footprintBeforeLoad = 0.0
    /// The newest boundary waiting for the model. Older ones are dropped unanswered.
    private var pending: Request?
    /// The reply of the prediction now running on `queue`.
    private var inFlight: Reply?
    private var isPredicting: Bool { inFlight != nil }

    private init() {}

    /// Asks for the next-word prediction at `boundary` (`SuggestionEngine.boundary(before:)`).
    /// Returns at once; the answer, if one comes, arrives through `reply`. The caller
    /// reads the Smart predictions setting: it calls this with the setting on and `turnOff()`
    /// with it off.
    func request(_ boundary: String, words: TypingModel, reply: @escaping Reply) {
        let request = Request(boundary: boundary, reply: reply)
        if state == .off { state = .waiting }
        // The app cleared the marker since this process first saw it.
        if state == .stoppedLastTime, !marker.isArmed { state = .waiting }
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

    static var availableMB: Double { Double(os_proc_available_memory()) / 1_048_576 }

    private func load(words: TypingModel, then request: Request) {
        guard let folder = Bundle.main.url(forResource: NextWordPredictor.Files.folderName, withExtension: nil),
            let files = NextWordPredictor.Files(folder: folder)
        else {
            state = .missing
            return
        }
        if marker.wasArmedAtLaunch, !launchMarkerHandled {
            // Still armed: the app has not cleared it since.
            if marker.isArmed {
                if strike.isArmed {
                    if state != .stoppedLastTime {
                        Self.log.error("language model: two keyboards in a row ended loading it; not loading")
                    }
                    state = .stoppedLastTime
                    return
                }
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
        state = .loading
        pending = request
        marker.arm()
        markerArmedHere = true
        footprintBeforeLoad = MemoryProbe.footprintMB()
        queue.async { [worker, weak self] in
            let started = ContinuousClock.now
            var failure: String?
            do {
                worker.predictor = try NextWordPredictor(files: files, words: words)
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
        loadSeconds = seconds
        state = .ready
        Self.log.info("language model loaded in \(String(format: "%.2f", seconds), privacy: .public) s")
        predictNext()
    }

    private func predictNext() {
        guard state == .ready, !isPredicting, let request = pending else { return }
        guard Self.availableMB >= Self.releaseBelowMB else {
            Self.log.info("language model released: \(Int(Self.availableMB), privacy: .public) MB left")
            state = .lowMemory
            pending = nil
            release()
            return
        }
        pending = nil
        inFlight = request.reply
        let boundary = request.boundary
        queue.async { [worker, weak self] in
            let started = ContinuousClock.now
            var prediction: WordPrediction?
            var failure: String?
            do {
                prediction = try worker.predictor?.predict(before: boundary)
            } catch {
                failure = String(describing: error)
            }
            let milliseconds = (ContinuousClock.now - started) / .milliseconds(1)
            Task { @MainActor [weak self] in
                self?.predicted(prediction, failure: failure, milliseconds: milliseconds)
            }
        }
    }

    private func predicted(_ prediction: WordPrediction?, failure: String?, milliseconds: Double) {
        let reply = inFlight
        inFlight = nil
        if let failure {
            Self.log.error("language model prediction failed: \(failure, privacy: .public)")
            if state == .ready { fail() }
            return
        }
        // Nil when the model was released while the request waited.
        guard let prediction, state == .ready else { return }
        lastPredictionMs = milliseconds
        if markerArmedHere {
            marker.disarm()
            strike.disarm()
            markerArmedHere = false
            footprintMB = max(0, MemoryProbe.footprintMB() - footprintBeforeLoad)
            Self.log.info(
                "language model: first prediction \(String(format: "%.1f", milliseconds), privacy: .public) ms, footprint +\(String(format: "%.1f", self.footprintMB ?? 0), privacy: .public) MB")
        }
        answers += 1
        reply?(prediction)
        predictNext()
    }

    private func fail() {
        state = .failed
        pending = nil
        release()
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
