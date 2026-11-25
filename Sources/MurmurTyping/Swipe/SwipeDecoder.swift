import CoreGraphics
import Foundation

/// Decodes a swipe over the letters page into words, in the manner of SHARK2 (Kristensson and
/// Zhai, UIST 2004), written from the published description.
///
/// A swipe is a path of touch points in the keyboard view's coordinates (the space of
/// `KeyboardMetrics` frames). Inside, every distance is in key pitches (a letter key's width plus
/// the gap), so the numbers mean the same on any phone. The steps:
///
/// 1. The path is resampled to `resamplePoints` equidistant points.
/// 2. Only words that start on one of the keys nearest the first point, end on one of the keys
///    nearest the last, and have an ideal path (the polyline through the key centres, with a
///    small loop for each doubled letter) of about the gesture's length are scored. The word
///    model's start and end buckets make the first cut free (`TypingModel.ids(first:last:)`).
/// 3. Each survivor's ideal path, resampled the same way, is compared with the gesture on two
///    channels: location (the points laid on the keys, ends weighted more) and shape (both
///    paths scaled to one unit and centred, so a swipe that is too small or too wide still has
///    the right outline). Each distance becomes a Gaussian log-likelihood, and the language
///    model adds λ · ln P(word | previous).
/// 4. The best `rerankCount` get a dynamic-time-warping location score in place of part of the
///    plain one, which forgives a gesture that dwells on one key and rushes another.
///
/// The decoder is immutable and holds no word list: words are read from the mapped model per
/// call, and the per-call scratch is a few kilobytes.
@inline(__always) private func norm(_ dx: Double, _ dy: Double) -> Double {
    (dx * dx + dy * dy).squareRoot()
}

public struct SwipeDecoder: Sendable {
    /// Every tunable of the decoder. The starting values are the milestone's (σ location 0.5
    /// pitch, σ shape 0.25, 32 points, 3 keys at each end, length within 30%, 80 re-ranked, loop
    /// radius 0.3, band 6, ends weighing 3 to 1), and the benchmark (`SwipeBenchTests`, 2,000
    /// words, 2026-11-25) left every one of them where it was: the surface is flat, and each
    /// neighbour tried scored the same or up to 1.3 points worse in top-1 (a locationEvidence of
    /// 8 or 20, shapeEvidence 6 or 20, λ 0.7 or 1.4, end weights 1 or 5, a loop radius of 0.2 or
    /// 0.4, no warping, all warping). What the benchmark did add is the likelihood scale
    /// (`locationEvidence` and `shapeEvidence`, 12 each: with a plain mean distance the language
    /// term outweighs the spatial one) and three cuts that exist for speed, none of which changed
    /// top-1: the coarse test, the key reach and the re-rank margin (25 nats first, 12 now: the
    /// decode's 99th percentile in a debug build fell from 33 ms to 14 ms, top-1 unchanged).
    /// The synthetic noise is smoother than iid per-point noise; real swipes may want other values.
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
        public var startKeyCount = 3
        /// Keys near the last point whose letters may end the word.
        public var endKeyCount = 3
        /// A word's ideal path may differ from the gesture's length by this fraction of it.
        public var lengthTolerance = 0.30
        /// Radius, in pitches, of the loop drawn for a doubled letter. Small, so a swipe that
        /// makes no loop at all is not punished hard for the doubled letter it did not mark.
        public var loopRadius = 0.3
        /// Points per loop in the ideal path.
        public var loopSegments = 12
        /// A word is dropped before its path is built when its ideal path, sampled at the ends,
        /// the quarters and the middle, lies on average farther than this many pitches from the
        /// gesture at those five points. A cheap test that spares most words the full scoring.
        public var coarseLimitPitches = 1.1
        /// Keys farther than this many pitches from the first or last point do not count among
        /// the nearest keys, so a point in the middle of a key does not also admit a key two
        /// keys away just because three were asked for.
        public var keyReachPitches = 1.2
        /// Gesture shorter than this many pitches in total decodes to nothing.
        public var minimumLengthPitches = 0.25
        /// Words shorter than this are not offered; a swipe of one letter is a tap.
        public var minimumLetters = 2
        /// Spread of the location channel, in pitches.
        public var sigmaLocation = 0.5
        /// Spread of the shape channel, in units of the path's longest side.
        public var sigmaShape = 0.25
        /// How many independent points the location distance stands for. The mean distance is a
        /// per-point figure; a likelihood needs the sum over points, but neighbouring points of a
        /// wobbly path are not independent, so this is well below `resamplePoints`.
        public var locationEvidence = 12.0
        /// The same for the shape channel.
        public var shapeEvidence = 12.0
        /// How much more the first and last points weigh in the location channel than the
        /// middle, rising linearly toward both ends.
        public var endWeightRatio = 3.0
        /// Weight of the language term, λ.
        public var languageWeight = 1.0
        /// The weight of the unigram when a pair is not stored (stupid backoff, as `TapDecoder`).
        public var backoffWeight = 0.4
        /// ln P of a lexicon word that is not in the model (as `TapDecoder`).
        public var lexiconLogPrior = -12.0
        /// How many of the best words by the first score get the warping score.
        public var rerankCount = 80
        /// A word more than this many nats behind the best so far is dropped before the re-rank:
        /// the warped score moves a word's location term by a fraction of its size, never as far
        /// as this. It lets the scoring of the unlikelier words stop early.
        public var rerankMargin = 12.0
        /// Half-width of the warping band, in resampled points.
        public var warpBand = 6
        /// The share of the location log-likelihood replaced by the warped one in the re-rank.
        public var warpWeight = 0.5

