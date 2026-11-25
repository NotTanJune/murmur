import CoreGraphics
import Foundation

// The pure state behind the keyboard's autocorrect. `TypingController` (UIKit) keeps one value of
// each type here and calls them as keys land: `WordTapTracker` collects the taps of the word being
// typed, `Autocorrector` decodes them when a word ends, `UndoOffer` remembers a replacement so
// delete can offer it back, and `NextLetterBiasCache` feeds the touch engine's hit tester. None of
// it imports UIKit, so each rule is checked on the Mac.

// MARK: - The word at the cursor

/// The word that ends at the cursor, read from the text before it.
public struct WordAtCursor: Equatable, Sendable {
    /// The word as it stands in the field: letters and apostrophes with their capitals.
    public let text: String
    /// Everything before the word, which gives its place in the sentence and the word before it.
    public let textBeforeWord: String
    /// The folded word before this one, when the bigram may use it (see
    /// `SuggestionEngine.previousWord(beforeWordAt:)`).
    public let previous: String?
    public let position: SentencePosition

    /// Lowercase with straight apostrophes, the form the model keys words by.
    public var folded: String { UserLexicon.fold(text) }

    /// What may stand directly before a word that autocorrect is allowed to touch: the start of
    /// the text, whitespace, or an opening mark. A word that follows a digit, `@`, `#`, `/`, `.`,
    /// `-` or `_` is part of something that is not prose (a handle, a path, a compound).
    static let openingMarks: Set<Character> = ["(", "[", "{", "\u{201C}", "\u{2018}", "\"", "'", "\u{2019}", "\u{2014}"]

    /// The letters and apostrophes right before the end of `text`, without apostrophes that open
    /// the word (a single quote in front is not part of it). Empty when the text does not end in
    /// a letter or an apostrophe.
    public static func trailingWord(of text: String) -> String {
        var start = text.endIndex
        while start > text.startIndex {
            let before = text.index(before: start)
            let character = text[before]
            guard character.isLetter || character == "'" || character == "\u{2019}" else { break }
            start = before
        }
        while start < text.endIndex, text[start] == "'" || text[start] == "\u{2019}" {
            start = text.index(after: start)
        }
        return String(text[start...])
    }

    /// The word the text ends with, when autocorrect may consider it: it has a letter and sits
    /// after the start of the text, whitespace or an opening mark.
    public static func ending(textBefore text: String) -> WordAtCursor? {
        let word = trailingWord(of: text)
        guard !word.isEmpty, word.contains(where: \.isLetter) else { return nil }
        let head = String(text.dropLast(word.count))
        if let boundary = head.last, !boundary.isWhitespace, !openingMarks.contains(boundary) {
            return nil
        }
        return WordAtCursor(
            text: word, textBeforeWord: head,
            previous: SuggestionEngine.previousWord(beforeWordAt: head),
            position: SentencePosition.of(textBeforeWord: head))
    }
}

// MARK: - Taps of the current word

/// The taps of the word being typed, in order, with the letters they produced. The controller adds
/// a tap for each letter the engine inserts and empties the tracker at the end of the word and
/// on anything that makes the taps untrustworthy; before the taps are used they are checked
/// against the field (`taps(matching:)`), so a host that changed the word behind the keyboard's
/// back costs the taps and nothing else.
public struct WordTapTracker: Equatable, Sendable {
    /// The most taps kept. A longer word is not decoded (`TapDecoder.Configuration.maxTaps` is 20)
    /// and the tracker stops growing, so its letters no longer equal the word and it matches nothing.
    public static let capacity = 32

    public private(set) var taps: [WordTap] = []
    /// The letters typed, as the keys produced them (capitals included).
    public private(set) var typed = ""

    public init() {}

    public var isEmpty: Bool { taps.isEmpty }

    /// Adds one letter and where the finger lifted. `letter` is one character as typed; the key
    /// recorded for the decoder is its lowercase form, the letters page's key.
    public mutating func append(letter: String, at point: CGPoint) {
        guard taps.count < Self.capacity else { return }
        typed += letter
        taps.append(WordTap(point: point, key: .character(letter.lowercased())))
    }

