import CoreGraphics
import Foundation

/// One tap of the word being typed: where the finger landed, in the keyboard view's coordinates
/// (the same space as `KeyboardMetrics` frames), and the key the touch engine resolved it to.
public struct WordTap: Hashable, Sendable {
    public let point: CGPoint
    public let key: KeyKind

    public init(point: CGPoint, key: KeyKind) {
        self.point = point
        self.key = key
    }
}

/// How a candidate relates to the taps. Everything except `.exact` and `.lexicon` cost an edit
/// penalty; `.split` is two words from one run of taps.
public enum CandidateKind: Hashable, Sendable {
    /// Every tap is one letter of the word.
    case exact
    /// The word has one letter the user did not tap.
    case omission
    /// One tap is not a letter of the word (a stray touch).
    case insertion
    /// Two neighbouring letters were tapped in the wrong order.
    case transposition
    /// The taps are two words typed without the space between them.
    case split
    /// A word from the user's lexicon that the word model lacks.
    case lexicon
    /// The string as typed, offered for a word the model does not know, so that a posterior
    /// accounts for the chance that the user typed exactly what they meant.
    case literal
}

/// A spatial noisy-channel decoder for one word of taps.
///
/// Each tap is modelled as a two-dimensional Gaussian around the centre of the key the user meant,
/// with a spread tied to the key's size. The decoder searches the word list for the words whose
/// letters the taps could plausibly have been aiming at, scores each as
///
///     score(w) = λ · ln P(w | previous) + Σ ln N(tap_i ; centre(key(w_i)), σx, σy) − edit penalty
///
/// where the Gaussian terms are measured against the best possible tap (so a perfect tap on a
/// centre costs nothing, and different candidate lengths stay comparable), and turns the scores
/// into posteriors with a softmax. The caller (the autocorrect policy) then decides whether the
/// best candidate is sure enough to replace what was typed.
///
/// The search walks the sorted word list as an implicit trie through `TypingModel.narrow`: a
/// state is a prefix and its id range, extended by the few letters near the next tap. A beam keeps
/// the best prefixes per tap. One edit may be spent anywhere in the word: a letter the user left
/// out, a stray tap, or two letters swapped. A missed space is tried separately by splitting the
/// taps in two and decoding each half.
public struct TapDecoder: Sendable {
    /// Every tunable of the decoder. `tuned` is what the keyboard runs; the replay benchmark found
    /// these values (see `AutocorrectReplayTests`). From the spec's starting values (σ 0.3 and
    /// 0.4, λ 1.0, penalties 2.0, 2.0 and 3.0) on 2026-11-25, errors reduced went 23.5% (σ as
    /// specified), 51.4% (σ matched to the replay's noise), 54.4% (λ 1.3), 59.3% (posterior 0.7,
    /// ratio 3) and 65.6% (omission and transposition 3.0, insertion 4.5), with under 0.25% of
    /// correct words changed throughout. The replay only generates substitution errors, so it
    /// always prefers larger edit penalties; the values stop where the unit tests' typos
    /// ("helo", "teh") are still corrected.
    public struct Configuration: Sendable, Equatable {
        /// σx as a fraction of a letter key's width. The spec starts at 0.3; the replay's taps are 1.3
        /// times noisier than that, and 0.39 is the decoder matched to them.
        public var sigmaXFactor = 0.39
        /// σy as a fraction of a key's height (spec 0.4, matched as above).
        public var sigmaYFactor = 0.52
        /// Weight of the language term, λ.
        public var languageWeight = 1.3
        /// The weight of the unigram when a pair is not stored (stupid backoff).
        public var backoffWeight = 0.4
        /// Prefixes kept per tap.
        public var beamWidth = 64
        /// Prefixes per tap that may spend the one edit. Edits fan out by up to 26 letters, so a
        /// narrower beam keeps a decode cheap.
        public var editBeamWidth = 16
        /// A letter is a candidate for a tap only inside this many σ (Mahalanobis distance).
        public var pruneSigmas = 2.5
        /// Nats subtracted for two swapped neighbours.
        public var transpositionPenalty = 3.0
        /// Nats subtracted for a letter the user left out.
        public var omissionPenalty = 3.0
        /// Nats subtracted for a stray tap.
        public var insertionPenalty = 4.5
        /// Nats subtracted for a missed space.
        public var splitPenalty = 4.0
        /// Nats subtracted for matching a contraction's apostrophe, which has no key on the
        /// letters page and so is always "omitted" by a user who types `dont`.
        public var apostrophePenalty = 0.3
        /// ln P of a lexicon word that is not in the model.
        public var lexiconLogPrior = -12.0
        /// ln P of the typed string when the model does not know it: `base + perLetter · length`.
        public var literalLogPriorBase = -4.0
        public var literalLogPriorPerLetter = -2.5
        /// Candidates returned, best first. Posteriors are normalised over all found.
        public var maxCandidates = 8
        /// Words with more taps than this are not decoded.
        public var maxTaps = 20
        /// A missed space is tried only for words of at least this many taps.
        public var minSplitTaps = 3
        /// Prefixes kept per half while splitting, and halves combined.
        public var splitBeamWidth = 12
        public var splitKeep = 6

