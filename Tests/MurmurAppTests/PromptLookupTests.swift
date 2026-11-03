import Testing
@testable import Murmur

struct PromptLookupTests {
    @Test("The continuation after the longest matching n-gram is drafted, capped in length")
    func drafts() {
        // prompt: 1 2 3 4 5 6 7 ; output so far: 1 2 3 → draft the 4 5 6 7 that followed in the prompt.
        let source = [1, 2, 3, 4, 5, 6, 7, 1, 2, 3]
        #expect(S1MiniRuntime.lookup(in: source, history: [1, 2, 3]) == [4, 5, 6, 7])
        #expect(S1MiniRuntime.lookup(in: source, history: [1, 2, 3], draftLength: 2) == [4, 5])
    }

    @Test("A shorter n-gram is tried when the longest finds nothing")
    func fallsBack() {
        let source = [1, 2, 3, 4, 9, 2, 3]
        // "9 2 3" never occurs earlier; "2 3" does, followed by 4 and then the 9 that began
        // the output. The draft stops short of the trailing key itself.
        #expect(S1MiniRuntime.lookup(in: source, history: [9, 2, 3]) == [4, 9])
    }

    @Test("No match, or a match with nothing after it, drafts nothing")
    func noDraft() {
        #expect(S1MiniRuntime.lookup(in: [1, 2, 3], history: [8]) == [])
        #expect(S1MiniRuntime.lookup(in: [5, 6], history: [5, 6]) == [])
        #expect(S1MiniRuntime.lookup(in: [], history: []) == [])
    }
}
