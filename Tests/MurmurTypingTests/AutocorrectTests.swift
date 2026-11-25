import CoreGraphics
import Foundation
import MurmurDictionary
import Testing

@testable import MurmurTyping

/// Fixtures shared by the autocorrect tests and the replay benchmark: the stock letters page at
/// 393 pt, a decoder over it, and taps drawn around key centres.
struct TypingFixture {
    let model: TypingModel
    let frames: [KeyFrame]
    let decoder: TapDecoder

    init(configuration: TapDecoder.Configuration = .tuned) throws {
        model = try TypingModel.bundled()
        let metrics = KeyboardMetrics(width: 393, isLandscape: false)
        frames = metrics.frames(for: KeyboardLayout.rows(for: .letters, showsGlobe: false))
        decoder = TapDecoder(model: model, frames: frames, configuration: configuration)
    }

    func frame(_ letter: Character) -> KeyFrame {
        frames.first { $0.kind == .character(String(letter)) }!
    }

    /// Taps for `letters`, each `offsets[i % count]` points from its key's centre: a steady hand
    /// that is never quite on the middle of a key.
    func taps(
        _ letters: String,
        offsets: [CGPoint] = [
            CGPoint(x: 4, y: -5), CGPoint(x: -6, y: 3), CGPoint(x: 3, y: 6), CGPoint(x: -5, y: -4),
        ]
    ) -> [WordTap] {
        letters.enumerated().map { index, letter in
            let keycap = frame(letter).keycap
            let offset = offsets[index % offsets.count]
            return WordTap(
                point: CGPoint(x: keycap.midX + offset.x, y: keycap.midY + offset.y),
                key: .character(String(letter)))
        }
    }

    func decode(
        _ letters: String, previous: String? = nil, lexicon: UserLexicon = .empty, offsets: [CGPoint]? = nil
    ) -> TapDecoder.Decoding {
        decoder.decode(
            taps: offsets.map { taps(letters, offsets: $0) } ?? taps(letters),
            previous: previous.flatMap { model.id(of: $0) }, lexicon: lexicon)
    }

    /// What autocorrect does with `typed` after it was tapped as `letters`.
    func decide(
        typed: String, letters: String? = nil, previous: String? = nil, field: FieldTraits = .standard,
        position: SentencePosition = .start, lexicon: UserLexicon = .empty,
        rejections: RejectionSet = RejectionSet(), offsets: [CGPoint]? = nil
    ) -> AutocorrectDecision {
        let decoding = decode(
            letters ?? typed.lowercased(), previous: previous, lexicon: lexicon, offsets: offsets)
        return AutocorrectPolicy.decide(
            typed: typed, decoding: decoding, field: field,
            knowledge: lexicon.knowledge(of: typed, model: model), position: position,
            rejections: rejections, model: model)
    }
}

@Suite struct AutocorrectTests {
    private func replacementText(_ decision: AutocorrectDecision) -> String? {
        if case .replace(let replacement) = decision { return replacement.text }
        return nil
    }

    // MARK: - Policy

    @Test("Fields that refuse autocorrect keep the word; a web search field does not refuse")
    func fieldRules() throws {
        let fixture = try TypingFixture()
        var refusing: [FieldTraits] = []
        refusing.append(FieldTraits(autocorrectionAllowed: false))
        refusing.append(FieldTraits(spellCheckingAllowed: false))
        refusing.append(FieldTraits(isSecure: true))
        for kind in [FieldKeyboardKind.url, .email, .number, .phone] {
            refusing.append(FieldTraits(keyboardKind: kind))
        }
        for field in refusing {
            #expect(fixture.decide(typed: "teh", field: field) == .keep(.fieldDisallows), "\(field)")
        }
        let search = FieldTraits(keyboardKind: .webSearch)
        #expect(replacementText(fixture.decide(typed: "teh", field: search)) == "the")
    }

    @Test("A digit, @, #, / or a full stop inside the word keeps it as typed")
    func notProse() throws {
        let fixture = try TypingFixture()
        for typed in ["teh2", "2teh", "teh@", "@teh", "#teh", "te/h", "t.eh", "teh.com"] {
            #expect(fixture.decide(typed: typed, letters: "teh") == .keep(.notAPlainWord), "\(typed)")
        }
    }

