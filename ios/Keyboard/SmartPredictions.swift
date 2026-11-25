import Foundation
import MurmurKit
import MurmurTyping
import OSLog
import os

/// Owns the keyboard's language model (`NextWordPredictor`): when it loads, where it runs, and
/// what happens when it cannot. The strip works without it, on the pair model, exactly as before
/// the model existed; everything here only ever adds a better answer a moment later.
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
/// process first looks means the last keyboard died in that window: the state is
/// `stoppedLastTime` and nothing loads until the app clears the marker (its Smart predictions
/// switch, turned on, does). A load that throws disarms it, because the process survived.
///
/// **Requests never queue up.** One prediction runs at a time on a background queue, and only the
/// newest waiting request is kept, so a fast typist costs at most one pass per word and never
/// waits for any of them. Answers come back on the main actor through `onPrediction`.
///
/// On a Mac the model, its tokenizer and its word tables added 25 MB of footprint at the first
/// load and 14 MB at later ones, loaded in 0.55 s and 0.29 s, and predicted in 3.5 ms
/// (2026-11-25, `training/typing-lm/README.md`). None of that is measured on a phone; `state`,
/// `loadSeconds`, `lastPredictionMs` and `footprintMB` go to `KeyboardStatus` so the Setup tab
/// shows what the phone does.
@MainActor
final class SmartPredictions {
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
    /// Called on the main actor with each prediction, in the order they were made.
    var onPrediction: (WordPrediction) -> Void = { _ in }

    /// The model itself, touched only on `queue`.
    private final class Worker: @unchecked Sendable {
        var predictor: NextWordPredictor?
    }

    private static let log = Logger(subsystem: "ai.pivotstudio.murmur", category: "typing")
    private let queue = DispatchQueue(label: "ai.pivotstudio.murmur.typing-lm", qos: .userInitiated)
    private let worker = Worker()
    /// Made at the first request, after `PhoneEnvironment.configure()` has said where storage is.
    private lazy var marker = CrashMarker.typingModel
    /// This process armed the marker and has not yet seen a prediction.
    private var markerArmedHere = false
    private var footprintBeforeLoad = 0.0
    /// The newest boundary waiting for the model. Older ones are dropped unanswered.
    private var pending: String?
    private var isPredicting = false

    /// Asks for the next-word prediction at `boundary` (`SuggestionEngine.boundary(before:)`).
    /// Returns at once; the answer, if one comes, arrives through `onPrediction`.
    func request(_ boundary: String, words: TypingModel) {
        guard Settings.shared.smartPredictions else {
            turnOff()
            return
        }
        if state == .off { state = .waiting }
        // The app cleared the marker since this process first saw it.
        if state == .stoppedLastTime, !marker.isArmed { state = .waiting }
        switch state {
        case .waiting, .lowMemory:
            load(words: words, then: boundary)
        case .loading:
            pending = boundary
        case .ready:
            pending = boundary
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

    private static var availableMB: Double { Double(os_proc_available_memory()) / 1_048_576 }

    private func load(words: TypingModel, then boundary: String) {
        guard let folder = Bundle.main.url(forResource: NextWordPredictor.Files.folderName, withExtension: nil),
            let files = NextWordPredictor.Files(folder: folder)
        else {
            state = .missing
            return
        }
        if marker.wasArmedAtLaunch, !markerArmedHere, marker.isArmed {
            if state != .stoppedLastTime { Self.log.error("language model: the last keyboard died loading it; not loading") }
            state = .stoppedLastTime
            return
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
        pending = boundary
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
        guard state == .ready, !isPredicting, let boundary = pending else { return }
        guard Self.availableMB >= Self.releaseBelowMB else {
            Self.log.info("language model released: \(Int(Self.availableMB), privacy: .public) MB left")
            state = .lowMemory
            pending = nil
            release()
            return
        }
        pending = nil
        isPredicting = true
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
        isPredicting = false
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
            markerArmedHere = false
            footprintMB = max(0, MemoryProbe.footprintMB() - footprintBeforeLoad)
            Self.log.info(
                "language model: first prediction \(String(format: "%.1f", milliseconds), privacy: .public) ms, footprint +\(String(format: "%.1f", self.footprintMB ?? 0), privacy: .public) MB")
        }
        onPrediction(prediction)
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
