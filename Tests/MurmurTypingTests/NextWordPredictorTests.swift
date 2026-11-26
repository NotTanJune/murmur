import CoreML
import Foundation
import Testing

@testable import MurmurTyping

/// The language model's files, which are not in the repo: `Tools/fetch_typing_lm.py` writes
/// them to `ios/TypingLM`. `MURMUR_TYPING_LM_DIR` names another folder.
enum TypingLMFiles {
    static let folder: URL = {
        if let path = ProcessInfo.processInfo.environment["MURMUR_TYPING_LM_DIR"] {
            return URL(fileURLWithPath: path)
        }
        // Tests/MurmurTypingTests/<this file> is two folders below the repo's root.
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ios/TypingLM")
    }()

    static let files = NextWordPredictor.Files(folder: folder)
    static let hasTokenizer =
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("vocab.json").path)
        && FileManager.default.fileExists(atPath: folder.appendingPathComponent("merges.txt").path)
    static let missing: Comment =
        "the language model is not in ios/TypingLM (run Tools/fetch_typing_lm.py --fetch)"
}

@Suite struct BPETokenizerTests {
    private struct Vector: Decodable {
        let text: String
        let ids: [Int32]
    }

    /// The reference tokenizer's ids for 379 texts (`training/typing-lm/make_bpe_vectors.py`):
    /// apostrophes, capitals, emoji, digits, leading and repeated spaces, line breaks, other
    /// scripts and everyday sentences.
    @Test(.enabled(if: TypingLMFiles.hasTokenizer, TypingLMFiles.missing))
    func encodesLikeTheReference() throws {
        let tokenizer = try BPETokenizer(
            vocabulary: TypingLMFiles.folder.appendingPathComponent("vocab.json"),
            merges: TypingLMFiles.folder.appendingPathComponent("merges.txt"))
        let url = try #require(Bundle.module.url(forResource: "bpe-vectors", withExtension: "json"))
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        #expect(vectors.count >= 300)
        var wrong = 0
        for vector in vectors where tokenizer.encode(vector.text) != vector.ids {
            wrong += 1
            Issue.record("\(vector.text.debugDescription): \(tokenizer.encode(vector.text)), expected \(vector.ids)")
        }
        #expect(wrong == 0)
        #expect(tokenizer.endOfText == 50256)
        #expect(tokenizer.tokens.count == 50257)
        #expect(tokenizer.tokens[tokenizer.encode(" the").first.map(Int.init) ?? 0] == "Ġthe")
    }

    private func tokenizer(adding table: URL?) throws -> BPETokenizer {
        try BPETokenizer(
            vocabulary: TypingLMFiles.folder.appendingPathComponent("vocab.json"),
            merges: TypingLMFiles.folder.appendingPathComponent("merges.txt"), addedTokens: table)
    }