    /// Takes back the last `count` letters, for a delete: what is left still matches the field.
    public mutating func dropLast(_ count: Int) {
        let removed = min(max(count, 0), taps.count)
        guard removed > 0 else { return }
        taps.removeLast(removed)
        typed.removeLast(removed)
    }

    public mutating func reset() {
        guard !taps.isEmpty else { return }
        taps = []
        typed = ""
    }

    /// The taps, when they are exactly the letters of `word`.
    public func taps(matching word: String) -> [WordTap]? {
        !taps.isEmpty && typed == word ? taps : nil
    }

    /// Whether the word at the end of `textBefore` is what was typed.
    public func isConsistent(with textBefore: String) -> Bool {
        typed == WordAtCursor.trailingWord(of: textBefore)
    }
}

// MARK: - Autocorrector

/// The decoder, the policy and the owner's words together: what the keyboard knows when a word
/// ends or while it is being typed.
public struct Autocorrector: Sendable {
    /// The answer for the word at the cursor.
    public struct Evaluation: Sendable {
        public let word: WordAtCursor
        public let decoding: TapDecoder.Decoding
        public let decision: AutocorrectDecision

        /// The replacement to type, when the decision is to replace.
        public var replacement: Replacement? {
            if case .replace(let replacement) = decision { return replacement }
            return nil
        }

        /// What the strip offers in its centre cell while the word is still being typed: the
        /// replacement, unless it only extends the typed letters (a completion, which the strip's
        /// other cell already offers) and is not a contraction.
        public var stripCorrection: String? {
            guard let replacement else { return nil }
            if !replacement.isContraction, replacement.kind != .split,
                UserLexicon.fold(replacement.text).hasPrefix(word.folded)
            {
                return nil
            }
            return replacement.text
        }
    }

    public let model: TypingModel
    /// The words the owner has: Murmur dictionary terms, the system's names, kept words.
    public var lexicon: UserLexicon
    /// The fixes the owner refused.
    public var rejections: RejectionSet
    public var thresholds = AutocorrectPolicy.Thresholds.tuned
    private var decoder: TapDecoder

    /// - Parameter lettersFrames: the letters page's key frames in the engine's coordinates, the
    ///   same space the taps are in, whatever page the keyboard shows.
    public init(
        model: TypingModel, lettersFrames: [KeyFrame], lexicon: UserLexicon = .empty,
        rejections: RejectionSet = RejectionSet(), configuration: TapDecoder.Configuration = .tuned
    ) {
        self.model = model
        self.lexicon = lexicon
        self.rejections = rejections
        decoder = TapDecoder(model: model, frames: lettersFrames, configuration: configuration)
    }

    /// New geometry: the decoder's key centres and spreads follow the width.
    public mutating func setLettersFrames(_ frames: [KeyFrame]) {
        decoder = TapDecoder(model: model, frames: frames, configuration: decoder.configuration)
    }

    /// The owner undid a fix: refuse it for the session, and count it toward the persisted limit.
    public mutating func recordUndo(_ offer: UndoOffer) {
        rejections.recordUndo(original: offer.original, replacement: offer.replacement)
    }

    /// Decodes and judges the word at the end of `textBefore`. Nil when the text does not end in
    /// a word autocorrect may consider. Taps that do not match the word (the host changed it, or
    /// it was typed before the keyboard appeared) are not used: the decoder is skipped and only the
    /// contraction rule can fire, which needs no taps.
    public func evaluate(
        textBefore: String, tracker: WordTapTracker, field: FieldTraits
    ) -> Evaluation? {
        guard let word = WordAtCursor.ending(textBefore: textBefore) else { return nil }
        let folded = word.folded
        var decoding = TapDecoder.Decoding(typed: folded, typedID: model.id(of: folded), candidates: [])
        // One tap is a single letter or a word the policy keeps whatever the decoder says.
        if AutocorrectPolicy.allows(field), let taps = tracker.taps(matching: word.text), taps.count >= 2 {
            decoding = decoder.decode(
                taps: taps, previous: word.previous.flatMap { model.id(of: $0) }, lexicon: lexicon)
        }
        let decision = AutocorrectPolicy.decide(
            typed: word.text, decoding: decoding, field: field,
            knowledge: lexicon.knowledge(of: word.text, model: model), position: word.position,
            rejections: rejections, model: model, thresholds: thresholds)
        return Evaluation(word: word, decoding: decoding, decision: decision)
    }
}

