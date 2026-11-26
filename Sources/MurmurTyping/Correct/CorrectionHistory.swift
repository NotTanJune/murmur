import Foundation

/// The last few things the keyboard replaced (autocorrect, a text replacement), kept so the
/// original can be offered again wherever the cursor comes back to the replaced word, not only
/// right after the correction. The stock keyboard does this: delete back through a later word,
/// or tap into the text, and the word it changed shows its original in the strip.
public struct CorrectionHistory: Sendable, Equatable {
    public struct Entry: Equatable, Sendable {
        /// What the owner typed.
        public let original: String
        /// What went into the field in its place.
        public let replacement: String
        /// Up to `contextLength` characters of the text that preceded the replacement.
        public let before: String
    }

    public static let capacity = 8
    public static let contextLength = 24

    /// Newest first.
    public private(set) var entries: [Entry] = []

    public init() {}

    public mutating func record(original: String, replacement: String, textBeforeWord: String) {
        let entry = Entry(
            original: original, replacement: replacement, before: String(textBeforeWord.suffix(Self.contextLength)))
        entries.removeAll { $0 == entry }
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    /// The newest entry whose replacement is the whole word that ends `textBefore`, with no word
    /// character at the cursor's other side, and that still follows the text it was typed after.
    /// The context comparison uses the shorter of the two lengths, so a field that only exposes a
    /// short context still matches.
    public func offer(textBefore: String, nextCharacter: Character?) -> Entry? {
        if let next = nextCharacter, next.isLetter || next.isNumber { return nil }
        for entry in entries where !entry.replacement.isEmpty && textBefore.hasSuffix(entry.replacement) {
            let head = textBefore.dropLast(entry.replacement.count)
            if let last = head.last, last.isLetter || last.isNumber { continue }
            let count = min(head.count, entry.before.count)
            if head.suffix(count) == entry.before.suffix(count) { return entry }
        }
        return nil
    }

    public mutating func remove(_ entry: Entry) {
        entries.removeAll { $0 == entry }
    }

    public mutating func clear() {
        entries.removeAll()
    }
}
