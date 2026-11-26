import Foundation
import Testing

@testable import MurmurTyping

/// Checks a word model built with `Tools/build_typing_model.py --hinglish`. The model derives from
/// a corpus that is not GPL-compatible, so it is never in the repository: the tests run only when
/// `MURMUR_HINGLISH_MTM` names the built file (normally `ios/TypingLM/en.mtm`).
///
///     MURMUR_HINGLISH_MTM=ios/TypingLM/en.mtm swift test --filter HinglishModelTests
@Suite struct HinglishModelTests {
    static let path = ProcessInfo.processInfo.environment["MURMUR_HINGLISH_MTM"]

    private func fixture() throws -> TypingFixture {
        let url = URL(fileURLWithPath: try #require(Self.path))
        return try TypingFixture(model: TypingModel(url: url))
    }

    @Test("Hinglish words are kept as typed", .enabled(if: path != nil))
    func keepsHinglishWords() throws {
        let fixture = try fixture()
        let words = [
            "kya", "nahi", "acha", "accha", "yaar", "haan", "theek", "kuch", "bahut", "matlab", "abhi", "kaise",
            "kyun", "chalo", "bhai",
        ]
        var replaced: [String] = []
        for word in words {
            if case .replace(let replacement) = fixture.decide(typed: word, position: .middle) {
                replaced.append("\(word) -> \(replacement.text)")
            }
            #expect(fixture.model.id(of: word) != nil, "\(word) is not in the model")
        }
        #expect(replaced.isEmpty, "\(replaced)")
    }

    @Test("English typos are still corrected", .enabled(if: path != nil))
    func stillCorrectsEnglish() throws {
        let fixture = try fixture()
        for (typo, fix) in [("teh", "the"), ("adn", "and"), ("becuase", "because"), ("recieve", "receive")] {
            guard case .replace(let replacement) = fixture.decide(typed: typo, position: .middle) else {
                Issue.record("\(typo) was kept")
                continue
            }
            #expect(replacement.text == fix, "\(typo) became \(replacement.text)")
        }
    }

    @Test("Completions and pairs", .enabled(if: path != nil))
    func completionsAndPairs() throws {
        let model = try fixture().model
        let completions = SuggestionEngine.suggestions(before: "nah", model: model).map(\.text)
        #expect(completions.contains("nahi"), "\(completions)")
        let kya = try #require(model.id(of: "kya"))
        let hai = try #require(model.id(of: "hai"))
        let next = model.next(after: kya, limit: 10)
        #expect(next.contains(hai), "\(next.map { model.word($0) })")
        print("after kya:", next.map { model.word($0) })
        print("nah completions:", completions)
    }

    @Test("Hinglish abuse is never volunteered and never autocorrected into", .enabled(if: path != nil))
    func abuseFilter() throws {
        let fixture = try fixture()
        let model = fixture.model
        let inModel = SuggestionEngine.hinglishAbuse.filter { model.id(of: $0) != nil }
        print("filter words: \(SuggestionEngine.hinglishAbuse.count), in this model: \(inModel.count)")
        #expect(inModel.count > 0)
        // No next-word suggestion after common words is one of them.
        for previous in ["tu", "abe", "kya", "yaar", "tera", "mera", "bhai", "tum", "ye", "wo", "ja", "chal"] {
            let words = SuggestionEngine.suggestions(before: previous + " ", model: model).map { $0.text.lowercased() }
            #expect(words.allSatisfy { !SuggestionEngine.neverVolunteered.contains($0) }, "\(previous): \(words)")
        }
        // A one-letter slip never autocorrects into one.
        for word in inModel where word.count >= 4 {
            let typo = String(word.dropLast())
            if case .replace(let replacement) = fixture.decide(typed: typo, position: .middle) {
                #expect(!SuggestionEngine.neverVolunteered.contains(replacement.text.lowercased()), "\(typo)")
            }
        }
    }
}
