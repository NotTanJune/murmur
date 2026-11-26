import Foundation

/// Emoji search by description: the CLDR name and keywords of each emoji matched against the
/// words typed. Keyword only, with no model behind it, so it answers at once on the main thread.
/// Pure.
public struct EmojiSearch: Sendable {
    public struct Entry: Sendable, Equatable {
        public let emoji: String
        public let name: String
        public let keywords: [String]

        public init(emoji: String, name: String, keywords: [String]) {
            self.emoji = emoji
            self.name = name
            self.keywords = keywords
        }
    }

    /// An entry with the words the lexical pass compares against, worked out once.
    private struct Indexed: Sendable {
        let nameWords: [String]
        let keywordWords: Set<String>
    }

    public let entries: [Entry]
    private let indexed: [Indexed]

    public init(entries: [Entry]) {
        self.entries = entries
        indexed = entries.map { entry in
            Indexed(
                nameWords: Self.words(entry.name),
                keywordWords: Set(entry.keywords.flatMap(Self.words)))
        }
    }

    /// The keyboard's emoji, in catalogue order, with their CLDR names and keywords.
    public static let standard = EmojiSearch(entries: parse(EmojiNames.table))

    /// Parses the generated table: `emoji TAB name TAB kw|kw|kw` per line.
    static func parse(_ table: String) -> [Entry] {
        table.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            let keywords = parts[2].split(separator: "|").map(String.init)
            return Entry(emoji: String(parts[0]), name: String(parts[1]), keywords: keywords)
        }
    }

    // MARK: Words

    private static let stopWords: Set<String> = [
        "a", "an", "the", "of", "to", "in", "on", "at", "for", "with", "and", "is", "are", "be", "it",
        "i", "im", "am", "my", "me", "so", "very", "really", "feel", "feeling", "just", "that", "this",
    ]

    /// Lowercase words of `text`, split at anything that is not a letter or a digit, with
    /// apostrophes dropped ("don't" is "dont"), each reduced to a stem (`stem`).
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if character == "'" || character == "\u{2019}" {
                continue
            } else if !current.isEmpty {
                result.append(stem(current))
                current = ""
            }
        }
        if !current.isEmpty { result.append(stem(current)) }
        return result
    }

    /// The query's words, without the small ones when anything else is left.
    static func queryWords(_ query: String) -> [String] {
        let all = words(query)
        let kept = all.filter { !stopWords.contains($0) }
        return kept.isEmpty ? all : kept
    }

    /// A plain suffix stripper: plurals, "-ing" and "-ed". Both sides of a comparison go through
    /// it, so it only has to be consistent. "crying" and "cries" both give "cry".
    static func stem(_ word: String) -> String {
        var word = word
        guard word.count > 3, word.allSatisfy(\.isLetter) else { return word }
        if word.hasSuffix("ies"), word.count > 4 {
            word.removeLast(3)
            return word + "y"
        }
        if word.hasSuffix("sses") {
            word.removeLast(2)
            return word
        }
        if word.hasSuffix("ing"), word.count > 5 {
            word.removeLast(3)
            return undouble(word)
        }
        if word.hasSuffix("ed"), word.count > 4 {
            word.removeLast(2)
            return undouble(word)
        }
        if word.hasSuffix("es"), word.count > 4, let before = word.dropLast(2).last, "sxz".contains(before) || word.hasSuffix("ches") || word.hasSuffix("shes") {
            word.removeLast(2)
            return word
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") {
            word.removeLast()
        }
        return word
    }

    /// "runn" is "run", "stopp" is "stop"; "ll", "ss" and "zz" stay ("fall", "kiss").
    private static func undouble(_ word: String) -> String {
        guard let last = word.last, word.dropLast().last == last, !"lsz".contains(last) else { return word }
        return String(word.dropLast())
    }

    // MARK: Lexical

    /// Points for how a query word meets an emoji, best kind first.
    private enum Match {
        static let nameExact = 10.0
        static let keywordExact = 7.0
        static let namePrefix = 6.0
        static let keywordPrefix = 3.0
        /// A name match is worth `1 / (1 + this * extra)` of its points when the name has `extra`
        /// words besides the one matched, so "car" prefers the automobile (a keyword) to
        /// "railway car" and "heart" prefers "red heart" to "heart with ribbon".
        static let nameDilution = 0.2
        /// A query that is the whole name.
        static let wholeName = 15.0
        /// Every query word found.
        static let allWords = 4.0
        /// The most a common emoji gains. It only separates matches that are otherwise level, so
        /// "heart" lists the red heart first and "lol" the tears of joy.
        static let popularity = 0.9
        /// Taken off for each word the emoji has in its name and keywords, so of two equal
        /// matches the one with fewer words (the more specific one) comes first: "car" lists the
        /// automobile before a railway car that also lists "car".
        static let perWord = 0.03
    }

    /// The emoji people type most, most common first, kept as a tie-breaker between equal
    /// matches. Hand-written from general knowledge of what messaging apps list first, not
    /// measured on the owner's typing.
    static let popular: [String] = [
        "😂", "❤️", "🤣", "👍", "😭", "🙏", "😘", "🥰", "😍", "😊", "🎉", "😁", "💕", "🥺", "😅", "🔥",
        "🤦", "🤔", "😎", "🙄", "😢", "👏", "💀", "😉", "🙂", "😀", "😃", "😄", "😆", "🥳", "😴", "🤯",
        "😡", "😱", "😳", "🤗", "😬", "😇", "🤩", "😋", "😜", "🤪", "🙃", "😏", "😒", "😔", "😞", "😩",
        "💪", "👌", "🙌", "👀", "💯", "✨", "🎂", "🌹", "💔", "💖", "💙", "💜", "🖤", "👋", "🤝", "🚀",
        "🚗", "🐶", "🐱", "🍕", "☕", "🍺", "🍻", "🌞", "⭐", "🎁", "🎈", "💰", "📱", "💻", "🏠", "⚽",
        "🍔", "🍟", "🌈", "🌙", "😪", "🥱", "😰", "😓", "🤢", "🤮", "🤒", "😷", "🤧", "☹️", "🙁",
    ]

    private static let popularityRank: [String: Int] = Dictionary(
        popular.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

    /// The most a lexical score can be for `wordCount` query words: scores are divided by it, so a
    /// score of 1 is a perfect match.
    private static func ceiling(wordCount: Int) -> Double {
        Match.nameExact * Double(wordCount) + Match.wholeName + Match.allWords
    }

    /// Entries that share a word with `query`, best first, with scores in 0...1 (1 is the whole
    /// name typed exactly). The last word may be a prefix, since it is being typed; earlier words
    /// must match a whole word.
    public func lexicalHits(_ query: String) -> [(index: Int, score: Double)] {
        let words = Self.queryWords(query)
        guard !words.isEmpty else { return [] }
        let ceiling = Self.ceiling(wordCount: words.count)
        var hits: [(index: Int, score: Double)] = []
        for index in indexed.indices {
            if var score = lexicalScore(words, of: indexed[index]) {
                if let rank = Self.popularityRank[entries[index].emoji] {
                    score += Match.popularity * (1 - Double(rank) / Double(Self.popular.count))
                }
                hits.append((index, min(score / ceiling, 1)))
            }
        }
        // Stable on the catalogue's own order, which puts the plain faces and common objects first.
        return hits.enumerated().sorted {
            $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset
        }.map(\.element)
    }

    private func lexicalScore(_ words: [String], of entry: Indexed) -> Double? {
        var total = 0.0
        var matched = 0
        for (position, word) in words.enumerated() {
            let isLast = position == words.count - 1
            var best = 0.0
            // How many of the name's words this query word does not stand for.
            let dilution = 1 / (1 + Match.nameDilution * Double(max(entry.nameWords.count - 1, 0)))
            for nameWord in entry.nameWords {
                if nameWord == word {
                    best = max(best, Match.nameExact * dilution)
                } else if isLast, word.count >= 2, nameWord.hasPrefix(word) {
                    best = max(best, Match.namePrefix * dilution)
                }
            }
            if entry.keywordWords.contains(word) {
                best = max(best, Match.keywordExact)
            } else if isLast, word.count >= 2, entry.keywordWords.contains(where: { $0.hasPrefix(word) }) {
                best = max(best, Match.keywordPrefix)
            }
            if best > 0 {
                total += best
                matched += 1
            }
        }
        guard matched > 0 else { return nil }
        // A query that names only some of its words is worth less, in proportion.
        let share = Double(matched) / Double(words.count)
        total *= words.count == 1 ? 1 : 0.4 + 0.6 * share
        if matched == words.count { total += Match.allWords }
        if entry.nameWords == words { total += Match.wholeName }
        total -= Match.perWord * Double(entry.nameWords.count + entry.keywordWords.count)
        return max(total, 0.01)
    }

    // MARK: Search

    /// The best `limit` emoji for `query`, best first.
    public func search(_ query: String, limit: Int = 40) -> [String] {
        lexicalHits(query).prefix(limit).map { entries[$0.index].emoji }
    }
}