        public init() {}

        /// The values the replay benchmark settled on.
        public static let tuned = Configuration()
    }

    /// One word (or two, for a split) the taps might have meant.
    public struct Candidate: Hashable, Sendable {
        /// Lowercase from the model, or the lexicon's own spelling when `preservesCase`. A split
        /// holds both words with a space between.
        public let text: String
        /// The model ids of the words; empty for a lexicon word or the literal string.
        public let ids: [Int]
        /// The log score in nats.
        public let score: Double
        /// The share of probability this candidate has among all the ones found, 0 to 1.
        public let posterior: Double
        public let kind: CandidateKind
        /// The text is the owner's spelling ("iPhone") and must not be re-cased to the typed word.
        public let preservesCase: Bool
    }

    /// The decoder's answer for one word.
    public struct Decoding: Sendable {
        /// The letters of the resolved keys, lowercase: what is on screen before any correction.
        public let typed: String
        /// The id of `typed` in the model, nil when the model does not know it.
        public let typedID: Int?
        /// The best candidates, best first, posteriors normalised over everything found.
        public let candidates: [Candidate]

        public var top: Candidate? { candidates.first }
    }

    public let model: TypingModel
    public let configuration: Configuration
    private let centres: [CGPoint]
    private let sigmaX: Double
    private let sigmaY: Double

    private static let ln10 = log(10.0)
    private static let apostrophe: UInt8 = 0x27
    private static let letterA: UInt8 = 97

    /// - Parameter frames: the key frames of the letters page, in the coordinates the taps use.
    ///   The key sizes give σ and the keycap centres are where each letter is aimed at.
    public init(model: TypingModel, frames: [KeyFrame], configuration: Configuration = .tuned) {
        self.model = model
        self.configuration = configuration
        var found: [CGPoint?] = Array(repeating: nil, count: 26)
        var width = 0.0
        var height = 0.0
        for frame in frames {
            guard let letter = frame.kind.characterValue, letter.utf8.count == 1,
                let byte = letter.utf8.first, byte >= Self.letterA, byte < Self.letterA + 26
            else { continue }
            found[Int(byte - Self.letterA)] = CGPoint(x: frame.keycap.midX, y: frame.keycap.midY)
            width = frame.keycap.width
            height = frame.keycap.height
        }
        if found.allSatisfy({ $0 != nil }) {
            centres = found.map { $0! }
        } else {
            centres = []
        }
        sigmaX = configuration.sigmaXFactor * width
        sigmaY = configuration.sigmaYFactor * height
    }

    // MARK: - Decoding

