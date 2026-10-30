import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT 0.6B, compiled to CoreML and run on the Neural Engine via FluidAudio.
///
/// **Batch, not streaming.** Audio is accumulated while the key is held and transcribed in
/// one pass on release. That's a deliberate trade: at ~100× realtime a 30-second utterance
/// resolves in roughly a third of a second, which is imperceptible for push-to-talk — but
/// it means no live text in the HUD while you speak, unlike Apple's engine.
/// FluidAudio's `SlidingWindowAsrManager` would restore live partials at the cost of a
/// more complex integration; see the note in `docs`.
///
/// The same engine runs Underdog Bark 3.0 Clean: it is a Parakeet TDT v3 fine-tune with the
/// identical component contract, so only the weights (`ParakeetModels.barkClean`) differ.
actor ParakeetEngine: TranscriptionEngine {
    private let models: ParakeetModels
    private var samples: [Float] = []
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?

    /// Defaults to 16 kHz mono float32 — exactly what Parakeet is trained on.
    private let converter = AudioConverter()

    init(models: ParakeetModels = .shared) {
        self.models = models
    }

    func preferredInputFormat() async -> AVAudioFormat? {
        // Parakeet is trained on 16 kHz mono; AudioCapture converts to whatever we ask for.
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        samples.removeAll(keepingCapacity: true)

        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation

        // Force the (possibly very slow) first load to happen here rather than on release,
        // so the user waits before speaking instead of losing an utterance to a timeout.
        _ = try await models.manager()

        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        let buffer = chunk.buffer
        guard buffer.frameLength > 0 else { return }

        // Delegated to FluidAudio's own converter rather than hand-rolled, for one reason
        // that matters more than tidiness: `AsrManager.transcribe(_ samples: [Float])`
        // performs **no resampling and no rate validation**. Feed it the wrong sample rate
        // and it doesn't throw — it silently transcribes garbage.
        //
        // That's a live risk here. In compare mode the capture format is dictated by
        // Apple's analyzer, and `bestAvailableAudioFormat` may legitimately return 8 kHz
        // as well as 16 kHz. `resampleBuffer` normalizes whatever arrives to the 16 kHz
        // mono float32 the model expects, and its Int16→Float path is bit-identical to
        // dividing by 32768, so nothing is lost versus doing it by hand.
        do {
            samples.append(contentsOf: try converter.resampleBuffer(buffer))
        } catch {
            Log.speech.error("\(self.models.source.label, privacy: .public): audio conversion failed — \(error.localizedDescription)")
        }
    }

    func finish() async {
        defer {
            continuation?.finish()
            continuation = nil
            samples.removeAll(keepingCapacity: true)
        }

        // Parakeet's encoder needs a minimum window; a stray tap of the key isn't speech.
        // Logged rather than silent — an unexpected drop to zero here is how the
        // format bug above disguised itself as a fast, empty result.
        guard samples.count >= 1_600 else {
            Log.speech.info("\(self.models.source.label, privacy: .public): skipped — only \(self.samples.count) samples captured")
            return
        }

        do {
            let manager = try await models.manager()
            var decoderState = try TdtDecoderState()
            let started = Date()
            let result = try await manager.transcribe(samples, decoderState: &decoderState)
            let elapsed = Date().timeIntervalSince(started)
            let audioSeconds = Double(samples.count) / 16_000

            Log.speech.info("""
                \(self.models.source.label, privacy: .public): \(audioSeconds, format: .fixed(precision: 1))s audio in \
                \(elapsed, format: .fixed(precision: 2))s (\(audioSeconds / max(elapsed, 0.0001), format: .fixed(precision: 0))× realtime)
                """)

            continuation?.yield(
                TranscriptionChunk(
                    text: Self.cleanTranscript(result.text),
                    isFinal: true
                )
            )
        } catch {
            Log.speech.error("\(self.models.source.label, privacy: .public) failed: \(error.localizedDescription)")
            continuation?.finish(throwing: error)
            continuation = nil
        }
    }

    /// Bark emits `<unk>` (token 0) where its training text had a quotation mark, and
    /// FluidAudio 0.15.6 joins every token it decodes, specials included. Removing the token
    /// can leave a doubled space or a space before punctuation, so both are tidied here.
    nonisolated static func cleanTranscript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<unk>", with: "")
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +([,.!?;:])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Process-wide model cache.
///
/// Loading is expensive — ~470 MB downloaded on first ever run, then a few seconds from
/// disk per process — and the models are immutable once loaded, so every dictation shares
/// one instance rather than paying that per utterance. Its own actor because `static var`
/// on `ParakeetEngine` would be unprotected global mutable state under Swift 6.
actor ParakeetModels {
    enum Source: Sendable {
        /// NVIDIA's weights, fetched and cached by FluidAudio.
        case parakeetV3
        /// Underdog Bark 3.0 Clean, fetched and verified by `BarkModelStore`.
        case barkClean

        var label: String {
            switch self {
            case .parakeetV3: "Parakeet"
            case .barkClean: "Bark Clean"
            }
        }
    }

    static let shared = ParakeetModels(source: .parakeetV3)
    static let barkClean = ParakeetModels(source: .barkClean)

    let source: Source

    init(source: Source) {
        self.source = source
    }

    /// Whether NVIDIA's v3 models are already on disk, checked without loading them.
    /// Bark's equivalent is `BarkModelStore.isDownloaded`.
    ///
    /// `nonisolated` and filesystem-based on purpose: the menu needs this synchronously
    /// while drawing, and an in-memory "have I loaded yet" flag would wrongly report
    /// "not downloaded" on every fresh launch.
    nonisolated static var isDownloaded: Bool {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let encoder = support
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3/Encoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path)
    }

    private var loaded: AsrManager?
    private var loadTask: Task<AsrManager, Error>?

    var isLoaded: Bool { loaded != nil }

    /// Releases the Core ML models so their Neural Engine and CPU memory go back to the
    /// system. Leaves a load in flight alone; the next `manager()` reloads from disk, which
    /// takes well under a second once the Neural Engine compile is cached.
    func unload() async {
        guard let manager = loaded else { return }
        loaded = nil
        loadTask = nil
        await manager.cleanup()
        Log.speech.info("\(self.source.label, privacy: .public): unloaded to free memory")
    }

    /// Loads once; concurrent callers await the same task rather than racing to download.
    func manager() async throws -> AsrManager {
        if let loaded { return loaded }
        if let loadTask { return try await loadTask.value }

        let source = source
        let task = Task<AsrManager, Error> {
            let started = Date()
            let models = switch source {
            case .parakeetV3: try await Self.loadParakeetV3()
            case .barkClean: try await Self.loadBarkClean()
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            await Self.warmUp(manager, label: source.label)
            Log.speech.info("\(source.label, privacy: .public): ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            return manager
        }
        loadTask = task

        do {
            let manager = try await task.value
            loaded = manager
            return manager
        } catch {
            // Don't cache a failed load — a transient download error shouldn't wedge the
            // engine for the rest of the session.
            loadTask = nil
            throw error
        }
    }

    private static func loadParakeetV3() async throws -> AsrModels {
        // Built as a value first: os.Logger requires a literal interpolation, so a
        // ternary can't be passed directly as the argument.
        let stage = isDownloaded
            ? "loading models from disk"
            : "downloading models (~470 MB, one time)"
        Log.speech.info("Parakeet: \(stage, privacy: .public)")
        return try await AsrModels.downloadAndLoad(version: .v3, encoderPrecision: .int8)
    }

    /// Loads Bark's components directly instead of through `AsrModels.load(from:)`.
    ///
    /// FluidAudio's loader resolves files by the stock v3 repo name and, when a load fails,
    /// purges the folder and re-downloads **NVIDIA's** v3 into it. Pointed at Bark's folder
    /// that would silently swap the model. Loading by hand keeps every byte the verified
    /// pinned download, and an error surfaces as an error.
    private static func loadBarkClean() async throws -> AsrModels {
        let directory = try await BarkModelStore.ensureDownloaded()
        Log.speech.info("Bark Clean: loading models (the first load compiles for the Neural Engine, about a minute)")

        func load(_ name: String, _ units: MLComputeUnits) async throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try await MLModel.load(
                contentsOf: directory.appendingPathComponent(name), configuration: configuration)
        }

        // Same placement as FluidAudio's v3 defaults: the mel front-end is all CPU ops, and
        // everything else stays off the GPU.
        let preprocessor = try await load("Preprocessor.mlmodelc", .cpuOnly)
        let encoder = try await load("Encoder.mlmodelc", .cpuAndNeuralEngine)
        let decoder = try await load("Decoder.mlmodelc", .cpuAndNeuralEngine)
        let joint = try await load("JointDecisionv3.mlmodelc", .cpuAndNeuralEngine)

        let data = try Data(contentsOf: directory.appendingPathComponent("parakeet_vocab.json"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw TranscriptionError.modelInstallFailed("parakeet_vocab.json has an unexpected format")
        }
        var vocabulary: [Int: String] = [:]
        for (key, token) in json {
            if let id = Int(key) { vocabulary[id] = token }
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return AsrModels(
            encoder: encoder, preprocessor: preprocessor, decoder: decoder, joint: joint,
            configuration: configuration, vocabulary: vocabulary, version: .v3)
    }

    /// One throwaway pass over a second of silence. The first prediction after a load
    /// allocates the compute plan and buffers, and that cost otherwise lands on the first
    /// real dictation after launch.
    private static func warmUp(_ manager: AsrManager, label: String) async {
        do {
            var state = try TdtDecoderState()
            let started = Date()
            _ = try await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
            Log.speech.info("\(label, privacy: .public): warm-up pass \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
        } catch {
            Log.speech.error("\(label, privacy: .public): warm-up failed — \(error.localizedDescription)")
        }
    }
}
