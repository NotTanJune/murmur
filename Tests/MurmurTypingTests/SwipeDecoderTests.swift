import CoreGraphics
import Foundation
import Testing

@testable import MurmurTyping

/// Fixtures for the swipe tests and the benchmark: the stock letters page at 393 pt and a swipe
/// decoder over it.
struct SwipeFixture {
    let typing: TypingFixture
    let decoder: SwipeDecoder
    var model: TypingModel { typing.model }
    var frames: [KeyFrame] { typing.frames }

    init(configuration: SwipeDecoder.Configuration = .tuned) throws {
        typing = try TypingFixture()
        decoder = SwipeDecoder(model: typing.model, frames: typing.frames, configuration: configuration)
    }

    func centre(_ letter: Character) -> CGPoint {
        let keycap = typing.frame(letter).keycap
        return CGPoint(x: keycap.midX, y: keycap.midY)
    }

    /// A path through the middle of the keys of `letters`, with no loops.
    func path(through letters: String) -> [CGPoint] { letters.map { centre($0) } }

    func decode(
        _ path: [CGPoint], previous: String? = nil, lexicon: UserLexicon = .empty, limit: Int = 4
    ) -> [SwipeDecoder.Candidate] {
        decoder.decode(
            path: path, times: nil, previous: previous.flatMap { model.id(of: $0) }, lexicon: lexicon,
            limit: limit)
    }
}

@Suite struct SwipeDecoderTests {
    // MARK: - Decoding

    @Test("The ideal path of hello decodes to hello")
    func hello() throws {
        let fixture = try SwipeFixture()
        let candidates = fixture.decode(fixture.decoder.idealPath(for: "hello"))
        #expect(candidates.first?.text == "hello")
        #expect(candidates.first?.id == fixture.model.id(of: "hello"))
    }

    @Test("The loop for a doubled letter separates pool from poll")
    func doubledLetterLoop() throws {
        let fixture = try SwipeFixture()
        for word in ["pool", "poll"] {
            let candidates = fixture.decode(fixture.decoder.idealPath(for: word))
            #expect(candidates.first?.text == word, "\(word) decoded as \(candidates.map(\.text))")
        }
        // The two ideal paths really are different shapes: the loop sits at another key.
        let pool = fixture.decoder.idealPath(for: "pool")
        let poll = fixture.decoder.idealPath(for: "poll")
        #expect(pool != poll)
        #expect(pool.count == poll.count)
    }

    @Test("Common words decode from their ideal paths")
    func commonWords() throws {
        let fixture = try SwipeFixture()
        for word in ["the", "and", "quick", "keyboard", "because", "people", "swipe", "typing"] {
            let candidates = fixture.decode(fixture.decoder.idealPath(for: word))
            #expect(candidates.first?.text == word, "\(word) decoded as \(candidates.map(\.text))")
        }
    }

    @Test("A path that does not reach a word's letters does not decode to it")
    func shortPathIsNoMatch() throws {
        let fixture = try SwipeFixture()
        // A degenerate or one-point path decodes to nothing rather than to a word.
        #expect(fixture.decode([]).isEmpty)
        #expect(fixture.decode([fixture.centre("a")]).isEmpty)
        #expect(fixture.decode([fixture.centre("a"), fixture.centre("a")]).isEmpty)
        #expect(fixture.decode(fixture.path(through: "ab"), limit: 0).isEmpty)
    }

    @Test("Candidates start and end on the keys nearest the path's ends")
    func prunedByEnds() throws {
        let fixture = try SwipeFixture()
        func nearest(_ point: CGPoint) -> Set<Character> {
            let ranked = "abcdefghijklmnopqrstuvwxyz".sorted {
                hypot(fixture.centre($0).x - point.x, fixture.centre($0).y - point.y)
                    < hypot(fixture.centre($1).x - point.x, fixture.centre($1).y - point.y)
            }
            return Set(ranked.prefix(3))
        }
        var seen = 0
        for word in ["hello", "he", "the", "are", "to", "see"] {
            let path = fixture.decoder.idealPath(for: word)
            let starts = nearest(path.first!)
            let ends = nearest(path.last!)
            for candidate in fixture.decode(path, limit: 80) {
                seen += 1
                #expect(starts.contains(candidate.text.first!), "\(candidate.text) starts off the start keys")
                #expect(ends.contains(candidate.text.last!), "\(candidate.text) ends off the end keys")
            }
        }
        #expect(seen >= 6)
    }