        public init() {}

        /// The values the benchmark settled on.
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
        guard isUsable, limit > 0, path.count >= 2 else { return [] }
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
        guard rawX.count >= 2 else { return [] }
        let gestureLength = Self.length(x: rawX, y: rawY)
        guard gestureLength >= configuration.minimumLengthPitches else { return [] }

        var gestureX = Array(repeating: 0.0, count: count)
        var gestureY = Array(repeating: 0.0, count: count)
        Self.resample(x: rawX, y: rawY, count: count, outX: &gestureX, outY: &gestureY)
        var gestureShapeX = Array(repeating: 0.0, count: count)
        var gestureShapeY = Array(repeating: 0.0, count: count)
        Self.normalise(x: gestureX, y: gestureY, intoX: &gestureShapeX, intoY: &gestureShapeY)

        // Where the gesture is at the ends, the quarters and the middle, for the coarse test.
        let probeIndices = [0, count / 4, (count - 1) / 2, (3 * (count - 1)) / 4, count - 1]
        let probeFractions = probeIndices.map { Double($0) / Double(count - 1) }
        let probeX = probeIndices.map { gestureX[$0] }
        let probeY = probeIndices.map { gestureY[$0] }

        let startKeys = nearestKeys(toX: rawX[0], y: rawY[0], count: configuration.startKeyCount)
        let endKeys = nearestKeys(
            toX: rawX[rawX.count - 1], y: rawY[rawY.count - 1], count: configuration.endKeyCount)
        let shortest = gestureLength * (1 - configuration.lengthTolerance)
        let longest = gestureLength * (1 + configuration.lengthTolerance)

        let gesture = Gesture(
            x: gestureX, y: gestureY, shapeX: gestureShapeX, shapeY: gestureShapeY,
            probeFractions: probeFractions, probeX: probeX, probeY: probeY,
            shortest: gestureLength * (1 - configuration.lengthTolerance),
            longest: gestureLength * (1 + configuration.lengthTolerance))
        var search = Search(
            count: count, keep: max(configuration.rerankCount, limit), margin: configuration.rerankMargin)
        let hasLexicon = !lexicon.entries.isEmpty

