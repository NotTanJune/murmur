import CoreGraphics
import Foundation
import Testing

@testable import MurmurTyping

/// The edits a fast two-thumb typist needs the decoder to repair, each with taps placed on the
/// centre of the key that was hit (so the Gaussian alone has nothing to go on) and the word before
/// it for context, as the keyboard has it. The cases are the failures found in the owner's real
/// taps (`RealTapReplayTests`).
@Suite struct DecoderEditTests {
    private let centred: [CGPoint] = [.zero]

    private func fix(
        _ typed: String, after previous: String? = nil, position: SentencePosition = .middle
    ) throws -> String? {
        let fixture = try TypingFixture()
        let decision = fixture.decide(typed: typed, previous: previous, position: position, offsets: centred)
        if case .replace(let replacement) = decision { return replacement.text }
        return nil
    }

    @Test("A string that is no word does not hold on to a strong prior: a letter left out is found with context")
    func omissionBeatsTheTypedString() throws {
        #expect(try fix("dg", after: "lazy") == "dog")
        #expect(try fix("jmps", after: "fox") == "jumps")
        #expect(try fix("azy", after: "the") == "lazy")
        #expect(try fix("qick", after: "the") == "quick")
        #expect(try fix("brwn", after: "quick") == "brown")
        let fixture = try TypingFixture()
        // A short string that is no word is almost always a slip, so its prior is low.
        #expect(fixture.decoder.literalLogPrior(2) < -12)
        #expect(fixture.decoder.literalLogPrior(2) == fixture.decoder.literalLogPrior(6))
        #expect(fixture.decoder.literalLogPrior(9) < fixture.decoder.literalLogPrior(6))
    }

    @Test("A tap on the centre of a neighbouring key is read as the key beside it")
    func neighbourSubstitution() throws {
        // n beside b, c beside v, k beside l: each tap is dead centre on the wrong key, 3 σ or more
        // from the right one, which the Gaussian alone prunes.
        #expect(try fix("nrown", after: "quick") == "brown")
        #expect(try fix("ocer", after: "jumps") == "over")
        #expect(try fix("kazy", after: "the") == "lazy")
        #expect(try fix("tbe", after: "over") == "the")
        let fixture = try TypingFixture()
        let decoding = fixture.decode("nrown", previous: "quick", offsets: centred)
        #expect(decoding.top?.kind == .substitution)
    }

    @Test("A word of four or more taps may spend two edits: a swap and a letter left out")
    func twoEdits() throws {
        // quci is quick with its last letter gone and its c and i swapped; ucik has the q gone
        // and the c and i swapped.
        #expect(try fix("quci", after: "a") == "quick")
        #expect(try fix("ucik", after: "a") == "quick")
        // Two edits need four taps: the same shape in a three letter word is left alone.
        let fixture = try TypingFixture()
        var short = fixture.decoder.configuration
        short.twoEditMinTaps = 99
        let single = TapDecoder(model: fixture.model, frames: fixture.frames, configuration: short)
        let taps = fixture.taps("ucik", offsets: centred)
        #expect(single.decode(taps: taps, previous: fixture.model.id(of: "a")).top?.text != "quick")
    }

    @Test("A letter left out at the start of a word is as findable as one inside it")
    func omissionAtTheStart() throws {
        #expect(try fix("azy", after: "the") == "lazy")
        #expect(try fix("ucik", after: "a") == "quick")
        #expect(try fix("oer", after: "jumps") == "over")
    }

    @Test("A missed space and a letter left out in one half")
    func missedSpaceWithAnEdit() throws {
        #expect(try fix("thnkyou") == "thank you")
        #expect(try fix("ithnk", position: .start) == "I think")
        #expect(try fix("goodmornin") == "good morning")
        // The exact split stays as it was.
        #expect(try fix("ofthe") == "of the")
    }

    @Test("Correct short words in their usual company are left alone")
    func correctWordsStay() throws {
        let cases: [(String, String)] = [
            ("he", "said"), ("of", "one"), ("is", "this"), ("no", "say"), ("on", "turn"), ("do", "will"),
            ("dog", "lazy"), ("fox", "brown"), ("quick", "the"), ("lazy", "the"), ("over", "jumps"),
        ]
        let fixture = try TypingFixture()
        for (word, previous) in cases {
            let decision = fixture.decide(typed: word, previous: previous, position: .middle, offsets: centred)
            if case .replace(let replacement) = decision {
                Issue.record("\(previous) \(word) became \(replacement.text)")
            }
        }
    }

    @Test("children(of:depth:) lists exactly the bytes that narrow(_:depth:byte:) finds non-empty")
    func childrenMatchNarrow() throws {
        let model = try TypingModel.bundled()
        for prefix in ["", "t", "th", "the", "don", "q", "qu", "ja", "zz", "sleep"] {
            let range = model.range(ofPrefix: prefix)
            let depth = prefix.utf8.count
            let children = model.children(of: range, depth: depth)
            var expected: [(UInt8, Range<Int>)] = []
            for byte in UInt8(0)...UInt8(255) {
                let child = model.narrow(range, depth: depth, byte: byte)
                if !child.isEmpty { expected.append((byte, child)) }
            }
            #expect(children.map(\.byte) == expected.map(\.0), "\(prefix)")
            #expect(children.map(\.range) == expected.map(\.1), "\(prefix)")
        }
        #expect(model.children(of: 0..<0, depth: 0).isEmpty)
    }

    @Test("The US spellings the SymSpell list lacks are words of the model")
    func americanSpellings() throws {
        let model = try TypingModel.bundled()
        for word in ["favorite", "favorites", "neighbor", "neighbors", "neighborhood"] {
            #expect(model.id(of: word) != nil, "\(word)")
        }
        let fixture = try TypingFixture()
        for word in ["favorite", "neighbor", "neighbors"] {
            #expect(fixture.decide(typed: word, position: .middle) == .keep(.typedIsBest), "\(word)")
        }
    }
}