    /// Decodes one word.
    ///
    /// - Parameters:
    ///   - taps: the word's taps in order. Only letter keys can be decoded; a word with a digit or
    ///     an apostrophe tap is returned with no candidates, because the user typed what they meant.
    ///   - previous: the id of the word before this one, for the bigram. Nil at a sentence start
    ///     or after a word the model does not know, which scores by frequency alone.
    ///   - lexicon: the user's own words, which add candidates and bonuses.
    public func decode(taps: [WordTap], previous: Int?, lexicon: UserLexicon = .empty) -> Decoding {
        let typed = taps.map { $0.key.characterValue ?? "" }.joined().lowercased()
        let typedID = model.id(of: typed)
        let empty = Decoding(typed: typed, typedID: typedID, candidates: [])
        guard !centres.isEmpty, !taps.isEmpty, taps.count <= configuration.maxTaps else { return empty }
        var resolved: [Int] = []
        for tap in taps {
            guard let letter = tap.key.characterValue, letter.utf8.count == 1, let byte = letter.utf8.first,
                byte >= Self.letterA, byte < Self.letterA + 26
            else { return empty }
            resolved.append(Int(byte - Self.letterA))
        }

        let tables = makeTables(taps: taps, resolved: resolved)
        var found: [String: Candidate] = [:]
        func offer(
            _ text: String, ids: [Int], score: Double, kind: CandidateKind, preservesCase: Bool = false
        ) {
            let key = UserLexicon.fold(text)
            if let existing = found[key], existing.score >= score { return }
            found[key] = Candidate(
                text: text, ids: ids, score: score, posterior: 0, kind: kind, preservesCase: preservesCase)
        }

        // 1. Words of the model, with up to one edit.
        for terminal in search(tables, from: 0, to: taps.count, allowEdits: true, beam: configuration.beamWidth) {
            var score = terminal.score + configuration.languageWeight * logPrior(terminal.id, previous: previous)
            if let entry = lexicon.entry(for: terminal.word) {
                score += entry.bonus
                offer(entry.display, ids: [terminal.id], score: score, kind: terminal.kind, preservesCase: true)
            } else {
                offer(terminal.word, ids: [terminal.id], score: score, kind: terminal.kind)
            }
        }

        // 2. Words of the lexicon the model does not know.
        for (folded, entry) in lexicon.entries.sorted(by: { $0.key < $1.key }) {
            let bytes = Array(folded.utf8)
            guard abs(bytes.count - taps.count) <= 1, bytes.allSatisfy({ $0 >= Self.letterA && $0 < Self.letterA + 26 }),
                model.id(of: folded) == nil, let spatial = lexiconSpatial(bytes, tables: tables)
            else { continue }
            let score = spatial.score + configuration.languageWeight * configuration.lexiconLogPrior + entry.bonus
            offer(entry.display, ids: [], score: score, kind: .lexicon, preservesCase: true)
        }

        // 3. A missed space.
        if taps.count >= configuration.minSplitTaps {
            for split in splits(tables, count: taps.count, previous: previous) {
                offer(split.text, ids: split.ids, score: split.score, kind: .split)
            }
        }

        // 4. The typed string itself, when the model has no such word.
        if typedID == nil {
            let spatial = zip(resolved.indices, resolved).reduce(0.0) { $0 + tables.g[$1.0][$1.1] }
            let prior = configuration.literalLogPriorBase + configuration.literalLogPriorPerLetter * Double(taps.count)
            offer(typed, ids: [], score: spatial + configuration.languageWeight * prior, kind: .literal)
        }

        return Decoding(typed: typed, typedID: typedID, candidates: rank(Array(found.values)))
    }

    /// Orders by score (ties by text, so the answer never depends on dictionary order), turns the
    /// scores into posteriors over everything found and keeps the best few.
    private func rank(_ found: [Candidate]) -> [Candidate] {
        let sorted = found.sorted { $0.score != $1.score ? $0.score > $1.score : $0.text < $1.text }
        guard let best = sorted.first?.score else { return [] }
        let total = sorted.reduce(0.0) { $0 + exp($1.score - best) }
        return sorted.prefix(configuration.maxCandidates).map {
            Candidate(
                text: $0.text, ids: $0.ids, score: $0.score, posterior: exp($0.score - best) / total,
                kind: $0.kind, preservesCase: $0.preservesCase)
        }
    }

    // MARK: - Language

    /// ln P(word | previous), in nats: the stored bigram, or the unigram scaled by the backoff
    /// weight when the pair is not stored, or the plain unigram with no previous word.
    func logPrior(_ id: Int, previous: Int?) -> Double {
        if let previous {
            if let stored = model.pairLogP(previous, id) { return Double(stored) * Self.ln10 }
            return log(configuration.backoffWeight) + Double(model.unigram(id)) * Self.ln10
        }
        return Double(model.unigram(id)) * Self.ln10
    }

    /// Single letters other than "a" and "i" are in the list as the halves of split contractions
    /// ("don t") and are never a word the user meant.
    private func isWord(_ word: String) -> Bool {
        word.utf8.count >= 2 || word == "a" || word == "i"
    }

    // MARK: - Spatial tables

    /// The per-tap, per-letter spatial scores: `g[i][c]` is -z²/2 for the letter `c` (0 to 25) at
    /// tap `i`, or -infinity when the letter lies beyond the pruning distance. The key the touch
    /// engine resolved the tap to is always admissible: a tap near a corner of its hit rect can be
    /// farther than 2.5σ from the key's centre, and the typed word must stay a candidate.
    private struct Tables {
        var g: [[Double]]
        var admissible: [[(letter: Int, g: Double)]]
    }