    @Test("Candidates come best first and the model's unigram breaks a spatial tie")
    func ordering() throws {
        let fixture = try SwipeFixture()
        let candidates = fixture.decode(fixture.decoder.idealPath(for: "hello"), limit: 10)
        #expect(candidates.map(\.score) == candidates.map(\.score).sorted(by: >))
        #expect(Set(candidates.map(\.text)).count == candidates.count)
    }

    @Test("The previous word changes which of two near-tied words wins")
    func previousWordContext() throws {
        let fixture = try SwipeFixture()
        let model = fixture.model
        let bit = try #require(model.id(of: "bit"))
        let but = try #require(model.id(of: "but"))
        // A gesture b, then halfway between i and u, then t: bit and but fit it equally well.
        let i = fixture.centre("i"), u = fixture.centre("u")
        let ambiguous = [
            fixture.centre("b"), CGPoint(x: (i.x + u.x) / 2, y: (i.y + u.y) / 2), fixture.centre("t"),
        ]
        // The preceding words that most favour each, among those the model pairs with both.
        var favouringBit: (id: Int, gap: Float)?
        var favouringBut: (id: Int, gap: Float)?
        for previous in 0..<model.wordCount {
            guard let a = model.pairLogP(previous, bit), let b = model.pairLogP(previous, but) else { continue }
            if a - b > (favouringBit?.gap ?? 0) { favouringBit = (previous, a - b) }
            if b - a > (favouringBut?.gap ?? 0) { favouringBut = (previous, b - a) }
        }
        let bitFirst = try #require(favouringBit)
        let butFirst = try #require(favouringBut)

        let withBit = fixture.decoder.decode(path: ambiguous, times: nil, previous: bitFirst.id)
        let withBut = fixture.decoder.decode(path: ambiguous, times: nil, previous: butFirst.id)
        #expect(withBit.first?.id == bit, "after \(model.word(bitFirst.id)): \(withBit.map(\.text))")
        #expect(withBut.first?.id == but, "after \(model.word(butFirst.id)): \(withBut.map(\.text))")
    }

    @Test("A word of the user's lexicon that the model lacks can be swiped")
    func lexiconWord() throws {
        let fixture = try SwipeFixture()
        try #require(fixture.model.id(of: "qpzm") == nil)
        let lexicon = UserLexicon(dictionaryTerms: ["Qpzm"])
        let withLexicon = fixture.decode(fixture.decoder.idealPath(for: "qpzm"), lexicon: lexicon)
        #expect(withLexicon.first?.text == "Qpzm")
        #expect(withLexicon.first?.id == nil)
        let without = fixture.decode(fixture.decoder.idealPath(for: "qpzm"))
        #expect(!without.contains { $0.text == "Qpzm" })
    }

    @Test("A lexicon bonus can lift a word the model knows")
    func lexiconBonus() throws {
        let fixture = try SwipeFixture()
        // "iPhone" is spelled with its own capitals when the owner has it in the dictionary.
        let lexicon = UserLexicon(dictionaryTerms: ["iPhone"])
        let candidates = fixture.decode(fixture.decoder.idealPath(for: "iphone"), lexicon: lexicon)
        #expect(candidates.first?.text == "iPhone")
    }

    // MARK: - Touch rules

