import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT 0.6B compiled to Core ML and run on the Neural Engine through
/// FluidAudio. This is the batch engine: it buffers audio during the hold and transcribes
/// everything once at release. That is cheap (about 100 times real time) but means the HUD
/// shows no live text while speaking, unlike Apple's engine. Live partials for this model
/// come from `IncrementalParakeetEngine`, chosen by the "While speaking" timing setting;
/// this type is the "On release" path and the compare-mode path.
///
/// The same engine runs Underdog Bark 3.0 Clean: it is a Parakeet TDT v3 fine-tune with the
/// identical component contract, so only the weights (`ParakeetModels.barkClean`) differ.
actor ParakeetEngine: TranscriptionEngine {
    private let models: ParakeetModels
    /// 16 kHz mono Float32 audio collected so far.
    private var samples: [Float] = []
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?
    /// FluidAudio's defaults (16 kHz mono Float32) are the format Parakeet was trained on.
    private let converter = AudioConverter()

    init(models: ParakeetModels = .shared) {
        self.models = models
    }

    func preferredInputFormat() async -> AVAudioFormat? {
        // Capture converts to whatever format the engine asks for.
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        samples.removeAll(keepingCapacity: true)
        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation

        // The first load can be very slow. Paying for it here puts the wait before the user
        // speaks, so no utterance is lost to a timeout.
        _ = try await models.manager()

        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        let buffer = chunk.buffer
        guard buffer.frameLength > 0 else { return }
        // The shared converter handles any capture format. In compare mode that is whatever
        // Apple's analyzer asked for, and `AsrManager.transcribe` never checks the sample
        // rate, so skipping this would produce silently wrong text.
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

        // Under 0.1 s is an accidental key tap, not speech. The skip is logged because an
        // earlier sample-rate bug showed up as a suspiciously fast empty result.
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
                \(elapsed, format: .fixed(precision: 2))s \
                (\(audioSeconds / max(elapsed, 0.0001), format: .fixed(precision: 0))x realtime)
                """)

            continuation?.yield(TranscriptionChunk(
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
            .replacingOccurrences(of: " +(?=[,.!?;:])", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The process-wide model cache. The first ever load downloads about 470 MB; later loads
/// take seconds from disk. Loaded models are immutable, so one shared instance serves every
/// dictation. It is an actor because Swift 6 rejects unprotected mutable static state on
/// `ParakeetEngine`.
actor ParakeetModels {
    enum Source: Sendable {
        /// NVIDIA's weights, fetched and cached by FluidAudio.
        case parakeetV3
        /// Underdog Bark 3.0 Clean, fetched and verified by `BarkModelStore`.
        case barkClean
        /// Bark Clean with the stock decoder pair regardless of the Settings choice. Compare
        /// mode uses it beside a fine-tuned `barkClean`.
        case barkCleanStock
        /// Bark Clean with a fine-tuned decoder and joint from `CustomDecoderSlot`, by slot name.
        case barkCleanCustom(String)

        var label: String {
            switch self {
            case .parakeetV3: "Parakeet"
            case .barkClean: "Bark Clean"
            case .barkCleanStock: "Bark Clean (stock)"
            case .barkCleanCustom: "Bark Clean (fine-tuned)"
            }
        }
    }

    static let shared = ParakeetModels(source: .parakeetV3)
    static let barkClean = ParakeetModels(source: .barkClean)
    static let stockBarkClean = ParakeetModels(source: .barkCleanStock)

    static func custom(_ name: String) -> ParakeetModels { ParakeetModels(source: .barkCleanCustom(name)) }

    let source: Source

    init(source: Source) {
        self.source = source
    }

    /// Whether NVIDIA's v3 models are already on disk, checked without loading them.
    /// Bark's equivalent is `BarkModelStore.isDownloaded`.
    ///
    /// This reads the disk, so it is correct straight after launch and can be called
    /// synchronously while a menu draws; an in-memory flag would be wrong until the first load.
    nonisolated static var isDownloaded: Bool {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }
        let encoder = support
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3", isDirectory: true)
            .appendingPathComponent("Encoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path)
    }

    private var loaded: AsrManager?
    /// The `AsrModels` behind `loaded`, kept so the incremental engine can wrap the same
    /// weights in a `SlidingWindowAsrManager` without loading anything again.
    private var models: AsrModels?
    private var loadTask: Task<(AsrManager, AsrModels), Error>?

    var isLoaded: Bool { loaded != nil }

    /// Releases the Core ML models so their Neural Engine and CPU memory go back to the
    /// system. Leaves a load in flight alone; the next `manager()` reloads from disk, which
    /// takes well under a second once the Neural Engine compile is cached.
    func unload() async {
        guard let manager = loaded else { return }
        loaded = nil
        models = nil
        loadTask = nil
        await manager.cleanup()
        Log.speech.info("\(self.source.label, privacy: .public): unloaded to free memory")
    }

    /// The decoder choice changed: drop the loaded pair and load the selected one. The
    /// encoder file is unchanged, so this is a sub-second reload with no recompile.
    func reload() async throws {
        // Never start a download from a settings change; the model loads when it is installed.
        guard BarkModelStore.isDownloaded else { return }
        await unload()
        _ = try await manager()
    }

    /// The loaded `AsrModels`, loading them first if needed (same single load as `manager()`).
    func loadedModels() async throws -> AsrModels {
        _ = try await manager()
        guard let models else { throw TranscriptionError.notRunning }
        return models
    }

    /// Loads at most once. Overlapping callers share one load task instead of each
    /// downloading.
    func manager() async throws -> AsrManager {
        if let loaded { return loaded }
        if let loadTask { return try await loadTask.value.0 }

        let source = source
        // Read before the load task: Settings is main-actor, and a switch expression can't
        // hold the multi-statement hop.
        let selectedDecoder = await MainActor.run { Settings.shared.barkDecoder }
        let task = Task<(AsrManager, AsrModels), Error> {
            let started = Date()
            let models = switch source {
            case .parakeetV3: try await Self.loadParakeetV3()
            case .barkClean: try await Self.loadBarkClean(slot: selectedDecoder)
            case .barkCleanStock: try await Self.loadBarkClean(slot: .stock)
            case .barkCleanCustom(let name): try await Self.loadBarkClean(slot: .custom(name))
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            await Self.warmUp(manager, label: source.label)
            Log.speech.info("\(source.label, privacy: .public): ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            return (manager, models)
        }
        loadTask = task

        do {
            let (manager, models) = try await task.value
            loaded = manager
            self.models = models
            return manager
        } catch {
            // A failed load is not cached, so a transient error doesn't strand the session.
            loadTask = nil
            throw error
        }
    }

    private static func loadParakeetV3() async throws -> AsrModels {
        // The stage text is built first because `os.Logger` interpolation needs a plain
        // value, so a conditional can't be written inline in the log call.
        let stage = isDownloaded
            ? "loading models from disk"
            : "downloading the models (about 470 MB, once)"
        Log.speech.info("Parakeet: \(stage, privacy: .public)")
        return try await AsrModels.downloadAndLoad(version: .v3, encoderPrecision: .int8)
    }

    /// Loads Bark's components directly instead of through `AsrModels.load(from:)`.
    ///
    /// FluidAudio's loader resolves files by the stock v3 repo name and, when a load fails,
    /// purges the folder and re-downloads **NVIDIA's** v3 into it. Pointed at Bark's folder
    /// that would silently swap the model. Loading by hand keeps every byte the verified
    /// pinned download, and an error surfaces as an error.
    ///
    /// Only the decoder and joint come from `slot`; the preprocessor and encoder always come
    /// from the verified stock folder, so a swap never triggers a Neural Engine recompile.
    private static func loadBarkClean(slot: BarkDecoderChoice) async throws -> AsrModels {
        let directory = try await BarkModelStore.ensureDownloaded()
        let pair: URL
        switch slot {
        case .stock:
            pair = directory
        case .custom(let name):
            pair = CustomDecoderSlot.directory(for: name)
            try CustomDecoderSlot.verify(pair, baseRevision: BarkModelStore.revision)
            Log.speech.info("Bark Clean: using fine-tuned decoder \(name, privacy: .public)")
        }
        Log.speech.info("Bark Clean: loading models (the first load compiles for the Neural Engine, about a minute)")

        func load(_ name: String, from folder: URL, _ units: MLComputeUnits) async throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try await MLModel.load(
                contentsOf: folder.appendingPathComponent(name), configuration: configuration)
        }

        // Same placement as FluidAudio's v3 defaults: the mel front-end is all CPU ops, and
        // everything else stays off the GPU.
        let preprocessor = try await load("Preprocessor.mlmodelc", from: directory, .cpuOnly)
        let encoder = try await load("Encoder.mlmodelc", from: directory, .cpuAndNeuralEngine)
        let decoder = try await load("Decoder.mlmodelc", from: pair, .cpuAndNeuralEngine)
        let joint = try await load("JointDecisionv3.mlmodelc", from: pair, .cpuAndNeuralEngine)

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
