import Foundation

/// Turns the text before the cursor into the three suggestions the strip shows. Pure: it reads
/// the model and the text and keeps nothing, so every answer can be checked on the Mac.
///
/// Mid-word the strip offers the word as typed and the two likeliest completions; after a space
/// it offers three predictions for the next word. Both rank words by a linear blend of the
/// word's probability after the previous word and its probability anywhere, so a rare word that
/// happens to follow the previous one cannot outrank a common one that fits nearly as well, and a
/// word with no stored pair after the previous one still ranks by frequency.
///
/// That pair model knows one word of context. When the keyboard's language model has answered
/// for the same word boundary (`WordPrediction`, from `NextWordPredictor`), its words come first
/// in both places and the pair model fills what it leaves; the rules below (what is never
/// offered, what is not repeated, how a word is cased) hold for both.
public enum SuggestionEngine {
    /// The share of a word's score that comes from the previous word (P(word | previous)); the
    /// rest comes from its plain frequency.
    public static let bigramWeight = 0.7
    /// How many of a prefix's most frequent words are ranked, besides the words the previous
    /// word is known to precede. A fixed pool keeps a one-letter prefix (thousands of words) cheap.
    public static let candidatePool = 40
    /// The share of its score a contraction keeps while the user has not yet typed its whole stem
    /// (the part before the apostrophe). The builder counts a contraction like its expanded pair
    /// ("don't" like "do not"), which puts it level with "the"; unscaled, "th" would offer "that's"
    /// ahead of "that", and a sentence would be full of "isn't" predictions. Once the stem is
    /// typed ("don"), the contraction competes at full strength.
    public static let contractionDiscount = 0.1
    /// What the strip offers at the start of a sentence, when there is no previous word to
    /// predict from and no language model answer. The pair model has no sentence-start
    /// statistics, so these are the stock keyboard's usual openers.
    static let sentenceStarters = ["I", "The", "I'm"]
    /// Words the strip never offers as the next word by itself. The pair counts come from web
    /// pages, where adult and spam pages are loud: after "dog" the likeliest next word was
    /// "sex", and tapping the centre cell from there gave "video porno gratis" in a loop (the
    /// owner's screenshot, 2026-11-25). The words stay in the model: they still complete when
    /// typed, autocorrect leaves them alone and a swipe reads them. They are only never
    /// volunteered.
    static let neverVolunteered: Set<String> = [
        "sex", "sexy", "sexual", "porn", "porno", "xxx", "nude", "naked", "erotic", "adult", "escort",
        "fuck", "fucking", "shit", "bitch", "pussy", "dick", "cock", "cum", "anal", "tits", "boobs",
        "milf", "hentai", "slut", "sluts", "whore", "rape", "incest", "bdsm", "fetish", "orgy",
        "blowjob", "gay", "lesbian", "teen", "teens", "viagra", "cialis", "casino", "poker", "gratis",
    ]
    /// How far back a repeat is looked for, in words. A prediction that would repeat a pair of
    /// words already in that stretch ("same time" after "the same time to the") is dropped, which
    /// is what breaks a loop, and a word already in it keeps `repeatDiscount` of its score.
    static let repeatWindow = 12
    public static let repeatDiscount = 0.05
    /// Words that repeat in ordinary writing and are not discounted for it.
    static let repeatsFreely: Set<String> = [
        "the", "a", "an", "to", "of", "and", "in", "is", "it", "i", "you", "that", "for", "on",
        "with", "as", "at", "be", "this", "are", "was", "or", "by", "not", "have", "he", "we", "but",
        "they", "from",
    ]

    /// The suggestions for the text before the cursor, in strip order: left, centre, right.
    ///
    /// - Mid-word: `[typed, best, second]`, shortened when fewer completions exist (the typed
    ///   word is always on the left, the likeliest completion in the centre). A word the model
    ///   does not know still gets its typed entry.
    /// - After a space, or in an empty field: exactly three predictions, `[second, best, third]`,
    ///   so the likeliest sits in the centre as on the stock keyboard. Sentence starts take the
    ///   capitalised form.
    /// - Directly after punctuation or a digit with no space (`"wait."`, `"3"`): none, because
    ///   neither a completion nor a prediction applies there.
    ///
    /// `prediction` is the language model's answer for this text's word boundary, when there is
    /// one (`boundary(before:)` names the text it must have been made for; any other is
    /// ignored). With it the next words are the model's likeliest, a sentence start is predicted
    /// from what came before instead of the fixed openers, and completions are ranked by the
    /// model first, with the pair model's filling the slots it leaves. Without it the answer is
    /// the pair model's alone. `capitalisesStarts` gives the model's sentence-start predictions
    /// a capital, which the keyboard turns off with auto-capitalisation.
    public static func suggestions(
        before text: String, model: TypingModel, prediction: WordPrediction? = nil, capitalisesStarts: Bool = true
    ) -> [Suggestion] {
        suggestions(
            before: text, model: model, prediction: prediction, capitalisesStarts: capitalisesStarts,
            completionLimit: 2)
    }