    private func makeTables(taps: [WordTap], resolved: [Int]) -> Tables {
        var g: [[Double]] = []
        var admissible: [[(letter: Int, g: Double)]] = []
        let limit = configuration.pruneSigmas * configuration.pruneSigmas
        for (index, tap) in taps.enumerated() {
            var row = [Double](repeating: -.infinity, count: 26)
            var list: [(letter: Int, g: Double)] = []
            for letter in 0..<26 {
                let dx = (Double(tap.point.x) - Double(centres[letter].x)) / sigmaX
                let dy = (Double(tap.point.y) - Double(centres[letter].y)) / sigmaY
                let z2 = dx * dx + dy * dy
                if z2 <= limit || letter == resolved[index] {
                    row[letter] = -0.5 * z2
                    list.append((letter, -0.5 * z2))
                }
            }
            g.append(row)
            admissible.append(list)
        }
        return Tables(g: g, admissible: admissible)
    }

    // MARK: - Beam search

    private struct State {
        var bytes: [UInt8]
        var range: Range<Int>
        var score: Double
        /// Whether the one edit is spent.
        var edited: Bool
        var kind: CandidateKind
    }

    private struct StateKey: Hashable {
        let bytes: [UInt8]
        let edited: Bool
    }

    private struct Terminal {
        let id: Int
        let word: String
        let score: Double
        let kind: CandidateKind
    }

    /// The best words for taps `lo..<hi`, with their spatial scores and edit penalties but no
    /// language score. States are grouped by how many taps they have consumed (an omission
    /// consumes none), and each group is cut to the beam before it is expanded.
    private func search(
        _ tables: Tables, from lo: Int, to hi: Int, allowEdits: Bool, beam: Int
    ) -> [Terminal] {
        let count = hi - lo
        var layers = [[State]](repeating: [], count: count + 2)
        layers[0] = [
            State(bytes: [], range: 0..<model.wordCount, score: 0, edited: false, kind: .exact)
        ]
        var terminals: [Terminal] = []

        for index in 0...count {
            var current = prune(layers[index], beam: beam)
            layers[index] = []

            if allowEdits {
                // A letter the user left out: any letter, before tap `index`.
                var omitted: [State] = []
                for state in current.prefix(configuration.editBeamWidth) where !state.edited {
                    for letter in 0..<26 {
                        let byte = Self.letterA + UInt8(letter)
                        let child = model.narrow(state.range, depth: state.bytes.count, byte: byte)
                        guard !child.isEmpty else { continue }
                        emit(
                            State(
                                bytes: state.bytes + [byte], range: child,
                                score: state.score - configuration.omissionPenalty, edited: true,
                                kind: .omission),
                            into: &omitted)
                    }
                }
                current += prune(omitted, beam: beam)
            }

            if index == count {
                for state in current {
                    let word = String(decoding: state.bytes, as: UTF8.self)
                    guard isWord(word), let id = model.id(of: word) else { continue }
                    terminals.append(Terminal(id: id, word: word, score: state.score, kind: state.kind))
                }
                continue
            }

            let tap = lo + index
            for (position, state) in current.enumerated() {
                // The tap is a letter of the word.
                for option in tables.admissible[tap] {
                    let byte = Self.letterA + UInt8(option.letter)
                    let child = model.narrow(state.range, depth: state.bytes.count, byte: byte)
                    guard !child.isEmpty else { continue }
                    emit(
                        State(
                            bytes: state.bytes + [byte], range: child, score: state.score + option.g,
                            edited: state.edited, kind: state.kind),
                        into: &layers[index + 1])
                }
                guard allowEdits, !state.edited else { continue }
                // The tap is a stray touch and is skipped.
                layers[index + 1].append(
                    State(
                        bytes: state.bytes, range: state.range,
                        score: state.score - configuration.insertionPenalty, edited: true,
                        kind: .insertion))
                // The tap and the next one are in the wrong order.
                guard position < configuration.editBeamWidth, index + 1 < count else { continue }
                for later in tables.admissible[tap + 1] {
                    let first = Self.letterA + UInt8(later.letter)
                    let firstChild = model.narrow(state.range, depth: state.bytes.count, byte: first)
                    guard !firstChild.isEmpty else { continue }
                    for earlier in tables.admissible[tap] where earlier.letter != later.letter {
                        let second = Self.letterA + UInt8(earlier.letter)
                        let child = model.narrow(firstChild, depth: state.bytes.count + 1, byte: second)
                        guard !child.isEmpty else { continue }
                        emit(
                            State(
                                bytes: state.bytes + [first, second], range: child,
                                score: state.score + later.g + earlier.g - configuration.transpositionPenalty,
                                edited: true, kind: .transposition),
                            into: &layers[index + 2])
                    }
                }
            }
        }
        return terminals
    }

