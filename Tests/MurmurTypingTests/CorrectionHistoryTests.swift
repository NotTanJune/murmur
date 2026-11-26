import Testing

@testable import MurmurTyping

@Suite struct CorrectionHistoryTests {
    private func history() -> CorrectionHistory {
        var history = CorrectionHistory()
        history.record(original: "teh", replacement: "the", textBeforeWord: "I saw ")
        return history
    }

    @Test func offeredRightAfterTheSpaceIsDeleted() {
        #expect(history().offer(textBefore: "I saw the", nextCharacter: nil)?.original == "teh")
    }

    @Test func offeredAfterDeletingBackThroughALaterWord() {
        // "I saw the cat " typed; deleting "cat " leaves the cursor after "the" again.
        let history = history()
        #expect(history.offer(textBefore: "I saw the cat ", nextCharacter: nil) == nil)
        #expect(history.offer(textBefore: "I saw the", nextCharacter: nil) != nil)
    }

    @Test func notOfferedWhenALetterFollowsTheCursor() {
        #expect(history().offer(textBefore: "I saw the", nextCharacter: "x") == nil)
    }

    @Test func notOfferedOnceTheWordWasEdited() {
        #expect(history().offer(textBefore: "I saw thex", nextCharacter: nil) == nil)
    }
}
