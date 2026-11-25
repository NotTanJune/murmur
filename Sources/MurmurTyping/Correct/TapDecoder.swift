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
    /// One tap landed on a key next to the one meant, far enough off that the spatial model alone
    /// would not have considered the letter.
    case substitution
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
/// the best prefixes per tap. One edit may be spent anywhere in the word, two in a word of five or
/// more taps (the second costs extra): a letter the user left out, a stray tap, two letters
/// swapped, or a tap read as a key next to the one it landed on. A missed space is tried
/// separately by splitting the taps in two and decoding each half, which may spend one edit
/// between them.
public struct TapDecoder: Sendable {
    /// Every tunable of the decoder. `tuned` is what the keyboard runs; the replay benchmark found
    /// these values (see `AutocorrectReplayTests`). From the spec's starting values (σ 0.3 and
    /// 0.4, λ 1.0, penalties 2.0, 2.0 and 3.0) on 2026-11-25, errors reduced went 23.5% (σ as
    /// specified), 51.4% (σ matched to the replay's noise), 54.4% (λ 1.3), 59.3% (posterior 0.7,
    /// ratio 3) and 65.6% (omission and transposition 3.0, insertion 4.5), with under 0.25% of
    /// correct words changed throughout. The replay only generates substitution errors, so it
    /// always prefers larger edit penalties; the values stop where the unit tests' typos
    /// ("helo", "teh") are still corrected.
    ///
    /// A second pass on 2026-11-25 used the owner's recorded taps (`RealTapReplayTests`). Counted
    /// there, 483 intended letters held 42 letters left out (8.7%), 10 taps on a neighbouring key,
    /// 1 swap and 1 stray tap, and every tap sat inside its key (spread about 8 and 9 pt, nearly
    /// uniform). So letters left out cost 2.5 nats (the old 3.0 was tuned on noise that has none),
    /// a stray tap 6.0, a swap 3.5 and a neighbour hit 5.0, a second edit costs 1.5 more, and σy
    /// is 0.4 as in the spec. The unknown string's prior fell, because a string that is no word is
    /// seldom what was meant. Together: the synthetic replay 65.6% to 75%, the real log 20 to 31
    /// of 47 wrong words fixed, no correct word changed in either.
    public struct Configuration: Sendable, Equatable {
        /// σx as a fraction of a letter key's width. The spec starts at 0.3; the replay's taps are 1.3
        /// times noisier than that, and 0.39 is the decoder matched to them.
        public var sigmaXFactor = 0.39
        /// σy as a fraction of a key's height (spec 0.4). The first pass matched it to the replay's
        /// noise, 0.52; the owner's real taps spread far less than that, and 0.4 keeps the
        /// synthetic gate comfortably above its bar.
        public var sigmaYFactor = 0.4
        /// Weight of the language term, λ.
        public var languageWeight = 1.3
        /// The weight of the unigram when a pair is not stored (stupid backoff).
        public var backoffWeight = 0.4
        /// Prefixes kept per tap.
        public var beamWidth = 64
        /// Prefixes kept per tap by the two-edit search, which runs only for a word the cheap
        /// readings leave open and fills its beam with states of every edit count.
        public var secondStageBeamWidth = 32
        /// Prefixes per tap that may spend an edit. Edits fan out by up to 26 letters, so a
        /// narrower beam keeps a decode cheap.
        public var editBeamWidth = 8
        /// The same for the halves of a missed space.
        public var splitEditBeamWidth = 8
        /// A half of a missed space may spend the one edit only when it has at least this many taps.
        public var splitEditMinTaps = 3
        /// How many cuts get that search, the ones whose other half is the strongest word.
        public var splitEditCuts = 3
        /// A single fix whose posterior reaches this settles the word: the two-edit search is skipped.
        /// It sits at the policy's own bar (`AutocorrectPolicy.Thresholds.unknownPosterior`), because a
        /// second look at a word that already passes it can only dilute the answer.
        public var settledPosterior = 0.6
        /// A letter is a candidate for a tap only inside this many σ (Mahalanobis distance).
        public var pruneSigmas = 2.5
        /// Nats subtracted for two swapped neighbours.
        public var transpositionPenalty = 3.5
        /// Nats subtracted for a letter the user left out.
        public var omissionPenalty = 2.5
        /// Nats subtracted for a stray tap.
        public var insertionPenalty = 6.0
        /// Nats subtracted for a tap read as a key next to the one it landed on. The letter is
        /// reached whatever the Gaussian says, so a tap on the centre of `n` can still be a `b`.
        public var substitutionPenalty = 5.0
        /// The share of the Gaussian's own score that a neighbour substitution keeps, so that of
        /// two neighbours the nearer one is likelier.
        public var substitutionSpread = 0.5
        /// A second edit in one word costs this much more than the first.
        public var secondEditPenalty = 1.5
        /// A word with at least this many taps may spend two edits.
        public var twoEditMinTaps = 4
        /// Nats subtracted for a missed space.
        public var splitPenalty = 4.0
        /// Nats subtracted for matching a contraction's apostrophe, which has no key on the
        /// letters page and so is always "omitted" by a user who types `dont`.
        public var apostrophePenalty = 0.3
        /// ln P of a lexicon word that is not in the model.
        public var lexiconLogPrior = -12.0
        /// ln P of the typed string when the model does not know it:
        /// `base + perLetter · max(length, shortLetters)`. A string that is no word is seldom what
        /// was meant, least of all a short one (a real two or three letter word is in the model, so
        /// "dg" is a slip), where a long one may be a name or a term. Counting every short string
        /// as `shortLetters` long keeps it from being likelier than a real word one edit away.
        public var literalLogPriorBase = -4.0
        public var literalLogPriorPerLetter = -2.5
        public var literalShortLetters = 6
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
    /// For each letter, the letters on the keys around it (the row's two neighbours and the
    /// keys above and below that touch it): where a stray finger is likeliest to have landed.
    private let neighbours: [[Int]]
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
        neighbours = Self.neighbours(of: centres)
        sigmaX = configuration.sigmaXFactor * width
        sigmaY = configuration.sigmaYFactor * height
    }

