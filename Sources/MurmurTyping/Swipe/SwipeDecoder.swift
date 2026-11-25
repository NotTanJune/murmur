import CoreGraphics
import Foundation

/// Decodes a swipe over the letters page into words, in the manner of SHARK2 (Kristensson and
/// Zhai, UIST 2004), written from the published description, and made to forgive the path a
/// thumb really draws.
///
/// A swipe is a path of touch points in the keyboard view's coordinates (the space of
/// `KeyboardMetrics` frames). Inside, every distance is in key pitches (a letter key's width plus
/// the gap), so the numbers mean the same on any phone. The steps:
///
/// 1. The path is resampled to `resamplePoints` equidistant points, and the distance from every
///    letter's key to the nearest point of the path is tabled once (`keyNear`, `keyAt`).
/// 2. Words are read from the model's start and end buckets (`TypingModel.ids(first:last:)`),
///    the buckets whose keys sit nearest the gesture's ends first. A word is cut at once when its
///    ideal path (the polyline through the key centres; a doubled letter may or may not carry a
///    small loop, so both lengths count) is not about the gesture's length, or when some letter's
///    key lies far from the path anywhere. What is left is scored without building any path: how
///    near the finger went to each key, in order, how far the gesture's ends are from the word's
///    first and last keys, how the lengths compare, and λ · ln P(word | previous). This first
///    stage keeps the best `rerankCount`. A far bucket is not read at all once its ends alone
///    put it behind the cut-off, and the number of words read is capped (`scanBudget`).
/// 3. Each kept word's ideal path, resampled the same way, is compared with the gesture on the
///    location channel (points laid on the keys, ends weighted more, plain and warped by dynamic
///    time warping, which forgives a gesture that dwells on one key and rushes another), the
///    shape channel (both paths scaled to one unit and centred), and how near the gesture stays
///    to the polyline. A word with a doubled letter is scored with and without its loop and the
///    better counts. Each distance becomes a log-likelihood with a Student-t shape.
///
/// The key-passing test is why a gesture that cuts a corner, lifts early or starts off the first
/// key still finds its word: a comparison at matching points along the two paths drifts out of
/// register as soon as the finger's path is shorter or longer than the ideal one.
///
/// The decoder is immutable and holds no word list: words are read from the mapped model per
/// call, and the per-call scratch is a few kilobytes.
@inline(__always) private func norm(_ dx: Double, _ dy: Double) -> Double {
    (dx * dx + dy * dy).squareRoot()
}

public struct SwipeDecoder: Sendable {
    /// Every tunable of the decoder. The first values came from the milestone's reading of SHARK2
    /// (σ location 0.5 pitch, σ shape 0.25, 32 points, 3 keys at each end, length within 30%, 80
    /// re-ranked, loop radius 0.3, band 6, ends weighing 3 to 1) and a clean synthetic benchmark
    /// (`SwipeBenchTests.synthetic`, 2,000 words, 2026-11-25) that found the surface flat.
    /// A harsher one (`sloppySentences`, whole sentences, corner cutting, end misses, thumb bias,
    /// no loops, the previous word as context) then showed that top-1 fell from 93% to 71% when the
    /// finger was imprecise. What recovered it: five keys at each end within 1.8 pitches, the
    /// length window of 50% plus 0.6 pitch, the key-passing first stage, the two-length doubled
    /// letters, a Student-t distance term and wider spreads, an explicit price for the ends'
    /// distance, and the near-the-path term. The numbers still depend on a noise model that is a
    /// guess at human behaviour, not a measurement of it; real swipes may want other values.
    public struct Configuration: Sendable, Equatable {
        /// Points both paths are resampled to.
        public var resamplePoints = 32
        /// A touch that travels farther than this many pitches from where it went down is a
        /// swipe.
        public var swipeStartPitches = 1.0
        /// A swipe that lifts on its starting key and never strayed beyond this many pitches
        /// from where it went down is a tap.
        public var tapTravelPitches = 1.6
        /// Keys near the first point whose letters may start the word.
        public var startKeyCount = 5
        /// Keys near the last point whose letters may end the word.
        public var endKeyCount = 5
        /// A word's ideal path may differ from the gesture's length by this fraction of it.
        public var lengthTolerance = 0.50
        /// Pitches added to the length window at both ends, so a short word is not ruled out by
        /// a finger that lifted early: for "we" (one pitch) the tolerance alone is 0.3.
        public var lengthSlackPitches = 0.6
        /// Radius, in pitches, of the loop drawn for a doubled letter. Small, so a swipe that
        /// makes no loop at all is not punished hard for the doubled letter it did not mark.
        public var loopRadius = 0.3
        /// Points per loop in the ideal path.
        public var loopSegments = 12
        /// A word is dropped before its path is built when some letter's key lies farther than
        /// this from the gesture's path anywhere along it. A cheap test that spares most words
        /// the full scoring; it forgives a finger that cut a corner, which a comparison at
        /// matching points along both paths does not.
        public var passLimitPitches = 1.6
        /// A key's distance counts for no more than this when the first stage and the key-order
        /// term add them up, so one key the finger missed does not sink an otherwise good word.
        public var passCapPitches = 1.6
        /// Spread of the keys-passed term, in pitches.
        public var sigmaPass = 0.6
        /// Nats lost when the keys of a word are passed in the wrong order, per whole gesture
        /// length of reversal.
        public var orderWeight = 3.0
        /// Spread, as the log of the ratio of the word's ideal length to the gesture's, of the
        /// length term. Zero leaves the length to the hard cut alone.
        public var lengthSigma = 0.3
        /// The most words read from the model in one decode, the nearest buckets first. Zero for
        /// no limit.
        public var scanBudget = 8000
        /// Weight of the second stage's term for how near the gesture stays to the ideal path.
        public var nearWeight = 1.0
        /// Spread of that term, in pitches.
        public var sigmaNear = 0.7
        /// How many independent points it stands for.
        public var nearEvidence = 12.0
        /// Keys farther than this many pitches from the first or last point do not count among
        /// the nearest keys, so a point in the middle of a key does not also admit a key two
        /// keys away just because three were asked for.
        public var keyReachPitches = 1.8
        /// Gesture shorter than this many pitches in total decodes to nothing.
        public var minimumLengthPitches = 0.25
        /// Words shorter than this are not offered; a swipe of one letter is a tap.
        public var minimumLetters = 2
        /// Spread of the location channel, in pitches.
        public var sigmaLocation = 0.65
        /// Degrees of freedom of the Student-t shape the distance terms follow. Zero is a Gaussian;
        /// a small number lets a few far points cost less, as a hand's slips do.
        public var tailDegrees = 2.0
        /// Spread, in pitches, of how far the gesture's first and last points may be from a word's
        /// first and last keys. Zero leaves the ends to the later stage.
        public var sigmaEnds = 0.7
        /// Spread of the shape channel, in units of the path's longest side.
        public var sigmaShape = 0.25
        /// How many independent points the location distance stands for. The mean distance is a
        /// per-point figure; a likelihood needs the sum over points, but neighbouring points of a
        /// wobbly path are not independent, so this is well below `resamplePoints`.
        public var locationEvidence = 10.0
        /// The same for the shape channel.
        public var shapeEvidence = 9.0
        /// How much more the first and last points weigh in the location channel than the
        /// middle, rising linearly toward both ends.
        public var endWeightRatio = 3.0
        /// Weight of the language term, λ.
        public var languageWeight = 1.0
        /// The most nats a stored word pair is expected to add to the word's own log probability.
        /// A word that cannot reach the cut-off even with that is dropped before the pair is
        /// looked up, which is the slowest step of a word that passed the length and key tests.
        public var pairBonusBound = 6.0
        /// The weight of the unigram when a pair is not stored (stupid backoff, as `TapDecoder`).
        public var backoffWeight = 0.4
        /// ln P of a lexicon word that is not in the model (as `TapDecoder`).
        public var lexiconLogPrior = -12.0
        /// How many of the best words by the first stage the second stage scores in full.
        public var rerankCount = 36
        /// A word more than this many nats behind the best so far in the first stage is dropped
        /// before the second: the second stage moves a word's score by a few nats, never as far as
        /// this. It lets the scoring of the unlikelier words stop early.
        public var rerankMargin = 8.0
        /// Half-width of the warping band, in resampled points.
        public var warpBand = 6
        /// The share of the location log-likelihood replaced by the warped one in the re-rank.
        public var warpWeight = 0.5