    /// Adds a state, and a second one that also matches the apostrophe of a contraction when the
    /// word list has words that continue with one ("don" has "don't"). The apostrophe has no key
    /// on the letters page, so a user types `dont` and the search supplies it.
    private func emit(_ state: State, into list: inout [State]) {
        list.append(state)
        guard !state.bytes.isEmpty, state.bytes.last != Self.apostrophe else { return }
        let child = model.narrow(state.range, depth: state.bytes.count, byte: Self.apostrophe)
        guard !child.isEmpty else { return }
        var next = state
        next.bytes.append(Self.apostrophe)
        next.range = child
        next.score -= configuration.apostrophePenalty
        list.append(next)
    }

    /// The best `beam` states, one per distinct (prefix, edit spent) pair, best first.
    private func prune(_ states: [State], beam: Int) -> [State] {
        guard states.count > 1 else { return states }
        let sorted = states.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.bytes.lexicographicallyPrecedes($1.bytes)
        }
        var seen = Set<StateKey>()
        var kept: [State] = []
        kept.reserveCapacity(min(beam, sorted.count))
        for state in sorted where seen.insert(StateKey(bytes: state.bytes, edited: state.edited)).inserted {
            kept.append(state)
            if kept.count == beam { break }
        }
        return kept
    }

    // MARK: - Lexicon words

    /// The spatial score of a lexicon word that is not in the model, with the same edits the
    /// search allows, or nil when the taps cannot have been aiming at it.
    private func lexiconSpatial(_ word: [UInt8], tables: Tables) -> (score: Double, kind: CandidateKind)? {
        let letters = word.map { Int($0 - Self.letterA) }
        let taps = tables.g.count
        var best: (score: Double, kind: CandidateKind)?
        func consider(_ score: Double, _ kind: CandidateKind) {
            guard score > -.infinity, score > (best?.score ?? -.infinity) else { return }
            best = (score, kind)
        }
        func sum(_ pairs: [(tap: Int, letter: Int)]) -> Double {
            pairs.reduce(0.0) { $0 + tables.g[$1.tap][$1.letter] }
        }
        if letters.count == taps {
            consider(sum(letters.indices.map { ($0, letters[$0]) }), .exact)
            for j in 0..<(taps - 1) where letters[j] != letters[j + 1] {
                var swapped = letters
                swapped.swapAt(j, j + 1)
                consider(
                    sum(swapped.indices.map { ($0, swapped[$0]) }) - configuration.transpositionPenalty,
                    .transposition)
            }
        } else if letters.count == taps + 1 {
            for j in letters.indices {
                var rest = letters
                rest.remove(at: j)
                consider(
                    sum(rest.indices.map { ($0, rest[$0]) }) - configuration.omissionPenalty, .omission)
            }
        } else if letters.count == taps - 1 {
            for j in 0..<taps {
                var pairs: [(tap: Int, letter: Int)] = []
                for tap in 0..<taps where tap != j {
                    pairs.append((tap, letters[tap < j ? tap : tap - 1]))
                }
                consider(sum(pairs) - configuration.insertionPenalty, .insertion)
            }
        }
        return best
    }

    // MARK: - Missed space

    /// Candidates that read the taps as two words with the space missing. Each half is decoded
    /// exactly (no edits) and cut to its likeliest few by spatial score plus frequency; the
    /// halves are then combined, the second scored after the first.
    private func splits(
        _ tables: Tables, count: Int, previous: Int?
    ) -> [(text: String, ids: [Int], score: Double)] {
        func halves(_ lo: Int, _ hi: Int) -> [Terminal] {
            let found = search(tables, from: lo, to: hi, allowEdits: false, beam: configuration.splitBeamWidth)
            let ranked = found.sorted {
                ($0.score + Double(model.unigram($0.id)) * Self.ln10)
                    > ($1.score + Double(model.unigram($1.id)) * Self.ln10)
            }
            return Array(ranked.prefix(configuration.splitKeep))
        }
        var result: [(text: String, ids: [Int], score: Double)] = []
        for cut in 1..<count {
            let left = halves(0, cut)
            guard !left.isEmpty else { continue }
            let right = halves(cut, count)
            for first in left {
                let head = configuration.languageWeight * logPrior(first.id, previous: previous)
                for second in right {
                    let tail = configuration.languageWeight * logPrior(second.id, previous: first.id)
                    result.append((
                        first.word + " " + second.word, [first.id, second.id],
                        first.score + second.score + head + tail - configuration.splitPenalty
                    ))
                }
            }
        }
        return result
    }
}
