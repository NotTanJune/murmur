import CoreML
import Foundation

/// The keyboard's language model: a small causal transformer run through Core ML that reads the
/// text before the cursor and says how likely each word is to come next.
///
/// One call is one forward pass over a fixed window of tokens (the model's `input_ids` shape,
/// left-truncated, with the start token in front). The model returns the log probability of
/// every token after the last real one. A token that starts a new word and is, folded to
/// lowercase, a word of the keyboard's list stands for that word; tokens that differ only in case
/// add up. Words the model writes as two or more tokens get no probability, which the pair model
/// makes up for (`SuggestionEngine`). A second pass for two-token words was measured on
/// 2026-11-25 and moved the top-three hit rate by 0.1 points, so there is none.
///
/// Loading reads the tokenizer's two files and builds the token-to-word tables against
/// `TypingModel`, so a rebuilt word list needs no new model. `predict` blocks for the length of
/// the pass and is safe to call from any thread; calls are serialised. The keyboard calls it
/// from a background queue and drops an answer that arrives late.
public final class NextWordPredictor: @unchecked Sendable {
    /// The model's files as `Tools/fetch_typing_lm.py` writes them into one folder.
    public struct Files: Sendable {
        /// The folder's name inside the keyboard's bundle and in the repo (`ios/TypingLM`).
        public static let folderName = "TypingLM"
        public static let modelName = "NextWord.mlmodelc"
        public static let vocabularyName = "vocab.json"
        public static let mergesName = "merges.txt"

        public let model: URL
        public let vocabulary: URL
        public let merges: URL

        /// Nil unless the folder holds all three.
        public init?(folder: URL) {
            model = folder.appendingPathComponent(Self.modelName)
            vocabulary = folder.appendingPathComponent(Self.vocabularyName)
            merges = folder.appendingPathComponent(Self.mergesName)
            let manager = FileManager.default
            guard manager.fileExists(atPath: model.appendingPathComponent("coremldata.bin").path),
                manager.fileExists(atPath: vocabulary.path), manager.fileExists(atPath: merges.path)
            else { return nil }
        }
    }

    public enum LoadError: Error, Equatable {
        /// The Core ML model does not have the inputs and output `Tools/fetch_typing_lm.py` gives it.
        case unexpectedModel(String)
        /// The vocabulary has no start token.
        case noStartToken
    }

    /// First halves of contractions that are no words by themselves. The model writes "didn't" as
    /// "didn" and "'t"; the word list holds the stem only because its source split contractions
    /// in two. The stem's token stands for the contraction.
    static let contractionStems = [
        "ain", "aren", "couldn", "didn", "doesn", "don", "hadn", "hasn", "haven", "isn", "mustn", "needn",
        "shouldn", "wasn", "weren", "wouldn",
    ]

    /// The tokens that stand for a word, and the words they stand for.
    private struct Table {
        /// Token ids, and for each the index of its word in `words`.
        var tokens: [Int32] = []
        var slots: [Int32] = []
        /// Word ids, ascending.
        var words: [Int32] = []
    }

    /// The window of tokens one pass reads, the start token included.
    public let contextLength: Int
    private let model: MLModel
    private let tokenizer: BPETokenizer
    private let start: Int32
    /// Tokens that begin with a space, read when the text before the cursor ends in one.
    private let afterSpace: Table
    /// Tokens with no space, read at the start of the text and right after a line break or an
    /// opening mark.
    private let bare: Table
    private let lock = NSLock()

