import Foundation

/// Where a word sits in its sentence, which decides whether a capital letter is a name.
public enum SentencePosition: Hashable, Sendable {
    /// The first word of a sentence, a line or the field: a capital is just the sentence's.
    case start
    /// Anywhere else: a capital letter here was typed on purpose, so it is probably a name.
    case middle

    /// The position of a word that starts right after `textBeforeWord`, by the same rule that
    /// turns shift on after a sentence end (`TextRules.autoShift`).
    public static func of(textBeforeWord: String) -> SentencePosition {
        TextRules.autoShift(before: textBeforeWord, autocapitalization: .sentences) ? .start : .middle
    }
}

/// The fixes the owner refused, as a value the controller keeps. A pair is refused for the
/// session after one undo, and for good (until the owner erases what the keyboard learned) after
/// two. Persistence is the caller's job: `entries` is the `typing-rejections.json` payload, and
/// `init(persisted:)` reads it back.
public struct RejectionSet: Sendable, Equatable {
    /// One line of `typing-rejections.json`.
    public struct Entry: Codable, Hashable, Sendable {
        public var original: String
        public var replacement: String
        public var count: Int

        public init(original: String, replacement: String, count: Int) {
            self.original = original
            self.replacement = replacement
            self.count = count
        }
    }

    private struct Pair: Hashable, Sendable {
        let original: String
        let replacement: String

        init(_ original: String, _ replacement: String) {
            self.original = UserLexicon.fold(original)
            self.replacement = UserLexicon.fold(replacement)
        }
    }

    /// A pair undone this many times is never applied again.
    public static let persistedLimit = 2

    private var counts: [Pair: Int] = [:]
    private var session: Set<Pair> = []

    public init(persisted: [Entry] = []) {
        for entry in persisted {
            counts[Pair(entry.original, entry.replacement), default: 0] += max(entry.count, 0)
        }
    }

    /// What to write to `typing-rejections.json`, in a stable order.
    public var entries: [Entry] {
        counts.map { Entry(original: $0.key.original, replacement: $0.key.replacement, count: $0.value) }
            .sorted { ($0.original, $0.replacement) < ($1.original, $1.replacement) }
    }

    /// The owner undid `original` becoming `replacement`: refuse it for the rest of the session,
    /// and count it toward the persisted limit.
    public mutating func recordUndo(original: String, replacement: String) {
        let pair = Pair(original, replacement)
        session.insert(pair)
        counts[pair, default: 0] += 1
    }

    /// Refuses a pair for this session only, with no count (the strip's undo arrow before the
    /// learning store is involved, or a field where nothing may be stored).
    public mutating func rejectForSession(original: String, replacement: String) {
        session.insert(Pair(original, replacement))
    }

    /// Whether the pair must not be applied: undone once this session, or twice ever.
    public func isRejected(original: String, replacement: String) -> Bool {
        let pair = Pair(original, replacement)
        return session.contains(pair) || (counts[pair] ?? 0) >= Self.persistedLimit
    }
}

/// Why autocorrect left a word as it was. The controller ignores it; the tests and the debug log
/// read it.
public enum KeepReason: Hashable, Sendable {
    /// The field refuses autocorrection: it is secure, a URL, email, number or phone field, or
    /// its traits turn autocorrection or spell checking off.
    case fieldDisallows
    /// The word has a digit, `@`, `#`, `/`, or a full stop inside, or another character a word of
    /// plain letters does not have.
    case notAPlainWord
    /// A single letter or an acronym typed in capitals.
    case tooShortOrAcronym
    /// In the user's lexicon, the system's names or the Murmur dictionary.
    case protectedWord
    /// A capital letter in the middle of a sentence: a name.
    case capitalMidSentence
    /// The decoder found nothing.
    case noCandidate
    /// What was typed is the decoder's best reading.
    case typedIsBest
    /// The best candidate is not sure enough.
    case belowThreshold
    /// The fix would write a word the keyboard never volunteers
    /// (`SuggestionEngine.neverVolunteered`) that the taps do not spell exactly.
    case neverVolunteered
    /// The owner refused this fix.
    case rejected
}

/// What autocorrect does with the word just finished.
public enum AutocorrectDecision: Hashable, Sendable {
    case keep(KeepReason)
    case replace(Replacement)
}

/// The text that takes the place of a typed word.
public struct Replacement: Hashable, Sendable {
    /// Ready to type: cased like the typed word. For a missed space it holds both words.
    public let text: String
    public let kind: CandidateKind
    /// The fix came from the contraction rule (`dont` to `don't`), not from the decoder.
    public let isContraction: Bool
}

/// The rules that decide when a decoded word replaces what was typed. Pure: the controller calls
/// it when a space or punctuation ends a word and applies the answer.
public enum AutocorrectPolicy {
    /// The confidence a correction needs.
    public struct Thresholds: Sendable, Equatable {
        /// For a typed word the model does not know: the top candidate's posterior at least this
        /// (the spec starts at 0.85 and 5 times; the replays settled lower, and the owner's real
        /// taps, whose errors are letters left out and neighbours hit, settled lower again: 0.6
        /// fixed one more word of 47 than 0.7 and changed no correct word in any replay)...
        public var unknownPosterior = 0.6
        /// ...and at least this many times the runner-up's.
        public var unknownRatio = 2.5
        /// For a typed word that is a word: the posterior must reach this much...
        public var knownPosterior = 0.97
        /// ...with at most this many edits between what was typed and the replacement.
        public var knownMaxEdits = 1

        public init() {}

        /// The values the replay benchmark settled on.
        public static let tuned = Thresholds()
    }