        // Words of the model, by the start and end buckets. The length cut comes first and reads
        // the word once; everything after it is for the few that pass.
        // The likeliest buckets first, so the cut-off is a good one early.
        var buckets: [(start: Int, end: Int, distance: Double)] = []
        for start in startKeys {
            for end in endKeys {
                buckets.append((
                    start, end,
                    norm(centreX[start] - rawX[0], centreY[start] - rawY[0])
                        + norm(centreX[end] - rawX[rawX.count - 1], centreY[end] - rawY[rawY.count - 1])))
            }
        }
        buckets.sort { $0.distance < $1.distance }
        do {
            for bucket in buckets {
                let ids = model.ids(
                    first: Character(UnicodeScalar(Self.letterA + UInt8(bucket.start))),
                    last: Character(UnicodeScalar(Self.letterA + UInt8(bucket.end))))
                for id in ids {
                    let word = model.word(id)
                    guard let ideal = idealLength(of: word), ideal >= gesture.shortest, ideal <= gesture.longest
                    else { continue }
                    var language = configuration.languageWeight * logPrior(id, previous: previous)
                    var display: String?
                    if hasLexicon, let entry = lexicon.entry(for: word) {
                        language += entry.bonus
                        display = entry.display
                    }
                    // The spatial terms are at most zero, so a word whose language score alone
                    // cannot reach the current cut-off is out.
                    if language <= search.cutoff { continue }
                    Self.letters(of: word, into: &search.letters)
                    consider(
                        &search, gesture, id: id, lexiconWord: nil, display: display, language: language,
                        length: ideal)
                }
            }
        }

        // Words of the lexicon that the model does not know.
        for (folded, entry) in lexicon.entries.sorted(by: { $0.key < $1.key }) {
            guard model.id(of: folded) == nil, let word = Self.letters(of: folded),
                word.count >= max(configuration.minimumLetters, 2),
                startKeys.contains(Int(word[0])), endKeys.contains(Int(word[word.count - 1]))
            else { continue }
            search.letters = word
            let ideal = idealLength(search.letters)
            guard ideal >= gesture.shortest, ideal <= gesture.longest else { continue }
            let language = configuration.languageWeight * configuration.lexiconLogPrior + entry.bonus
            consider(
                &search, gesture, id: -1, lexiconWord: folded, display: entry.display, language: language,
                length: ideal)
        }
        let best = search.best
        var polyX = search.polyX
        var polyY = search.polyY
        var templateX = search.templateX
        var templateY = search.templateY

