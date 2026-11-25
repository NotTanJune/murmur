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
        // "swipe" was in this list while the spatial evidence was narrow. Its exact path now ranks
        // third, behind the far likelier "store" and "stripe", because the likelihood forgives a
        // sloppy finger and a rare word pays for it (see `Configuration`'s note on the sloppy
        // benchmark); the words left are ones the model also finds frequent.
        for word in ["the", "and", "quick", "keyboard", "because", "people", "typing"] {
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
        // The decoder admits the nearest `startKeyCount` keys, but only those within the reach
        // (the nearest key always counts). The count and the reach were three and 1.2 pitches
        // before the sloppy benchmark; five and 1.8 let a swipe that began a key off find its word.
        let configuration = fixture.decoder.configuration
        let reach = configuration.keyReachPitches * fixture.decoder.pitch
        func nearest(_ point: CGPoint, count: Int) -> Set<Character> {
            func distance(_ letter: Character) -> Double {
                hypot(fixture.centre(letter).x - point.x, fixture.centre(letter).y - point.y)
            }
            let ranked = "abcdefghijklmnopqrstuvwxyz".sorted { distance($0) < distance($1) }
            return Set(ranked.prefix(count).enumerated().filter { $0.offset == 0 || distance($0.element) <= reach }.map(\.element))
        }
        var seen = 0
        for word in ["hello", "he", "the", "are", "to", "see"] {
            let path = fixture.decoder.idealPath(for: word)
            let starts = nearest(path.first!, count: configuration.startKeyCount)
            let ends = nearest(path.last!, count: configuration.endKeyCount)
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

    /// The vertices of a word's ideal path with each interior one pulled `pull` pitches toward the
    /// chord between its neighbours, as a thumb rounds a corner. Doubled letters are written once
    /// (the finger made no loop), so the word's letters are given already collapsed.
    private func cornerCut(_ letters: String, pull: Double, fixture: SwipeFixture) -> [CGPoint] {
        let vertices = fixture.path(through: letters)
        let pitch = fixture.decoder.pitch
        var result = [vertices[0]]
        for index in 1..<(vertices.count - 1) {
            let here = vertices[index]
            let toX = (vertices[index - 1].x + vertices[index + 1].x) / 2 - here.x
            let toY = (vertices[index - 1].y + vertices[index + 1].y) / 2 - here.y
            let distance = hypot(toX, toY)
            let step = min(pull * pitch, 0.9 * distance)
            result.append(CGPoint(x: here.x + step * toX / max(distance, 1e-9), y: here.y + step * toY / max(distance, 1e-9)))
        }
        result.append(vertices[vertices.count - 1])
        return result
    }

    /// The word in the model whose pair with `word` gains the most over `word`'s own unigram,
    /// that is, the word before it that most favours it.
    private func mostFavouringPrevious(of word: String, model: TypingModel) throws -> Int {
        let id = try #require(model.id(of: word))
        var best: (id: Int, gain: Float)?
        for previous in 0..<model.wordCount {
            guard let pair = model.pairLogP(previous, id) else { continue }
            let gain = pair - model.unigram(id)
            if gain > (best?.gain ?? 0) { best = (previous, gain) }
        }
        return try #require(best).id
    }

    @Test("A swipe that cuts every corner by almost half a pitch still decodes")
    func cornerCutting() throws {
        let fixture = try SwipeFixture()
        for (word, letters) in [
            ("because", "because"), ("keyboard", "keyboard"), ("people", "people"), ("typing", "typing"),
            ("quick", "quick"),
        ] {
            let path = cornerCut(letters, pull: 0.45, fixture: fixture)
            let candidates = fixture.decode(path, limit: 3)
            #expect(candidates.first?.text == word, "\(word) cut at the corners decoded as \(candidates.map(\.text))")
        }
        // "hello" swiped with no loop for its doubled l and the corners cut ends on the o, one key
        // from the p of the likelier "help": it is among the first three alone, and first when the
        // word before it fits it.
        let hello = cornerCut("helo", pull: 0.45, fixture: fixture)
        #expect(fixture.decode(hello, limit: 3).contains { $0.text == "hello" })
        let previous = try mostFavouringPrevious(of: "hello", model: fixture.model)
        let withContext = fixture.decoder.decode(path: hello, times: nil, previous: previous, limit: 3)
        #expect(withContext.first?.text == "hello", "after \(fixture.model.word(previous)): \(withContext.map(\.text))")
    }

    @Test("A doubled letter with no loop decodes as the word with the doubled letter")
    func missingLoop() throws {
        let fixture = try SwipeFixture()
        for (word, letters) in [("hello", "helo"), ("letter", "leter"), ("coffee", "cofe"), ("little", "litle")] {
            let candidates = fixture.decode(fixture.path(through: letters), limit: 3)
            #expect(candidates.contains { $0.text == word }, "\(word) without its loop decoded as \(candidates.map(\.text))")
        }
    }

    @Test("A swipe that lifts early or runs on past the last key still decodes")
    func endMisses() throws {
        let fixture = try SwipeFixture()
        let pitch = fixture.decoder.pitch
        // "people" lifted half a pitch short of the e, and "keyboard" carried on 0.5 pitch.
        var early = fixture.path(through: "people")
        let e = early[early.count - 1], l = early[early.count - 2]
        let toward = hypot(l.x - e.x, l.y - e.y)
        early[early.count - 1] = CGPoint(x: e.x + 0.5 * pitch * (l.x - e.x) / toward, y: e.y + 0.5 * pitch * (l.y - e.y) / toward)
        #expect(fixture.decode(early, limit: 3).contains { $0.text == "people" })

        var long = fixture.path(through: "keyboard")
        let d = long[long.count - 1], r = long[long.count - 2]
        let away = hypot(d.x - r.x, d.y - r.y)
        long.append(CGPoint(x: d.x + 0.5 * pitch * (d.x - r.x) / away, y: d.y + 0.5 * pitch * (d.y - r.y) / away))
        #expect(fixture.decode(long, limit: 3).contains { $0.text == "keyboard" })
    }

    @Test("A swipe that starts a key off finds its word, and the previous word makes it first")
    func startOneKeyOff() throws {
        let fixture = try SwipeFixture()
        let model = fixture.model
        // The ideal path of hello with its first point on the g, one key to the left of the h.
        var path = fixture.path(through: "helo")
        path[0] = fixture.centre("g")
        let alone = fixture.decode(path, limit: 4)
        #expect(alone.contains { $0.text == "hello" }, "started on g, decoded as \(alone.map(\.text))")

        // The preceding word that most favours hello over its own unigram, among the model's pairs.
        let favouring = try mostFavouringPrevious(of: "hello", model: model)
        let withContext = fixture.decoder.decode(path: path, times: nil, previous: favouring, limit: 4)
        #expect(withContext.first?.text == "hello", "after \(model.word(favouring)): \(withContext.map(\.text))")
    }

    @Test("The scan budget caps the words read")
    func scanBudget() throws {
        var configuration = SwipeDecoder.Configuration.tuned
        configuration.scanBudget = 40
        let fixture = try SwipeFixture(configuration: configuration)
        var stats = SwipeDecoder.ScanStats()
        _ = fixture.decoder.decode(
            path: fixture.decoder.idealPath(for: "the"), previous: nil, lexicon: .empty, limit: 3, stats: &stats)
        #expect(stats.scanned == 40)
        #expect(stats.budgetHit)

        // With the default budget a clean "the" is not cut short.
        let full = try SwipeFixture()
        var fullStats = SwipeDecoder.ScanStats()
        let result = full.decoder.decode(
            path: full.decoder.idealPath(for: "the"), previous: nil, lexicon: .empty, limit: 3, stats: &fullStats)
        #expect(result.first?.text == "the")
        #expect(fullStats.scanned <= full.decoder.configuration.scanBudget)
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

    @Test("A contact's name that is also a plain word swipes as the plain word")
    func systemNameDoesNotRespell() throws {
        let fixture = try SwipeFixture()
        try #require(fixture.model.id(of: "will") != nil)
        let contacts = UserLexicon(systemWords: ["Will", "Mark"])
        #expect(fixture.decode(fixture.decoder.idealPath(for: "will"), lexicon: contacts).first?.text == "will")
        #expect(fixture.decode(fixture.decoder.idealPath(for: "mark"), lexicon: contacts).first?.text == "mark")
        // The owner's own dictionary term still decides its spelling.
        let own = UserLexicon(dictionaryTerms: ["Will"])
        #expect(fixture.decode(fixture.decoder.idealPath(for: "will"), lexicon: own).first?.text == "Will")
        // A contact the model does not know types as written.
        try #require(fixture.model.id(of: "qpzm") == nil)
        let unknown = UserLexicon(systemWords: ["Qpzm"])
        #expect(fixture.decode(fixture.decoder.idealPath(for: "qpzm"), lexicon: unknown).first?.text == "Qpzm")
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
