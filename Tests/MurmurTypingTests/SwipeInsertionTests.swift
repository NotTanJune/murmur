import Foundation
import Testing

@testable import MurmurTyping

/// The text rules of a swiped word: the space before it, its case, the strip's other readings.
@Suite struct SwipeInsertionTests {
    @Test("A space goes first unless the text is empty, ends in whitespace, or ends in an opening mark")
    func leadingSpace() {
        #expect(!SwipeInsertion.needsLeadingSpace(before: ""))
        #expect(!SwipeInsertion.needsLeadingSpace(before: "hello "))
        #expect(!SwipeInsertion.needsLeadingSpace(before: "hello\n"))
        #expect(!SwipeInsertion.needsLeadingSpace(before: "see ("))
        #expect(!SwipeInsertion.needsLeadingSpace(before: "he said \u{201C}"))
        #expect(!SwipeInsertion.needsLeadingSpace(before: "well-"))
        #expect(SwipeInsertion.needsLeadingSpace(before: "hello"))
        #expect(SwipeInsertion.needsLeadingSpace(before: "hello."))
        #expect(SwipeInsertion.needsLeadingSpace(before: "see (note)"))
        #expect(SwipeInsertion.needsLeadingSpace(before: "room 4"))
    }

    @Test("Shift capitalises the first letter, caps lock all of it, a sentence start counts as shift")
    func casing() {
        #expect(SwipeInsertion.cased("hello", shift: .off, sentenceCapital: false) == "hello")
        #expect(SwipeInsertion.cased("hello", shift: .on, sentenceCapital: false) == "Hello")
        #expect(SwipeInsertion.cased("hello", shift: .capsLock, sentenceCapital: false) == "HELLO")
        #expect(SwipeInsertion.cased("hello", shift: .off, sentenceCapital: true) == "Hello")
        #expect(SwipeInsertion.cased("hello", shift: .capsLock, sentenceCapital: true) == "HELLO")
        #expect(SwipeInsertion.cased("i'm", shift: .off, sentenceCapital: false) == "I'm")
        #expect(SwipeInsertion.cased("i\u{2019}ll", shift: .off, sentenceCapital: false) == "I\u{2019}ll")
        // The owner's own spelling keeps its inner capital when only a first capital is asked for.
        #expect(SwipeInsertion.cased("iPhone", shift: .on, sentenceCapital: false) == "iPhone")
        #expect(SwipeInsertion.cased("iPhone", shift: .capsLock, sentenceCapital: false) == "IPHONE")
    }

    @Test("A sentence start is judged with the space the swipe types: after a full stop the next word is capital")
    func sentenceCapital() {
        #expect(SwipeInsertion.wantsCapital(before: "", autocapitalization: .sentences))
        #expect(SwipeInsertion.wantsCapital(before: "Hello.", autocapitalization: .sentences))
        #expect(SwipeInsertion.wantsCapital(before: "Hello. ", autocapitalization: .sentences))
        #expect(!SwipeInsertion.wantsCapital(before: "Hello", autocapitalization: .sentences))
        #expect(!SwipeInsertion.wantsCapital(before: "Hello.", autocapitalization: .none))
        #expect(SwipeInsertion.wantsCapital(before: "Hello", autocapitalization: .words))
    }

    @Test("The previous word is the last word of the text, once the swipe's space is in")
    func previous() {
        #expect(SwipeInsertion.previousWord(before: "") == nil)
        #expect(SwipeInsertion.previousWord(before: "Hello") == "hello")
        #expect(SwipeInsertion.previousWord(before: "Hello ") == "hello")
        #expect(SwipeInsertion.previousWord(before: "so ok") == "ok")
        #expect(SwipeInsertion.previousWord(before: "Hello. ") == nil, "a sentence end has no previous word")
        #expect(SwipeInsertion.previousWord(before: "Hello.") == nil)
    }

    @Test("An offer lists the other readings and survives a swap")
    func offer() {
        let offer = SwipeOffer(readings: ["hello", "jello", "hells", "hallo", "hullo"])
        #expect(offer.word == "hello")
        #expect(offer.alternatives == ["jello", "hells", "hallo"])
        #expect(offer.isConsistent(with: "say hello"))
        #expect(!offer.isConsistent(with: "say hello "))
        #expect(!offer.isConsistent(with: "say hell"))

        let swapped = offer.choosing("hells")
        #expect(swapped?.word == "hells")
        #expect(swapped?.alternatives == ["hello", "jello", "hallo"], "the word that was typed is offered back")
        #expect(offer.choosing("hello") == nil)
        #expect(offer.choosing("nothing") == nil)

        #expect(SwipeOffer(readings: ["hello"]).alternatives.isEmpty)
    }

    @Test("The strip puts the best other reading in the centre and the runner-up on the left")
    func stripCells() {
        func cells(_ readings: [String]) -> [String] {
            SwipeInsertion.stripCells(for: SwipeOffer(readings: readings)).map(\.text)
        }
        #expect(cells(["a", "b", "c", "d"]) == ["c", "b", "d"])
        #expect(cells(["a", "b", "c"]) == ["c", "b"])
        #expect(cells(["a", "b"]) == ["b"])
        #expect(cells(["a"]).isEmpty)
    }

    @Test("Marks that sit against a swiped word with no space between")
    func attaching() {
        for mark in ",.!?;:)]}'-/" { #expect(SwipeInsertion.attachingMarks.contains(mark)) }
        #expect(!SwipeInsertion.attachingMarks.contains(" "))
        #expect(!SwipeInsertion.attachingMarks.contains("a"))
    }
}