// MARK: - Undo offer

/// A replacement the owner may take back. After autocorrect typed `replacement` and then the
/// terminator (a space or a closing mark), one delete removes only the terminator and shows the
/// original word on the strip; tapping it puts the original back with no space. Any other edit
/// ends the offer.
public struct UndoOffer: Equatable, Sendable {
    /// What the owner typed.
    public let original: String
    /// What autocorrect typed in its place, as it stands in the field.
    public let replacement: String
    /// What was typed after the replacement: a space, or one of `, . ! ? ; : )`.
    public let terminator: String
    /// The terminator was deleted: the chip shows.
    public private(set) var isShown = false

    public init(original: String, replacement: String, terminator: String) {
        self.original = original
        self.replacement = replacement
        self.terminator = terminator
    }

    /// The offer after a delete of `count` characters, or nil when the delete ends it. Only one
    /// character, right after the replacement, keeps it, and it shows the chip; a second delete,
    /// or a repeat of the first, ends it.
    public func afterDelete(count: Int) -> UndoOffer? {
        guard !isShown, count == 1 else { return nil }
        var next = self
        next.isShown = true
        return next
    }

    /// Whether the field still ends the way this offer expects: the replacement and its
    /// terminator, or the replacement alone once the terminator is gone.
    public func isConsistent(with textBefore: String) -> Bool {
        textBefore.hasSuffix(isShown ? replacement : replacement + terminator)
    }

    /// How many characters to delete to take the replacement out.
    public var restoreDeleteCount: Int { replacement.count }
}

// MARK: - Next-letter bias

/// The next-letter bias for the touch engine, cached by prefix. The controller feeds it the text
/// at each coalesced refresh (`noteText`), and asks for `logOdds` on every touch event; the
/// tables behind it (`NextLetterBias`) are built once, off the typing path, and installed when
/// ready. A touch recomputes nothing unless the prefix or the previous word changed.
public struct NextLetterBiasCache {
    /// How many times the underlying model was asked, for the tests.
    public private(set) var computations = 0

    private var bias: NextLetterBias?
    /// Whether the text at the cursor lets a bias apply: not in the middle of a word, not right
    /// after a digit or punctuation, not in a word that follows `@`, `/` and the like.
    private var allowed = false
    /// The letters of the word at the cursor as of the last `noteText`.
    private var textPrefix = ""
    private var previous: Int?
    private var cached: (prefix: String, previous: Int?, value: [String: Double])?

    public init() {}

    /// The tables are ready.
    public mutating func install(_ bias: NextLetterBias) {
        self.bias = bias
        cached = nil
    }

    public var isReady: Bool { bias != nil }

    /// Reads the text before the cursor: the word being typed and the word before it.
    /// `followedByLetter` is true when letters sit right after the cursor (a word cut in two).
    public mutating func noteText(before text: String, followedByLetter: Bool, model: TypingModel) {
        previous = nil
        textPrefix = ""
        allowed = false
        guard !followedByLetter else { return }
        let word = WordAtCursor.trailingWord(of: text)
        if word.isEmpty {
            // At a word start: after whitespace, or an empty field. Right after a mark or a digit
            // there is no word to bias.
            if let last = text.last, !last.isWhitespace { return }
            allowed = true
            previous = SuggestionEngine.previousWord(beforeWordAt: text).flatMap { model.id(of: $0) }
        } else if let ending = WordAtCursor.ending(textBefore: text) {
            allowed = true
            textPrefix = ending.folded
            previous = ending.previous.flatMap { model.id(of: $0) }
        }
    }

    /// The log-odds for the letters that may come next, or empty for no bias. The prefix is the
    /// tracker's letters when it holds any (they are current within a burst of touches), else the
    /// word at the cursor as of the last `noteText`.
    public mutating func logOdds(tracker: WordTapTracker) -> [String: Double] {
        guard let bias, allowed else { return [:] }
        let prefix = UserLexicon.fold(tracker.isEmpty ? textPrefix : tracker.typed)
        if let cached, cached.prefix == prefix, cached.previous == previous { return cached.value }
        let value = bias.logOdds(prefix: prefix, previous: previous)
        computations += 1
        cached = (prefix, previous, value)
        return value
    }
}