    /// Decides what to do with a finished word.
    ///
    /// - Parameters:
    ///   - typed: the word as it stands in the field, with its capitals.
    ///   - decoding: the decoder's answer for the word's taps.
    ///   - field: the host field's traits.
    ///   - knowledge: whether the typed word is in the model, the user lexicon, the system
    ///     lexicon or the Murmur dictionary (`UserLexicon.knowledge(of:model:)`).
    ///   - position: whether the word starts a sentence (`SentencePosition.of(textBeforeWord:)`).
    ///   - rejections: the fixes the owner has refused.
    public static func decide(
        typed: String,
        decoding: TapDecoder.Decoding,
        field: FieldTraits,
        knowledge: WordKnowledge,
        position: SentencePosition,
        rejections: RejectionSet,
        model: TypingModel,
        thresholds: Thresholds = .tuned
    ) -> AutocorrectDecision {
        guard allows(field) else { return .keep(.fieldDisallows) }
        guard isPlainWord(typed) else { return .keep(.notAPlainWord) }
        let letters = typed.filter(\.isLetter)
        if typed.count < 2 || (letters.count > 1 && letters == letters.uppercased()) {
            return .keep(.tooShortOrAcronym)
        }
        if knowledge.isProtected { return .keep(.protectedWord) }
        let folded = UserLexicon.fold(typed)

        // A contraction typed without its apostrophe always gets it, whatever the decoder thinks
        // and whatever the capital letter says, unless the owner has refused that very fix.
        if !knowledge.inModel, let contraction = contraction(for: folded, model: model) {
            if rejections.isRejected(original: folded, replacement: contraction) { return .keep(.rejected) }
            return .replace(
                Replacement(
                    text: cased(contraction, matching: typed, preservesCase: false), kind: .exact,
                    isContraction: true))
        }

        if typed.first?.isUppercase == true, position == .middle { return .keep(.capitalMidSentence) }
        guard let top = decoding.top else { return .keep(.noCandidate) }
        if top.kind == .literal || UserLexicon.fold(top.text) == folded { return .keep(.typedIsBest) }

        if knowledge.inModel {
            guard top.posterior >= thresholds.knownPosterior,
                editDistance(folded, UserLexicon.fold(top.text)) <= thresholds.knownMaxEdits
            else { return .keep(.belowThreshold) }
        } else {
            let runnerUp = decoding.candidates.dropFirst().first?.posterior ?? 0
            guard top.posterior >= thresholds.unknownPosterior,
                top.posterior >= thresholds.unknownRatio * runnerUp
            else { return .keep(.belowThreshold) }
        }
        // Autocorrect never turns a typo into a word the strip would not volunteer, however near;
        // only taps that spell it letter for letter (kind exact) can write one.
        if top.kind != .exact,
            top.text.lowercased().split(separator: " ").contains(where: { SuggestionEngine.neverVolunteered.contains(String($0)) })
        {
            return .keep(.neverVolunteered)
        }
        if rejections.isRejected(original: folded, replacement: top.text) { return .keep(.rejected) }
        return .replace(
            Replacement(
                text: cased(top.text, matching: typed, preservesCase: top.preservesCase), kind: top.kind,
                isContraction: false))
    }

    // MARK: - Rules

    /// Whether the field takes autocorrection at all. A web search field counts as ordinary text.
    public static func allows(_ field: FieldTraits) -> Bool {
        guard field.autocorrectionAllowed, field.spellCheckingAllowed, !field.isSecure else { return false }
        switch field.keyboardKind {
        case .default, .webSearch: return true
        case .url, .email, .number, .decimal, .phone: return false
        }
    }

    /// Letters and apostrophes only. A digit, `@`, `#`, `/`, a full stop inside the word or any
    /// other symbol marks something that is not prose (a handle, a path, a version number).
    static func isPlainWord(_ typed: String) -> Bool {
        !typed.isEmpty && typed.allSatisfy { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }
    }

    /// The contraction a word without its apostrophe stands for: `im` is `i'm`, `dont` is
    /// `don't`. Found by trying the apostrophe at each position against the model's contraction
    /// flag; the likeliest wins.
    public static func contraction(for folded: String, model: TypingModel) -> String? {
        let letters = Array(folded)
        guard letters.count >= 2, letters.allSatisfy(\.isLetter) else { return nil }
        var best: (word: String, unigram: Float)?
        for position in 1..<letters.count {
            let word = String(letters[..<position]) + "'" + String(letters[position...])
            guard let id = model.id(of: word), model.isContraction(id) else { continue }
            let unigram = model.unigram(id)
            if best == nil || unigram > best!.unigram { best = (word, unigram) }
        }
        return best?.word
    }

    /// Gives a replacement the case of the word it replaces: all capitals stay all capitals, a
    /// leading capital carries over, and a lone "i" is always "I". The owner's own spellings
    /// ("iPhone") are left as they are.
    static func cased(_ text: String, matching typed: String, preservesCase: Bool) -> String {
        if preservesCase { return text }
        let letters = typed.filter(\.isLetter)
        var result = text
        if letters.count > 1, letters == letters.uppercased() {
            result = text.uppercased()
        } else if typed.first?.isUppercase == true, let first = text.first {
            result = first.uppercased() + text.dropFirst()
        }
        return result.split(separator: " ", omittingEmptySubsequences: false).map { token in
            token == "i" || token.hasPrefix("i'") ? token.prefix(1).uppercased() + token.dropFirst() : String(token)
        }.joined(separator: " ")
    }

    /// The optimal string alignment distance (insertions, deletions, substitutions and swaps of
    /// neighbours each cost one).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[a.count][b.count]
    }
}
