import Foundation

/// One rule that fired during a pass, as shown on the history row.
public struct AppliedCorrection: Codable, Hashable, Sendable {
    /// The first match of the rule, as it stood when the rule ran.
    public let from: String
    /// The entry's `write` text, unchanged.
    public let to: String
    /// How many spans the rule replaced.
    public let count: Int
}

/// Rewrites known mishearings into their correct spelling, deterministically.
///
/// Rules are compiled once in `init` because `apply` sits on the release path of every
/// dictation. Matching is done by hand over characters rather than with a regular
/// expression, so the replacement is plain text and a trigger can hold any character.
public struct DictionaryCorrector: Sendable {
    /// A compiled trigger: its words, each folded to lowercase per character, and the text
    /// that replaces a match.
    private struct Rule: Sendable {
        let words: [[String]]
        let replacement: String
    }

    private let rules: [Rule]

    public init(entries: [DictionaryEntry]) {
        // Longest trigger first, measured on the string as stored. `sorted` is not
        // guaranteed stable, so the original position is the explicit tie-break.
        let eligible = entries.enumerated().filter { _, entry in
            entry.isEnabled && entry.kind == .correction
                && !entry.hear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let ordered = eligible.sorted { lhs, rhs in
            let l = lhs.element.hear.count
            let r = rhs.element.hear.count
            return l != r ? l > r : lhs.offset < rhs.offset
        }
        rules = ordered.compactMap { _, entry in
            let trigger = entry.hear.precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let words = trigger
                .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "\t" })
                .map { $0.map(Self.fold) }
            guard !words.isEmpty else { return nil }
            return Rule(words: words, replacement: entry.write)
        }
    }

    public var isEmpty: Bool { rules.isEmpty }

    public func apply(to text: String) -> (text: String, applied: [AppliedCorrection]) {
        guard !rules.isEmpty, !text.isEmpty else { return (text, []) }

        var current = text.precomposedStringWithCanonicalMapping
        var applied: [AppliedCorrection] = []
        for rule in rules {
            let chars = Array(current)
            let spans = Self.matches(of: rule, in: chars)
            guard let first = spans.first else { continue }

            applied.append(AppliedCorrection(
                from: String(chars[first]),
                to: rule.replacement,
                count: spans.count
            ))

            var rebuilt = ""
            var cursor = 0
            for span in spans {
                rebuilt += String(chars[cursor..<span.lowerBound])
                rebuilt += rule.replacement
                cursor = span.upperBound
            }
            rebuilt += String(chars[cursor...])
            current = rebuilt
        }
        return (current, applied)
    }

    // MARK: Matching

    private static func fold(_ character: Character) -> String {
        String(character).lowercased()
    }

    /// Separators the input may carry between two trigger words.
    private static func isSeparator(_ character: Character) -> Bool {
        character == "-" || character.isWhitespace
    }

    /// A letter or number of any script next to a span stops it from matching.
    private static func blocksMatch(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// Non-overlapping spans of `chars`, leftmost first.
    private static func matches(of rule: Rule, in chars: [Character]) -> [Range<Int>] {
        let folded = chars.map(fold)
        let words = rule.words
        let lastWord = words.count - 1

        // The end of a match that places word `index` at `position`, if one exists. Trying
        // fewer separator characters on failure matters only when a word itself begins
        // with a separator-like character such as a no-break space.
        func end(ofWord index: Int, at position: Int) -> Int? {
            let word = words[index]
            guard position + word.count <= folded.count else { return nil }
            for offset in word.indices where folded[position + offset] != word[offset] {
                return nil
            }
            let wordEnd = position + word.count
            if index == lastWord {
                if wordEnd < chars.count, blocksMatch(chars[wordEnd]) { return nil }
                return wordEnd
            }
            var farthest = wordEnd
            while farthest < chars.count, isSeparator(chars[farthest]) { farthest += 1 }
            var next = farthest
            while next >= wordEnd {
                if let found = end(ofWord: index + 1, at: next) { return found }
                next -= 1
            }
            return nil
        }

        var spans: [Range<Int>] = []
        var start = 0
        while start < chars.count {
            let boundaryOK = start == 0 || !blocksMatch(chars[start - 1])
            if boundaryOK, let finish = end(ofWord: 0, at: start) {
                spans.append(start..<finish)
                start = finish
            } else {
                start += 1
            }
        }
        return spans
    }
}

// MARK: Biasing

extension DictionaryCorrector {
    /// Engines drift when handed long vocabulary lists and, on quiet audio, start inventing
    /// text from them. A short list costs a misspelling now and then; a long one costs
    /// hallucinated words, which is worse.
    public static let biasLimit = 40

    /// The spellings to hand the speech engine as context, in entry order. Only the `write`
    /// side is used, and the first spelling of a case-insensitive duplicate wins.
    public static func biasPhrases(from entries: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        var phrases: [String] = []
        for entry in entries where entry.isEnabled {
            let phrase = entry.write.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty else { continue }
            let key = phrase.precomposedStringWithCanonicalMapping.lowercased()
            guard seen.insert(key).inserted else { continue }
            phrases.append(phrase)
            if phrases.count == biasLimit { break }
        }
        return phrases
    }
}