    @Test("A capital letter in the middle of a sentence is a name; at a sentence start it is not")
    func capitals() throws {
        let fixture = try TypingFixture()
        #expect(fixture.decide(typed: "Teh", letters: "teh", position: .middle) == .keep(.capitalMidSentence))
        #expect(replacementText(fixture.decide(typed: "Teh", letters: "teh", position: .start)) == "The")
        // An acronym typed in capitals is left alone anywhere.
        #expect(fixture.decide(typed: "TEH", letters: "teh", position: .start) == .keep(.tooShortOrAcronym))
        #expect(SentencePosition.of(textBeforeWord: "") == .start)
        #expect(SentencePosition.of(textBeforeWord: "Hello. ") == .start)
        #expect(SentencePosition.of(textBeforeWord: "Hello ") == .middle)
    }

    @Test("A fix refused twice for good, or once this session, is not applied; once persisted it still is")
    func rejections() throws {
        let fixture = try TypingFixture()
        #expect(replacementText(fixture.decide(typed: "teh")) == "the")

        var persisted = RejectionSet(persisted: [.init(original: "teh", replacement: "the", count: 2)])
        #expect(fixture.decide(typed: "teh", rejections: persisted) == .keep(.rejected))

        let once = RejectionSet(persisted: [.init(original: "teh", replacement: "the", count: 1)])
        #expect(replacementText(fixture.decide(typed: "teh", rejections: once)) == "the")

        var session = RejectionSet()
        session.rejectForSession(original: "teh", replacement: "the")
        #expect(fixture.decide(typed: "teh", rejections: session) == .keep(.rejected))
        // The pair is what is refused, not the word.
        #expect(replacementText(fixture.decide(typed: "hte", rejections: session)) == "the")

        // Two undos in a row reach the persisted limit, and the list round trips as JSON.
        var counted = RejectionSet()
        counted.recordUndo(original: "teh", replacement: "the")
        counted.recordUndo(original: "teh", replacement: "the")
        #expect(counted.entries == [.init(original: "teh", replacement: "the", count: 2)])
        let data = try JSONEncoder().encode(counted.entries)
        let restored = RejectionSet(persisted: try JSONDecoder().decode([RejectionSet.Entry].self, from: data))
        #expect(restored.isRejected(original: "Teh", replacement: "the"))
        persisted = RejectionSet()
        #expect(!persisted.isRejected(original: "teh", replacement: "the"))
    }

    @Test("A contraction typed without its apostrophe always gets it, in any case, unless refused")
    func contractions() throws {
        let fixture = try TypingFixture()
        #expect(replacementText(fixture.decide(typed: "im", position: .middle)) == "I'm")
        #expect(replacementText(fixture.decide(typed: "dont", position: .middle)) == "don't")
        #expect(replacementText(fixture.decide(typed: "Dont", letters: "dont", position: .start)) == "Don't")
        #expect(replacementText(fixture.decide(typed: "youre", position: .middle)) == "you're")
        // Sloppy taps do not matter: the rule reads the letters the keys resolved to.
        let sloppy = [CGPoint(x: 14, y: -14), CGPoint(x: -14, y: 14), CGPoint(x: 14, y: 14), CGPoint(x: -14, y: -14)]
        let decoding = fixture.decoder.decode(taps: fixture.taps("dont", offsets: sloppy), previous: nil)
        let decision = AutocorrectPolicy.decide(
            typed: "dont", decoding: decoding, field: .standard, knowledge: WordKnowledge(), position: .middle,
            rejections: RejectionSet(), model: fixture.model)
        #expect(replacementText(decision) == "don't")
        // A real word that is also a contraction without its apostrophe is not forced.
        #expect(replacementText(fixture.decide(typed: "ill", position: .middle)) == nil)
        // The field and the owner still win.
        #expect(fixture.decide(typed: "dont", field: FieldTraits(keyboardKind: .email)) == .keep(.fieldDisallows))
        var refused = RejectionSet()
        refused.recordUndo(original: "dont", replacement: "don't")
        refused.recordUndo(original: "dont", replacement: "don't")
        #expect(fixture.decide(typed: "dont", rejections: refused) == .keep(.rejected))
    }