        public init() {}

        /// The values the benchmarks settled on.
        public static let tuned = Configuration()
    }

    /// One word the swipe might have meant.
    public struct Candidate: Hashable, Sendable {
        /// Lowercase from the model, or the lexicon's own spelling ("iPhone") for a lexicon word.
        public let text: String
        /// The model id, nil for a lexicon word the model lacks.
        public let id: Int?
        /// The log score in nats; only the order and the gaps between candidates mean anything.
        public let score: Double
    }

    public let model: TypingModel
    public let configuration: Configuration
    /// A letter key's width plus the gap, in points: the unit of every distance inside.
    public let pitch: Double

    private let frames: [KeyFrame]
    /// Key centres in pitch units, indexed by letter (0 for a to 25 for z).
    private let centreX: [Double]
    private let centreY: [Double]
    /// Distance in pitches between every pair of letters, `a * 26 + b`.
    private let pairDistance: [Double]
    /// The weights of the location channel, summing to 1.
    private let weights: [Double]
    private let isUsable: Bool

    private static let ln10 = log(10.0)
    /// log10 of the likeliest unigram in the model, "the" at about -1.7, rounded up.
    private static let unigramCeiling = -1.5
    private static let letterA: UInt8 = 97
    private static let apostrophe: UInt8 = 0x27

    /// - Parameter frames: the key frames of the letters page, in the coordinates the swipe's
    ///   points use. The keycap centres are where each letter is aimed at.
    public init(model: TypingModel, frames: [KeyFrame], configuration: Configuration = .tuned) {
        self.model = model
        self.configuration = configuration
        self.frames = frames

        var found: [CGPoint?] = Array(repeating: nil, count: 26)
        for frame in frames {
            guard let letter = frame.kind.characterValue, letter.utf8.count == 1, let byte = letter.utf8.first,
                byte >= Self.letterA, byte < Self.letterA + 26
            else { continue }
            found[Int(byte - Self.letterA)] = CGPoint(x: frame.keycap.midX, y: frame.keycap.midY)
        }
        // The pitch is read off the layout, q to w across, as `TapDecoder` reads its neighbours.
        let q = found[16], w = found[22]
        let measured = (q != nil && w != nil) ? abs(Double(w!.x - q!.x)) : 0
        if found.allSatisfy({ $0 != nil }), measured > 0 {
            pitch = measured
            centreX = found.map { Double($0!.x) / measured }
            centreY = found.map { Double($0!.y) / measured }
            isUsable = true
        } else {
            pitch = 1
            centreX = Array(repeating: 0, count: 26)
            centreY = Array(repeating: 0, count: 26)
            isUsable = false
        }
        var distances = Array(repeating: 0.0, count: 26 * 26)
        for a in 0..<26 {
            for b in 0..<26 {
                distances[a * 26 + b] = norm(centreX[a] - centreX[b], centreY[a] - centreY[b])
            }
        }
        pairDistance = distances

        // Linear from 1 in the middle to `endWeightRatio` at both ends, then normalised.
        let count = max(configuration.resamplePoints, 2)
        let half = Double(count - 1) / 2
        var raw = (0..<count).map { index in
            1 + (configuration.endWeightRatio - 1) * abs(Double(index) - half) / half
        }
        let total = raw.reduce(0, +)
        raw = raw.map { $0 / total }
        weights = raw
    }

    // MARK: - Touch rules

    /// Whether a touch that went down at `start` and is now at `current` has become a swipe:
    /// it has travelled farther than `swipeStartPitches` key pitches. The engine asks this on
    /// every move of a touch that began on a letter, before the accent hold fires.
    public static func isSwipe(
        start: CGPoint, current: CGPoint, pitch: CGFloat, configuration: Configuration = .tuned
    ) -> Bool {
        Double(hypot(current.x - start.x, current.y - start.y)) > configuration.swipeStartPitches * Double(pitch)
    }

    /// Whether a swipe that has ended was really a tap: it lifted on the key it went down on and
    /// never wandered beyond `tapTravelPitches` from where it began. That is a finger that slid
    /// a little while pressing, and it types its key.
    public func isTap(path: [CGPoint]) -> Bool {
        guard isUsable else { return false }
        return Self.isTap(path: path, frames: frames, pitch: CGFloat(pitch), configuration: configuration)
    }

