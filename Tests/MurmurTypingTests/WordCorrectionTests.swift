import CoreGraphics
import Foundation
import Testing

@testable import MurmurTyping

/// The pure state the keyboard's autocorrect keeps between keys: the word at the cursor, the
/// tracker of its taps, the evaluation at a word end, the undo offer and the next-letter cache.
@Suite struct WordCorrectionTests {
    /// A tracker holding `letters` tapped around their keys' centres, as the controller builds it.
    private func tracker(_ fixture: TypingFixture, _ letters: String, typed: String? = nil) -> WordTapTracker {
        var tracker = WordTapTracker()
        let shown = typed ?? letters
        for (tap, letter) in zip(fixture.taps(letters), shown) {
            tracker.append(letter: String(letter), at: tap.point)
        }
        return tracker
    }

    private func autocorrector(_ fixture: TypingFixture, lexicon: UserLexicon = .empty) -> Autocorrector {
        Autocorrector(model: fixture.model, lettersFrames: fixture.frames, lexicon: lexicon)
    }

    // MARK: - Word at the cursor

    @Test("The word at the cursor is read with its place in the sentence and its previous word")
    func wordAtCursor() throws {
        let word = try #require(WordAtCursor.ending(textBefore: "Thank you for teh"))
        #expect(word.text == "teh")
        #expect(word.previous == "for")
        #expect(word.position == .middle)
        #expect(word.textBeforeWord == "Thank you for ")

        let first = try #require(WordAtCursor.ending(textBefore: "Teh"))
        #expect(first.position == .start)
        #expect(first.previous == nil)

        // After a sentence end the previous word does not carry over.
        #expect(try #require(WordAtCursor.ending(textBefore: "Hi. teh")).previous == nil)
        // An opening quote or bracket is not part of the word and does not hide it.
        #expect(WordAtCursor.ending(textBefore: "he said \u{201C}teh")?.text == "teh")
        #expect(WordAtCursor.ending(textBefore: "(teh")?.text == "teh")
        #expect(WordAtCursor.ending(textBefore: "it's 'teh")?.text == "teh")
        // A contraction's apostrophe is part of it.
        #expect(WordAtCursor.ending(textBefore: "I dont\u{2019}t")?.text == "dont\u{2019}t")
    }

    @Test("Text that does not end in a plain word, or a word fused to something else, has no word")
    func notAWord() {
        #expect(WordAtCursor.ending(textBefore: "") == nil)
        #expect(WordAtCursor.ending(textBefore: "hello ") == nil)
        #expect(WordAtCursor.ending(textBefore: "hello.") == nil)
        #expect(WordAtCursor.ending(textBefore: "see foo.teh") == nil)
        #expect(WordAtCursor.ending(textBefore: "mail @teh") == nil)
        #expect(WordAtCursor.ending(textBefore: "tag #teh") == nil)
        #expect(WordAtCursor.ending(textBefore: "a/teh") == nil)
        #expect(WordAtCursor.ending(textBefore: "well-teh") == nil)
        #expect(WordAtCursor.ending(textBefore: "3teh") == nil)
        #expect(WordAtCursor.ending(textBefore: "''") == nil)
    }

    // MARK: - Tracker

    @Test("The tracker keeps taps in order, with capitals, and matches only the word it typed")
    func trackerBasics() throws {
        let fixture = try TypingFixture()
        var word = tracker(fixture, "teh", typed: "Teh")
        #expect(word.typed == "Teh")
        #expect(word.taps.map(\.key) == [.character("t"), .character("e"), .character("h")])
        #expect(word.taps(matching: "Teh")?.count == 3)
        #expect(word.taps(matching: "teh") == nil)
        #expect(word.taps(matching: "Tehs") == nil)
        #expect(word.isConsistent(with: "so Teh"))
        #expect(!word.isConsistent(with: "so Tee"))
        #expect(!word.isConsistent(with: "so Teh "))

        word.dropLast(1)
        #expect(word.typed == "Te")
        #expect(word.taps.count == 2)
        #expect(word.isConsistent(with: "so Te"))
        word.dropLast(9)
        #expect(word.isEmpty && word.typed.isEmpty)
        #expect(word.taps(matching: "") == nil)

        word.append(letter: "a", at: .zero)
        word.reset()
        #expect(word.isEmpty && word.typed.isEmpty)
    }

    @Test("A tracker stops growing at its capacity, so a longer word matches nothing")
    func trackerCapacity() {
        var word = WordTapTracker()
        for _ in 0..<(WordTapTracker.capacity + 5) { word.append(letter: "a", at: .zero) }
        #expect(word.taps.count == WordTapTracker.capacity)
        #expect(word.taps(matching: String(repeating: "a", count: WordTapTracker.capacity + 5)) == nil)
    }