    /// The same, with room for more completions than the strip shows. The evaluation of the
    /// language model (`TypingLMEvalTests`) asks for three, to compare like with like.
    static func suggestions(
        before text: String, model: TypingModel, prediction: WordPrediction? = nil, capitalisesStarts: Bool = true,
        completionLimit: Int
    ) -> [Suggestion] {
        let context = Context(text)
        guard context.isWordBoundary else { return [] }
        // A prediction counts only for the word boundary it was made at.
        let prediction = prediction.flatMap { $0.boundary == text.dropLast(context.partial.count) ? $0 : nil }
        if context.partial.isEmpty {
            return predictNext(
                context, model, recent: recentWords(before: text), prediction: prediction,
                capitalisesStarts: capitalisesStarts)
        }
        return complete(context, model, limit: completionLimit, prediction: prediction)
    }

    /// How many characters at the end of `text` are the word being typed: 0 after a space. Nil
    /// where the strip offers nothing (directly after punctuation or a digit). It reads only the
    /// end of the text, so it is cheap on a long one.
    public static func typedLength(before text: String) -> Int? {
        let context = Context(text)
        return context.isWordBoundary ? context.partial.count : nil
    }

    /// The text up to the start of the word being typed, which is what the language model
    /// predicts from: all of `text` after a space, and `text` less the typed letters mid-word.
    /// Nil where `typedLength` is.
    public static func boundary(before text: String) -> String? {
        typedLength(before: text).map { String(text.dropLast($0)) }
    }

    /// The edit a tap on `suggestion` makes to `text`: the typed word is replaced by the
    /// suggestion plus a trailing space. A `.typed` entry only adds the space.
    public static func edit(applying suggestion: Suggestion, before text: String) -> SuggestionEdit {
        if suggestion.kind == .typed {
            return SuggestionEdit(deleteCount: 0, insert: " ")
        }
        return SuggestionEdit(
            deleteCount: Context(text).partial.count, insert: suggestion.text + " ")
    }

    /// The word before the one that starts right after `textBeforeWord`, folded to the model's
    /// form, by the rule the strip's context uses: only a word with whitespace between it and the
    /// cursor counts, and nothing follows a sentence end or other punctuation. Autocorrect and the
    /// next-letter bias read it as the bigram's previous word.
    public static func previousWord(beforeWordAt textBeforeWord: String) -> String? {
        Context(textBeforeWord).previous
    }

    /// The strip's cells with a correction in the centre. Mid-word the strip is `[typed, best
    /// completion, second completion]`; with a correction it is `[typed, correction, best
    /// completion]`, so the stock layout holds (the typed word in quotes on the left, the fix in
    /// the emphasised centre) and one completion stays on the right. A completion that is the
    /// correction itself is dropped, so the same word is never offered twice. A strip that does
    /// not start with the typed word (after a space, in an empty field) is returned unchanged.
    public static func merging(correction: String, into suggestions: [Suggestion]) -> [Suggestion] {
        guard let typed = suggestions.first, typed.kind == .typed else { return suggestions }
        let fix = Suggestion(text: correction, kind: .correction)
        let completions = suggestions.dropFirst().filter {
            $0.text.lowercased() != correction.lowercased()
        }
        return [typed, fix] + completions.prefix(1)
    }

    // MARK: - Ranking

