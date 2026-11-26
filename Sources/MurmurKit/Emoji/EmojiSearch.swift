import Foundation

#if canImport(Accelerate)
import Accelerate
#endif

/// Gives a vector for a piece of text, for the semantic half of emoji search. A protocol so the
/// tests inject a fake and the keyboard injects Apple's on-device sentence embedding
/// (`NLEmbeddingEmojiEmbedder`).
public protocol EmojiEmbedder: Sendable {
    /// Names the model that makes the vectors. A cache of emoji vectors is only valid for the
    /// revision it was built with.
    var revision: String { get }
    /// The length of every vector.
    var dimension: Int { get }
    /// A vector for `text`, or nil when the model has none for it. It need not be unit length.
    func vector(for text: String) -> [Float]?
}

/// One vector per emoji of an `EmojiSearch`'s entries, each scaled to unit length so a dot product
/// is a cosine. Holds a prefix when the build was not finished (`count` is then below the entry
/// count) and the rows after it simply have no semantic score.
public struct EmojiVectors: Sendable {
    public let dimension: Int
    /// `count` rows of `dimension` floats, back to back.
    public let values: [Float]

    public var count: Int { dimension > 0 ? values.count / dimension : 0 }

    public init(dimension: Int, values: [Float]) {
        self.dimension = dimension
        self.values = values
    }

    /// Unit-length copy of `vector`; nil when it is empty or all zero.
    public static func normalised(_ vector: [Float]) -> [Float]? {
        var sum: Float = 0
        for value in vector { sum += value * value }
        guard sum > 0 else { return nil }
        let scale = 1 / sum.squareRoot()
        return vector.map { $0 * scale }
    }

    /// The cosine of each row with `query`, which must be unit length. Empty when the length
    /// differs from this table's.
    public func similarities(to query: [Float]) -> [Float] {
        guard query.count == dimension, dimension > 0 else { return [] }
        let rows = count
        var result = [Float](repeating: 0, count: rows)
        #if canImport(Accelerate)
        // One matrix-vector product: (rows x dimension) times (dimension x 1).
        vDSP_mmul(values, 1, query, 1, &result, 1, vDSP_Length(rows), 1, vDSP_Length(dimension))
        return result
        #else
        values.withUnsafeBufferPointer { rowsPointer in
            query.withUnsafeBufferPointer { queryPointer in
                for row in 0..<rows {
                    var sum: Float = 0
                    let base = row * dimension
                    for column in 0..<dimension { sum += rowsPointer[base + column] * queryPointer[column] }
                    result[row] = sum
                }
            }
        }
        return result
        #endif
    }
}

/// Emoji search by description: the CLDR name and keywords of each emoji matched against the
/// words typed (the lexical half, instant and always available), and when an embedder's vectors
/// are present, their cosine with the query's vector (the semantic half), which fills and
/// re-ranks. Pure; the keyboard supplies the embedder and does the slow parts off the main thread.
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

    // MARK: Text for embedding

    /// What an emoji's vector is made from: its name and its first three keywords. All of the
    /// keywords did worse than three on the evaluation (`EmojiSearchEvaluationTests`): a long list
    /// of loosely related words pulls every vector toward the same middle, and CLDR lists the
    /// keywords alphabetically, so a longer list adds no more important ones.
    public func embeddingText(at index: Int) -> String {
        let entry = entries[index]
        return ([entry.name] + entry.keywords.prefix(Self.embeddedKeywords)).joined(separator: ", ")
    }

    static let embeddedKeywords = 3

    /// A fingerprint of everything the vectors are made from, for a cache key. FNV-1a, because
    /// `Hasher` is seeded per process.
    public var dataHash: String {
        var hash: UInt64 = 0xcbf29ce484222325
        for index in entries.indices {
            for byte in entries[index].emoji.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            for byte in embeddingText(at: index).utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        }
        return String(hash, radix: 16)
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
    /// lexical score of 1 is a perfect match and blends against a cosine.
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

    // MARK: Blend

    /// How the semantic half joins the lexical one. The cosine is read against the other emoji's
    /// for the same query, because a sentence embedding's raw cosines sit in a narrow band that
    /// differs from query to query: `sem` below is 0 at `floorDeviations` standard deviations
    /// above the query's mean cosine and 1 at the nearest emoji.
    ///
    /// Apple's embedding is a weak judge of single emoji (measured, `EmojiSearchEvaluationTests`:
    /// alone it puts an accepted emoji first for 27% of the queries), so it never outranks a
    /// lexical match: it brings in emoji the words missed at `fillWeight * sem`, which puts the
    /// nearest of them level with a prefix match and the rest below the words' own matches.
    /// `rerankWeight` adds `rerankWeight * sem` to an emoji the words did match, which only
    /// separates close lexical scores; at 0.05 it cost one first place in 51 and gained nothing
    /// held out, so it is off.
    public struct Blend: Sendable, Equatable {
        public var rerankWeight = 0.0
        public var fillWeight = 0.1
        public var floorDeviations = 2.0
        /// How many of the nearest by meaning can join the candidates.
        public var semanticCandidates = 40

        public init() {}
    }

    /// The best `limit` emoji for `query`. With no `queryVector` (no embedder, no vectors yet, or
    /// not worked out yet) it is lexical only. `queryVector` must be unit length and made by the
    /// embedder `vectors` came from.
    public func search(
        _ query: String, queryVector: [Float]? = nil, vectors: EmojiVectors? = nil,
        blend: Blend = Blend(), limit: Int = 40
    ) -> [String] {
        let lexical = lexicalHits(query)
        guard let queryVector, let vectors, vectors.count > 0 else {
            return lexical.prefix(limit).map { entries[$0.index].emoji }
        }
        let cosines = vectors.similarities(to: queryVector)
        guard !cosines.isEmpty else { return lexical.prefix(limit).map { entries[$0.index].emoji } }

        // The query's own cosine distribution, which sets what counts as near.
        var sum: Float = 0
        var top: Float = -1
        for value in cosines {
            sum += value
            top = max(top, value)
        }
        let mean = sum / Float(cosines.count)
        var variance: Float = 0
        for value in cosines { variance += (value - mean) * (value - mean) }
        let deviation = max((variance / Float(cosines.count)).squareRoot(), 1e-6)
        let floor = mean + Float(blend.floorDeviations) * deviation
        let span = max(top - floor, 1e-6)
        func semantic(_ index: Int) -> Double {
            Double(max(cosines[index] - floor, 0) / span)
        }

        var scores: [Int: Double] = [:]
        for hit in lexical { scores[hit.index] = hit.score + blend.rerankWeight * semantic(hit.index) }
        // The nearest by meaning that the words missed. Only cosines above the floor are sorted.
        let near = cosines.indices.filter { cosines[$0] > floor && scores[$0] == nil }
            .sorted { cosines[$0] > cosines[$1] }
            .prefix(blend.semanticCandidates)
        for index in near { scores[index] = blend.fillWeight * semantic(index) }
        return scores
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { entries[$0.key].emoji }
    }
}
