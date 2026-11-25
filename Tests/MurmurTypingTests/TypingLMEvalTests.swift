import Foundation
import Testing

@testable import MurmurTyping

/// The pair model's side of the language model evaluation (`training/typing-lm/evaluate.py`).
///
/// Skipped unless `MURMUR_TYPING_LM_CASES` names a JSON array of texts before the cursor. For each
/// it writes what `SuggestionEngine` offers, as `[kind, word]` pairs in ranked order (the typed
/// entry first mid-word, then up to three completions; the three predictions after a space, best
/// first), to the file `MURMUR_TYPING_LM_OUT` names, and the model's word list, one word a line
/// with its log10 frequency, to `MURMUR_TYPING_LM_WORDS`. The Python side computes the hit rates
/// for both models from the same cases, so they cannot disagree about what a case is.
@Suite struct TypingLMEvalTests {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["MURMUR_TYPING_LM_CASES"] != nil

    @Test(.enabled(if: TypingLMEvalTests.enabled))
    func dumpPairModelSuggestions() throws {
        let environment = Self.environment
        let cases = try JSONDecoder().decode(
            [String].self, from: Data(contentsOf: URL(fileURLWithPath: #require(environment["MURMUR_TYPING_LM_CASES"]))))
        let model = try TypingModel.bundled()

        if let path = environment["MURMUR_TYPING_LM_WORDS"] {
            var lines = ""
            for id in 0..<model.wordCount { lines += "\(model.word(id))\t\(model.unigram(id))\n" }
            try lines.write(toFile: path, atomically: true, encoding: .utf8)
        }

        var answers: [[[String]]] = []
        answers.reserveCapacity(cases.count)
        for text in cases {
            var cells = SuggestionEngine.suggestions(before: text, model: model, completionLimit: 3)
            // After a space the strip's order is runner-up, best, third; put the best first.
            if cells.count >= 2, cells[0].kind == .next { cells.swapAt(0, 1) }
            answers.append(cells.map { ["\($0.kind)", $0.text] })
        }
        let out = try #require(environment["MURMUR_TYPING_LM_OUT"])
        try JSONEncoder().encode(answers).write(to: URL(fileURLWithPath: out))
        print("wrote \(answers.count) answers to \(out)")

        // What repeated taps on the centre cell write, the owner's test of 2026-11-25.
        var chains = ""
        for start in ["my dog ", "i ", "the ", "please ", "can you "] {
            var text = start
            for _ in 0..<15 {
                let cells = SuggestionEngine.suggestions(before: text, model: model)
                guard cells.count >= 2 else { break }
                text += cells[1].text + " "
            }
            chains += text + "\n"
        }
        try chains.write(toFile: out + ".chains.txt", atomically: true, encoding: .utf8)
        print(chains)
    }
}