    /// The same rule with no word model: the touch engine, which has the frames and the pitch
    /// but no `TypingModel`, decides a tap-shaped swipe with it. Keys are found without the
    /// next-letter bias, as the instance form does.
    public static func isTap(
        path: [CGPoint], frames: [KeyFrame], pitch: CGFloat, configuration: Configuration = .tuned
    ) -> Bool {
        guard let start = path.first, let end = path.last, pitch > 0 else { return false }
        let limit = configuration.tapTravelPitches * Double(pitch)
        for point in path where Double(hypot(point.x - start.x, point.y - start.y)) > limit { return false }
        guard let first = HitTester.key(at: start, frames: frames, bias: [:]),
            let last = HitTester.key(at: end, frames: frames, bias: [:])
        else { return false }
        return first == last
    }

    // MARK: - Paths

    /// The ideal path of a word: the polyline through the centres of its letters, with a small
    /// loop at each doubled letter, in the keyboard view's coordinates. An apostrophe is skipped
    /// (the letters page has no such key); empty for a word with another character or none.
    public func idealPath(for word: String) -> [CGPoint] {
        guard isUsable, let letters = Self.letters(of: word) else { return [] }
        var x: [Double] = []
        var y: [Double] = []
        buildIdealPath(letters, x: &x, y: &y)
        return zip(x, y).map { CGPoint(x: $0 * pitch, y: $1 * pitch) }
    }