    private static func complete(
        _ context: Context, _ model: TypingModel, limit: Int, prediction: WordPrediction?
    ) -> [Suggestion] {
        let typed = Suggestion(text: context.partial, kind: .typed)
        let folded = fold(context.partial)
        let range = model.range(ofPrefix: folded)
        guard !range.isEmpty else { return [typed] }

        let previousID = context.previous.flatMap { model.id(of: $0) }
        var candidates = Set(model.completions(prefix: folded, limit: candidatePool))
        if let previousID {
            for successor in model.successors(of: previousID) where range.contains(successor.id) {
                candidates.insert(successor.id)
            }
        }
        let exact = model.id(of: folded)
        var ranked: [Int] = []
        // The language model's words with this prefix come first, likeliest first, under the
        // same rules as the pair model's: never the typed word itself, and a contraction held
        // back until its stem is typed.
        if let prediction {
            let scored = prediction.candidates(in: range).map { entry -> (id: Int, score: Double) in
                var score = Double(entry.probability)
                if model.isContraction(entry.id),
                    folded.count < model.word(entry.id).prefix(while: { $0 != "'" }).count
                {
                    score *= contractionDiscount
                }
                return (entry.id, score)
            }
            for entry in scored.sorted(by: { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }) {
                guard ranked.count < limit else { break }
                if entry.id != exact, isSuggestible(model.word(entry.id)) { ranked.append(entry.id) }
            }
        }
        if ranked.count < limit {
            let rest = rank(
                candidates.filter { $0 != exact && !ranked.contains($0) }, previous: previousID,
                typedLength: folded.count, model: model)
            ranked += rest.prefix(limit - ranked.count)
        }
        let completions = ranked.map {
            Suggestion(text: matchCase(model.word($0), to: context.partial), kind: .completion)
        }
        return [typed] + completions
    }

