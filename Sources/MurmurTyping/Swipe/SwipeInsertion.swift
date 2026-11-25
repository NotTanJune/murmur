import Foundation

/// A swiped word the keyboard has typed and may still change: what was typed and the other
/// readings the strip offers in its place.
///
/// A swipe types the word and **not** the space after it. That space is owed: the next swipe types
/// it first (the text ends in a letter, so `SwipeInsertion.needsLeadingSpace` says so), a typed
/// letter gets it first (the controller types it), and a closing mark (`, . ! ? ; : ) ] } ' - /`)
/// or the space key simply goes in, so punctuation sits against the word without a space to
/// delete. This is `PendingSpace`'s idea turned around: that type holds a space already typed
/// that a mark may take back, this one holds a space not yet typed that a letter may claim.
///
/// The offer lives until anything else edits the text: the controller drops it on every key, a
/// delete included (a delete takes one character, as anywhere else), and `isConsistent(with:)`
/// drops it when the field no longer ends with the word.
public struct SwipeOffer: Equatable, Sendable {
    /// How many other readings the strip shows.
    public static let alternativeLimit = 3

    /// Every reading of the swipe, cased as it would be typed, best first. One of them is in the
    /// field.
    public let readings: [String]
    /// Which reading is typed now.
    public let index: Int

    /// - Precondition: `readings` is not empty.
    public init(readings: [String], index: Int = 0) {
        precondition(!readings.isEmpty && readings.indices.contains(index))
        self.readings = readings
        self.index = index
    }

    /// The word in the field.
    public var word: String { readings[index] }

    /// The other readings, best first, for the strip.
    public var alternatives: [String] {
        readings.enumerated().filter { $0.offset != index }.map(\.element).prefix(Self.alternativeLimit).map { $0 }
    }

    /// Whether the field still ends with the word, so a swap may act on it.
    public func isConsistent(with textBefore: String) -> Bool {
        textBefore.hasSuffix(word)
    }

    /// The offer after the strip's reading `text` replaced the word: the same readings with that
    /// one typed, so the word that was typed is offered back. Nil when `text` is not an
    /// alternative.
    public func choosing(_ text: String) -> SwipeOffer? {
        guard let next = readings.firstIndex(of: text), next != index else { return nil }
        return SwipeOffer(readings: readings, index: next)
    }
}

/// The text rules of a swiped word, as pure functions: whether a space goes first, how the word
/// is cased, and what the strip shows. `TypingController` types the result.
public enum SwipeInsertion {
    /// What may stand directly before the word without a space between: an opening bracket or
    /// quote, and the marks that join words (a dash or a slash).
    public static let openers: Set<Character> = [
        "(", "[", "{", "\u{201C}", "\u{2018}", "\"", "'", "-", "\u{2013}", "\u{2014}", "/",
    ]

    /// The marks that attach to a swiped word with no space between: what a typed key types
    /// directly after the word, since the space after it is only owed. The space key is not here:
    /// it types its own space.
    public static let attachingMarks: Set<Character> = [",", ".", "!", "?", ";", ":", ")", "]", "}", "'", "-", "/"]

    /// A word is typed after a space unless the text before the cursor is empty, ends in
    /// whitespace or a line break, or ends in an opening mark.
    public static func needsLeadingSpace(before: String) -> Bool {
        guard let last = before.last else { return false }
        return !last.isWhitespace && !last.isNewline && !openers.contains(last)
    }

    /// The word before the one a swipe starts: the last word of the text before the cursor, found
    /// the way the strip finds it, once the space the swipe types is in. Nil at a sentence start
    /// and after a mark, where the decoder scores by frequency alone.
    public static func previousWord(before: String) -> String? {
        SuggestionEngine.previousWord(
            beforeWordAt: needsLeadingSpace(before: before) ? before + " " : before)
    }

    /// Whether the word starts a sentence (or the field's capitalisation asks for a capital),
    /// judged on the text as it will stand once the swipe's own space is typed. After "Hello."
    /// with no space the stock rule says the sentence continues, but the swipe types a space and
    /// so begins the next one.
    public static func wantsCapital(before: String, autocapitalization: AutocapMode) -> Bool {
        TextRules.autoShift(
            before: needsLeadingSpace(before: before) ? before + " " : before,
            autocapitalization: autocapitalization)
    }

    /// The word as it is typed. Caps lock uppercases it, shift or a sentence start capitalises its
    /// first letter, and a lone "i" or "i'm" is capital unless `capitalisesI` is false (the owner
    /// has auto-capitalisation off). A spelling with a capital inside ("iPhone") keeps its own
    /// form when only the first letter is asked for.
    public static func cased(
        _ word: String, shift: ShiftState, sentenceCapital: Bool, capitalisesI: Bool = true
    ) -> String {
        var result = word
        if shift == .capsLock {
            result = word.uppercased()
        } else if shift == .on || sentenceCapital {
            if !word.dropFirst().contains(where: \.isUppercase) { result = capitalised(word) }
        }
        if capitalisesI, result == "i" || result.hasPrefix("i'") || result.hasPrefix("i\u{2019}") {
            result = capitalised(result)
        }
        return result
    }

    private static func capitalised(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    /// The strip's cells for a swipe's other readings: the best in the centre and the runner-up on
    /// the left, as the strip lays out its predictions.
    public static func stripCells(for offer: SwipeOffer) -> [Suggestion] {
        let cells = offer.alternatives.map { Suggestion(text: $0, kind: .correction) }
        guard cells.count >= 2 else { return cells }
        var slots = [cells[1], cells[0]]
        if cells.count >= 3 { slots.append(cells[2]) }
        return slots
    }
}
