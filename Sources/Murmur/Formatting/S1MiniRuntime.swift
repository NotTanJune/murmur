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
    func clean(_ text: String, profile: CleanupProfile, decoding: Decoding = .promptLookup) async throws -> String {
        guard let container else { throw S1MiniError.notLoaded }
        let prefix = prefixes[profile]
        let previous = tail
        let work = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await Self.generate(container, prefix: prefix, profile: profile, text: text, decoding: decoding)
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

    /// How the next token is chosen. Both are greedy; they differ only in how many tokens
    /// each GPU pass produces.
    enum Decoding: String, Sendable {
        /// One forward pass per token, through `TokenIterator`. The reference.
        case greedy
        /// Prompt lookup: cleanup mostly copies its input, so after each token the next few
        /// are guessed from the transcript (the longest recent n-gram match) and verified in
        /// one pass. Every token the model would have chosen on its own is kept, so the
        /// output is the greedy output; a wrong guess only costs the pass. Measured on an M2
        /// it turns about 165 tokens/s into several hundred for ordinary dictation.
        case promptLookup
    }

    /// Longest n-gram tried when looking up a continuation. Three tokens rarely matches
    /// the wrong place in a transcript; two is the fallback when three finds nothing.
    /// `MURMUR_S1_NGRAM` overrides it for tuning runs of `--cleanup-check`.
    static let lookupNGram = ProcessInfo.processInfo.environment["MURMUR_S1_NGRAM"].flatMap(Int.init) ?? 3
    /// Most tokens guessed per pass. Measured on an M2 with the 4-bit model, a pass over
    /// 1 + k tokens costs about a single-token pass plus a third of one per extra token, so
    /// guessing pays only while most guesses land. The draft starts here and adapts: a pass
    /// that accepts everything doubles it, one that accepts under half halves it, down to
    /// `lookupMinimumDraft`. `MURMUR_S1_DRAFT` fixes it for tuning runs of `--cleanup-check`.
    static let lookupDraftLength = ProcessInfo.processInfo.environment["MURMUR_S1_DRAFT"].flatMap(Int.init) ?? 12
    static let lookupMinimumDraft = 2
    /// Set when `MURMUR_S1_DRAFT` is given: the draft then stays fixed.
    static let lookupDraftFixed = ProcessInfo.processInfo.environment["MURMUR_S1_DRAFT"] != nil

    static func generate(
        _ container: ModelContainer,
        prefix: PromptPrefix?,
        profile: CleanupProfile,
        text: String,
        decoding: Decoding = .promptLookup
    ) async throws -> String {
        try await container.perform { (context: ModelContext) in
            let all = try await promptTokens(context, profile: profile, text: text)
            var feed = all
            var cache: [KVCache]
            if let prefix, all.count > prefix.tokens.count, all.starts(with: prefix.tokens) {
                feed = Array(all.dropFirst(prefix.tokens.count))
                cache = prefix.cache.map { $0.copy() }
            } else {
                cache = try context.model.newCache(parameters: GenerateParameters(maxTokens: 1, temperature: 0))
            }
            let transcriptTokens = all.count - (prefix?.tokens.count ?? 0)
            guard transcriptTokens <= maxInputTokens else { throw S1MiniError.tooLong(transcriptTokens) }

            // Greedy, as the card prescribes; output length tracks input, so cap it there.
            let maxTokens = Int(Double(transcriptTokens) * 1.3) + 32
            let started = ContinuousClock.now
            let output: [Int]
            var drafted = 0
            var passes = 0
            switch decoding {
            case .greedy:
                let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0)
                let input = LMInput(tokens: MLXArray(feed))
                let iterator = try TokenIterator(input: input, model: context.model, cache: cache, parameters: parameters)
                var tokens: [Int] = []
                _ = MLXLMCommon.generate(input: input, context: context, iterator: iterator) { (token: Int) in
                    tokens.append(token)
                    return Task.isCancelled ? .stop : .more
                }
                output = tokens
                passes = tokens.count
            case .promptLookup:
                (output, drafted, passes) = try promptLookupDecode(
                    context, prompt: feed, cache: cache, maxTokens: maxTokens)
            }
            try Task.checkCancellation()
            let elapsed = ContinuousClock.now - started
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            Log.speech.info(
                "S1-mini: \(output.count) tokens in \(seconds, format: .fixed(precision: 2))s (\(Double(output.count) / max(seconds, 0.001), format: .fixed(precision: 0)) tokens/s, \(passes) passes, \(drafted) accepted from lookup, \(decoding.rawValue, privacy: .public))"
            )
            return context.tokenizer.decode(tokenIds: output, skipSpecialTokens: true)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Token ids that end generation: the tokenizer's EOS plus the chat template's turn end.
    private static func stopTokens(_ context: ModelContext) -> Set<Int> {
        var stops = Set<Int>()
        if let eos = context.tokenizer.eosTokenId { stops.insert(eos) }
        for token in context.configuration.extraEOSTokens.union(["<|im_end|>", "<|endoftext|>"]) {
            if let id = context.tokenizer.convertTokenToId(token) { stops.insert(id) }
        }
        return stops
    }

    /// Runs `tokens` through the model in chunks, filling `cache`, and returns the logits of
    /// the last position. Chunked so the vocabulary-wide logits of a long prompt never exist
    /// all at once.
    private static func prefill(_ model: any LanguageModel, tokens: [Int], cache: [KVCache]) -> MLXArray {
        precondition(!tokens.isEmpty)
        let step = 256
        var last: MLXArray?
        var index = 0
        while index < tokens.count {
            let chunk = Array(tokens[index..<min(index + step, tokens.count)])
            let logits = model(MLXArray(chunk)[.newAxis, 0...], cache: cache)
            last = logits[0, -1, 0...]
            eval(cache)
            index += step
        }
        let result = last!
        eval(result)
        return result
    }

    /// Prompt-lookup decoding. Returns the generated tokens, how many of them were accepted
    /// from a draft, and the number of forward passes.
    private static func promptLookupDecode(
        _ context: ModelContext,
        prompt: [Int],
        cache: [KVCache],
        maxTokens: Int
    ) throws -> ([Int], Int, Int) {
        let model = context.model
        let stops = stopTokens(context)
        var next = prefill(model, tokens: prompt, cache: cache).argMax().item(Int32.self)
        var passes = 1
        var output: [Int] = []
        var drafted = 0
        var draftLength = lookupDraftLength

        decode: while output.count < maxTokens {
            try Task.checkCancellation()
            let token = Int(next)
            if stops.contains(token) { break }
            output.append(token)
            if output.count >= maxTokens { break }

            // Guess what follows from the transcript and from what was already written.
            let source = prompt + output
            let draft = Array(
                lookup(in: source, history: output, draftLength: draftLength).prefix(maxTokens - output.count))
            let step = [token] + draft
            let logits = model(MLXArray(step)[.newAxis, 0...], cache: cache)
            // Row i is the model's choice after step[i]: row 0 continues `token`, row i
            // (i ≥ 1) continues draft[i - 1]. A draft token is right when the row before it
            // chose it.
            let choices = logits[0].argMax(axis: -1).asArray(Int32.self)
            passes += 1

            var accepted = 0
            while accepted < draft.count, Int(choices[accepted]) == draft[accepted] {
                accepted += 1
            }
            // Positions fed past the last accepted token are speculative; roll them back so
            // the cache ends exactly after the committed text.
            let rejected = draft.count - accepted
            if rejected > 0 {
                for layer in cache { _ = layer.trim(rejected) }
            }
            for guess in draft.prefix(accepted) {
                if stops.contains(guess) { break decode }
                output.append(guess)
                drafted += 1
            }
            next = choices[accepted]
            if !lookupDraftFixed, !draft.isEmpty {
                if accepted == draft.count {
                    draftLength = min(draftLength * 2, lookupDraftLength)
                } else if accepted * 2 < draft.count {
                    draftLength = max(draftLength / 2, lookupMinimumDraft)
                }
            }
        }
        return (output, drafted, passes)
    }

    /// The tokens that followed the most recent occurrence of the end of `history` inside
    /// `source`, longest n-gram first. Empty when nothing matches.
    static func lookup(
        in source: [Int],
        history: [Int],
        ngram: Int = lookupNGram,
        draftLength: Int = lookupDraftLength
    ) -> [Int] {
        guard draftLength > 0 else { return [] }
        for n in stride(from: min(ngram, history.count), through: 1, by: -1) {
            let key = Array(history.suffix(n))
            // The last `n` tokens of `source` are the key itself; a match must end before
            // them so it has a continuation to offer, and the draft stops where they begin.
            let keyStart = source.count - n
            var start = keyStart - 1
            while start >= 0 {
                if Array(source[start..<start + n]) == key {
                    let from = start + n
                    let to = min(from + draftLength, keyStart)
                    if to > from { return Array(source[from..<to]) }
                }
                start -= 1
            }
        }
        return []
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