    private static func predictNext(
        _ context: Context, _ model: TypingModel, recent: [String], prediction: WordPrediction?,
        capitalisesStarts: Bool
    ) -> [Suggestion] {
        if context.isSentenceStart, prediction == nil {
            return strip(sentenceStarters.map { Suggestion(text: $0, kind: .next) })
        }
        let previousID = context.previous.flatMap { model.id(of: $0) }
        // The pairs of neighbouring words just written, so the same pair is not offered again.
        var writtenPairs: Set<[String]> = []
        for index in recent.indices.dropLast() { writtenPairs.insert([recent[index], recent[index + 1]]) }
        let repeated = Set(recent).subtracting(repeatsFreely)
        func offered(_ id: Int) -> Bool {
            let word = model.word(id)
            guard isSuggestible(word), !neverVolunteered.contains(word) else { return false }
            if let previous = context.previous, writtenPairs.contains([previous, word]) { return false }
            return true
        }
        let discounted = Set(repeated.compactMap { model.id(of: $0) })
        var ids: [Int] = []
        // The language model's likeliest words, under the rules every prediction keeps: nothing
        // from the never-volunteered list, no pair of words written again, and a word already
        // used held back.
        if let prediction {
            let scored = prediction.best.compactMap { entry -> (id: Int, score: Double)? in
                guard entry.id != previousID, offered(entry.id) else { return nil }
                return (entry.id, Double(entry.probability) * (discounted.contains(entry.id) ? repeatDiscount : 1))
            }
            ids = scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }.prefix(3).map(\.id)
        }
        if ids.count < 3, let previousID {
            let successors = model.successors(of: previousID).map(\.id).filter {
                // The n-gram data holds "the the" and the like, which are never worth predicting.
                $0 != previousID && !ids.contains($0) && offered($0)
            }
            ids += rank(
                Set(successors), previous: previousID, typedLength: 0, model: model,
                discounted: discounted
            ).prefix(3 - ids.count)
        }
        // A previous word with fewer than three stored successors (or none known) falls back
        // to the most frequent words, so the strip is never short.
        if ids.count < 3 {
            let common = Set(model.completions(prefix: "", limit: candidatePool))
                .subtracting(ids).filter(offered)
            ids += rank(common, previous: nil, typedLength: 0, model: model, discounted: discounted)
                .prefix(3 - ids.count)
        }
        return strip(ids.map {
            let word = matchCase(model.word($0), to: "")
            return Suggestion(
                text: context.isSentenceStart && capitalisesStarts ? capitalised(word) : word, kind: .next)
        })
    }

    /// The last `repeatWindow` words of the sentence being written, folded to the model's form,
    /// oldest first. A sentence end or a line break starts over.
    static func recentWords(before text: String) -> [String] {
        var words: [String] = []
        var word = ""
        for character in text.reversed() {
            if isWordCharacter(character) {
                word.append(character)
                continue
            }
            if !word.isEmpty {
                words.append(fold(String(word.reversed())))
                word = ""
                if words.count == repeatWindow { break }
            }
            if character.isNewline || ".!?".contains(character) { break }
        }
        if !word.isEmpty, words.count < repeatWindow { words.append(fold(String(word.reversed()))) }
        return words.reversed()
    }

    /// Orders candidate ids by blended score, best first; ties go to the lower id so the answer
    /// never depends on set order.
    private static func rank(
        _ ids: Set<Int>, previous: Int?, typedLength: Int, model: TypingModel,
        discounted: Set<Int> = []
    ) -> [Int] {
        let scored: [(id: Int, score: Double)] = ids.compactMap { id in
            let word = model.word(id)
            guard isSuggestible(word) else { return nil }
            let frequency = pow(10, Double(model.unigram(id)))
            var score = (1 - bigramWeight) * frequency
            if let previous, let logP = model.pairLogP(previous, id) {
                score += bigramWeight * pow(10, Double(logP))
            }
            if model.isContraction(id), typedLength < word.prefix(while: { $0 != "'" }).count {
                score *= contractionDiscount
            }
            if discounted.contains(id) { score *= repeatDiscount }
            return (id, score)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }.map(\.id)
    }

    /// Single letters other than "a" and "i" are in the word list (the halves of split
    /// contractions: "don t") but are never worth a suggestion slot.
    private static func isSuggestible(_ word: String) -> Bool {
        word.count >= 2 || word == "a" || word == "i"
    }

    /// Puts predictions in slot order: the likeliest in the centre, the runner-up on the left.
    private static func strip(_ ranked: [Suggestion]) -> [Suggestion] {
        guard ranked.count >= 2 else { return ranked }
        var slots = [ranked[1], ranked[0]]
        if ranked.count >= 3 { slots.append(ranked[2]) }
        return slots
    }

    // MARK: - Text

    /// Lowercase and straight apostrophes: the form the model stores.
    private static func fold(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    /// Gives a model word the case of what was typed: all capitals stay all capitals, a leading
    /// capital carries over, and "I" and its contractions are always capital.
    private static func matchCase(_ word: String, to typed: String) -> String {
        var result = word
        let letters = typed.filter(\.isLetter)
        if letters.count > 1, letters == letters.uppercased() {
            result = word.uppercased()
        } else if typed.first?.isUppercase == true {
            result = capitalised(word)
        }
        if result == "i" || result.hasPrefix("i'") { result = capitalised(result) }
        return result
    }

    private static func capitalised(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character == "'" || character == "’"
    }

    /// What the text before the cursor says about the word being typed.
    private struct Context {
        /// The word being typed, verbatim; empty after a space.
        var partial = ""
        /// The word before it, folded to the model's form, when one sits right before.
        var previous: String?
        /// Whether a sentence ends right before the word: the start of the text, a line break,
        /// or `. ! ?`.
        var isSentenceStart = false
        /// False when the cursor follows punctuation or a digit with no space, where no
        /// suggestion applies.
        var isWordBoundary = true

        init(_ text: String) {
            var head = Substring(text)
            // The word being typed: letters and apostrophes, minus apostrophes opening it (a
            // single quote in front of the word is not part of it).
            var start = head.endIndex
            while start > head.startIndex {
                let before = head.index(before: start)
                guard isWordCharacter(head[before]) else { break }
                start = before
            }
            while start < head.endIndex, head[start] == "'" || head[start] == "’" {
                start = head.index(after: start)
            }
            partial = String(head[start...])
            head = head[..<start]

            // Whitespace between the previous word and the cursor; a line break anywhere in it
            // starts a sentence.
            var sawBreak = false
            var gap = head.endIndex
            while gap > head.startIndex, head[head.index(before: gap)].isWhitespace {
                gap = head.index(before: gap)
                if head[gap].isNewline { sawBreak = true }
            }
            let hadGap = gap != head.endIndex
            head = head[..<gap]

            guard let last = head.last else {
                isSentenceStart = true
                return
            }
            if sawBreak {
                isSentenceStart = true
                return
            }
            if ".!?".contains(last) {
                // A sentence ended before the gap. Directly against the cursor ("wait.") there
                // is nothing to predict; directly against a typed word ("end.th") there is no
                // previous word either.
                if hadGap { isSentenceStart = true } else if partial.isEmpty { isWordBoundary = false }
                return
            }
            if isWordCharacter(last) {
                // With a gap this is the previous word. Without one it is an opening quote
                // mark (the partial is otherwise maximal), which has nothing to predict.
                guard hadGap else {
                    if partial.isEmpty { isWordBoundary = false }
                    return
                }
                var wordStart = head.endIndex
                while wordStart > head.startIndex, isWordCharacter(head[head.index(before: wordStart)]) {
                    wordStart = head.index(before: wordStart)
                }
                while wordStart < head.endIndex, head[wordStart] == "'" || head[wordStart] == "’" {
                    wordStart = head.index(after: wordStart)
                }
                previous = SuggestionEngine.fold(String(head[wordStart...]))
                return
            }
            // Other punctuation or a digit: no previous word. With no partial and no space the
            // cursor sits directly against it.
            if partial.isEmpty, !hadGap { isWordBoundary = false }
        }
    }
}