        // The re-rank: warp the location channel for everything kept.
        var rescored: [Candidate] = []
        rescored.reserveCapacity(best.count)
        for item in best {
            let wordLetters: [UInt8]
            if let lexiconWord = item.lexiconWord {
                wordLetters = Self.letters(of: lexiconWord) ?? []
            } else {
                wordLetters = Self.letters(of: model.word(item.id)) ?? []
            }
            buildIdealPath(wordLetters, x: &polyX, y: &polyY)
            Self.resample(x: polyX, y: polyY, count: count, outX: &templateX, outY: &templateY)
            let warped = warpedDistance(gestureX, gestureY, templateX, templateY)
            let warpedLL = Self.logLikelihood(
                distance: warped, sigma: configuration.sigmaLocation, evidence: configuration.locationEvidence)
            let location = (1 - configuration.warpWeight) * item.locationLL + configuration.warpWeight * warpedLL
            let text = item.display ?? (item.lexiconWord ?? model.word(item.id))
            rescored.append(
                Candidate(
                    text: text, id: item.lexiconWord == nil ? item.id : nil,
                    score: location + item.shapeLL + item.languageScore))
        }
        rescored.sort { $0.score > $1.score }
        return Array(rescored.prefix(limit))
    }

    // MARK: - Search

    /// What the gesture offers every word, built once per decode.
    private struct Gesture {
        let x: [Double]
        let y: [Double]
        let shapeX: [Double]
        let shapeY: [Double]
        let probeFractions: [Double]
        let probeX: [Double]
        let probeY: [Double]
        /// The ideal path lengths a word may have.
        let shortest: Double
        let longest: Double
    }

    /// A word that passed the first score, kept for the re-rank.
    private struct Scored {
        var id: Int
        var lexiconWord: String?
        var display: String?
        var score: Double
        var locationLL: Double
        var shapeLL: Double
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
        var letters: [UInt8] = []
        var polyX: [Double] = []
        var polyY: [Double] = []
        var templateX: [Double]
        var templateY: [Double]
        var templateShapeX: [Double]
        var templateShapeY: [Double]

        init(count: Int, keep: Int, margin: Double) {
            self.keep = keep
            self.margin = margin
            best.reserveCapacity(keep + 1)
            letters.reserveCapacity(24)
            polyX.reserveCapacity(64)
            polyY.reserveCapacity(64)
            templateX = Array(repeating: 0, count: count)
            templateY = Array(repeating: 0, count: count)
            templateShapeX = Array(repeating: 0, count: count)
            templateShapeY = Array(repeating: 0, count: count)
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

    /// Scores the word whose letters are in `search.letters` and keeps it if it is among the best.
    private func consider(
        _ search: inout Search, _ gesture: Gesture, id: Int, lexiconWord: String?, display: String?,
        language: Double, length: Double
    ) {
        guard coarseDistance(search.letters, length: length, gesture: gesture) <= configuration.coarseLimitPitches
        else { return }
        buildIdealPath(search.letters, x: &search.polyX, y: &search.polyY)
        // The farthest the weighted mean distance may go before this word cannot reach the
        // cut-off even with a perfect shape, which is the exact bound the early stop uses.
        var farthest = Double.infinity
        if search.cutoff > -Double.infinity {
            farthest = configuration.sigmaLocation
                * (2 * max(language - search.cutoff, 0) / configuration.locationEvidence).squareRoot()
        }
        guard
            let location = locate(
                x: search.polyX, y: search.polyY, gesture: gesture, farthest: farthest,
                outX: &search.templateX, outY: &search.templateY)
        else { return }
        Self.normalise(
            x: search.templateX, y: search.templateY, intoX: &search.templateShapeX,
            intoY: &search.templateShapeY)
        let shape = Self.meanDistance(
            gesture.shapeX, gesture.shapeY, search.templateShapeX, search.templateShapeY)
        let locationLL = Self.logLikelihood(
            distance: location, sigma: configuration.sigmaLocation, evidence: configuration.locationEvidence)
        let shapeLL = Self.logLikelihood(
            distance: shape, sigma: configuration.sigmaShape, evidence: configuration.shapeEvidence)
        let score = locationLL + shapeLL + language
        guard score > search.cutoff else { return }
        search.insert(
            Scored(
                id: id, lexiconWord: lexiconWord, display: display, score: score, locationLL: locationLL,
                shapeLL: shapeLL, languageScore: language))
    }

    /// Resamples the polyline into `outX`, `outY` and returns the weighted mean distance to the
    /// gesture, as `Self.resample` and `locationDistance` do together, but gives up and returns
    /// nil as soon as the running sum passes `farthest`: the later terms only add to it.
    private func locate(
        x: [Double], y: [Double], gesture: Gesture, farthest: Double, outX: inout [Double], outY: inout [Double]
    ) -> Double? {
        let count = gesture.x.count
        let total = x.count > 1 ? Self.length(x: x, y: y) : 0
        guard total > 1e-12 else {
            // A path with no length sits on one point.
            for index in 0..<count {
                outX[index] = x[0]
                outY[index] = y[0]
            }
            let distance = locationDistance(gesture.x, gesture.y, outX, outY)
            return distance <= farthest ? distance : nil
        }
        let step = total / Double(count - 1)
        var segment = 0
        var segmentStart = 0.0
        var segmentLength = norm(x[1] - x[0], y[1] - y[0])
        var sum = 0.0
        for index in 0..<count {
            let target = Double(index) * step
            while segment < x.count - 2, segmentStart + segmentLength < target {
                segmentStart += segmentLength
                segment += 1
                segmentLength = norm(x[segment + 1] - x[segment], y[segment + 1] - y[segment])
            }
            let t = segmentLength > 0 ? min(max((target - segmentStart) / segmentLength, 0), 1) : 0
            let px = x[segment] + t * (x[segment + 1] - x[segment])
            let py = y[segment] + t * (y[segment + 1] - y[segment])
            outX[index] = px
            outY[index] = py
            sum += weights[index] * norm(gesture.x[index] - px, gesture.y[index] - py)
            if sum > farthest { return nil }
        }
        return sum
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

    /// A Gaussian log-likelihood of a mean distance, scaled by the number of points it stands for.
    private static func logLikelihood(distance: Double, sigma: Double, evidence: Double) -> Double {
        let z = distance / sigma
        return -0.5 * evidence * z * z
    }

    /// The weighted mean distance between the gesture and the ideal path, point for point.
    private func locationDistance(_ ax: [Double], _ ay: [Double], _ bx: [Double], _ by: [Double]) -> Double {
        var sum = 0.0
        for index in 0..<ax.count {
            sum += weights[index] * norm(ax[index] - bx[index], ay[index] - by[index])
        }
        return sum
    }

    private static func meanDistance(_ ax: [Double], _ ay: [Double], _ bx: [Double], _ by: [Double]) -> Double {
        var sum = 0.0
        for index in 0..<ax.count { sum += norm(ax[index] - bx[index], ay[index] - by[index]) }
        return sum / Double(ax.count)
    }

    /// Dynamic time warping between the two resampled paths, inside a diagonal band: the mean
    /// distance along the cheapest alignment.
    private func warpedDistance(_ ax: [Double], _ ay: [Double], _ bx: [Double], _ by: [Double]) -> Double {
        let n = ax.count
        let band = max(configuration.warpBand, 1)
        let infinity = Double.infinity
        var cost = Array(repeating: infinity, count: n * n)
        var steps = Array(repeating: 0, count: n * n)
        for i in 0..<n {
            let low = max(0, i - band)
            let high = min(n - 1, i + band)
            for j in low...high {
                let d = norm(ax[i] - bx[j], ay[i] - by[j])
                if i == 0 && j == 0 {
                    cost[0] = d
                    steps[0] = 1
                    continue
                }
                var bestCost = infinity
                var bestSteps = 0
                if i > 0, j > 0, cost[(i - 1) * n + j - 1] < bestCost {
                    bestCost = cost[(i - 1) * n + j - 1]
                    bestSteps = steps[(i - 1) * n + j - 1]
                }
                if i > 0, cost[(i - 1) * n + j] < bestCost {
                    bestCost = cost[(i - 1) * n + j]
                    bestSteps = steps[(i - 1) * n + j]
                }
                if j > 0, cost[i * n + j - 1] < bestCost {
                    bestCost = cost[i * n + j - 1]
                    bestSteps = steps[i * n + j - 1]
                }
                guard bestCost < infinity else { continue }
                cost[i * n + j] = bestCost + d
                steps[i * n + j] = bestSteps + 1
            }
        }
        let last = (n - 1) * n + n - 1
        guard cost[last] < infinity, steps[last] > 0 else { return infinity }
        return cost[last] / Double(steps[last])
    }

    /// The mean distance between the gesture's probe points and the points of the word's ideal
    /// path at the same shares of its length. A loop counts for its circumference but is treated as
    /// standing still on its key, which is wrong by at most a loop's diameter and needs no path.
    private func coarseDistance(_ letters: [UInt8], length: Double, gesture: Gesture) -> Double {
        let fractions = gesture.probeFractions
        let loop = 2 * Double.pi * configuration.loopRadius
        var total = 0.0
        var probe = 0
        var walked = 0.0
        var index = 0
        while probe < fractions.count {
            let target = fractions[probe] * length
            // The segment from letter index - 1 to index, or the whole path's end.
            let px: Double
            let py: Double
            if index == 0 {
                index = 1
                continue
            } else if index >= letters.count {
                px = centreX[Int(letters[letters.count - 1])]
                py = centreY[Int(letters[letters.count - 1])]
            } else {
                let a = Int(letters[index - 1])
                let b = Int(letters[index])
                let segment = a == b ? loop : pairDistance[a * 26 + b]
                if walked + segment < target {
                    walked += segment
                    index += 1
                    continue
                }
                let t = segment > 0 && a != b ? (target - walked) / segment : 0
                px = centreX[a] + t * (centreX[b] - centreX[a])
                py = centreY[a] + t * (centreY[b] - centreY[a])
            }
            total += norm(px - gesture.probeX[probe], py - gesture.probeY[probe])
            // The remaining probes can only add to the sum, so a word already over the limit is out.
            if total > configuration.coarseLimitPitches * Double(fractions.count) { return .infinity }
            probe += 1
        }
        return total / Double(fractions.count)
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

    /// Fills `result` as `letters(of:)` does; leaves it empty for a word with another byte.
    private static func letters(of word: String, into result: inout [UInt8]) {
        result.removeAll(keepingCapacity: true)
        for byte in word.utf8 {
            if byte >= letterA, byte < letterA + 26 {
                result.append(byte - letterA)
            } else if byte != apostrophe {
                result.removeAll(keepingCapacity: true)
                return
            }
        }
    }

    /// The length in pitches of a word's ideal path, read straight off its bytes; nil for a word
    /// with another character or fewer than two letters.
    private func idealLength(of word: String) -> Double? {
        let loop = 2 * Double.pi * configuration.loopRadius
        var total = 0.0
        var previous = -1
        var letters = 0
        for byte in word.utf8 {
            if byte == Self.apostrophe { continue }
            guard byte >= Self.letterA, byte < Self.letterA + 26 else { return nil }
            let letter = Int(byte - Self.letterA)
            if previous >= 0 { total += previous == letter ? loop : pairDistance[previous * 26 + letter] }
            previous = letter
            letters += 1
        }
        return letters >= max(configuration.minimumLetters, 2) ? total : nil
    }

    /// The length in pitches of a word's ideal path, without building it.
    private func idealLength(_ letters: [UInt8]) -> Double {
        var total = 0.0
        guard letters.count > 1 else { return total }
        let loop = 2 * Double.pi * configuration.loopRadius
        for index in 1..<letters.count {
            let a = Int(letters[index - 1])
            let b = Int(letters[index])
            total += a == b ? loop : pairDistance[a * 26 + b]
        }
        return total
    }

    /// The polyline through the key centres of `letters`. A doubled letter adds a loop: a circle
    /// of `loopRadius` that passes through the key's centre and bulges to the side of the path's
    /// direction there, upward when it can, so the same word always has the same ideal path.
    private func buildIdealPath(_ letters: [UInt8], x: inout [Double], y: inout [Double]) {
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
            if end - index > 1 {
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
        let total = x.count > 1 ? length(x: x, y: y) : 0
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
        for index in 0..<count {
            let target = Double(index) * step
            while segment < x.count - 2, segmentStart + segmentLength < target {
                segmentStart += segmentLength
                segment += 1
                segmentLength = norm(x[segment + 1] - x[segment], y[segment + 1] - y[segment])
            }
            let t = segmentLength > 0 ? min(max((target - segmentStart) / segmentLength, 0), 1) : 0
            outX[index] = x[segment] + t * (x[segment + 1] - x[segment])
            outY[index] = y[segment] + t * (y[segment + 1] - y[segment])
        }
    }

    /// Centres the path on its bounding box and scales it so the longest side is 1.
    private static func normalise(x: [Double], y: [Double], intoX: inout [Double], intoY: inout [Double]) {
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for index in 0..<x.count {
            minX = min(minX, x[index])
            maxX = max(maxX, x[index])
            minY = min(minY, y[index])
            maxY = max(maxY, y[index])
        }
        let size = max(maxX - minX, maxY - minY)
        let scale = size > 1e-9 ? 1 / size : 1
        let midX = (minX + maxX) / 2
        let midY = (minY + maxY) / 2
        for index in 0..<x.count {
            intoX[index] = (x[index] - midX) * scale
            intoY[index] = (y[index] - midY) * scale
        }
    }
}