    /// The keys within about one key pitch of each key, across and down. The pitch is read off the
    /// layout (q to w across, q to a down), so a layout with other gaps follows.
    private static func neighbours(of centres: [CGPoint]) -> [[Int]] {
        guard centres.count == 26 else { return [] }
        let q = centres[16], w = centres[22], a = centres[0]
        let pitchX = abs(Double(w.x - q.x))
        let pitchY = abs(Double(a.y - q.y))
        guard pitchX > 0, pitchY > 0 else { return [] }
        return (0..<26).map { letter in
            (0..<26).filter { other in
                other != letter
                    && abs(Double(centres[other].x - centres[letter].x)) <= 1.15 * pitchX
                    && abs(Double(centres[other].y - centres[letter].y)) <= 1.15 * pitchY
            }
        }
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

        func offerWords(_ terminals: [Terminal]) {
            for terminal in terminals {
                var score = terminal.score + configuration.languageWeight * logPrior(terminal.id, previous: previous)
                if let entry = lexicon.entry(for: terminal.word) {
                    score += entry.bonus
                    if entry.respellsKnownWords {
                        offer(entry.display, ids: [terminal.id], score: score, kind: terminal.kind, preservesCase: true)
                    } else {
                        offer(terminal.word, ids: [terminal.id], score: score, kind: terminal.kind)
                    }
                } else {
                    offer(terminal.word, ids: [terminal.id], score: score, kind: terminal.kind)
                }
            }
        }

        // 1. Words of the model, with up to one edit.
        offerWords(
            search(
                tables, from: 0, to: taps.count, maxEdits: 1, beam: configuration.beamWidth,
                editBeam: configuration.editBeamWidth))

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
        var anchors: [SplitAnchor] = []
        if taps.count >= configuration.minSplitTaps {
            let exact = splits(tables, count: taps.count, previous: previous)
            anchors = exact.anchors
            for split in exact.found { offer(split.text, ids: split.ids, score: split.score, kind: .split) }
        }

        // 4. The typed string itself, when the model has no such word.
        if typedID == nil {
            let spatial = zip(resolved.indices, resolved).reduce(0.0) { $0 + tables.g[$1.0][$1.1] }
            offer(typed, ids: [], score: spatial + configuration.languageWeight * literalLogPrior(taps.count), kind: .literal)
        }

        // 5. Two edits, or one edit beside a missed space. The policy changes a word that is already
        // in the model by one edit at most, so this is only for a string the model does not know, and
        // only when the cheap readings above leave it open: a clear single fix needs no second look.
        if typedID == nil {
            let first = rank(Array(found.values))
            let settled = first.first.map { $0.kind != .literal && $0.posterior >= configuration.settledPosterior } ?? false
            if !settled {
                if taps.count >= configuration.twoEditMinTaps {
                    offerWords(
                        search(
                            tables, from: 0, to: taps.count, maxEdits: 2, beam: configuration.secondStageBeamWidth,
                            editBeam: configuration.editBeamWidth))
                }
                for split in editedSplits(anchors, tables: tables, count: taps.count, previous: previous) {
                    offer(split.text, ids: split.ids, score: split.score, kind: .split)
                }
            }
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

    /// ln P of a typed string the model does not know (see `Configuration.literalLogPriorBase`).
    func literalLogPrior(_ length: Int) -> Double {
        configuration.literalLogPriorBase
            + configuration.literalLogPriorPerLetter * Double(max(length, configuration.literalShortLetters))
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
    /// `substitutes[i]` lists the neighbours of the resolved key that the Gaussian pruned, each with
    /// the score of reading the tap as that letter (a flat penalty plus a share of its -z²/2).
    private struct Tables {
        var g: [[Double]]
        var admissible: [[(letter: Int, g: Double)]]
        var substitutes: [[(letter: Int, g: Double)]]
    }

    private func makeTables(taps: [WordTap], resolved: [Int]) -> Tables {
        var g: [[Double]] = []
        var admissible: [[(letter: Int, g: Double)]] = []
        var substitutes: [[(letter: Int, g: Double)]] = []
        let limit = configuration.pruneSigmas * configuration.pruneSigmas
        for (index, tap) in taps.enumerated() {
            var row = [Double](repeating: -.infinity, count: 26)
            var list: [(letter: Int, g: Double)] = []
            var raw = [Double](repeating: -.infinity, count: 26)
            for letter in 0..<26 {
                let dx = (Double(tap.point.x) - Double(centres[letter].x)) / sigmaX
                let dy = (Double(tap.point.y) - Double(centres[letter].y)) / sigmaY
                let z2 = dx * dx + dy * dy
                raw[letter] = -0.5 * z2
                if z2 <= limit || letter == resolved[index] {
                    row[letter] = -0.5 * z2
                    list.append((letter, -0.5 * z2))
                }
            }
            var swaps: [(letter: Int, g: Double)] = []
            if !neighbours.isEmpty {
                for letter in neighbours[resolved[index]] where row[letter] == -.infinity {
                    swaps.append(
                        (letter, -configuration.substitutionPenalty + configuration.substitutionSpread * raw[letter]))
                }
            }
            g.append(row)
            admissible.append(list)
            substitutes.append(swaps)
        }
        return Tables(g: g, admissible: admissible, substitutes: substitutes)
    }

    // MARK: - Beam search

    private struct State {
        var bytes: [UInt8]
        var range: Range<Int>
        var score: Double
        /// How many of the word's edits are spent.
        var edits: Int
        var kind: CandidateKind
    }

    private struct StateKey: Hashable {
        let bytes: [UInt8]
        let edits: Int
    }

    private struct Terminal {
        let id: Int
        let word: String
        let score: Double
        let edits: Int
        let kind: CandidateKind
    }

    /// An edit costs its own penalty, and the second one in a word costs more.
    private func cost(_ penalty: Double, spent: Int) -> Double {
        penalty + (spent >= 1 ? configuration.secondEditPenalty : 0)
    }

    /// The best words for taps `lo..<hi`, with their spatial scores and edit penalties but no
    /// language score. States are grouped by how many taps they have consumed (an omission
    /// consumes none), and each group is cut to the beam before it is expanded.
    private func search(
        _ tables: Tables, from lo: Int, to hi: Int, maxEdits: Int, beam: Int, editBeam: Int
    ) -> [Terminal] {
        let count = hi - lo
        var layers = [[State]](repeating: [], count: count + 2)
        layers[0] = [
            State(bytes: [], range: 0..<model.wordCount, score: 0, edits: 0, kind: .exact)
        ]
        var terminals: [Terminal] = []

        for index in 0...count {
            var current = prune(layers[index], beam: beam)
            layers[index] = []

            // A letter the user left out: any letter, before tap `index`. A state that has spent
            // one edit may spend another, so the rounds chain. The letter must be followed by one
            // this tap could be (or, with an edit left, a neighbour of its key), or the state is
            // dead; checking that here keeps 26 children per state from filling the beam. Two
            // omissions in a row therefore only happen with a tap between them.
            for round in 0..<maxEdits {
                var omitted: [State] = []
                for state in current.filter({ $0.edits == round }).prefix(editBeam) {
                    for (byte, child) in model.children(of: state.range, depth: state.bytes.count)
                    where byte >= Self.letterA && byte < Self.letterA + 26 {
                        if index < count {
                            let next = tables.admissible[lo + index].contains {
                                !model.narrow(child, depth: state.bytes.count + 1, byte: Self.letterA + UInt8($0.letter))
                                    .isEmpty
                            }
                            let beside =
                                round + 1 < maxEdits
                                && tables.substitutes[lo + index].contains {
                                    !model.narrow(child, depth: state.bytes.count + 1, byte: Self.letterA + UInt8($0.letter))
                                        .isEmpty
                                }
                            if !next && !beside { continue }
                        }
                        emit(
                            State(
                                bytes: state.bytes + [byte], range: child,
                                score: state.score - cost(configuration.omissionPenalty, spent: round),
                                edits: round + 1, kind: .omission),
                            into: &omitted)
                    }
                }
                current += prune(omitted, beam: beam)
            }

            if index == count {
                for state in current {
                    let word = String(decoding: state.bytes, as: UTF8.self)
                    guard isWord(word), let id = model.id(of: word) else { continue }
                    terminals.append(
                        Terminal(id: id, word: word, score: state.score, edits: state.edits, kind: state.kind))
                }
                continue
            }

            let tap = lo + index
            // How many states of each edit count have been expanded. A state with one edit already
            // spent got there by an omission among dozens of ties, so its budget is wider.
            var expanded = [Int](repeating: 0, count: maxEdits + 1)
            for state in current {
                // The tap is a letter of the word.
                for option in tables.admissible[tap] {
                    let byte = Self.letterA + UInt8(option.letter)
                    let child = model.narrow(state.range, depth: state.bytes.count, byte: byte)
                    guard !child.isEmpty else { continue }
                    emit(
                        State(
                            bytes: state.bytes + [byte], range: child, score: state.score + option.g,
                            edits: state.edits, kind: state.kind),
                        into: &layers[index + 1])
                }
                guard state.edits < maxEdits else { continue }
                // The tap is a stray touch and is skipped.
                layers[index + 1].append(
                    State(
                        bytes: state.bytes, range: state.range,
                        score: state.score - cost(configuration.insertionPenalty, spent: state.edits),
                        edits: state.edits + 1, kind: .insertion))
                expanded[state.edits] += 1
                guard expanded[state.edits] <= (state.edits == 0 ? editBeam : 2 * editBeam) else { continue }
                // The tap landed beside the key that was meant.
                let extra = state.edits >= 1 ? configuration.secondEditPenalty : 0
                for option in tables.substitutes[tap] {
                    let byte = Self.letterA + UInt8(option.letter)
                    let child = model.narrow(state.range, depth: state.bytes.count, byte: byte)
                    guard !child.isEmpty else { continue }
                    emit(
                        State(
                            bytes: state.bytes + [byte], range: child, score: state.score + option.g - extra,
                            edits: state.edits + 1, kind: .substitution),
                        into: &layers[index + 1])
                }
                // The tap and the next one are in the wrong order.
                guard index + 1 < count else { continue }
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
                                score: state.score + later.g + earlier.g
                                    - cost(configuration.transpositionPenalty, spent: state.edits),
                                edits: state.edits + 1, kind: .transposition),
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

    /// The best `beam` states, one per distinct (prefix, edits spent) pair, best first.
    private func prune(_ states: [State], beam: Int) -> [State] {
        guard states.count > 1 else { return states }
        let sorted = states.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.bytes.lexicographicallyPrecedes($1.bytes)
        }
        var seen = Set<StateKey>()
        var kept: [State] = []
        kept.reserveCapacity(min(beam, sorted.count))
        for state in sorted where seen.insert(StateKey(bytes: state.bytes, edits: state.edits)).inserted {
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

    /// A cut of the taps whose one half read as a word, and how well: where an edit in the other
    /// half is worth searching for.
    private struct SplitAnchor {
        let strength: Double
        let cut: Int
        let anchorIsLeft: Bool
    }

    private func strength(_ terminal: Terminal) -> Double {
        terminal.score + Double(model.unigram(terminal.id)) * Self.ln10
    }

    /// The likeliest few words for taps `lo..<hi`, by spatial score plus frequency.
    private func halves(_ tables: Tables, _ lo: Int, _ hi: Int, edits: Int) -> [Terminal] {
        let found = search(
            tables, from: lo, to: hi, maxEdits: edits, beam: configuration.splitBeamWidth,
            editBeam: configuration.splitEditBeamWidth)
        return Array(found.sorted { strength($0) > strength($1) }.prefix(configuration.splitKeep))
    }

    private func combine(
        _ left: [Terminal], _ right: [Terminal], edits: Int, previous: Int?
    ) -> [(text: String, ids: [Int], score: Double)] {
        var result: [(text: String, ids: [Int], score: Double)] = []
        for first in left {
            let head = configuration.languageWeight * logPrior(first.id, previous: previous)
            for second in right where first.edits + second.edits == edits {
                let tail = configuration.languageWeight * logPrior(second.id, previous: first.id)
                result.append((
                    first.word + " " + second.word, [first.id, second.id],
                    first.score + second.score + head + tail - configuration.splitPenalty
                ))
            }
        }
        return result
    }

    /// Candidates that read the taps as two words with the space missing. Each half is decoded
    /// exactly and cut to its likeliest few; the halves are then combined, the second scored after
    /// the first. The anchors say which cuts have a half worth building an edited reading on.
    private func splits(
        _ tables: Tables, count: Int, previous: Int?
    ) -> (found: [(text: String, ids: [Int], score: Double)], anchors: [SplitAnchor]) {
        var result: [(text: String, ids: [Int], score: Double)] = []
        var anchors: [SplitAnchor] = []
        for cut in 1..<count {
            let left = halves(tables, 0, cut, edits: 0)
            let right = halves(tables, cut, count, edits: 0)
            result += combine(left, right, edits: 0, previous: previous)
            if let best = left.first, count - cut >= configuration.splitEditMinTaps {
                anchors.append(SplitAnchor(strength: strength(best), cut: cut, anchorIsLeft: true))
            }
            if let best = right.first, cut >= configuration.splitEditMinTaps {
                anchors.append(SplitAnchor(strength: strength(best), cut: cut, anchorIsLeft: false))
            }
        }
        return (result, anchors)
    }

    /// One edit in a half of a missed space (`thelay` is `the` and a `lazy` with its letter left
    /// out). That search is dear, so it runs only for the few cuts whose other half is the
    /// strongest word (`the`, `of`): a split worth believing has one half the user plainly meant.
    private func editedSplits(
        _ anchors: [SplitAnchor], tables: Tables, count: Int, previous: Int?
    ) -> [(text: String, ids: [Int], score: Double)] {
        let picks = anchors.sorted { $0.strength != $1.strength ? $0.strength > $1.strength : $0.cut < $1.cut }
        var result: [(text: String, ids: [Int], score: Double)] = []
        for pick in picks.prefix(configuration.splitEditCuts) {
            if pick.anchorIsLeft {
                result += combine(
                    halves(tables, 0, pick.cut, edits: 0), halves(tables, pick.cut, count, edits: 1), edits: 1,
                    previous: previous)
            } else {
                result += combine(
                    halves(tables, 0, pick.cut, edits: 1), halves(tables, pick.cut, count, edits: 0), edits: 1,
                    previous: previous)
            }
        }
        return result
    }
}