    // MARK: - Evaluation at a word end

    @Test("A typo typed with its taps is replaced, keeping the capital of a sentence start")
    func replacesTypo() throws {
        let fixture = try TypingFixture()
        let corrector = autocorrector(fixture)
        let middle = try #require(
            corrector.evaluate(textBefore: "I saw teh", tracker: tracker(fixture, "teh"), field: .standard))
        #expect(middle.replacement?.text == "the")
        #expect(middle.stripCorrection == "the")

        let start = try #require(
            corrector.evaluate(textBefore: "Teh", tracker: tracker(fixture, "teh", typed: "Teh"), field: .standard))
        #expect(start.replacement?.text == "The")
    }

    @Test("A word typed right is kept, and one whose taps do not match the field is not decoded")
    func keepsWhatItShould() throws {
        let fixture = try TypingFixture()
        let corrector = autocorrector(fixture)
        let right = try #require(
            corrector.evaluate(textBefore: "I saw the", tracker: tracker(fixture, "the"), field: .standard))
        #expect(right.replacement == nil)
        #expect(right.stripCorrection == nil)

        // The host changed the word: the taps say "teh", the field says "tee".
        let changed = try #require(
            corrector.evaluate(textBefore: "I saw tee", tracker: tracker(fixture, "teh"), field: .standard))
        #expect(changed.replacement == nil)
        #expect(changed.decoding.candidates.isEmpty)
    }

    @Test("Without taps only the contraction rule fires: dont, im, and the sentence-start capital")
    func contractionsWithoutTaps() throws {
        let fixture = try TypingFixture()
        let corrector = autocorrector(fixture)
        let none = WordTapTracker()
        #expect(corrector.evaluate(textBefore: "I dont", tracker: none, field: .standard)?.replacement?.text == "don't")
        #expect(corrector.evaluate(textBefore: "well im", tracker: none, field: .standard)?.replacement?.text == "I'm")
        #expect(corrector.evaluate(textBefore: "Dont", tracker: none, field: .standard)?.replacement?.text == "Don't")
        // A typo without taps stays: nothing says what was meant.
        #expect(corrector.evaluate(textBefore: "I saw teh", tracker: none, field: .standard)?.replacement == nil)
        // The strip offers the contraction while the word is still being typed.
        #expect(corrector.evaluate(textBefore: "I dont", tracker: none, field: .standard)?.stripCorrection == "don't")
    }

    @Test("Fields that refuse autocorrect, and fixes the owner refused, are left alone")
    func fieldsAndRefusals() throws {
        let fixture = try TypingFixture()
        var corrector = autocorrector(fixture)
        let taps = tracker(fixture, "teh")
        for field in [
            FieldTraits(autocorrectionAllowed: false), FieldTraits(isSecure: true),
            FieldTraits(keyboardKind: .url), FieldTraits(keyboardKind: .email),
        ] {
            let result = try #require(corrector.evaluate(textBefore: "I saw teh", tracker: taps, field: field))
            #expect(result.replacement == nil, "\(field)")
            #expect(result.decoding.candidates.isEmpty, "\(field) is not even decoded")
        }

        let before = try #require(corrector.evaluate(textBefore: "I saw teh", tracker: taps, field: .standard))
        let replacement = try #require(before.replacement)
        corrector.recordUndo(UndoOffer(original: "teh", replacement: replacement.text, terminator: " "))
        let after = try #require(corrector.evaluate(textBefore: "I saw teh", tracker: taps, field: .standard))
        #expect(after.decision == .keep(.rejected))
    }

    @Test("Dictionary terms are never corrected away")
    func dictionaryTerms() throws {
        let fixture = try TypingFixture()
        let corrector = autocorrector(fixture, lexicon: UserLexicon(dictionaryTerms: ["Kelpie"]))
        let result = try #require(
            corrector.evaluate(textBefore: "my Kelpie", tracker: tracker(fixture, "kelpie", typed: "Kelpie"), field: .standard))
        #expect(result.replacement == nil)
    }

    // MARK: - Strip

    @Test("A correction takes the centre cell, the typed word stays left, one completion stays right")
    func stripMerge() {
        let base = [
            Suggestion(text: "teh", kind: .typed), Suggestion(text: "tehran", kind: .completion),
            Suggestion(text: "tehsil", kind: .completion),
        ]
        let merged = SuggestionEngine.merging(correction: "the", into: base)
        #expect(merged.map(\.text) == ["teh", "the", "tehran"])
        #expect(merged.map(\.kind) == [.typed, .correction, .completion])

        // A completion equal to the fix is not offered twice.
        let duplicate = SuggestionEngine.merging(
            correction: "The", into: [base[0], Suggestion(text: "the", kind: .completion), base[2]])
        #expect(duplicate.map(\.text) == ["teh", "The", "tehsil"])

        // Only the typed word: the fix still goes in the centre.
        #expect(SuggestionEngine.merging(correction: "the", into: [base[0]]).map(\.text) == ["teh", "the"])
        // Predictions after a space are untouched.
        let predictions = [Suggestion(text: "of", kind: .next)]
        #expect(SuggestionEngine.merging(correction: "the", into: predictions) == predictions)
    }

    // MARK: - Undo offer

    @Test("One delete right after the replacement shows the offer; anything else ends it")
    func undoOffer() {
        let offer = UndoOffer(original: "teh", replacement: "the", terminator: " ")
        #expect(!offer.isShown)
        #expect(offer.isConsistent(with: "I saw the "))
        #expect(!offer.isConsistent(with: "I saw the"))
        #expect(offer.afterDelete(count: 2) == nil)
        #expect(offer.afterDelete(count: 0) == nil)

        let shown = offer.afterDelete(count: 1)
        #expect(shown?.isShown == true)
        #expect(shown?.isConsistent(with: "I saw the") == true)
        #expect(shown?.isConsistent(with: "I saw the ") == false)  // the space is back: not ours
        #expect(shown?.isConsistent(with: "I saw th") == false)
        // A second delete, or a repeat of the first, ends it.
        #expect(shown?.afterDelete(count: 1) == nil)
        #expect(shown?.restoreDeleteCount == 3)

        // A split replacement is restored as a whole.
        let split = UndoOffer(original: "ofthe", replacement: "of the", terminator: ",")
        #expect(split.restoreDeleteCount == 6)
        #expect(split.isConsistent(with: "one of the,"))
    }

    // MARK: - Next-letter bias

    @Test("The bias cache is empty until its tables are ready, then caches per prefix and previous word")
    func biasCache() throws {
        let fixture = try TypingFixture()
        var cache = NextLetterBiasCache()
        cache.noteText(before: "thank ", followedByLetter: false, model: fixture.model)
        #expect(cache.logOdds(tracker: WordTapTracker()).isEmpty)

        cache.install(NextLetterBias(model: fixture.model))
        #expect(cache.isReady)
        let start = cache.logOdds(tracker: WordTapTracker())
        #expect(start.count == 26)
        // After "thank" the next word is likelier "you" than anything else starting with a z.
        #expect((start["y"] ?? -9) > (start["z"] ?? 9))
        #expect(cache.computations == 1)
        _ = cache.logOdds(tracker: WordTapTracker())
        _ = cache.logOdds(tracker: WordTapTracker())
        #expect(cache.computations == 1, "the same prefix is not computed again")

        // A letter typed before the next refresh moves the prefix from the tracker.
        let typed = tracker(fixture, "t")
        let afterT = cache.logOdds(tracker: typed)
        #expect(afterT != start)
        #expect(cache.computations == 2)
        let afterTH = cache.logOdds(tracker: tracker(fixture, "th"))
        #expect(afterTH.max { $0.value < $1.value }?.key == "e")

        // The text catching up changes nothing when it agrees.
        cache.noteText(before: "thank th", followedByLetter: false, model: fixture.model)
        #expect(cache.logOdds(tracker: WordTapTracker()) == afterTH)
    }

    @Test("No bias in the middle of a word, after a digit or punctuation, or in a handle")
    func biasNeedsAWordBoundary() throws {
        let fixture = try TypingFixture()
        var cache = NextLetterBiasCache()
        cache.install(NextLetterBias(model: fixture.model))
        let none = WordTapTracker()

        cache.noteText(before: "thank ", followedByLetter: true, model: fixture.model)
        #expect(cache.logOdds(tracker: none).isEmpty)
        cache.noteText(before: "call 3", followedByLetter: false, model: fixture.model)
        #expect(cache.logOdds(tracker: none).isEmpty)
        cache.noteText(before: "wait.", followedByLetter: false, model: fixture.model)
        #expect(cache.logOdds(tracker: none).isEmpty)
        cache.noteText(before: "mail @jo", followedByLetter: false, model: fixture.model)
        #expect(cache.logOdds(tracker: none).isEmpty)
        // A fresh field and a normal word do get one.
        cache.noteText(before: "", followedByLetter: false, model: fixture.model)
        #expect(cache.logOdds(tracker: none).count == 26)
        cache.noteText(before: "so th", followedByLetter: false, model: fixture.model)
        #expect(cache.logOdds(tracker: none).count == 26)
    }
}
