import Foundation
import Testing
@testable import MurmurKit

struct WindowSeamTests {
    /// Words spaced 0.4 s apart starting at `start`.
    private func words(_ text: String, from start: TimeInterval) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            let begin = start + Double(index) * 0.4
            return TimedWord(text: String(word), start: begin, end: begin + 0.3)
        }
    }

    private func text(_ words: [TimedWord]) -> String { words.map(\.text).joined(separator: " ") }

    @Test("A word cut off at the earlier window's end is taken whole from the later window")
    func cutOffWord() {
        // The earlier window's audio stops at 13 s, inside "infringement": 2026-11-13.
        let previous = words("protected from any copyright inference.", from: 10.2)
        let next = words("Also are protected from any copyright infringement.", from: 9.4)
        #expect(text(WindowSeam.join(previous, next, boundary: 11)) == "protected from any copyright infringement.")
    }

    @Test("The join takes the later window's copy of the agreed word and its punctuation")
    func agreedWordFromLaterWindow() {
        let previous = words("we rework to do is.", from: 10.2)
        let next = words("Rework to do is basically", from: 10.62)
        #expect(text(WindowSeam.join(previous, next, boundary: 11)) == "we rework to do is basically")
    }

    @Test("A repeated word joins on the copy at the same time, not the first one found")
    func repeatedWord() {
        let previous = words("that that is fine", from: 10.2)
        let next = words("So that that is fine now", from: 9.8)
        #expect(text(WindowSeam.join(previous, next, boundary: 11)) == "that that is fine now")
    }

    @Test("The later window's first word is never the join")
    func cutInEdge() {
        let previous = words("going to the store", from: 10.6)
        let next = words("The store was closed", from: 11.4)
        #expect(text(WindowSeam.join(previous, next, boundary: 11)) == "going to the store was closed")
    }

    @Test("With no word in common the windows are cut by time, a straddling word kept once")
    func timeCut() {
        let previous = [
            TimedWord(text: "at", start: 10.4, end: 10.6),
            TimedWord(text: "Erickson", start: 10.9, end: 11.5),
            TimedWord(text: "the.", start: 11.6, end: 11.8),
        ]
        let next = [
            TimedWord(text: "At", start: 10.42, end: 10.6),
            TimedWord(text: "Ericsson", start: 10.94, end: 11.5),
            TimedWord(text: "that", start: 11.62, end: 11.8),
            TimedWord(text: "we", start: 11.9, end: 12.0),
        ]
        #expect(text(WindowSeam.join(previous, next, boundary: 11)) == "at Erickson that we")
    }

    @Test("Silence across the boundary keeps both sides and doubles nothing already settled")
    func silence() {
        let next = [
            TimedWord(text: "Settled", start: 9.9, end: 10.3),
            TimedWord(text: "Then", start: 12.5, end: 12.8),
            TimedWord(text: "more", start: 12.9, end: 13.1),
        ]
        #expect(text(WindowSeam.join([], next, boundary: 11, settledEnd: 10.3)) == "Then more")
        #expect(text(WindowSeam.join(words("last words", from: 10.1), [], boundary: 11)) == "last words")
    }
}