    /// `points` resampled to `count` points equally spaced along the path's length, first and
    /// last included. A path with no length gives `count` copies of its point.
    public static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard let first = points.first, count >= 1 else { return [] }
        let x = points.map { Double($0.x) }
        let y = points.map { Double($0.y) }
        var outX = Array(repeating: Double(first.x), count: count)
        var outY = Array(repeating: Double(first.y), count: count)
        resample(x: x, y: y, count: count, outX: &outX, outY: &outY)
        return zip(outX, outY).map { CGPoint(x: $0, y: $1) }
    }

    // MARK: - Decoding

    /// What one decode read, for the benchmark's prune rates and its timing.
    struct ScanStats {
        /// Words read from the model.
        var scanned = 0
        /// Words whose ideal path has about the gesture's length.
        var lengthPassed = 0
        /// Words whose letters all lie near the gesture's path.
        var screenPassed = 0
        /// Whether the scan stopped at `scanBudget` before the last bucket.
        var budgetHit = false
    }

    /// Decodes one swipe.
    ///
    /// - Parameters:
    ///   - path: the touch points, in the space of the frames the decoder was built from.
    ///   - times: each point's timestamp. Not used yet: the arc-length resampling makes the
    ///     speed of the finger irrelevant, and no dwell feature has earned its place.
    ///   - previous: the id of the word before this one, for the bigram. Nil at a sentence
    ///     start, which scores by frequency alone.
    ///   - lexicon: the user's own words, which add candidates and bonuses.
    ///   - limit: how many candidates to return, best first.
    public func decode(
        path: [CGPoint], times: [TimeInterval]? = nil, previous: Int?, lexicon: UserLexicon = .empty,
        limit: Int = 4
    ) -> [Candidate] {
        var stats = ScanStats()
        return decode(path: path, previous: previous, lexicon: lexicon, limit: limit, stats: &stats)
    }

    func decode(
        path: [CGPoint], previous: Int?, lexicon: UserLexicon, limit: Int, stats: inout ScanStats
    ) -> [Candidate] {
        guard limit > 0, let prepared = prepare(path: path) else { return [] }
        let count = max(configuration.resamplePoints, 2)
        let rawX = prepared.rawX
        let rawY = prepared.rawY
        let gesture = prepared.gesture
        var search = Search(
            count: count, keep: max(configuration.rerankCount, limit), margin: configuration.rerankMargin)
        let hasLexicon = !lexicon.entries.isEmpty

        // Words of the model, by the start and end buckets, the likeliest bucket first so the
        // cut-off is a good one early and a spent scan budget loses only the unlikeliest. A word
        // pays for how far the gesture's ends are from its first and last keys.
        var buckets: [(start: Int, end: Int, distance: Double, penalty: Double)] = []
        let endSigma = configuration.sigmaEnds
        for start in prepared.startKeys {
            for end in prepared.endKeys {
                let ds = norm(centreX[start] - rawX[0], centreY[start] - rawY[0])
                let de = norm(centreX[end] - rawX[rawX.count - 1], centreY[end] - rawY[rawY.count - 1])
                buckets.append((start, end, ds + de, endSigma > 0 ? -0.5 * (ds * ds + de * de) / (endSigma * endSigma) : 0))
            }
        }
        buckets.sort { endSigma > 0 ? $0.penalty > $1.penalty : $0.distance < $1.distance }
        // What the best word of any bucket could score in language, so a bucket whose ends alone
        // put it past the cut-off is not read at all: the unigram of "the" without a previous
        // word or a lexicon, nothing sharper than a certainty otherwise.
        let languageCeiling = (previous == nil && !hasLexicon)
            ? configuration.languageWeight * Self.unigramCeiling * Self.ln10 : 0
        scan: for (index, bucket) in buckets.enumerated() {
            // The first bucket is always read, so a swipe is never left with nothing to decode.
            if index > 0, endSigma > 0, bucket.penalty + languageCeiling <= search.cutoff { break }
            // No word between two keys is shorter than the straight line between them.
            if pairDistance[bucket.start * 26 + bucket.end] > gesture.longest { continue }
            let ids = model.ids(
                first: Character(UnicodeScalar(Self.letterA + UInt8(bucket.start))),
                last: Character(UnicodeScalar(Self.letterA + UInt8(bucket.end))))
            for id in ids {
                if configuration.scanBudget > 0, stats.scanned >= configuration.scanBudget {
                    stats.budgetHit = true
                    break scan
                }
                stats.scanned += 1
                var word = model.word(id)
                // Read straight off the word's bytes, with no array built: this runs for every
                // word of the bucket.
                guard
                    let first = word.withUTF8({ firstStage($0, gesture: gesture, stats: &stats) })
                else { continue }
                let spatial = first + bucket.penalty
                var bonus = 0.0
                var display: String?
                if hasLexicon, let entry = lexicon.entry(for: word) {
                    bonus = entry.bonus
                    if entry.respellsKnownWords { display = entry.display }
                }
                // The pair lookup is the dear part of a word, so it waits until the word could
                // reach the cut-off with the most a pair is allowed to add to its unigram.
                let unigram = Double(model.unigram(id)) * Self.ln10
                let optimistic = configuration.languageWeight
                    * (unigram + (previous == nil ? 0 : configuration.pairBonusBound))
                if spatial + optimistic + bonus <= search.cutoff { continue }
                let language = bonus + configuration.languageWeight * logPrior(id, previous: previous)
                if spatial + language <= search.cutoff { continue }
                search.insert(
                    Scored(
                        id: id, lexiconWord: nil, display: display, score: spatial + language,
                        languageScore: language))
            }
        }

        // Words of the lexicon that the model does not know.
        for (folded, entry) in lexicon.entries.sorted(by: { $0.key < $1.key }) {
            guard model.id(of: folded) == nil, let word = Self.letters(of: folded),
                word.count >= max(configuration.minimumLetters, 2),
                prepared.startKeys.contains(Int(word[0])), prepared.endKeys.contains(Int(word[word.count - 1]))
            else { continue }
            var scratch = ScanStats()
            guard let screened = Array(folded.utf8).withUnsafeBufferPointer({
                firstStage($0, gesture: gesture, stats: &scratch)
            })
            else { continue }
            let language = configuration.languageWeight * configuration.lexiconLogPrior + entry.bonus
            var endPenalty = 0.0
            if endSigma > 0 {
                let ds = norm(centreX[Int(word[0])] - rawX[0], centreY[Int(word[0])] - rawY[0])
                let de = norm(
                    centreX[Int(word[word.count - 1])] - rawX[rawX.count - 1],
                    centreY[Int(word[word.count - 1])] - rawY[rawY.count - 1])
                endPenalty = -0.5 * (ds * ds + de * de) / (endSigma * endSigma)
            }
            let spatial = screened + endPenalty
            if spatial + language <= search.cutoff { continue }
            search.insert(
                Scored(
                    id: -1, lexiconWord: folded, display: entry.display, score: spatial + language,
                    languageScore: language))
        }

        // The second stage: everything kept is scored on the full channels.
        var rescored: [Candidate] = []
        rescored.reserveCapacity(search.best.count)
        for item in search.best {
            let wordLetters: [UInt8]
            if let lexiconWord = item.lexiconWord {
                wordLetters = Self.letters(of: lexiconWord) ?? []
            } else {
                wordLetters = Self.letters(of: model.word(item.id)) ?? []
            }
            let spatial = fullSpatialScore(wordLetters, gesture: gesture, search: &search)
            let text = item.display ?? (item.lexiconWord ?? model.word(item.id))
            rescored.append(
                Candidate(
                    text: text, id: item.lexiconWord == nil ? item.id : nil, score: spatial + item.languageScore))
        }
        rescored.sort { $0.score > $1.score }
        return Array(rescored.prefix(limit))
    }

    /// Everything a decode computes from the gesture alone.
    private struct Prepared {
        let rawX: [Double]
        let rawY: [Double]
        let gesture: Gesture
        let startKeys: [Int]
        let endKeys: [Int]
    }

    /// The gesture in pitch units, resampled and normalised, with the keys its ends may start
    /// and end a word on; nil for a path too short to decode.
    private func prepare(path: [CGPoint]) -> Prepared? {
        guard isUsable, path.count >= 2 else { return nil }
        let count = max(configuration.resamplePoints, 2)

        // The gesture in pitch units, without repeated points.
        var rawX: [Double] = []
        var rawY: [Double] = []
        rawX.reserveCapacity(path.count)
        rawY.reserveCapacity(path.count)
        for point in path {
            let px = Double(point.x) / pitch
            let py = Double(point.y) / pitch
            if let lx = rawX.last, let ly = rawY.last, norm(px - lx, py - ly) < 1e-9 { continue }
            rawX.append(px)
            rawY.append(py)
        }
        guard rawX.count >= 2 else { return nil }
        let gestureLength = Self.length(x: rawX, y: rawY)
        guard gestureLength >= configuration.minimumLengthPitches else { return nil }

        var gestureX = Array(repeating: 0.0, count: count)
        var gestureY = Array(repeating: 0.0, count: count)
        Self.resample(x: rawX, y: rawY, count: count, outX: &gestureX, outY: &gestureY)
        var gestureShapeX = Array(repeating: 0.0, count: count)
        var gestureShapeY = Array(repeating: 0.0, count: count)
        Self.normalise(x: gestureX, y: gestureY, intoX: &gestureShapeX, intoY: &gestureShapeY)

        // How near the gesture passes each key, and where along it: a word is only a candidate
        // if every one of its letters has a key the finger went by, however it cut the corner.
        var keyNear = Array(repeating: 0.0, count: 26)
        var keyAt = Array(repeating: 0.0, count: 26)
        for letter in 0..<26 {
            var nearest = Double.infinity
            var at = 0.0
            for index in 0..<(count - 1) {
                let ax = gestureX[index], ay = gestureY[index]
                let dx = gestureX[index + 1] - ax, dy = gestureY[index + 1] - ay
                let lengthSquared = dx * dx + dy * dy
                var t = 0.0
                if lengthSquared > 1e-12 {
                    t = min(max(((centreX[letter] - ax) * dx + (centreY[letter] - ay) * dy) / lengthSquared, 0), 1)
                }
                let ex = centreX[letter] - (ax + t * dx), ey = centreY[letter] - (ay + t * dy)
                let distance = ex * ex + ey * ey
                if distance < nearest {
                    nearest = distance
                    at = (Double(index) + t) / Double(count - 1)
                }
            }
            keyNear[letter] = nearest.squareRoot()
            keyAt[letter] = at
        }

        let tables = Workspace(points: count, pairDistance: pairDistance, weights: weights)
        for index in 0..<count {
            tables.gestureX[index] = gestureX[index]
            tables.gestureY[index] = gestureY[index]
            tables.gestureShapeX[index] = gestureShapeX[index]
            tables.gestureShapeY[index] = gestureShapeY[index]
        }
        for letter in 0..<26 {
            tables.near[letter] = keyNear[letter]
            tables.at[letter] = keyAt[letter]
        }

        let startKeys = nearestKeys(toX: rawX[0], y: rawY[0], count: configuration.startKeyCount)
        let endKeys = nearestKeys(
            toX: rawX[rawX.count - 1], y: rawY[rawY.count - 1], count: configuration.endKeyCount)
        let gesture = Gesture(
            tables: tables, length: gestureLength,
            startX: rawX[0], startY: rawY[0], endX: rawX[rawX.count - 1], endY: rawY[rawY.count - 1],
            shortest: gestureLength * (1 - configuration.lengthTolerance) - configuration.lengthSlackPitches,
            longest: gestureLength * (1 + configuration.lengthTolerance) + configuration.lengthSlackPitches)
        return Prepared(rawX: rawX, rawY: rawY, gesture: gesture, startKeys: startKeys, endKeys: endKeys)
    }

    /// Where in the cuts before scoring a word is dropped, for the benchmark's prune rates.
    enum PruneStage: String {
        case endKeys, length, screen, survives, notAWord
    }

    /// The first cut that removes `word` for this gesture, or `survives` when it reaches scoring.
    func pruneStage(of word: String, path: [CGPoint]) -> PruneStage {
        guard let prepared = prepare(path: path), let letters = Self.letters(of: word), letters.count >= 2
        else { return .notAWord }
        guard prepared.startKeys.contains(Int(letters[0])), prepared.endKeys.contains(Int(letters[letters.count - 1]))
        else { return .endKeys }
        var stats = ScanStats()
        _ = Array(word.utf8).withUnsafeBufferPointer { firstStage($0, gesture: prepared.gesture, stats: &stats) }
        if stats.lengthPassed == 0 { return .length }
        if stats.screenPassed == 0 { return .screen }
        return .survives
    }

    // MARK: - Search

    /// What the gesture offers every word, built once per decode.
    private struct Gesture {
        /// The gesture resampled, its key table and the scratch of both stages.
        let tables: Workspace
        let length: Double
        /// The first and last point of the gesture.
        let startX: Double
        let startY: Double
        let endX: Double
        let endY: Double
        /// The ideal path lengths a word may have.
        let shortest: Double
        let longest: Double
    }

    /// What both stages read and write for every word, as bare memory: the first stage's loop
    /// runs for thousands of words a decode and the second compares paths point by point, and
    /// in a debug build, where the tests time them, every access to an array is a checked call.
    /// One allocation per decode, freed with it.
    private final class Workspace {
        /// Points in the resampled gesture and in a resampled ideal path.
        let points: Int
        /// Distance in pitches between every pair of letters, `a * 26 + b`.
        let pair: UnsafeMutablePointer<Double>
        /// Distance in pitches from each letter's key centre to the nearest point of the gesture,
        /// and how far along the gesture (0 to 1) that point is.
        let near: UnsafeMutablePointer<Double>
        let at: UnsafeMutablePointer<Double>
        /// The gesture resampled, and scaled to one unit and centred.
        let gestureX: UnsafeMutablePointer<Double>
        let gestureY: UnsafeMutablePointer<Double>
        let gestureShapeX: UnsafeMutablePointer<Double>
        let gestureShapeY: UnsafeMutablePointer<Double>
        /// The ideal path being scored, the same two ways.
        let templateX: UnsafeMutablePointer<Double>
        let templateY: UnsafeMutablePointer<Double>
        let templateShapeX: UnsafeMutablePointer<Double>
        let templateShapeY: UnsafeMutablePointer<Double>
        /// The weights of the location channel.
        let weights: UnsafeMutablePointer<Double>
        /// The warping's rolling row: the cost and the steps of the cheapest alignment so far.
        let warpCost: UnsafeMutablePointer<Double>
        let warpSteps: UnsafeMutablePointer<Double>
        private let doubles: UnsafeMutablePointer<Double>

        init(points: Int, pairDistance: [Double], weights source: [Double]) {
            self.points = points
            let total = 26 * 26 + 2 * 26 + 11 * points
            doubles = .allocate(capacity: total)
            doubles.initialize(repeating: 0, count: total)
            pair = doubles
            near = pair + 26 * 26
            at = near + 26
            gestureX = at + 26
            gestureY = gestureX + points
            gestureShapeX = gestureY + points
            gestureShapeY = gestureShapeX + points
            templateX = gestureShapeY + points
            templateY = templateX + points
            templateShapeX = templateY + points
            templateShapeY = templateShapeX + points
            weights = templateShapeY + points
            warpCost = weights + points
            warpSteps = warpCost + points
            for index in 0..<min(pairDistance.count, 26 * 26) { pair[index] = pairDistance[index] }
            for index in 0..<min(source.count, points) { weights[index] = source[index] }
        }

        deinit {
            doubles.deallocate()
        }
    }

    /// A word that passed the first stage, kept for the second.
    private struct Scored {
        var id: Int
        var lexiconWord: String?
        var display: String?
        var score: Double
        var languageScore: Double
    }

    /// The best words so far and the scratch the scoring reuses, so a decode allocates these once.
    private struct Search {
        let keep: Int
        let margin: Double
        /// A word whose score cannot exceed this is not worth finishing: the worst of the kept
        /// words once there are `keep`, or `margin` behind the best.
        var cutoff = -Double.infinity
        var best: [Scored] = []
        var polyX: [Double] = []
        var polyY: [Double] = []

        init(count: Int, keep: Int, margin: Double) {
            self.keep = keep
            self.margin = margin
            best.reserveCapacity(keep + 1)
            polyX.reserveCapacity(64)
            polyY.reserveCapacity(64)
        }

        mutating func insert(_ scored: Scored) {
            var slot = best.count
            while slot > 0, best[slot - 1].score < scored.score { slot -= 1 }
            best.insert(scored, at: slot)
            if best.count > keep { best.removeLast() }
            while let last = best.last, last.score < best[0].score - margin { best.removeLast() }
            cutoff = best[0].score - margin
            if best.count == keep { cutoff = max(cutoff, best[keep - 1].score) }
        }
    }

    /// The first stage, from a word's UTF-8 bytes alone: nil when the word's ideal path is not
    /// about the gesture's length, or some letter's key is farther from the gesture than
    /// `passLimitPitches`; else the log-likelihood that the finger went by every key of the word,
    /// in order. It needs no path, so it is what spares most words the second stage; the second
    /// stage looks at the shape the gesture really has. An apostrophe has no key and is skipped,
    /// and any other byte that is not a lowercase letter rules the word out.
    private func firstStage(_ bytes: UnsafeBufferPointer<UInt8>, gesture: Gesture, stats: inout ScanStats) -> Double? {
        guard let base = bytes.baseAddress else { return nil }
        let count = bytes.count
        let pair = gesture.tables.pair
        let near = gesture.tables.near
        let places = gesture.tables.at
        let letterA: UInt8 = 97, apostrophe: UInt8 = 0x27
        var total = 0.0
        var doubled = 0
        var previous = -1
        var letters = 0
        var index = 0
        while index < count {
            let byte = base[index]
            index += 1
            if byte == apostrophe { continue }
            guard byte >= letterA, byte < letterA + 26 else { return nil }
            let letter = Int(byte - letterA)
            if previous >= 0 {
                if previous == letter { doubled += 1 } else { total += pair[previous * 26 + letter] }
            }
            previous = letter
            letters += 1
        }
        guard letters >= max(configuration.minimumLetters, 2) else { return nil }
        let lengths = (short: total, long: total + Double(doubled) * 2 * Double.pi * configuration.loopRadius)
        guard lengths.long >= gesture.shortest, lengths.short <= gesture.longest else { return nil }
        stats.lengthPassed += 1

        let cap = configuration.passCapPitches
        let limit = configuration.passLimitPitches
        var sum = 0.0
        var inversion = 0.0
        var previousLetter = -1
        var previousAt = -1.0
        index = 0
        while index < count {
            let byte = base[index]
            index += 1
            if byte == apostrophe { continue }
            let letter = Int(byte - letterA)
            if letter == previousLetter { continue }
            previousLetter = letter
            let distance = near[letter]
            if distance > limit { return nil }
            let capped = min(distance, cap)
            sum += capped * capped
            let at = places[letter]
            // A key passed before the one the word has just before it: the word is out of order.
            if previousAt >= 0, at < previousAt { inversion += previousAt - at }
            previousAt = at
        }
        stats.screenPassed += 1
        let sigma = configuration.sigmaPass
        return -0.5 * sum / (sigma * sigma) - configuration.orderWeight * inversion
            - lengthPenalty(lengths, gesture: gesture.length)
    }

    /// What the gesture's length costs a word, as a Gaussian in the log of the ratio to whichever
    /// of the word's two ideal lengths is nearer. Zero when `lengthSigma` is zero.
    private func lengthPenalty(_ lengths: (short: Double, long: Double), gesture: Double) -> Double {
        guard configuration.lengthSigma > 0, gesture > 1e-9 else { return 0 }
        let ideal = min(max(gesture, lengths.short), lengths.long)
        guard ideal > 1e-9 else { return 0 }
        let z = log(ideal / gesture) / configuration.lengthSigma
        return 0.5 * z * z
    }

    /// The second stage: the spatial score of a word on every channel. A word with a doubled
    /// letter is scored with its loop and without, and the better counts, because a finger often
    /// does not mark the doubled letter at all.
    private func fullSpatialScore(_ letters: [UInt8], gesture: Gesture, search: inout Search) -> Double {
        let lengths = idealLength(letters)
        var score = pathScore(letters, loops: true, gesture: gesture, search: &search)
        if lengths.long > lengths.short + 1e-9 {
            score = max(score, pathScore(letters, loops: false, gesture: gesture, search: &search))
        }
        score -= lengthPenalty(lengths, gesture: gesture.length)
        if configuration.sigmaEnds > 0, let first = letters.first, let final = letters.last {
            let ds = norm(centreX[Int(first)] - gesture.startX, centreY[Int(first)] - gesture.startY)
            let de = norm(centreX[Int(final)] - gesture.endX, centreY[Int(final)] - gesture.endY)
            score -= 0.5 * (ds * ds + de * de) / (configuration.sigmaEnds * configuration.sigmaEnds)
        }
        return score
    }

    /// One reading of the word's ideal path: location (plain and warped), shape, the keys
    /// passed in order, and how near the gesture stays to the path.
    private func pathScore(_ letters: [UInt8], loops: Bool, gesture: Gesture, search: inout Search) -> Double {
        buildIdealPath(letters, loops: loops, x: &search.polyX, y: &search.polyY)
        let work = gesture.tables
        let count = work.points
        let vertices = search.polyX.count
        var near = 0.0
        search.polyX.withUnsafeBufferPointer { polyX in
            search.polyY.withUnsafeBufferPointer { polyY in
                guard let px = polyX.baseAddress, let py = polyY.baseAddress else { return }
                Self.resample(
                    x: px, y: py, points: vertices, count: count, outX: work.templateX, outY: work.templateY)
                if configuration.nearWeight > 0 {
                    near = Self.nearDistance(
                        x: work.gestureX, y: work.gestureY, count: count, polyX: px, polyY: py, vertices: vertices)
                }
            }
        }
        let location = Self.locationDistance(
            work.gestureX, work.gestureY, work.templateX, work.templateY, weights: work.weights, count: count)
        let locationLL = logLikelihood(
            distance: location, sigma: configuration.sigmaLocation, evidence: configuration.locationEvidence)
        let warped = warpedDistance(work.gestureX, work.gestureY, work.templateX, work.templateY, work: work)
        let warpedLL = logLikelihood(
            distance: warped, sigma: configuration.sigmaLocation, evidence: configuration.locationEvidence)
        Self.normalise(
            x: work.templateX, y: work.templateY, count: count, intoX: work.templateShapeX,
            intoY: work.templateShapeY)
        let shape = Self.meanDistance(
            work.gestureShapeX, work.gestureShapeY, work.templateShapeX, work.templateShapeY, count: count)
        let shapeLL = logLikelihood(
            distance: shape, sigma: configuration.sigmaShape, evidence: configuration.shapeEvidence)
        var score = (1 - configuration.warpWeight) * locationLL + configuration.warpWeight * warpedLL + shapeLL
        if configuration.nearWeight > 0 {
            score += configuration.nearWeight
                * logLikelihood(distance: near, sigma: configuration.sigmaNear, evidence: configuration.nearEvidence)
        }
        return score
    }

    /// The mean distance from the gesture's sample points to the nearest point of the ideal path.
    private static func nearDistance(
        x: UnsafePointer<Double>, y: UnsafePointer<Double>, count: Int, polyX: UnsafePointer<Double>,
        polyY: UnsafePointer<Double>, vertices: Int
    ) -> Double {
        guard vertices > 1, count > 0 else { return 0 }
        var total = 0.0
        var index = 0
        while index < count {
            let px = x[index], py = y[index]
            var nearest = Double.infinity
            var segment = 0
            while segment < vertices - 1 {
                let ax = polyX[segment], ay = polyY[segment]
                let dx = polyX[segment + 1] - ax, dy = polyY[segment + 1] - ay
                let lengthSquared = dx * dx + dy * dy
                var t = 0.0
                if lengthSquared > 1e-12 { t = min(max(((px - ax) * dx + (py - ay) * dy) / lengthSquared, 0), 1) }
                let ex = px - (ax + t * dx), ey = py - (ay + t * dy)
                nearest = min(nearest, ex * ex + ey * ey)
                segment += 1
            }
            total += nearest.squareRoot()
            index += 1
        }
        return total / Double(count)
    }

    // MARK: - Scoring

    /// ln P of a word given the one before it: the stored pair, or the unigram backed off.
    private func logPrior(_ id: Int, previous: Int?) -> Double {
        if let previous {
            if let stored = model.pairLogP(previous, id) { return Double(stored) * Self.ln10 }
            return log(configuration.backoffWeight) + Double(model.unigram(id)) * Self.ln10
        }
        return Double(model.unigram(id)) * Self.ln10
    }

    /// The log-likelihood of a mean distance, scaled by the number of points it stands for: a
    /// Gaussian, or with `tailDegrees` above zero a Student-t shape that agrees with it for small
    /// distances and falls away more slowly for large ones, so a sloppy swipe that lands far
    /// from every word is not decided by which of them it is least far from alone.
    private func logLikelihood(distance: Double, sigma: Double, evidence: Double) -> Double {
        let z = distance / sigma
        let nu = configuration.tailDegrees
        if nu > 0 { return -0.5 * evidence * nu * log(1 + z * z / nu) }
        return -0.5 * evidence * z * z
    }

    /// The weighted mean distance between the gesture and the ideal path, point for point.
    private static func locationDistance(
        _ ax: UnsafePointer<Double>, _ ay: UnsafePointer<Double>, _ bx: UnsafePointer<Double>,
        _ by: UnsafePointer<Double>, weights: UnsafePointer<Double>, count: Int
    ) -> Double {
        var sum = 0.0
        var index = 0
        while index < count {
            sum += weights[index] * norm(ax[index] - bx[index], ay[index] - by[index])
            index += 1
        }
        return sum
    }

    private static func meanDistance(
        _ ax: UnsafePointer<Double>, _ ay: UnsafePointer<Double>, _ bx: UnsafePointer<Double>,
        _ by: UnsafePointer<Double>, count: Int
    ) -> Double {
        var sum = 0.0
        var index = 0
        while index < count {
            sum += norm(ax[index] - bx[index], ay[index] - by[index])
            index += 1
        }
        return sum / Double(count)
    }

    /// Dynamic time warping between the two resampled paths, inside a diagonal band: the mean
    /// distance along the cheapest alignment. One rolling row, so nothing is allocated.
    private func warpedDistance(
        _ ax: UnsafePointer<Double>, _ ay: UnsafePointer<Double>, _ bx: UnsafePointer<Double>,
        _ by: UnsafePointer<Double>, work: Workspace
    ) -> Double {
        let n = work.points
        let band = max(configuration.warpBand, 1)
        let infinity = Double.infinity
        let rowCost = work.warpCost, rowSteps = work.warpSteps
        var j = 0
        while j < n {
            rowCost[j] = infinity
            rowSteps[j] = 0
            j += 1
        }
        // `rowCost` holds the row above and, as it is overwritten left to right, the current one:
        // the cell left of j is already the current row's, the diagonal is kept in `diagonal*`.
        var i = 0
        while i < n {
            let low = max(0, i - band)
            let high = min(n - 1, i + band)
            var diagonalCost = low > 0 ? rowCost[low - 1] : (i == 0 ? 0 : infinity)
            var diagonalSteps = low > 0 ? rowSteps[low - 1] : 0
            if low > 0 {
                // The cell just left of the band is out of it on the current row.
                rowCost[low - 1] = infinity
                rowSteps[low - 1] = 0
            }
            let gx = ax[i], gy = ay[i]
            j = low
            while j <= high {
                let upCost = rowCost[j]
                let upSteps = rowSteps[j]
                let d = norm(gx - bx[j], gy - by[j])
                var bestCost = infinity
                var bestSteps = 0.0
                if i == 0 && j == 0 {
                    bestCost = 0
                } else {
                    if diagonalCost < bestCost, i > 0, j > 0 {
                        bestCost = diagonalCost
                        bestSteps = diagonalSteps
                    }
                    if upCost < bestCost, i > 0 {
                        bestCost = upCost
                        bestSteps = upSteps
                    }
                    if j > low || low == 0, j > 0, rowCost[j - 1] < bestCost {
                        bestCost = rowCost[j - 1]
                        bestSteps = rowSteps[j - 1]
                    }
                }
                diagonalCost = upCost
                diagonalSteps = upSteps
                if bestCost < infinity {
                    rowCost[j] = bestCost + d
                    rowSteps[j] = bestSteps + 1
                } else {
                    rowCost[j] = infinity
                    rowSteps[j] = 0
                }
                j += 1
            }
            if high < n - 1 {
                // The cells right of the band belong to no row yet.
                rowCost[high + 1] = infinity
                rowSteps[high + 1] = 0
            }
            i += 1
        }
        let cost = rowCost[n - 1]
        let steps = rowSteps[n - 1]
        guard cost < infinity, steps > 0 else { return infinity }
        return cost / steps
    }

    /// The `count` letters whose keys are nearest the point, nearest first.
    private func nearestKeys(toX x: Double, y: Double, count: Int) -> [Int] {
        let ranked = (0..<26).map { ($0, norm(centreX[$0] - x, centreY[$0] - y)) }
            .sorted { $0.1 < $1.1 }
        // The nearest key always counts, however far.
        return ranked.enumerated()
            .filter { $0.offset < count && ($0.offset == 0 || $0.element.1 <= configuration.keyReachPitches) }
            .map(\.element.0)
    }

    // MARK: - Ideal paths

    /// The letters of a word as 0 to 25, with apostrophes dropped; nil for any other byte.
    private static func letters(of word: String) -> [UInt8]? {
        var result: [UInt8] = []
        result.reserveCapacity(word.utf8.count)
        for byte in word.utf8 {
            if byte >= letterA, byte < letterA + 26 {
                result.append(byte - letterA)
            } else if byte != apostrophe {
                return nil
            }
        }
        return result
    }

    /// The length in pitches of a word's ideal path, without building it: `short` with no loop
    /// for any doubled letter and `long` with every loop, because a finger often skips the loop.
    private func idealLength(_ letters: [UInt8]) -> (short: Double, long: Double) {
        var total = 0.0
        var doubled = 0
        guard letters.count > 1 else { return (0, 0) }
        for index in 1..<letters.count {
            let a = Int(letters[index - 1])
            let b = Int(letters[index])
            if a == b { doubled += 1 } else { total += pairDistance[a * 26 + b] }
        }
        return (total, total + Double(doubled) * 2 * Double.pi * configuration.loopRadius)
    }

    /// The polyline through the key centres of `letters`. A doubled letter adds a loop: a circle
    /// of `loopRadius` that passes through the key's centre and bulges to the side of the path's
    /// direction there, upward when it can, so the same word always has the same ideal path.
    private func buildIdealPath(_ letters: [UInt8], loops: Bool = true, x: inout [Double], y: inout [Double]) {
        x.removeAll(keepingCapacity: true)
        y.removeAll(keepingCapacity: true)
        guard !letters.isEmpty else { return }
        let radius = configuration.loopRadius
        let segments = max(configuration.loopSegments, 4)
        var index = 0
        while index < letters.count {
            // A run of the same letter.
            var end = index + 1
            while end < letters.count, letters[end] == letters[index] { end += 1 }
            let letter = Int(letters[index])
            let cx = centreX[letter]
            let cy = centreY[letter]
            x.append(cx)
            y.append(cy)
            if loops, end - index > 1 {
                // The direction the path takes through this key.
                var dx = 0.0
                var dy = 0.0
                let hasPrevious = index > 0
                let hasNext = end < letters.count
                if hasPrevious, hasNext {
                    dx = centreX[Int(letters[end])] - centreX[Int(letters[index - 1])]
                    dy = centreY[Int(letters[end])] - centreY[Int(letters[index - 1])]
                } else if hasPrevious {
                    dx = cx - centreX[Int(letters[index - 1])]
                    dy = cy - centreY[Int(letters[index - 1])]
                } else if hasNext {
                    dx = centreX[Int(letters[end])] - cx
                    dy = centreY[Int(letters[end])] - cy
                }
                var length = norm(dx, dy)
                if length < 1e-9 {
                    dx = 1
                    dy = 0
                    length = 1
                }
                var nx = dy / length
                var ny = -dx / length
                if ny > 0 || (ny == 0 && nx < 0) {
                    nx = -nx
                    ny = -ny
                }
                // The loop starts and ends at the centre; the circle's own centre is one radius
                // along the normal, so the start vector points back the other way.
                for _ in 1..<(end - index) {
                    for step in 1...segments {
                        let angle = 2 * Double.pi * Double(step) / Double(segments)
                        let sx = -nx
                        let sy = -ny
                        let rx = sx * cos(angle) - sy * sin(angle)
                        let ry = sx * sin(angle) + sy * cos(angle)
                        x.append(cx + radius * nx + radius * rx)
                        y.append(cy + radius * ny + radius * ry)
                    }
                }
            }
            index = end
        }
    }

    // MARK: - Geometry

    private static func length(x: [Double], y: [Double]) -> Double {
        var total = 0.0
        for index in 1..<x.count { total += norm(x[index] - x[index - 1], y[index] - y[index - 1]) }
        return total
    }

    /// Resamples a polyline to `count` points equally spaced along its length, in place of
    /// `outX` and `outY`, which must already hold `count` elements.
    private static func resample(x: [Double], y: [Double], count: Int, outX: inout [Double], outY: inout [Double]) {
        let points = x.count
        x.withUnsafeBufferPointer { sourceX in
            y.withUnsafeBufferPointer { sourceY in
                outX.withUnsafeMutableBufferPointer { intoX in
                    outY.withUnsafeMutableBufferPointer { intoY in
                        guard let sx = sourceX.baseAddress, let sy = sourceY.baseAddress,
                            let ox = intoX.baseAddress, let oy = intoY.baseAddress
                        else { return }
                        resample(x: sx, y: sy, points: points, count: count, outX: ox, outY: oy)
                    }
                }
            }
        }
    }

    /// The same over bare memory: `points` vertices in, `count` points out.
    private static func resample(
        x: UnsafePointer<Double>, y: UnsafePointer<Double>, points: Int, count: Int,
        outX: UnsafeMutablePointer<Double>, outY: UnsafeMutablePointer<Double>
    ) {
        guard points > 0 else { return }
        var total = 0.0
        var vertex = 1
        while vertex < points {
            total += norm(x[vertex] - x[vertex - 1], y[vertex] - y[vertex - 1])
            vertex += 1
        }
        guard total > 1e-12, count > 1 else {
            for index in 0..<count {
                outX[index] = x[0]
                outY[index] = y[0]
            }
            return
        }
        let step = total / Double(count - 1)
        var segment = 0
        var segmentStart = 0.0
        var segmentLength = norm(x[1] - x[0], y[1] - y[0])
        var index = 0
        while index < count {
            let target = Double(index) * step
            while segment < points - 2, segmentStart + segmentLength < target {
                segmentStart += segmentLength
                segment += 1
                segmentLength = norm(x[segment + 1] - x[segment], y[segment + 1] - y[segment])
            }
            let t = segmentLength > 0 ? min(max((target - segmentStart) / segmentLength, 0), 1) : 0
            outX[index] = x[segment] + t * (x[segment + 1] - x[segment])
            outY[index] = y[segment] + t * (y[segment + 1] - y[segment])
            index += 1
        }
    }

    /// Centres the path on its bounding box and scales it so the longest side is 1.
    private static func normalise(x: [Double], y: [Double], intoX: inout [Double], intoY: inout [Double]) {
        let count = x.count
        x.withUnsafeBufferPointer { sourceX in
            y.withUnsafeBufferPointer { sourceY in
                intoX.withUnsafeMutableBufferPointer { outX in
                    intoY.withUnsafeMutableBufferPointer { outY in
                        guard let sx = sourceX.baseAddress, let sy = sourceY.baseAddress,
                            let ox = outX.baseAddress, let oy = outY.baseAddress
                        else { return }
                        normalise(x: sx, y: sy, count: count, intoX: ox, intoY: oy)
                    }
                }
            }
        }
    }

    private static func normalise(
        x: UnsafePointer<Double>, y: UnsafePointer<Double>, count: Int, intoX: UnsafeMutablePointer<Double>,
        intoY: UnsafeMutablePointer<Double>
    ) {
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        var index = 0
        while index < count {
            minX = min(minX, x[index])
            maxX = max(maxX, x[index])
            minY = min(minY, y[index])
            maxY = max(maxY, y[index])
            index += 1
        }
        let size = max(maxX - minX, maxY - minY)
        let scale = size > 1e-9 ? 1 / size : 1
        let midX = (minX + maxX) / 2
        let midY = (minY + maxY) / 2
        index = 0
        while index < count {
            intoX[index] = (x[index] - midX) * scale
            intoY[index] = (y[index] - midY) * scale
            index += 1
        }
    }
}
