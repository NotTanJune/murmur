import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXNN
import Tokenizers

/// S1-mini by Superwhisper on the GPU through MLX. Runs only inside the helper process
/// (`S1MiniServer`); the app talks to it through `S1MiniEngine`.
///
/// Called through `MLXLMCommon` directly rather than the FoundationModels `MLXLanguageModel`
/// adapter: the adapter measured the same speed but has no prompt cache. Every request starts
/// with the same system prompt and one of four control lines (69 tokens), so each profile's
/// prefix is run through the model once at load and its KV cache copied per request. That
/// measured 40–60 ms faster per utterance on an M2, with token-identical output.
///
/// Requests are serialized. Holds are pipelined, so two cleanups can arrive together, and
/// one model's GPU work shouldn't interleave with another's.
actor S1MiniRuntime {
    static let shared = S1MiniRuntime()

    /// Required verbatim: the model was trained on this exact wording.
    static let systemPrompt = "You are a text normalizer for speech-to-text transcripts. The input begins "
        + "with a control line specifying the styling, structure, and context settings; "
        + "clean the transcript to match those settings and output only the cleaned text."

    /// The model card recommends single passes under about 1,000 tokens.
    static let maxInputTokens = 900

    private var container: ModelContainer?
    private var prefixes: [CleanupProfile: PromptPrefix] = [:]
    private var tail: Task<Void, Never>?
    /// The load in progress, so a cleanup that arrives mid-load waits for it rather than
    /// falling back to the rule pass.
    private var loading: Task<Void, Error>?

    var isLoaded: Bool { container != nil }

    /// Waits for a load in progress. True when the model is ready to clean.
    func waitUntilReady() async -> Bool {
        if container != nil { return true }
        if let loading { _ = try? await loading.value }
        return container != nil
    }

    /// Frees the model's GPU memory after outstanding cleanups finish. The next `load`
    /// reads the 4-bit weights back from disk.
    func unload() async {
        guard loading == nil, container != nil else { return }
        await tail?.value
        container = nil
        prefixes = [:]
        tail = nil
        Memory.clearCache()
        Log.speech.info("S1-mini: unloaded to free memory")
    }

    /// Installs if needed, loads, compiles the GPU kernels with one throwaway request, and
    /// caches every profile's prefix. Idempotent; concurrent callers share one load.
    func load(phase: @escaping @Sendable (S1MiniModelStore.Phase?) -> Void) async throws {
        guard container == nil else { return }
        if let loading { return try await loading.value }
        let task = Task { try await self.performLoad(phase: phase) }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func performLoad(phase: @escaping @Sendable (S1MiniModelStore.Phase?) -> Void) async throws {
        guard container == nil else { return }
        // MLX otherwise keeps freed GPU buffers for reuse without bound. This app is resident
        // all day, so cap the reuse pool; generation measured no slower with it.
        Memory.cacheLimit = 64 << 20

        let directory = try await S1MiniModelStore.ensureInstalled(phase: { phase($0) }) { source, destination in
            try await Self.convert(source: source, destination: destination)
        }
        phase(nil)

        let started = Date()
        let container = try await loadModelContainer(from: directory, using: #huggingFaceTokenizerLoader())
        _ = try await Self.generate(container, prefix: nil, profile: .general, text: "warm up")
        var prefixes: [CleanupProfile: PromptPrefix] = [:]
        for profile in CleanupProfile.allCases {
            prefixes[profile] = try await Self.makePrefix(container, profile: profile)
        }
        self.prefixes = prefixes
        self.container = container
        Log.speech.info("S1-mini: ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
    }

    /// Cleans one transcript. Throws if the model isn't loaded or the input is too long for
    /// one pass; the formatter falls back to the rule pass either way.
    func clean(_ text: String, profile: CleanupProfile) async throws -> String {
        guard let container else { throw S1MiniError.notLoaded }
        let prefix = prefixes[profile]
        let previous = tail
        let work = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await Self.generate(container, prefix: prefix, profile: profile, text: text)
        }
        tail = Task { _ = try? await work.value }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: - Model work

    /// The fixed part of a request with its KV cache. The caches are only ever copied, never
    /// extended, so sharing them across requests is safe.
    final class PromptPrefix: @unchecked Sendable {
        let tokens: [Int]
        let cache: [KVCache]

        init(tokens: [Int], cache: [KVCache]) {
            self.tokens = tokens
            self.cache = cache
        }
    }

    private static func promptTokens(_ context: ModelContext, profile: CleanupProfile, text: String) async throws -> [Int] {
        let input = try await context.processor.prepare(input: UserInput(
            chat: [.system(systemPrompt), .user(profile.controlLine + "\n" + text)],
            // Qwen3's template thinks by default; S1-mini was trained without it and returns
            // nothing if it's left on.
            additionalContext: ["enable_thinking": false]
        ))
        return input.text.tokens.asArray(Int.self)
    }

    /// The shared prefix is the longest run of tokens two renderings agree on when only the
    /// transcript differs, so it can't split a token that the transcript would merge into.
    private static func makePrefix(_ container: ModelContainer, profile: CleanupProfile) async throws -> PromptPrefix {
        try await container.perform { (context: ModelContext) in
            let a = try await promptTokens(context, profile: profile, text: "alpha")
            let b = try await promptTokens(context, profile: profile, text: "Zulu")
            let common = Array(zip(a, b).prefix { $0 == $1 }.map(\.0))
            let cache = try context.model.newCache(parameters: GenerateParameters(maxTokens: 1, temperature: 0))
            let logits = context.model(MLXArray(common)[.newAxis, 0...], cache: cache)
            eval(logits)
            eval(cache)
            return PromptPrefix(tokens: common, cache: cache)
        }
    }

    static func generate(
        _ container: ModelContainer,
        prefix: PromptPrefix?,
        profile: CleanupProfile,
        text: String
    ) async throws -> String {
        try await container.perform { (context: ModelContext) in
            let all = try await promptTokens(context, profile: profile, text: text)
            var feed = all
            var cache: [KVCache]?
            if let prefix, all.count > prefix.tokens.count, all.starts(with: prefix.tokens) {
                feed = Array(all.dropFirst(prefix.tokens.count))
                cache = prefix.cache.map { $0.copy() }
            }
            let transcriptTokens = all.count - (prefix?.tokens.count ?? 0)
            guard transcriptTokens <= maxInputTokens else { throw S1MiniError.tooLong(transcriptTokens) }

            // Greedy, as the card prescribes; output length tracks input, so cap it there.
            let parameters = GenerateParameters(
                maxTokens: Int(Double(transcriptTokens) * 1.3) + 32,
                temperature: 0
            )
            let input = LMInput(tokens: MLXArray(feed))
            let iterator = try TokenIterator(input: input, model: context.model, cache: cache, parameters: parameters)
            var output: [Int] = []
            _ = MLXLMCommon.generate(input: input, context: context, iterator: iterator) { (token: Int) in
                output.append(token)
                return Task.isCancelled ? .stop : .more
            }
            try Task.checkCancellation()
            return context.tokenizer.decode(tokenIds: output, skipSpecialTokens: true)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Quantizes the BF16 source to 4-bit and writes it in the layout MLX loads, with the
    /// quantization block added to config.json.
    static func convert(source: URL, destination: URL) async throws {
        let started = Date()
        let container = try await loadModelContainer(from: source, using: #huggingFaceTokenizerLoader())
        try await container.perform { (context: ModelContext) in
            quantize(model: context.model, groupSize: 64, bits: 4, mode: .affine)
            let weights = Dictionary(uniqueKeysWithValues: context.model.parameters().flattened())
            eval(Array(weights.values))
            try save(
                arrays: weights,
                metadata: ["format": "mlx"],
                url: destination.appendingPathComponent("model.safetensors")
            )
        }
        let config = try Data(contentsOf: source.appendingPathComponent("config.json"))
        try S1MiniModelStore.quantizedConfig(from: config)
            .write(to: destination.appendingPathComponent("config.json"))
        Memory.clearCache()
        Log.speech.info("S1-mini: converted to 4-bit in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
    }
}