    private func check(_ tokenizer: BPETokenizer, against vectors: URL) throws -> Int {
        let list = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: vectors))
        var wrong = 0
        for vector in list where tokenizer.encode(vector.text) != vector.ids {
            wrong += 1
            Issue.record("\(vector.text.debugDescription): \(tokenizer.encode(vector.text)), expected \(vector.ids)")
        }
        return wrong
    }

    /// Plan 004: three ordinary words (`added-tokens-test.txt`, written by hand) are whole-word tokens,
    /// 50257 on, and the reference's ids for about 600 texts around them (`make_bpe_vectors.py --added`,
    /// the 379 plain texts included) are what the Swift tokenizer gives. Whole pieces only: " kyaa" and
    /// " nahin" are cut as before.
    @Test(.enabled(if: TypingLMFiles.hasTokenizer, TypingLMFiles.missing))
    func addedTokensEncodeLikeTheReference() throws {
        let words = try #require(Bundle.module.url(forResource: "added-tokens-test", withExtension: "txt"))
        var table: [String: Int] = [:]
        for (index, line) in try String(contentsOf: words, encoding: .utf8).split(separator: "\n").enumerated() {
            table[String(line)] = 50257 + index
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-added-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONSerialization.data(withJSONObject: table).write(to: file)

        let plain = try tokenizer(adding: nil)
        let added = try tokenizer(adding: file)
        let vectors = try #require(Bundle.module.url(forResource: "bpe-vectors-added", withExtension: "json"))
        #expect(try check(added, against: vectors) == 0)
        #expect(added.vocabularySize == 50260)
        #expect(plain.vocabularySize == 50257)
        #expect(added.tokens[50257] == "Ġkya")

        #expect(added.encode(" kya") == [50257])
        #expect(added.encode("dog nahi.").last == 13 && added.encode("dog nahi.").dropLast().last == 50258)
        // Only a whole piece is an added token.
        #expect(added.encode(" kyaa") == plain.encode(" kyaa"))
        #expect(added.encode(" nahin") == plain.encode(" nahin"))
        #expect(added.encode("kya") == plain.encode("kya"))
        #expect(added.encode(" Kya") == plain.encode(" Kya"))
        #expect(added.encode("dog\nkya") == plain.encode("dog\nkya"))
        // Without the file nothing changes: the 379 plain vectors are the other test's.
        #expect(plain.encode(" kya").count == 2)
    }

    @Test(.enabled(if: TypingLMFiles.hasTokenizer, TypingLMFiles.missing))
    func aBrokenAddedTokenTableIsRefused() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-added-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        for body in ["[1]", "{\" kya\": \"x\"}", "{\" kya\": 5}", "{\" kya\": 50257, \" nahi\": 50257}"] {
            try Data(body.utf8).write(to: file)
            #expect(throws: BPETokenizer.LoadError.unreadableAddedTokens, "\(body)") { _ = try tokenizer(adding: file) }
        }
    }

    /// The same check against the real list (derived from a corpus that is not GPL-compatible, so
    /// neither it nor its vectors are in the repository): `MURMUR_ADDED_TOKENS_JSON` is the built
    /// `added_tokens.json` and `MURMUR_ADDED_VECTORS` the vectors `make_bpe_vectors.py --added` wrote
    /// for its word list.
    @Test(.enabled(
        if: TypingLMFiles.hasTokenizer && ProcessInfo.processInfo.environment["MURMUR_ADDED_VECTORS"] != nil,
        "set MURMUR_ADDED_TOKENS_JSON and MURMUR_ADDED_VECTORS"))
    func theRealAddedTokensEncodeLikeTheReference() throws {
        let environment = ProcessInfo.processInfo.environment
        let tablePath = try #require(environment["MURMUR_ADDED_TOKENS_JSON"])
        let vectorsPath = try #require(environment["MURMUR_ADDED_VECTORS"])
        let table = URL(fileURLWithPath: tablePath)
        let vectors = URL(fileURLWithPath: vectorsPath)
        let added = try tokenizer(adding: table)
        #expect(added.vocabularySize > 50257)
        #expect(try check(added, against: vectors) == 0)
    }

    @Test func aFolderWithoutTheFilesIsRefused() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-\(UUID().uuidString)")
        #expect(NextWordPredictor.Files(folder: empty) == nil)
        #expect(throws: (any Error).self) {
            _ = try BPETokenizer(
                vocabulary: empty.appendingPathComponent("vocab.json"), merges: empty.appendingPathComponent("merges.txt"))
        }
    }
}

@Suite struct AddedTokenModelWidthTests {
    /// A tokenizer with added ids on a model that has no rows for them is refused when the model is
    /// loaded (the stock model's `logp` is 50,257 wide); out-of-range ids would never reach it.
    @Test(.enabled(if: TypingLMFiles.files != nil, TypingLMFiles.missing))
    func aNarrowModelRefusesAddedTokens() throws {
        let source = try #require(TypingLMFiles.files)
        let width = try MLModel(contentsOf: source.model).modelDescription
            .outputDescriptionsByName["logp"]?.multiArrayConstraint?.shape.last?.intValue
        guard width == 50257 else { return }  // a folder built with added tokens: nothing narrow to test
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-narrow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in [NextWordPredictor.Files.modelName, "vocab.json", "merges.txt"] {
            try FileManager.default.createSymbolicLink(
                at: folder.appendingPathComponent(name), withDestinationURL: TypingLMFiles.folder.appendingPathComponent(name))
        }
        try Data("{\" kya\": 50257}".utf8).write(to: folder.appendingPathComponent("added_tokens.json"))
        let files = try #require(NextWordPredictor.Files(folder: folder))
        #expect(files.addedTokens != nil)
        #expect(throws: NextWordPredictor.LoadError.self) {
            _ = try NextWordPredictor(files: files, words: TypingModel.bundled())
        }
    }
}

