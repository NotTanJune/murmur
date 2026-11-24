import Foundation

/// One entry of the keyboard's suggestion strip.
public struct Suggestion: Hashable, Sendable {
    /// Where a suggestion came from, which decides how the strip draws it and what a tap does.
    public enum Kind: Hashable, Sendable {
        /// The word as typed so far. The strip shows it in quotes; a tap keeps it as it is.
        case typed
        /// A longer word that starts with what was typed.
        case completion
        /// A word likely to follow the previous one, offered after a space.
        case next
        /// A spelling fix for the typed word. Milestone 5 produces these; Milestone 4 never does.
        case correction
    }

    /// The whole word, ready to type: cased to match the typed word, with a straight apostrophe.
    /// The quotes around a `.typed` entry are the strip's drawing, not part of this string.
    public let text: String
    public let kind: Kind

    public init(text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }
}

/// What a tap on a suggestion does to the text: delete the typed word's characters, then type
/// `insert`, which is the suggestion and one trailing space.
public struct SuggestionEdit: Hashable, Sendable {
    /// How many characters (grapheme clusters, as `deleteBackward` removes them) to delete first.
    public let deleteCount: Int
    /// The text to type afterwards, ending in a space.
    public let insert: String

    public init(deleteCount: Int, insert: String) {
        self.deleteCount = deleteCount
        self.insert = insert
    }
}
