import Testing

@testable import MurmurTyping

@Suite struct TextReplacementTests {
    private let replacements = TextReplacements(pairs: [
        (shortcut: "addr", phrase: "12 Example Street, Springfield"),
        (shortcut: "Will", phrase: "Will"),
    ])

    @Test func matchesWithoutRegardToCase() {
        let match = replacements.expansion(forTextBefore: "send it to Addr")
        #expect(match?.shortcut == "Addr")
        #expect(match?.phrase == "12 Example Street, Springfield")
    }

    @Test func aNamePairIsNotAReplacement() {
        #expect(replacements.expansion(forTextBefore: "hi Will") == nil)
        #expect(replacements.shortcuts == ["addr"])
    }

    @Test func aLongerTokenDoesNotMatch() {
        #expect(replacements.expansion(forTextBefore: "xaddr") == nil)
    }
}
