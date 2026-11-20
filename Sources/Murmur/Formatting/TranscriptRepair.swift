import Foundation

/// Text-only repairs for three habits of Bark's decoder, applied whatever cleanup engine runs.
///
/// All were measured on the run log (2026-10-27 to 2026-11-13):
///
/// - At a short pause Bark writes a period but leaves the next word lowercase (123 times,
///   against 208 real sentence ends it capitalised itself), in batch and streaming alike, so
///   it is the model and not the window seam. The lowercase word is the model saying "not a
///   sentence end"; `RuleBasedFormatter` used to capitalise it and lose that signal.
/// - Bark Clean never writes digits: every number in the raw text is spelled out. S1-mini
///   is meant to write numerals and does so only sometimes on this input.
/// - Bark spells an acronym out letter by letter, in three styles: "m. c. p.", "N T U" and
///   "x y z" (about 90 runs of letters in 410 transcripts). S1-mini then wrote "M.C.P.S." or
///   "H-T-M-L", and the rule pass capitalised the word after each period.
enum TranscriptRepair {
    // MARK: Pause periods

    /// Two or more letters, a period, a space, then a lowercase word of two or more letters
    /// (or "a"). Spelled letters ("l. l. m."), abbreviations ("e.g."), ellipses and decimals
    /// all fail one side of that and keep their period; "etc." and "vs." are the two
    /// abbreviations long enough to pass and are excluded by name.
    private static let pausePeriod = try! NSRegularExpression(
        pattern: #"(?<=\p{L}{2})(?<!\betc)(?<!\bvs)\. (?=\p{Ll}{2}|a )"#
    )

    static func dropPausePeriods(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return pausePeriod.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    }

    // MARK: Spelled letters

    /// One whitespace-separated token that is a single letter: "m.", "N", "s?".
    private struct Letter {
        let character: Character
        /// Written with its own period, the "m. c. p." style.
        let dotted: Bool
        /// A comma or other mark after the letter. It ends the run.
        let trailing: String

        init?(_ token: Substring) {
            var rest = token[...]
            guard let first = rest.popFirst(), first.isASCII, first.isLetter else { return nil }
            character = first
            dotted = rest.first == "."
            if dotted { rest.removeFirst() }
            guard rest.count <= 1, rest.allSatisfy({ ",?!;:".contains($0) }) else { return nil }
            trailing = String(rest)
        }

        var isBareLowercase: Bool { !dotted && character.isLowercase }
    }

    /// Joins a run of two or more spelled letters into one uppercase word: "m. c. p." and
    /// "N T U" become "MCP" and "NTU".
    ///
    /// Two single letters are also English words, so they join only where the run shows
    /// they are letters: a bare "a" needs a bare lowercase letter beside it ("a b c", not
    /// "a U A T"), a bare "I" needs a bare letter beside it, and one ending a run of two is
    /// taken as the pronoun ("option A I think") unless a mark follows it ("T I,"). "i. e."
    /// and "e. g." are left alone. A
    /// lowercase "s" closing a dotted run of four or more is a plural: "m. c. p. s." is
    /// "MCPs". Three letters ending in "s" are an acronym far more often than the plural of
    /// a two-letter one (NUS, AWS, DNS against PRs): "N. u. s." typed "Nus." on 2026-11-13
    /// when the rule started at three. The last letter's own period stays only where a sentence may end, before a
    /// capital or at the end of the text; a period after a bare letter was written as
    /// punctuation and always stays.
    static func joinSpelledLetters(_ text: String) -> String {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false)
        var output: [String] = []
        output.reserveCapacity(tokens.count)

