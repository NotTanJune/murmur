import Foundation
import MurmurDictionary

/// What the keyboard knows about a typed word, one flag per source. The autocorrect policy reads
/// these four and nothing else about where a word came from.
public struct WordKnowledge: Hashable, Sendable {
    /// The word is in the English word model.
    public var inModel: Bool
    /// The word is one the user kept (typed again after the keyboard wanted to change it).
    public var inUserLexicon: Bool
    /// The word is in the system's supplementary lexicon (`requestSupplementaryLexicon`: contact
    /// names and the user's text replacements).
    public var inSystemLexicon: Bool
    /// The word is a term or correction target of the Murmur dictionary.
    public var inDictionary: Bool

    public init(
        inModel: Bool = false, inUserLexicon: Bool = false, inSystemLexicon: Bool = false,
        inDictionary: Bool = false
    ) {
        self.inModel = inModel
        self.inUserLexicon = inUserLexicon
        self.inSystemLexicon = inSystemLexicon
        self.inDictionary = inDictionary
    }

    /// True for any word the user chose to have: autocorrect never changes these.
    public var isProtected: Bool { inUserLexicon || inSystemLexicon || inDictionary }
}

/// Words the user owns: the Murmur dictionary's terms, the system's names and replacements, and
/// words the user kept. They are never corrected away, and a typed near miss of one of them is
/// pulled toward it by a fixed bonus in the decoder.
///
/// `MurmurTyping` cannot read `DictionaryStore` (that lives in the app's shared storage), so the
/// caller builds this from plain values: the keyboard passes the dictionary's entries, the words
/// of `UILexicon`, and the kept words of the learning store. It holds a few hundred strings at
/// most, which is why it is a value type and not a mapped file.
public struct UserLexicon: Sendable, Equatable {
    /// Nats added to a dictionary term that the typed taps nearly spell.
    public static let dictionaryBonus = 3.0
    /// Nats added to a system lexicon name (a contact, a text replacement).
    public static let systemBonus = 1.0
    /// Nats added to a word the user kept.
    public static let keptBonus = 1.0

    /// Where a word came from, which decides its bonus.
    public enum Source: Hashable, Sendable {
        case dictionary
        case system
        case kept

        /// The decoder's bonus for this source.
        public var bonus: Double {
            switch self {
            case .dictionary: UserLexicon.dictionaryBonus
            case .system: UserLexicon.systemBonus
            case .kept: UserLexicon.keptBonus
            }
        }
    }

    /// One word of the lexicon.
    public struct Entry: Hashable, Sendable {
        /// The word as the owner wrote it ("iPhone", "Kubernetes"): what a correction types.
        public let display: String
        public let source: Source

        public var bonus: Double { source.bonus }
    }

    /// Words by folded form (lowercase, straight apostrophes). When a word has several sources
    /// the one with the larger bonus wins.
    public private(set) var entries: [String: Entry]
    /// Words that are protected but never offered as candidates: the pieces of a multi-word
    /// dictionary entry ("Pivot Studio"). A piece such as "the" with a bonus would pull its
    /// neighbours toward a common word; protecting it costs nothing.
    private var protectedOnly: Set<String>

    public static let empty = UserLexicon()

    public init(dictionaryTerms: [String] = [], systemWords: [String] = [], keptWords: [String] = []) {
        entries = [:]
        protectedOnly = []
        for term in dictionaryTerms { add(term, source: .dictionary) }
        for word in systemWords { add(word, source: .system) }
        for word in keptWords { add(word, source: .kept) }
    }

    /// Builds the dictionary side from the Murmur dictionary's entries: the `write` text of every
    /// enabled entry, terms and correction targets alike (a user who writes "Kelpie" for "kelpy"
    /// does not want the keyboard to undo it).
    public init(entries dictionary: [DictionaryEntry], systemWords: [String] = [], keptWords: [String] = []) {
        self.init(
            dictionaryTerms: dictionary.filter(\.isEnabled).map(\.write), systemWords: systemWords,
            keptWords: keptWords)
    }

    /// Lowercase with straight apostrophes: the form the model and this lexicon key words by.
    public static func fold(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    public var isEmpty: Bool { entries.isEmpty && protectedOnly.isEmpty }

    /// The entry for a word, if the lexicon has it as a candidate source.
    public func entry(for word: String) -> Entry? {
        entries[Self.fold(word)]
    }

    /// Whether autocorrect must leave this word alone.
    public func isProtected(_ word: String) -> Bool {
        let folded = Self.fold(word)
        return entries[folded] != nil || protectedOnly.contains(folded)
    }

    /// The flags for a typed word. System names and dictionary terms stay apart because the policy
    /// treats them alike but the tests, and later the settings screen, tell them apart.
    public func knowledge(of word: String, model: TypingModel) -> WordKnowledge {
        let folded = Self.fold(word)
        let entry = entries[folded]
        let pieceOfPhrase = protectedOnly.contains(folded)
        return WordKnowledge(
            inModel: model.id(of: folded) != nil,
            inUserLexicon: entry?.source == .kept,
            inSystemLexicon: entry?.source == .system,
            inDictionary: entry?.source == .dictionary || pieceOfPhrase)
    }

    private mutating func add(_ text: String, source: Source) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pieces = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        if pieces.count > 1 {
            for piece in pieces { protectedOnly.insert(Self.fold(piece)) }
            return
        }
        let folded = Self.fold(trimmed)
        if let existing = entries[folded], existing.bonus >= source.bonus { return }
        entries[folded] = Entry(display: trimmed, source: source)
    }
}