    /// Loads the model and the tokenizer and builds the word tables. `computeUnits` is the CPU by
    /// default: a Neural Engine compile at first load took 85 s for Bark, and a keyboard cannot
    /// wait for that.
    public init(files: Files, words: TypingModel, computeUnits: MLComputeUnits = .cpuOnly) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: files.model, configuration: configuration)
        let inputs = model.modelDescription.inputDescriptionsByName
        guard let shape = inputs["input_ids"]?.multiArrayConstraint?.shape, shape.count == 2,
            inputs["last"] != nil, model.modelDescription.outputDescriptionsByName["logp"] != nil
        else { throw LoadError.unexpectedModel("expected inputs input_ids and last, output logp") }
        contextLength = shape[1].intValue
        guard contextLength >= 2 else { throw LoadError.unexpectedModel("a window of \(contextLength) tokens") }

        tokenizer = try BPETokenizer(vocabulary: files.vocabulary, merges: files.merges)
        guard let start = tokenizer.endOfText else { throw LoadError.noStartToken }
        self.start = start

        var stems: [Int: Int] = [:]
        for stem in Self.contractionStems {
            if let from = words.id(of: stem), let to = words.id(of: stem + "'t") { stems[from] = to }
        }
        var spaced: [(word: Int, token: Int32)] = []
        var unspaced: [(word: Int, token: Int32)] = []
        for (token, text) in tokenizer.tokens.enumerated() {
            let hasSpace = text.first == BPETokenizer.spaceMark
            let body = hasSpace ? text.dropFirst() : Substring(text)
            guard !body.isEmpty, body.utf8.allSatisfy({ ($0 | 0x20) >= 0x61 && ($0 | 0x20) <= 0x7A }),
                let word = words.id(of: body.lowercased())
            else { continue }
            let entry = (stems[word] ?? word, Int32(token))
            if hasSpace { spaced.append(entry) } else { unspaced.append(entry) }
        }
        afterSpace = Self.table(spaced)
        bare = Self.table(unspaced)
    }

    private static func table(_ entries: [(word: Int, token: Int32)]) -> Table {
        var table = Table()
        for entry in entries.sorted(by: { $0.word != $1.word ? $0.word < $1.word : $0.token < $1.token }) {
            if table.words.last != Int32(entry.word) { table.words.append(Int32(entry.word)) }
            table.tokens.append(entry.token)
            table.slots.append(Int32(table.words.count - 1))
        }
        return table
    }

    /// How many of the keyboard's words the model can predict after a space.
    public var predictableWordCount: Int { afterSpace.words.count }

    /// The next-word probabilities after `boundary`, the text before the cursor up to the start
    /// of the word being typed. Trailing spaces say the next word starts with one; a text that is
    /// empty or ends in anything else (a line break, an opening bracket or quote) takes the
    /// tokens with no space.
    public func predict(before boundary: String) throws -> WordPrediction {
        var head = Substring(boundary)
        while head.last == " " { head.removeLast() }
        let table = head.count < boundary.count && !head.isEmpty ? afterSpace : bare
        let tokens = [start] + tokenizer.encode(String(head)).suffix(contextLength - 1)

        let ids = try MLMultiArray(shape: [1, NSNumber(value: contextLength)], dataType: .int32)
        ids.withUnsafeMutableBufferPointer(ofType: Int32.self) { buffer, _ in
            buffer.update(repeating: 0)
            for (index, token) in tokens.enumerated() { buffer[index] = token }
        }
        let last = try MLMultiArray(shape: [1], dataType: .int32)
        last[0] = NSNumber(value: Int32(tokens.count - 1))
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "last": last])

        lock.lock()
        defer { lock.unlock() }
        let output = try model.prediction(from: input)
        guard let logp = output.featureValue(for: "logp")?.multiArrayValue, logp.dataType == .float32 else {
            throw LoadError.unexpectedModel("logp is not a Float32 array")
        }
        var probabilities = [Float](repeating: 0, count: table.words.count)
        logp.withUnsafeBufferPointer(ofType: Float.self) { values in
            for index in table.tokens.indices {
                let token = Int(table.tokens[index])
                guard token < values.count else { continue }
                probabilities[Int(table.slots[index])] += exp(values[token])
            }
        }
        return WordPrediction(boundary: boundary, ids: table.words, probabilities: probabilities)
    }
}
