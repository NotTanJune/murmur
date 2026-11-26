import Foundation

/// The owner's Text Replacement entries from Settings, General, Keyboard: a short shortcut that
/// types a longer phrase ("addr" for an address). iOS hands them to a keyboard through
/// `UILexicon`, where a contact's name also appears as a pair whose two sides are the same word;
/// those pairs are names, not replacements, and are dropped here.
public struct TextReplacements: Sendable, Equatable {
    public struct Match: Equatable, Sendable {
        /// The shortcut as it stands in the field, with the owner's casing.
        public let shortcut: String
        public let phrase: String

        public init(shortcut: String, phrase: String) {
            self.shortcut = shortcut
            self.phrase = phrase
        }
    }

    public static let empty = TextReplacements(pairs: [])

    /// Phrases by folded shortcut. When a shortcut appears twice the first wins.
    private let phrases: [String: String]

    public init(pairs: [(shortcut: String, phrase: String)]) {
        var phrases: [String: String] = [:]
        for pair in pairs {
            let key = UserLexicon.fold(pair.shortcut)
            guard !key.isEmpty, !pair.phrase.isEmpty, key != UserLexicon.fold(pair.phrase),
                !key.contains(where: \.isWhitespace), phrases[key] == nil
            else { continue }
            phrases[key] = pair.phrase
        }
        self.phrases = phrases
    }

    public var isEmpty: Bool { phrases.isEmpty }

    /// The shortcuts, folded: autocorrect must leave them alone.
    public var shortcuts: [String] { Array(phrases.keys) }

    /// The replacement for the run of non-whitespace characters that ends `text`, matched without
    /// regard to case. A shortcut that is only the tail of a longer token ("xaddr") does not match.
    public func expansion(forTextBefore text: String) -> Match? {
        guard !phrases.isEmpty else { return nil }
        let token = text.reversed().prefix(while: { !$0.isWhitespace })
        guard !token.isEmpty else { return nil }
        let typed = String(token.reversed())
        guard let phrase = phrases[UserLexicon.fold(typed)] else { return nil }
        return Match(shortcut: typed, phrase: phrase)
    }
}
