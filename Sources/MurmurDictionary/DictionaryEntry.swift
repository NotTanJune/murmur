import Foundation

/// One line of the user's dictionary: a term to favour or a correction to apply.
public struct DictionaryEntry: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case term, correction }

    public var id: UUID
    public var kind: Kind
    /// The correct text. For a term it is the word itself.
    public var write: String
    /// The mishearing to rewrite. Empty for terms.
    public var hear: String
    /// A disabled entry stays in the file but affects nothing.
    public var isEnabled: Bool

    public init(id: UUID = UUID(), kind: Kind, write: String, hear: String = "", isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.write = write
        self.hear = hear
        self.isEnabled = isEnabled
    }

    public static func term(_ word: String) -> DictionaryEntry {
        DictionaryEntry(kind: .term, write: word)
    }

    public static func correction(hear: String, write: String) -> DictionaryEntry {
        DictionaryEntry(kind: .correction, write: write, hear: hear)
    }

    /// The entry as it is stored in `dictionary.txt`, without a trailing newline.
    public var fileLine: String {
        let body = kind == .correction ? "\(hear) -> \(write)" : write
        return isEnabled ? body : "# off: " + body
    }
}

/// A hint shown while editing, for an entry likely to fire on text the user did not mean.
/// It never blocks saving.
public struct DictionaryWarning: Identifiable, Sendable {
    public var id: String { message }
    public let message: String

    public static func check(_ entry: DictionaryEntry) -> [DictionaryWarning] {
        guard entry.kind == .correction else { return [] }
        let trigger = entry.hear.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else { return [] }

        var warnings: [DictionaryWarning] = []

        let words = trigger.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" })
        if words.count == 1, let word = words.first.map(String.init) {
            if commonWords.contains(word) {
                warnings.append(DictionaryWarning(message:
                    "\"\(trigger)\" is an ordinary word, so this rule will rewrite every use of it. A longer phrase is safer."))
            } else if word.count <= 3 {
                warnings.append(DictionaryWarning(message:
                    "\"\(trigger)\" is very short and will match often. A longer phrase is safer."))
            }
        }

        let written = entry.write.trimmingCharacters(in: .whitespacesAndNewlines)
        if written.caseInsensitiveCompare(trigger) == .orderedSame {
            warnings.append(DictionaryWarning(message:
                "\"\(trigger)\" is rewritten to itself, so this rule will never change anything."))
        }
        return warnings
    }

    /// Words frequent enough that a single-word trigger would fire constantly in speech.
    /// Deliberately short: it targets obvious foot-guns, not every common word.
    private static let commonWords: Set<String> = [
        // articles, pronouns, determiners
        "a", "an", "the", "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us",
        "them", "my", "your", "his", "its", "our", "their", "this", "that", "these", "those",
        // prepositions and conjunctions
        "of", "in", "on", "at", "to", "for", "with", "from", "by", "about", "into", "over",
        "after", "before", "between", "under", "and", "or", "but", "so", "if", "then", "than",
        "because", "as", "while", "when", "where",
        // auxiliaries and very common verbs
        "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "have", "has", "had",
        "will", "would", "can", "could", "should", "may", "might", "must", "get", "got", "go",
        "going", "make", "made", "take", "see", "know", "think", "want", "use", "need", "say",
        "said", "come", "give", "look", "put", "set", "let", "keep", "try",
        // question words and quantifiers
        "what", "which", "who", "whom", "whose", "why", "how", "all", "any", "some", "no", "not",
        "more", "most", "many", "much", "few", "each", "every", "other", "another", "such", "only",
        "just", "also", "very", "too", "here", "there", "now",
        // generic nouns and adjectives
        "thing", "time", "way", "day", "work", "good", "new", "first", "last", "long", "great",
        "little", "own", "right", "big", "high", "old", "same",
        // generic software vocabulary
        "code", "file", "data", "list", "page", "test", "user", "state", "type", "key", "run",
        "name", "value", "text", "line", "app", "build", "main", "model", "tool", "view",
        "node", "task", "form",
    ]
}