    @Test("A slide shorter than a pitch is a tap, one longer is a swipe")
    func swipeStart() throws {
        let fixture = try SwipeFixture()
        let pitch = CGFloat(fixture.decoder.pitch)
        #expect(abs(pitch - 38.7) < 0.1)
        let start = fixture.centre("g")
        #expect(!SwipeDecoder.isSwipe(start: start, current: start, pitch: pitch))
        #expect(!SwipeDecoder.isSwipe(start: start, current: CGPoint(x: start.x + 0.9 * pitch, y: start.y), pitch: pitch))
        #expect(SwipeDecoder.isSwipe(start: start, current: CGPoint(x: start.x + 1.1 * pitch, y: start.y), pitch: pitch))
        // Distance, not direction: a diagonal of 0.8 pitch each way is 1.13 pitches.
        #expect(SwipeDecoder.isSwipe(start: start, current: CGPoint(x: start.x + 0.8 * pitch, y: start.y - 0.8 * pitch), pitch: pitch))
    }

    @Test("A swipe that lifts on its starting key within 1.6 pitches is a tap")
    func tapRule() throws {
        let fixture = try SwipeFixture()
        let pitch = CGFloat(fixture.decoder.pitch)
        let g = fixture.centre("g")
        // Out 1.2 pitches and back: crossed the swipe threshold, but ends where it began.
        let outAndBack = [g, CGPoint(x: g.x + 1.2 * pitch, y: g.y), CGPoint(x: g.x + 2, y: g.y + 1)]
        #expect(fixture.decoder.isTap(path: outAndBack))
        // Out 2 pitches and back: strayed too far to be a slip.
        let farAndBack = [g, CGPoint(x: g.x + 2 * pitch, y: g.y), g]
        #expect(!fixture.decoder.isTap(path: farAndBack))
        // Lifts on another key.
        #expect(!fixture.decoder.isTap(path: [g, fixture.centre("h")]))
        #expect(!fixture.decoder.isTap(path: []))
    }

    // MARK: - Paths

    @Test("Resampling gives 32 equidistant points")
    func resampling() {
        // Uneven vertices on one line: the equal arc spacing shows as equal chords.
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 31, y: 0)]
        let points = SwipeDecoder.resample(line, count: 32)
        #expect(points.count == 32)
        #expect(points.first == CGPoint(x: 0, y: 0))
        #expect(abs(points.last!.x - 31) < 1e-9)
        for index in 1..<points.count {
            #expect(abs(hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y) - 1) < 1e-9)
        }
        // Around a corner the spacing is along the path, not the chord: the sample that lands on
        // the corner is 10 along each leg.
        let corner = SwipeDecoder.resample(
            [CGPoint(x: 0, y: 0), CGPoint(x: 31, y: 0), CGPoint(x: 31, y: 31)], count: 63)
        #expect(corner.count == 63)
        #expect(abs(corner[31].x - 31) < 1e-9 && abs(corner[31].y) < 1e-9)
        #expect(abs(corner[62].y - 31) < 1e-9)
        // No length at all: every sample is the point.
        let still = SwipeDecoder.resample([CGPoint(x: 5, y: 6), CGPoint(x: 5, y: 6)], count: 4)
        #expect(still == Array(repeating: CGPoint(x: 5, y: 6), count: 4))
    }

    @Test("An ideal path goes through the key centres and loops on a doubled letter")
    func idealPath() throws {
        let fixture = try SwipeFixture()
        let decoder = fixture.decoder
        let tee = decoder.idealPath(for: "the")
        #expect(tee.count == 3)
        for (point, letter) in zip(tee, "the") {
            #expect(hypot(point.x - fixture.centre(letter).x, point.y - fixture.centre(letter).y) < 1e-6)
        }
        let loop = decoder.idealPath(for: "oo")
        #expect(loop.count > 3)
        #expect(hypot(loop.first!.x - loop.last!.x, loop.first!.y - loop.last!.y) < 1e-6)
        // The loop stays within its radius of the key's centre, twice over.
        let radius = decoder.configuration.loopRadius * decoder.pitch
        for point in loop {
            let away = hypot(point.x - fixture.centre("o").x, point.y - fixture.centre("o").y)
            #expect(away <= 2 * radius + 1e-6)
        }
        // An apostrophe has no key and is skipped; another character makes no path.
        #expect(decoder.idealPath(for: "don't") == decoder.idealPath(for: "dont"))
        #expect(decoder.idealPath(for: "a1").isEmpty)
        #expect(decoder.idealPath(for: "").isEmpty)
    }
}