    @Test("Dictionary terms, system names and kept words are never corrected away, and near misses are pulled in")
    func protectedWords() throws {
        let fixture = try TypingFixture()
        let lexicon = UserLexicon(
            entries: [
                .term("Zorbix"), .correction(hear: "pivot studios", write: "Pivot Studio"),
                DictionaryEntry(kind: .term, write: "Hidden", isEnabled: false),
            ],
            systemWords: ["Teh"], keptWords: ["wuz"])
        // Typed exactly, each is kept even though the decoder would prefer another word.
        #expect(fixture.decide(typed: "zorbix", lexicon: lexicon) == .keep(.protectedWord))
        #expect(fixture.decide(typed: "teh", lexicon: lexicon) == .keep(.protectedWord))
        #expect(fixture.decide(typed: "wuz", lexicon: lexicon) == .keep(.protectedWord))
        #expect(fixture.decide(typed: "studio", lexicon: lexicon) == .keep(.protectedWord))
        // A disabled entry protects nothing.
        #expect(!lexicon.isProtected("hidden"))
        let knowledge = lexicon.knowledge(of: "Zorbix", model: fixture.model)
        #expect(knowledge.inDictionary && !knowledge.inModel && knowledge.isProtected)
        #expect(lexicon.knowledge(of: "teh", model: fixture.model).inSystemLexicon)
        #expect(lexicon.knowledge(of: "wuz", model: fixture.model).inUserLexicon)
        // A near miss of a term the model has never heard is pulled to the owner's spelling.
        // The fifth tap sits between u and i, on the u side.
        let between = [CGPoint](repeating: .zero, count: 4) + [CGPoint(x: 15, y: 0), .zero]
        #expect(
            replacementText(
                fixture.decide(typed: "zorbux", position: .middle, lexicon: lexicon, offsets: between))
                == "Zorbix")
        #expect(UserLexicon.dictionaryBonus == 3 && UserLexicon.systemBonus == 1)
    }

    // MARK: - Decoder

    @Test("Clear typos from realistic taps are corrected")
    func typos() throws {
        let fixture = try TypingFixture()
        // "teh" is the two neighbours swapped; "helo" has a letter left out; "wiht" swaps two;
        // "thsi" likewise; "becuase" swaps in a longer word.
        for (typed, wanted) in [
            ("teh", "the"), ("helo", "hello"), ("wiht", "with"), ("thsi", "this"), ("becuase", "because"),
        ] {
            let decision = fixture.decide(typed: typed, position: .middle)
            #expect(replacementText(decision) == wanted, "\(typed) -> \(String(describing: decision))")
        }
    }

    @Test("A real word typed accurately is left alone")
    func realWordsStay() throws {
        let fixture = try TypingFixture()
        for word in ["the", "hello", "with", "because", "morning", "form", "from", "that", "have"] {
            #expect(fixture.decide(typed: word, previous: "of", position: .middle) == .keep(.typedIsBest), "\(word)")
        }
        // A word the model does not know, typed accurately, is left alone too: the typed string
        // competes as a candidate, so a distant dictionary word cannot win.
        for word in ["kubectl", "ghostty", "murmurs"] {
            let decision = fixture.decide(typed: word, position: .middle)
            #expect(decision == .keep(.typedIsBest) || decision == .keep(.belowThreshold), "\(word) -> \(decision)")
        }
    }

    @Test("A missed space is found: ofthe becomes of the")
    func missedSpace() throws {
        let fixture = try TypingFixture()
        for (typed, wanted) in [("ofthe", "of the"), ("inthe", "in the"), ("thisis", "this is")] {
            let decision = fixture.decide(typed: typed, position: .middle)
            #expect(replacementText(decision) == wanted, "\(typed) -> \(String(describing: decision))")
        }
    }

    @Test("Candidates come back ranked, with posteriors that sum to at most one")
    func decodingShape() throws {
        let fixture = try TypingFixture()
        let decoding = fixture.decode("helo")
        #expect(decoding.typed == "helo")
        #expect(decoding.typedID == nil)
        #expect(decoding.candidates.count > 1)
        #expect(decoding.top?.text == "hello")
        let scores = decoding.candidates.map(\.score)
        #expect(scores == scores.sorted(by: >))
        let total = decoding.candidates.reduce(0.0) { $0 + $1.posterior }
        #expect(total > 0.99 && total <= 1.0 + 1e-9)
        #expect(decoding.candidates.contains { $0.kind == .literal && $0.text == "helo" })
        // Taps on non-letter keys are not decoded.
        let digits = [WordTap(point: .zero, key: .character("1")), WordTap(point: .zero, key: .character("2"))]
        #expect(fixture.decoder.decode(taps: digits, previous: nil).candidates.isEmpty)
        #expect(fixture.decoder.decode(taps: [], previous: nil).candidates.isEmpty)
    }

    @Test("The previous word raises the score of the reading it fits")
    func context() throws {
        let fixture = try TypingFixture()
        // The second tap sits between h and j. "the" is the only word, and what comes before it
        // changes how likely it is: after "of" it is a very common pair.
        let between = [CGPoint.zero, CGPoint(x: -17, y: 0), .zero]
        let alone = fixture.decode("tje", offsets: between)
        let after = fixture.decode("tje", previous: "of", offsets: between)
        #expect(alone.top?.text == "the" && after.top?.text == "the")
        #expect((after.top?.score ?? 0) > (alone.top?.score ?? 0))
    }

    // MARK: - Model helpers

    @Test("narrow(range:depth:byte:) is the trie child that range(ofPrefix:) finds the slow way")
    func narrowMatchesPrefixRanges() throws {
        let model = try TypingModel.bundled()
        for prefix in ["", "t", "th", "the", "don", "don'", "q", "qu", "zz", "i"] {
            let parent = model.range(ofPrefix: prefix)
            for byte in Array("abcdefghijklmnopqrstuvwxyz'".utf8) {
                let child = model.narrow(parent, depth: prefix.utf8.count, byte: byte)
                let expected = model.range(ofPrefix: prefix + String(UnicodeScalar(byte)))
                if expected.isEmpty {
                    #expect(child.isEmpty, "\(prefix)\(UnicodeScalar(byte))")
                } else {
                    #expect(child == expected, "\(prefix)\(UnicodeScalar(byte))")
                }
            }
        }
    }

    // MARK: - Next-letter bias

    @Test("The next-letter bias lists every letter, favours what words continue with, and feeds HitTester")
    func nextLetterBias() throws {
        let fixture = try TypingFixture()
        let bias = NextLetterBias(model: fixture.model)
        let afterTH = bias.logOdds(prefix: "th", previous: nil)
        #expect(afterTH.count == 26)
        let best = afterTH.max { $0.value < $1.value }
        #expect(best?.key == "e")
        #expect((afterTH["e"] ?? 0) > (afterTH["z"] ?? 0) + 4)
        #expect(afterTH.values.allSatisfy { $0 >= NextLetterBias.floor && $0 <= NextLetterBias.ceiling })

        // Before any letter, the first letters of common words lead.
        let start = bias.logOdds(prefix: "", previous: nil)
        #expect(start.count == 26)
        #expect((start["t"] ?? -9) > (start["x"] ?? 9))
        // The previous word shifts it: after "thank" the next word is likelier "you" than "yellow".
        let thank = try #require(fixture.model.id(of: "thank"))
        let afterThank = bias.logOdds(prefix: "", previous: thank)
        let withoutThank = bias.logOdds(prefix: "", previous: nil)
        #expect((afterThank["y"] ?? 0) > (withoutThank["y"] ?? 0))

        #expect(bias.logOdds(prefix: "qzxqzx", previous: nil).isEmpty)
        // A long range is capped: one letter's range holds thousands of words, but the work is not
        // proportional to it, and the answer for a two-letter prefix still comes out.
        #expect(bias.logOdds(prefix: "co", previous: nil).count == 26)

        // A tap two points into "d" toward "e" lands on "e" once the bias says so.
        let d = fixture.frame("d")
        let point = CGPoint(x: d.hitRect.midX, y: d.hitRect.minY + 2)
        #expect(HitTester.key(at: point, frames: fixture.frames, bias: [:])?.kind == .character("d"))
        let biased = HitTester.key(at: point, frames: fixture.frames, bias: afterTH)
        #expect(biased?.kind == .character("e"))
    }

    // MARK: - Speed

    @Test("A word decodes in a few milliseconds even in a debug build")
    func decodeIsFast() throws {
        let fixture = try TypingFixture()
        let words = ["teh", "helo", "morning", "becuase", "ofthe", "restaurant", "interesting"]
        // One warm-up pass touches the mapped pages, as a keyboard that has been typing would.
        for word in words { _ = fixture.decode(word) }
        let clock = ContinuousClock()
        let elapsed = clock.measure { for word in words { _ = fixture.decode(word) } }
        let perWord = elapsed / words.count
        // The release number is well under 5 ms; a debug build is several times slower, so this
        // only guards against a search that stopped being bounded.
        #expect(perWord < .milliseconds(100), "\(perWord) per word")
    }
}
