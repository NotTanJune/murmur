import Foundation
import Testing

@testable import MurmurTyping

/// Words in `SuggestionEngine.neverVolunteered` (English and Hinglish) are never written by the
/// keyboard's own initiative: not as a next word, not by autocorrect, not as a swipe's first reading.
@Suite struct NeverVolunteeredGuaranteeTests {
    private let flagged = SuggestionEngine.neverVolunteered

    @Test func hinglishSetIsPartOfTheFilter() {
        #expect(SuggestionEngine.hinglishAbuse.count >= 40)
        #expect(flagged.isSuperset(of: SuggestionEngine.hinglishAbuse))
        #expect(flagged.contains("porn"))
        #expect(SuggestionEngine.hinglishAbuse.allSatisfy { $0 == $0.lowercased() })
    }

    @Test("Autocorrect never turns a typo into a flagged word, and keeps one the taps spell")
    func autocorrectNeverWritesOne() throws {
        let fixture = try TypingFixture()
        var checked = 0
        for word in ["sex", "porn", "nude", "naked", "fuck", "shit", "bitch", "pussy", "casino", "poker"] {
            guard fixture.model.id(of: word) != nil else { continue }
            let letters = Array(word)
            var typos: [String] = []
            for index in letters.indices {  // one letter missing
                typos.append(String(letters[..<index]) + String(letters[(index + 1)...]))
            }
            for index in letters.indices.dropLast() {  // two neighbours swapped
                var swapped = letters
                swapped.swapAt(index, index + 1)
                typos.append(String(swapped))
            }
            for typo in typos where typo.count >= 2 && typo != word {
                if case .replace(let replacement) = fixture.decide(typed: typo, position: .middle) {
                    #expect(!flagged.contains(replacement.text.lowercased()), "\(typo) became \(replacement.text)")
                }
                checked += 1
            }
            // Spelled exactly: nothing replaces it.
            #expect(fixture.decide(typed: word, position: .middle) == .keep(.typedIsBest), "\(word)")
        }
        #expect(checked > 20)
    }

    @Test("A swipe's first reading is never a flagged word while another exists")
    func swipeFirstChoice() throws {
        let fixture = try SwipeFixture()
        var checked = 0
        for word in ["sex", "porn", "nude", "naked", "fuck", "shit", "bitch", "pussy", "casino", "poker"] {
            guard fixture.model.id(of: word) != nil else { continue }
            let candidates = fixture.decode(fixture.decoder.idealPath(for: word))
            guard let first = candidates.first else { continue }
            if candidates.contains(where: { !flagged.contains($0.text.lowercased()) }) {
                #expect(!flagged.contains(first.text.lowercased()), "\(word): \(candidates.map(\.text))")
            }
            checked += 1
        }
        #expect(checked >= 8)
    }
}