@Suite(.serialized) struct NextWordPredictorTests {
    private static let predictor = Result { () throws -> NextWordPredictor in
        try NextWordPredictor(files: #require(TypingLMFiles.files), words: TypingModel.bundled())
    }

    @Test(.enabled(if: TypingLMFiles.files != nil, TypingLMFiles.missing))
    func predictsWordsThatFitTheSentence() throws {
        let predictor = try Self.predictor.get()
        let model = try TypingModel.bundled()
        #expect(predictor.contextLength >= 16)
        #expect(predictor.predictableWordCount > 15_000)

        let answer = try predictor.predict(before: "my dog ")
        #expect(answer.boundary == "my dog ")
        let best = answer.best.prefix(10).map { model.word($0.id) }
        #expect(best.contains("is"), "after \"my dog\": \(best)")
        #expect(answer.best.first.map { $0.probability > 0.01 && $0.probability <= 1 } == true)

        // A contraction's stem stands for the contraction.
        let did = try predictor.predict(before: "no i ").best.prefix(40).map { model.word($0.id) }
        #expect(!did.contains("didn"))
        #expect(did.contains("don't") || did.contains("didn't"), "after \"no i\": \(did)")

        // An empty text and a line break predict a first word.
        #expect(try !predictor.predict(before: "").best.isEmpty)
        #expect(try !predictor.predict(before: "thanks.\n").best.isEmpty)
        // Text longer than the window is cut from the left.
        let long = String(repeating: "we went to the shop and then ", count: 30)
        #expect(try !predictor.predict(before: long).best.isEmpty)
    }

    /// Plan 004 on the real thing: a folder built with `fetch_typing_lm.py --added-tokens` (point
    /// `MURMUR_TYPING_LM_DIR` at it) and the word model built with the same words
    /// (`MURMUR_HINGLISH_MTM`, `ios/TypingLM/en.mtm`). An added word, which was two tokens or more,
    /// now has a probability at a word boundary, and the model's width matches the tokenizer's. Neither
    /// the folder nor the word model is in the repository.
    @Test(.enabled(
        if: TypingLMFiles.files?.addedTokens != nil && ProcessInfo.processInfo.environment["MURMUR_HINGLISH_MTM"] != nil,
        "needs MURMUR_TYPING_LM_DIR with added_tokens.json and MURMUR_HINGLISH_MTM"))
    func anAddedWordIsPredictedAsOneWord() throws {
        let files = try #require(TypingLMFiles.files)
        let environment = ProcessInfo.processInfo.environment
        let wordsPath = try #require(environment["MURMUR_HINGLISH_MTM"])
        let words = try TypingModel(url: URL(fileURLWithPath: wordsPath))
        let tableURL = try #require(files.addedTokens)
        let table = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: tableURL)) as? [String: Int])
        let predictor = try NextWordPredictor(files: files, words: words)
        let english = try Self.predictor.get()
        let gained = predictor.predictableWordCount - english.predictableWordCount
        print("added tokens: \(table.count) in the table, \(gained) more predictable words than the English word model")
        #expect(gained > 0)

        let answer = try predictor.predict(before: "my dog ")
        var checked = 0
        for text in table.keys.sorted().prefix(400) {
            guard let id = words.id(of: String(text.dropFirst())) else { continue }
            checked += 1
            let found = answer.candidates(in: id..<(id + 1))
            #expect(found.count == 1 && found[0].probability > 0, "\(text) has no probability")
        }
        print("added words checked against the word model: \(checked)")
        #expect(checked > 100, "only \(checked) added words are in the word model")
        // The same folder's words, one token each, are what the tokenizer reads back.
        #expect(try !predictor.predict(before: "").best.isEmpty)
    }

    /// How many taps each chain below makes; `MURMUR_TYPING_LM_TAPS` asks for more, to read what
    /// a long run without punctuation turns into.
    private static let chainTaps =
        ProcessInfo.processInfo.environment["MURMUR_TYPING_LM_TAPS"].flatMap(Int.init) ?? 15

    /// What the strip offers with the model behind it, and what repeated taps on the centre cell
    /// write: the owner's test of 2026-11-25, which read "my dog breeds of the same time to the
    /// first to be a new window" on the pair model.
    @Test(.enabled(if: TypingLMFiles.files != nil, TypingLMFiles.missing))
    func stripAndCentreTapChains() throws {
        let predictor = try Self.predictor.get()
        let model = try TypingModel.bundled()
        var milliseconds: [Double] = []
        for start in ["my dog ", "i ", "the ", "please ", "can you "] {
            var text = start
            for _ in 0..<Self.chainTaps {
                let began = ContinuousClock.now
                let answer = try predictor.predict(before: #require(SuggestionEngine.boundary(before: text)))
                milliseconds.append((ContinuousClock.now - began) / .milliseconds(1))
                let cells = SuggestionEngine.suggestions(
                    before: text, model: model, prediction: answer, capitalisesStarts: false)
                #expect(cells.count == 3)
                #expect(cells.allSatisfy { $0.kind == .next })
                for cell in cells {
                    let word = cell.text.lowercased()
                    #expect(!SuggestionEngine.neverVolunteered.contains(word))
                    #expect(word.count >= 2 || word == "a" || word == "i")
                }
                // The keyboard types a curly apostrophe where the field has smart quotes on.
                text += cells[1].text.replacingOccurrences(of: "'", with: "\u{2019}") + " "
            }
            print(text)
            let words = text.split(separator: " ").map(String.init)
            #expect(Set(words).count >= 10, "a chain that loops: \(text)")
        }
        milliseconds.sort()
        print(String(
            format: "predict: median %.1f ms, slowest %.1f ms over %d calls", milliseconds[milliseconds.count / 2],
            milliseconds[milliseconds.count - 1], milliseconds.count))

        // Mid-word the same answer ranks the completions; nothing runs again.
        let answer = try predictor.predict(before: "my dog ")
        let completions = SuggestionEngine.suggestions(before: "my dog i", model: model, prediction: answer)
        #expect(completions.map(\.text) == ["i", "is", "isn't"] || completions[1].text == "is", "\(completions)")
    }
}
