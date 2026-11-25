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

    @Test func aFolderWithoutTheFilesIsRefused() {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-\(UUID().uuidString)")
        #expect(NextWordPredictor.Files(folder: empty) == nil)
        #expect(throws: (any Error).self) {
            _ = try BPETokenizer(
                vocabulary: empty.appendingPathComponent("vocab.json"), merges: empty.appendingPathComponent("merges.txt"))
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
            for _ in 0..<15 {
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
                text += cells[1].text + " "
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
