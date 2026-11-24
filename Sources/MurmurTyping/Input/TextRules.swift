import Foundation

/// The rules that read the text before the cursor, as pure functions. The engine does not see
/// the text, so `TypingController` calls these after each effect and feeds the answer back (shift
/// through `TypingEngine.setShift`, replacements as effects of its own).
public enum TextRules {
    /// The longest gap between two spaces that still counts as a double space.
    public static let doubleSpaceWindow: TimeInterval = 0.6

    /// Closing marks that may follow a sentence end and still leave the next word at a sentence
    /// start: `He said "go." Then`.
    private static let closers: Set<Character> = ["\"", "”", "’", "'", ")", "]", "}"]
    private static let sentenceEnds: Set<Character> = [".", "!", "?"]
    /// What may stand directly before a lone "i" for it to be a word of its own.
    private static let openers: Set<Character> = ["(", "[", "{", "“", "‘", "\"", "'"]
    /// What ends a word, so a lone "i" before it becomes "I". A hyphen or slash does not: "i-phone"
    /// is a different word.
    private static let wordEnds: Set<Character> = [
        ".", ",", "!", "?", ";", ":", ")", "]", "}", "'", "’", "\"", "”", "“",
    ]

    /// Whether the next letter should be capital, for the field's capitalisation mode. `.sentences`
    /// is true at the start of the field, after a line break, and after `. ! ?` (with any closing
    /// quote or bracket) followed by a space or newline; `.words` is true at the start of every
    /// word; `.allCharacters` always; `.none` never.
    public static func autoShift(before: String, autocapitalization: AutocapMode) -> Bool {
        switch autocapitalization {
        case .none: return false
        case .allCharacters: return true
        case .words:
            guard let last = before.last else { return true }
            return last.isWhitespace || last.isNewline
        case .sentences:
            guard let last = before.last else { return true }
            if last.isNewline { return true }
            // A sentence end counts only once a space follows it: "Hello." still continues.
            guard last.isWhitespace else { return false }
            var rest = before.dropLast()
            while let c = rest.last, c.isWhitespace { rest = rest.dropLast() }
            while let c = rest.last, closers.contains(c) { rest = rest.dropLast() }
            guard let end = rest.last else { return true }
            return sentenceEnds.contains(end)
        }
    }

    /// The double-space shortcut. Called when a space is about to be typed: `before` is the text
    /// before the cursor *without* that space, so it ends in the previous space. A second space
    /// within `doubleSpaceWindow` of the first, after a letter or digit, becomes a period and a
    /// space and turns shift on. Nil when the shortcut does not apply and the space types as is.
    public static func doubleSpacePeriod(
        before: String, lastSpaceTime: TimeInterval?, now: TimeInterval
    ) -> [TypingEffect]? {
        guard let lastSpaceTime, now >= lastSpaceTime, now - lastSpaceTime <= doubleSpaceWindow + 1e-9
        else { return nil }
        guard before.last == " " else { return nil }
        let beforeSpace = before.dropLast()
        guard let letter = beforeSpace.last, letter.isLetter || letter.isNumber else { return nil }
        return [.deleteBackward(count: 1), .insert(". ", tap: nil), .setShift(.on)]
    }

    /// The curly form of a straight quote. A quote opens at the start of the text, after
    /// whitespace, after an opening bracket and after an opening quote; anywhere else it closes
    /// (so an apostrophe in "don't" is the closing single quote, the right apostrophe). `enabled`
    /// is the field's smart-quotes flag; any other mark comes back unchanged.
    public static func smartQuote(_ mark: Character, before: String, enabled: Bool) -> String {
        guard enabled, mark == "'" || mark == "\"" else { return String(mark) }
        let opens: Bool
        if let last = before.last {
            opens = last.isWhitespace || last.isNewline || "([{“‘".contains(last)
        } else {
            opens = true
        }
        switch (mark, opens) {
        case ("'", true): return "‘"
        case ("'", false): return "’"
        case (_, true): return "“"
        case (_, false): return "”"
        }
    }

    /// Two hyphens become an em dash. Called when `-` is about to be typed: if `before` ends in a
    /// hyphen the answer deletes it and inserts U+2014 in its place, and nil means the hyphen
    /// types as is. (The plan's signature returned one effect; replacing a character takes two.)
    public static func smartDash(before: String, enabled: Bool) -> [TypingEffect]? {
        guard enabled, before.last == "-" else { return nil }
        return [.deleteBackward(count: 1), .insert("\u{2014}", tap: nil)]
    }

    /// A lone "i" becomes "I". Called when `typed` is about to be typed: if it ends a word and the
    /// word before the cursor is exactly "i" (so not "hi" or "pi"), the answer replaces that "i",
    /// and the caller then types `typed` as usual. Apostrophes count as word ends, which makes
    /// "i'm" and "i'll" come out right.
    public static func standaloneI(before: String, typed: Character) -> [TypingEffect]? {
        guard typed.isWhitespace || typed.isNewline || wordEnds.contains(typed) else { return nil }
        guard before.last == "i" else { return nil }
        let beforeI = before.dropLast()
        if let previous = beforeI.last {
            guard previous.isWhitespace || previous.isNewline || openers.contains(previous) else {
                return nil
            }
        }
        return [.deleteBackward(count: 1), .insert("I", tap: nil)]
    }
}