        var index = 0
        while index < tokens.count {
            var run: [Letter] = []
            var end = index
            while end < tokens.count, let letter = Letter(tokens[end]) {
                let next = end + 1 < tokens.count ? Letter(tokens[end + 1]) : nil
                if letter.isBareLowercase, letter.character == "a",
                   !(run.last?.isBareLowercase ?? false), !(next?.isBareLowercase ?? false) {
                    break
                }
                // A bare "I" is the pronoun unless bare letters surround it: "m. c. p. s. I had".
                if !letter.dotted, letter.character == "I",
                   run.last?.dotted ?? (next?.dotted ?? true) {
                    break
                }
                run.append(letter)
                end += 1
                if !letter.trailing.isEmpty { break }
            }
            // A bare "I" closing a run of two with nothing after it but more words.
            if run.count == 2, let last = run.last, !last.dotted, last.character == "I",
               last.trailing.isEmpty, end < tokens.count {
                run.removeLast()
                end -= 1
            }
            let spelled = String(run.map(\.character)).lowercased()
            guard run.count >= 2, spelled != "ie", spelled != "eg", let last = run.last else {
                output.append(String(tokens[index]))
                index += 1
                continue
            }

            let dottedStyle = run[run.count - 2].dotted
            var word = spelled.uppercased()
            if run.count >= 4, dottedStyle, last.character == "s" {
                word = String(word.dropLast()) + "s"
            }
            if last.dotted {
                let nextStartsSentence = end >= tokens.count
                    || (tokens[end].first(where: \.isLetter)?.isUppercase ?? false)
                if !dottedStyle || nextStartsSentence { word += "." }
            }
            output.append(word + last.trailing)
            index = end
        }
        return output.joined(separator: " ")
    }

    // MARK: Numerals

    private static let unitWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9,
    ]
    private static let teenWords: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tenWords: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]
    private static let magnitudeWords: [String: Int] = [
        "hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]
    private static let rangeWords: Set<String> = ["to", "through", "or"]

    private enum Word: Equatable {
        case unit(Int), teen(Int), tens(Int), magnitude(Int), and, point

        init?(_ word: String) {
            let w = word.lowercased()
            if let v = unitWords[w] { self = .unit(v) }
            else if let v = teenWords[w] { self = .teen(v) }
            else if let v = tenWords[w] { self = .tens(v) }
            else if let v = magnitudeWords[w] { self = .magnitude(v) }
            else if w == "and" { self = .and }
            else if w == "point" { self = .point }
            else { return nil }
        }
    }

    /// One whitespace-separated token split into the part that may be a number and what
    /// surrounds it: leading punctuation, trailing possessive and punctuation.
    private struct Token {
        let leading: String
        let core: String
        let trailing: String
        /// The number words of `core`, split at hyphens; nil when any part is not one.
        let words: [Word]?

        init(_ raw: Substring) {
            var start = raw.startIndex
            while start < raw.endIndex, raw[start].isPunctuation { start = raw.index(after: start) }
            var end = raw.endIndex
            while end > start, raw[raw.index(before: end)].isPunctuation {
                end = raw.index(before: end)
            }
            var core = raw[start..<end]
            var trailing = String(raw[end...])
            for suffix in ["'s", "\u{2019}s"] where core.hasSuffix(suffix) {
                trailing = suffix + trailing
                core = core.dropLast(suffix.count)
            }
            leading = String(raw[..<start])
            self.core = String(core)
            self.trailing = trailing
            let parts = core.split(separator: "-")
            let words = parts.compactMap { Word(String($0)) }
            self.words = (!parts.isEmpty && words.count == parts.count) ? words : nil
        }

        var text: String { leading + core + trailing }
        func replacing(_ value: String) -> String { leading + value + trailing }
    }

    static func writeNumerals(_ text: String) -> String {
        guard text.contains(where: \.isLetter) else { return text }
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(Token.init)
        var output: [String] = Array(repeating: "", count: tokens.count)
        var converted = Array(repeating: false, count: tokens.count)
        var smallWordValue: [Int?] = Array(repeating: nil, count: tokens.count)

        var index = 0
        while index < tokens.count {
            guard tokens[index].words != nil else {
                output[index] = tokens[index].text
                index += 1
                continue
            }
            // Extend the run while tokens are number words joined without punctuation. "and"
            // continues only after a magnitude, "point" only when a digit follows, and "a"
            // before a magnitude counts as one.
            var run: [Word] = []
            var end = index
            var lastWasMagnitude = false
            while end < tokens.count, let words = tokens[end].words {
                if words == [.and] {
                    guard lastWasMagnitude, end + 1 < tokens.count, let next = tokens[end + 1].words,
                          next.first != .and, next.first != .point, tokens[end].trailing.isEmpty
                    else { break }
                } else if words == [.point] {
                    guard !run.isEmpty, end + 1 < tokens.count, let next = tokens[end + 1].words,
                          next.allSatisfy({ if case .unit = $0 { return true }; if case .tens = $0 { return true }; return false }),
                          tokens[end].trailing.isEmpty
                    else { break }
                }
                run.append(contentsOf: words)
                if case .magnitude = words.last { lastWasMagnitude = true } else { lastWasMagnitude = false }
                end += 1
                if !tokens[end - 1].trailing.isEmpty { break }
            }
            if run.isEmpty || run == [.and] || run == [.point] {
                output[index] = tokens[index].text
                index += 1
                continue
            }
            let endIndex = end
            // "a hundred", "a thousand": the article is the leading one.
            var leadingArticle = false
            if case .magnitude = run.first, index > 0, tokens[index - 1].core.lowercased() == "a",
               tokens[index - 1].trailing.isEmpty, tokens[index - 1].leading.isEmpty {
                leadingArticle = true
            }

            if let rendered = render(run) {
                if run.count == 1, case .unit(let v) = run[0] {
                    // Kept as a word unless a range joins it to a number that converted.
                    smallWordValue[index] = v
                    output[index] = tokens[index].text
                } else {
                    let first = index
                    if leadingArticle { output[first - 1] = ""; converted[first - 1] = true }
                    for i in first..<endIndex { output[i] = ""; converted[i] = true }
                    output[first] = tokens[first].replacing(rendered)
                    // Trailing punctuation of the last token stays on the number.
                    if endIndex - 1 > first {
                        output[first] = tokens[first].leading + rendered + tokens[endIndex - 1].trailing
                    }
                }
            } else {
                for i in index..<endIndex { output[i] = tokens[i].text }
            }
            index = endIndex
        }

        // Range rule: "six to eleven" reads as "6 to 11", never "six to 11".
        for i in tokens.indices where smallWordValue[i] != nil {
            let neighbours = [i - 2, i + 2].filter { tokens.indices.contains($0) }
            let joined = neighbours.contains { n in
                let between = min(i, n) + 1
                return converted[n] && output[n].contains(where: \.isNumber)
                    && rangeWords.contains(tokens[between].core.lowercased()) && tokens[between].trailing.isEmpty
            }
            if joined, let v = smallWordValue[i] {
                output[i] = tokens[i].replacing(String(v))
                converted[i] = true
            }
        }

        // Tokens emptied by a conversion vanish together with their space; tokens that were
        // empty in the input (a doubled space) stay, so spacing is otherwise untouched.
        var pieces: [String] = []
        for (i, piece) in output.enumerated() where !(converted[i] && piece.isEmpty) {
            pieces.append(piece)
        }
        return pieces.joined(separator: " ")
    }

    /// Digits for a run of number words, or nil when the words do not form one number.
    private static func render(_ run: [Word]) -> String? {
        var words = run[...]
        var fraction: [Word] = []
        if let point = words.firstIndex(of: .point) {
            fraction = Array(words[words.index(after: point)...])
            words = words[..<point]
            guard !fraction.isEmpty else { return nil }
        }
        let whole = Array(words.filter { $0 != .and })

        // A bare string of digits: "one two three" is "1 2 3".
        if whole.count >= 2, fraction.isEmpty, whole.allSatisfy({ if case .unit = $0 { return true }; return false }) {
            return whole.map { if case .unit(let v) = $0 { return String(v) }; return "" }.joined(separator: " ")
        }
        // Two tens-groups with no magnitude read as a year or a model number: "twenty
        // twenty-six" is 2026, "ten eighty" is 1080.
        if fraction.isEmpty, let (a, b) = twoGroups(whole), a >= 10, b >= 10 {
            return String(a * 100 + b)
        }
        guard let value = integer(whole) else { return nil }
        var text = grouped(value)
        if !fraction.isEmpty {
            var digits = ""
            for word in fraction {
                switch word {
                case .unit(let v): digits += String(v)
                case .tens(let v): digits += String(v)
                default: return nil
                }
            }
            text += "." + digits
        }
        return text
    }

    /// Splits a run into exactly two groups each of the form tens, teen or tens+unit.
    private static func twoGroups(_ words: [Word]) -> (Int, Int)? {
        var groups: [Int] = []
        var i = 0
        while i < words.count {
            switch words[i] {
            case .teen(let v):
                groups.append(v); i += 1
            case .tens(let v):
                if i + 1 < words.count, case .unit(let u) = words[i + 1], u > 0 {
                    groups.append(v + u); i += 2
                } else {
                    groups.append(v); i += 1
                }
            default:
                return nil
            }
        }
        guard groups.count == 2 else { return nil }
        return (groups[0], groups[1])
    }

    /// Standard English number grammar. Returns nil for sequences it does not recognise
    /// ("fifteen five"), which then stay as spoken.
    private static func integer(_ words: [Word]) -> Int? {
        var total = 0
        var current = 0
        var group: [Word] = []
        func close() -> Bool {
            // One group between magnitudes: unit | teen | tens | tens unit, optionally after
            // "<that> hundred".
            var i = 0
            var value = 0
            if let h = group.firstIndex(of: .magnitude(100)) {
                let before = Array(group[..<h])
                guard before.isEmpty || isSmallGroup(before) else { return false }
                value = max(1, smallValue(before)) * 100
                i = h + 1
            }
            let rest = Array(group[i...])
            guard rest.isEmpty || isSmallGroup(rest) else { return false }
            current = value + smallValue(rest)
            return true
        }
        for word in words {
            if case .magnitude(let m) = word, m >= 1_000 {
                guard close() else { return nil }
                guard total == 0 || m < lastMagnitude(total) else { return nil }
                total += max(current, 1) * m
                current = 0
                group = []
            } else {
                group.append(word)
            }
        }
        guard close() else { return nil }
        return total + current
    }

    private static func lastMagnitude(_ total: Int) -> Int {
        total >= 1_000_000_000 ? 1_000_000_000 : total >= 1_000_000 ? 1_000_000 : 1_000
    }

    private static func isSmallGroup(_ words: [Word]) -> Bool {
        switch words.count {
        case 1:
            switch words[0] {
            case .unit, .teen, .tens: return true
            default: return false
            }
        case 2:
            if case .tens = words[0], case .unit(let u) = words[1], u > 0 { return true }
            return false
        default:
            return false
        }
    }

    private static func smallValue(_ words: [Word]) -> Int {
        words.reduce(0) { sum, word in
            switch word {
            case .unit(let v), .teen(let v), .tens(let v): sum + v
            default: sum
            }
        }
    }

    private static func grouped(_ value: Int) -> String {
        let digits = String(value)
        guard digits.count > 3 else { return digits }
        var out = ""
        for (offset, ch) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return String(out.reversed())
    }
}
