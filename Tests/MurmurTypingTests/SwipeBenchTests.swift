import CoreGraphics
import Foundation
import Testing

@testable import MurmurTyping

/// The swipe benchmark: synthetic swipes for the most frequent words, decoded one at a time.
///
/// Skipped unless `MURMUR_TYPING_BENCH=1`. The generator is deliberately not the decoder's own
/// model, so tuning the decoder cannot make the benchmark easier:
///
/// - the finger's path through the key centres has its corners rounded (a moving average along
///   the path, as a real finger cuts them),
/// - a doubled letter gets a loop of a random radius and orientation, where the decoder assumes
///   one fixed shape,
/// - the noise is smooth along the path: a Gaussian of σ 0.3 pitch per axis at a control point
///   each pitch of arc length, joined by a smooth curve, so a swipe wanders as a hand does and
///   does not jitter point by point,
/// - one constant offset of 0.15 pitch in a random direction per swipe, a hand held off centre,
/// - touch points arrive at uneven spacing.
///
/// The seed is fixed, so every run sees the same swipes. Dictation of the number of words and
/// tuning without a rebuild: `MURMUR_SWIPE_WORDS` (default 2000) and
/// `MURMUR_TYPING_TUNE="sigmaLocation=0.5,warpWeight=0.4,..."` (see `apply`).
///
/// Gate: top-1 of at least 90% and a 99th percentile decode time under 15 ms. The timing is of
/// whichever build runs the test; a debug build (the default for `swift test`) is the slow one.
/// The suite is serialized so the two benchmarks never time each other. This one is the easy
/// case: frequent words, no corner cutting beyond a moving average, ends within noise of the
/// keys and no context. `sloppySentences` below is the hard one.
@Suite(.serialized) struct SwipeBenchTests {
    static let enabled = ProcessInfo.processInfo.environment["MURMUR_TYPING_BENCH"] == "1"

    static let requiredTop1 = 0.90
    /// Held-out half of the sloppy sentences, with context. The decoder before the sloppy
    /// benchmark scored 0.71 on it; the noise model is a guess, so this is a floor for regressions.
    static let requiredSloppyTop1 = 0.80
    static let allowedP99Milliseconds = 15.0

    @Test(.enabled(if: SwipeBenchTests.enabled))
    func synthetic() throws {
        let environment = ProcessInfo.processInfo.environment
        var configuration = SwipeDecoder.Configuration.tuned
        if let tune = environment["MURMUR_TYPING_TUNE"] { Self.apply(tune, to: &configuration) }
        let wordCount = Int(environment["MURMUR_SWIPE_WORDS"] ?? "") ?? 2000

        let fixture = try SwipeFixture(configuration: configuration)
        let words = Self.frequentWords(in: fixture.model, count: wordCount)
        #expect(words.count == wordCount)
        let pitch = fixture.decoder.pitch
        var random = AutocorrectReplayTests.SplitMix64(seed: 0x5748_4950_45)

        var top1 = 0
        var top3 = 0
        var milliseconds: [Double] = []
        var misses: [(word: String, got: [String])] = []
        var byLength: [Int: (hits: Int, total: Int)] = [:]
        let clock = ContinuousClock()
        for word in words {
            let path = Self.synthesise(
                word, fixture: fixture, pitch: pitch, random: &random)
            var candidates: [SwipeDecoder.Candidate] = []
            let elapsed = clock.measure {
                candidates = fixture.decoder.decode(path: path, times: nil, previous: nil, limit: 3)
            }
            milliseconds.append(
                Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            let hit = candidates.first?.text == word
            if hit { top1 += 1 } else if misses.count < 30 { misses.append((word, candidates.map(\.text))) }
            if candidates.contains(where: { $0.text == word }) { top3 += 1 }
            let key = min(word.count, 9)
            byLength[key, default: (0, 0)].total += 1
            if hit { byLength[key, default: (0, 0)].hits += 1 }
        }

        milliseconds.sort()
        func percentile(_ fraction: Double) -> Double {
            milliseconds[min(Int(Double(milliseconds.count) * fraction), milliseconds.count - 1)]
        }
        let n = Double(words.count)
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        print("swipe bench (\(build) build): \(words.count) words, seed fixed")
        print(String(format: "  top-1 %.2f%%  top-3 %.2f%%", 100 * Double(top1) / n, 100 * Double(top3) / n))
        print(String(format: "  decode ms: p50 %.2f  p90 %.2f  p99 %.2f  max %.2f",
            percentile(0.5), percentile(0.9), percentile(0.99), milliseconds.last ?? 0))
        let lengths = byLength.keys.sorted().map { key in
            String(format: "%@: %.0f%% of %d", key == 9 ? "9+" : String(key),
                   100 * Double(byLength[key]!.hits) / Double(byLength[key]!.total), byLength[key]!.total)
        }
        print("  by length: " + lengths.joined(separator: ", "))
        for miss in misses.prefix(20) { print("  miss \(miss.word): \(miss.got.joined(separator: ", "))") }

        #expect(Double(top1) / n >= Self.requiredTop1)
        #expect(percentile(0.99) < Self.allowedP99Milliseconds)
    }

    // MARK: - Sloppy sentences

    /// The harsher benchmark: whole sentences from `replay-sentences.txt`, swiped one word at a
    /// time with the word before passed as context (nil at a sentence start), under the "sloppy"
    /// human model in `SloppySwipe`. The noise model is a guess at human behaviour, not a
    /// measurement: nobody has recorded real swipes for it yet.
    ///
    /// Sentences are numbered from 1. The decoder was tuned on the even-numbered ones; the
    /// odd-numbered ones are the held-out half and are the figures to believe. Words of one letter
    /// are taps, not swipes, and words the model lacks cannot be decoded; neither is scored, but a
    /// one-letter word is still the previous word of the next.
    @Test(.enabled(if: SwipeBenchTests.enabled))
    func sloppySentences() throws {
        let environment = ProcessInfo.processInfo.environment
        var configuration = SwipeDecoder.Configuration.tuned
        if let tune = environment["MURMUR_TYPING_TUNE"] { Self.apply(tune, to: &configuration) }

        let fixture = try SwipeFixture(configuration: configuration)
        let pitch = fixture.decoder.pitch
        let model = fixture.model
        var random = AutocorrectReplayTests.SplitMix64(seed: SloppySwipe.seed)

        struct Item {
            let word: String
            let previous: Int?
            let path: [CGPoint]
            let held: Bool
        }
        var items: [Item] = []
        var unknown = 0
        for (index, sentence) in try AutocorrectReplayTests.sentences().enumerated() {
            let held = (index + 1) % 2 == 1
            var previous: Int?
            for word in sentence.split(separator: " ").map(String.init) {
                defer { previous = model.id(of: word) }
                guard word.count >= 2 else { continue }
                guard model.id(of: word) != nil else {
                    unknown += 1
                    continue
                }
                let path = SloppySwipe.synthesise(word, fixture: fixture, pitch: pitch, random: &random)
                items.append(Item(word: word, previous: previous, path: path, held: held))
            }
        }

        struct Tally {
            var top1 = 0
            var top3 = 0
            var total = 0
            var line: String {
                String(format: "top-1 %5.1f%%  top-3 %5.1f%%  (n %d)", 100 * Double(top1) / Double(max(total, 1)),
                    100 * Double(top3) / Double(max(total, 1)), total)
            }
        }
        struct Outcome { var first: String?; var top: [String] }

        var scans: [SwipeDecoder.ScanStats] = []
        func run(_ decoder: SwipeDecoder, context: Bool) -> (outcomes: [Outcome], milliseconds: [Double]) {
            var outcomes: [Outcome] = []
            var milliseconds: [Double] = []
            var statsList: [SwipeDecoder.ScanStats] = []
            let clock = ContinuousClock()
            for item in items {
                var candidates: [SwipeDecoder.Candidate] = []
                var stats = SwipeDecoder.ScanStats()
                let elapsed = clock.measure {
                    candidates = decoder.decode(
                        path: item.path, previous: context ? item.previous : nil, lexicon: .empty, limit: 3,
                        stats: &stats)
                }
                statsList.append(stats)
                milliseconds.append(
                    Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                outcomes.append(Outcome(first: candidates.first?.text, top: candidates.map(\.text)))
            }
            if context { scans = statsList }
            return (outcomes, milliseconds)
        }
        func tally(_ outcomes: [Outcome], held: Bool?, where keep: (Item) -> Bool = { _ in true }) -> Tally {
            var result = Tally()
            for (item, outcome) in zip(items, outcomes) where (held == nil || item.held == held!) && keep(item) {
                result.total += 1
                if outcome.first == item.word { result.top1 += 1 }
                if outcome.top.contains(item.word) { result.top3 += 1 }
            }
            return result
        }

        let tunedNo = run(fixture.decoder, context: false)
        let tunedWith = run(fixture.decoder, context: true)

        print("sloppy sentence bench: \(items.count) swipes (\(unknown) words not in the model skipped), seed fixed")
        print("  noise model (a guess, not measured): \(SloppySwipe.summary)")
        for (name, outcomes) in [
            ("current,   no context ", tunedNo.outcomes), ("current,   context    ", tunedWith.outcomes),
        ] {
            print("  \(name) tune half: \(tally(outcomes, held: false).line) | held-out half: \(tally(outcomes, held: true).line)")
        }
        var flipsGained = 0, flipsLost = 0
        for (index, item) in items.enumerated() where item.held {
            let without = tunedNo.outcomes[index].first == item.word
            let with = tunedWith.outcomes[index].first == item.word
            if with && !without { flipsGained += 1 }
            if without && !with { flipsLost += 1 }
        }
        print("  held-out: the previous word fixes \(flipsGained) words and breaks \(flipsLost)")

        // By word length, held-out half, current configuration.
        for (title, outcomes) in [("no context", tunedNo.outcomes), ("context", tunedWith.outcomes)] {
            var parts: [String] = []
            for length in 2...9 {
                let t = tally(outcomes, held: true) { length == 9 ? $0.word.count >= 9 : $0.word.count == length }
                if t.total > 0 {
                    parts.append(String(format: "%@: %.0f%% (%d)", length == 9 ? "9+" : String(length),
                        100 * Double(t.top1) / Double(t.total), t.total))
                }
            }
            print("  held-out top-1 by length, \(title): " + parts.joined(separator: ", "))
        }

        // Which cut removes the intended word, for the current configuration.
        for (title, held) in [("tune half", false), ("held-out half", true)] {
            var stages: [String: Int] = [:]
            var total = 0
            var scoredButLost = 0
            for (index, item) in items.enumerated() where item.held == held {
                total += 1
                let stage = fixture.decoder.pruneStage(of: item.word, path: item.path)
                stages[stage.rawValue, default: 0] += 1
                if stage == .survives, tunedWith.outcomes[index].first != item.word { scoredButLost += 1 }
            }
            func rate(_ key: String) -> String { String(format: "%.1f%%", 100 * Double(stages[key] ?? 0) / Double(total)) }
            print("  pruned before scoring, \(title): end keys \(rate("endKeys")), length \(rate("length")), key screen \(rate("screen")); reaches scoring \(rate("survives")), of which \(scoredButLost) lose")
        }

        // How far the path's ends land from the intended first and last keys, in pitches: what the
        // key reach and the bucket cut must cover.
        var startMiss: [Double] = [], endMiss: [Double] = [], bothMiss: [Double] = []
        for item in items {
            let letters = Array(item.word.filter { $0 != "'" })
            let a = fixture.centre(letters[0]), b = fixture.centre(letters[letters.count - 1])
            let ds = hypot(item.path[0].x - a.x, item.path[0].y - a.y) / pitch
            let de = hypot(item.path[item.path.count - 1].x - b.x, item.path[item.path.count - 1].y - b.y) / pitch
            startMiss.append(ds)
            endMiss.append(de)
            bothMiss.append(ds + de)
        }
        func quantiles(_ values: [Double]) -> String {
            let v = values.sorted()
            return [0.5, 0.9, 0.95, 0.99].map { String(format: "%.2f", v[min(Int(Double(v.count) * $0), v.count - 1)]) }
                .joined(separator: " / ")
        }
        print("  intended end distance in pitches, p50/p90/p95/p99: start \(quantiles(startMiss)), end \(quantiles(endMiss)), sum \(quantiles(bothMiss))")

        let sorted = tunedWith.milliseconds.sorted()
        func percentile(_ fraction: Double) -> Double { sorted[min(Int(Double(sorted.count) * fraction), sorted.count - 1)] }
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        print(String(format: "  decode ms (%@ build, current, context): p50 %.2f  p90 %.2f  p99 %.2f  max %.2f",
            build, percentile(0.5), percentile(0.9), percentile(0.99), sorted.last ?? 0))

        func counts(_ pick: (SwipeDecoder.ScanStats) -> Int) -> String {
            let v = scans.map(pick).sorted()
            return String(format: "p50 %d / p90 %d / p99 %d", v[v.count / 2], v[v.count * 9 / 10], v[min(v.count * 99 / 100, v.count - 1)])
        }
        print("  words per decode: read \(counts { $0.scanned }), length \(counts { $0.lengthPassed }), screen \(counts { $0.screenPassed }); budget hit \(scans.filter(\.budgetHit).count) times")

        var shown = 0
        for (index, item) in items.enumerated() where item.held && tunedWith.outcomes[index].first != item.word {
            guard shown < 30 else { break }
            let stage = fixture.decoder.pruneStage(of: item.word, path: item.path)
            print("  miss \(item.word) -> \(tunedWith.outcomes[index].top.joined(separator: ", ")) [\(stage.rawValue)]")
            shown += 1
        }

        // Gates: the held-out half with context (what the keyboard sends) and the decode time.
        let held = tally(tunedWith.outcomes, held: true)
        #expect(Double(held.top1) / Double(max(held.total, 1)) >= Self.requiredSloppyTop1)
        #expect(percentile(0.99) < Self.allowedP99Milliseconds)
    }

    // MARK: - Words

    /// The most frequent words of two or more letters, letters only (a contraction's apostrophe
    /// has no key), likeliest first.
    static func frequentWords(in model: TypingModel, count: Int) -> [String] {
        var ranked: [(id: Int, logP: Float)] = []
        for id in 0..<model.wordCount {
            let word = model.word(id)
            guard word.utf8.count >= 2, word.utf8.allSatisfy({ $0 >= 97 && $0 <= 122 }) else { continue }
            ranked.append((id, model.unigram(id)))
        }
        ranked.sort { $0.logP != $1.logP ? $0.logP > $1.logP : $0.id < $1.id }
        return ranked.prefix(count).map { model.word($0.id) }
    }

    // MARK: - Synthetic swipes

    /// One swipe for `word`: the points a touch might report, in keyboard coordinates.
    static func synthesise(
        _ word: String, fixture: SwipeFixture, pitch: Double, random: inout AutocorrectReplayTests.SplitMix64
    ) -> [CGPoint] {
        // Waypoints in pitch units, with a loop of its own shape at each doubled letter.
        var waypoints: [(x: Double, y: Double)] = []
        let letters = Array(word)
        for (index, letter) in letters.enumerated() {
            let centre = fixture.centre(letter)
            let cx = Double(centre.x) / pitch, cy = Double(centre.y) / pitch
            if index > 0, letters[index - 1] == letter {
                let radius = Double.random(in: 0.2...0.4, using: &random)
                let heading = Double.random(in: 0..<(2 * .pi), using: &random)
                for step in 1...10 {
                    let angle = 2 * Double.pi * Double(step) / 10
                    waypoints.append((
                        cx + radius * (cos(heading) - cos(heading + angle)),
                        cy + radius * (sin(heading) - sin(heading + angle))))
                }
            } else {
                waypoints.append((cx, cy))
            }
        }

        // Dense path along the waypoints, then corners rounded by a moving average over a
        // quarter pitch each side. The ends stay put: the window shrinks to what exists.
        let dense = densify(waypoints, spacing: 0.04)
        let rounded = (0..<dense.count).map { index -> (x: Double, y: Double) in
            let window = 6
            let low = max(0, index - window), high = min(dense.count - 1, index + window)
            let shrink = min(index - low, high - index)
            var sx = 0.0, sy = 0.0
            for k in (index - shrink)...(index + shrink) {
                sx += dense[k].x
                sy += dense[k].y
            }
            let count = Double(2 * shrink + 1)
            return (sx / count, sy / count)
        }

        // Smooth noise: control points one pitch apart along the path, each with its own
        // Gaussian offset, blended with a smoothstep.
        let total = pathLength(rounded)
        let controls = max(Int(total.rounded(.up)) + 1, 2)
        let noise = (0..<controls).map { _ in
            (x: 0.3 * AutocorrectReplayTests.gaussian(&random), y: 0.3 * AutocorrectReplayTests.gaussian(&random))
        }
        let heading = Double.random(in: 0..<(2 * .pi), using: &random)
        let offsetX = 0.15 * cos(heading), offsetY = 0.15 * sin(heading)

        // Touch points at uneven spacing along the path.
        var points: [CGPoint] = []
        var arc = 0.0
        var cursor = 0
        var travelled = 0.0
        points.reserveCapacity(Int(total / 0.2) + 4)
        func emit(at distance: Double) {
            while cursor < rounded.count - 2,
                travelled + hypot(rounded[cursor + 1].x - rounded[cursor].x, rounded[cursor + 1].y - rounded[cursor].y)
                    < distance
            {
                travelled += hypot(rounded[cursor + 1].x - rounded[cursor].x, rounded[cursor + 1].y - rounded[cursor].y)
                cursor += 1
            }
            let a = rounded[cursor], b = rounded[cursor + 1]
            let length = hypot(b.x - a.x, b.y - a.y)
            let t = length > 0 ? min(max((distance - travelled) / length, 0), 1) : 0
            let position = distance / max(total, 1e-9) * Double(controls - 1)
            let low = min(Int(position), controls - 2)
            var f = position - Double(low)
            f = f * f * (3 - 2 * f)
            let nx = noise[low].x * (1 - f) + noise[low + 1].x * f
            let ny = noise[low].y * (1 - f) + noise[low + 1].y * f
            points.append(CGPoint(
                x: (a.x + t * (b.x - a.x) + nx + offsetX) * pitch,
                y: (a.y + t * (b.y - a.y) + ny + offsetY) * pitch))
        }
        while arc < total {
            emit(at: arc)
            arc += Double.random(in: 0.05...0.35, using: &random)
        }
        emit(at: total)
        return points
    }

    private static func densify(_ waypoints: [(x: Double, y: Double)], spacing: Double) -> [(x: Double, y: Double)] {
        var result: [(x: Double, y: Double)] = [waypoints[0]]
        for index in 1..<waypoints.count {
            let a = waypoints[index - 1], b = waypoints[index]
            let length = hypot(b.x - a.x, b.y - a.y)
            let steps = max(Int((length / spacing).rounded(.up)), 1)
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                result.append((a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)))
            }
        }
        return result
    }

    private static func pathLength(_ points: [(x: Double, y: Double)]) -> Double {
        var total = 0.0
        for index in 1..<points.count {
            total += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        }
        return total
    }

    // MARK: - Tuning

    /// Applies `name=value` pairs, comma separated, to the decoder's configuration.
    static func apply(_ tune: String, to configuration: inout SwipeDecoder.Configuration) {
        for pair in tune.split(separator: ",") {
            let parts = pair.split(separator: "=")
            guard parts.count == 2, let value = Double(parts[1]) else { continue }
            switch String(parts[0]) {
            case "sigmaLocation": configuration.sigmaLocation = value
            case "sigmaEnds": configuration.sigmaEnds = value
            case "tailDegrees": configuration.tailDegrees = value
            case "sigmaShape": configuration.sigmaShape = value
            case "locationEvidence": configuration.locationEvidence = value
            case "shapeEvidence": configuration.shapeEvidence = value
            case "endWeightRatio": configuration.endWeightRatio = value
            case "languageWeight": configuration.languageWeight = value
            case "backoffWeight": configuration.backoffWeight = value
            case "pairBonusBound": configuration.pairBonusBound = value
            case "loopRadius": configuration.loopRadius = value
            case "passLimitPitches": configuration.passLimitPitches = value
            case "passCapPitches": configuration.passCapPitches = value
            case "sigmaPass": configuration.sigmaPass = value
            case "orderWeight": configuration.orderWeight = value
            case "lengthSigma": configuration.lengthSigma = value
            case "scanBudget": configuration.scanBudget = Int(value)
            case "nearWeight": configuration.nearWeight = value
            case "sigmaNear": configuration.sigmaNear = value
            case "nearEvidence": configuration.nearEvidence = value
            case "rerankMargin": configuration.rerankMargin = value
            case "keyReachPitches": configuration.keyReachPitches = value
            case "lengthTolerance": configuration.lengthTolerance = value
            case "lengthSlackPitches": configuration.lengthSlackPitches = value
            case "rerankCount": configuration.rerankCount = Int(value)
            case "warpBand": configuration.warpBand = Int(value)
            case "warpWeight": configuration.warpWeight = value
            case "startKeyCount": configuration.startKeyCount = Int(value)
            case "endKeyCount": configuration.endKeyCount = Int(value)
            default: print("unknown tuning key \(parts[0])")
            }
        }
    }
}

/// A harsher, human-like swipe than the clean benchmark's, for `sloppySentences`. Every parameter
/// is a guess at how a thumb moves, chosen to be rougher than the clean model; none is measured.
/// Distances are in key pitches. The order of the steps matters: the vertices of the ideal
/// polyline are changed first (loops dropped, corners cut or overshot, ends missed), then the
/// result is smoothed, and last the wobble and the thumb bias are laid over it.
enum SloppySwipe {
    static let seed: UInt64 = 0x534C_4F50_5059
    /// A doubled letter gets no loop at all this often.
    static let skipLoopProbability = 0.5
    /// A loop, when made, has a radius in this range (the decoder assumes 0.3).
    static let loopRadius = 0.2...0.4
    /// How far an interior vertex is pulled toward the chord between its neighbours, capped at
    /// 90% of the way so it never crosses the chord.
    static let cornerCut = 0.3...0.6
    /// A turn sharper than this many degrees may be overshot instead of cut.
    static let overshootTurnDegrees = 70.0
    static let overshootProbability = 0.35
    /// How far past the turning key the finger travels, along the direction it arrived in.
    static let overshoot = 0.15...0.4
    /// The largest miss at either end. 70% of misses are along the path (the swipe begins before
    /// the key or lifts early or long), the rest in a random direction.
    static let endMiss = 0.6
    static let endMissAlongPath = 0.7
    /// The moving average that rounds what is left, half-width in pitches of arc.
    static let smoothingHalfWidth = 0.2
    /// Smooth wobble: a Gaussian of this sigma per axis at a control point each pitch of arc.
    static let wobbleSigma = 0.35
    /// A constant offset for the whole swipe (the thumb's bias), in a random direction.
    static let thumbBias = 0.15...0.45

    static var summary: String {
        "no loop on doubled letters \(Int(skipLoopProbability * 100))% (else radius \(loopRadius.lowerBound)-\(loopRadius.upperBound)), "
            + "corners pulled \(cornerCut.lowerBound)-\(cornerCut.upperBound) toward the chord, turns over "
            + "\(Int(overshootTurnDegrees)) deg overshot \(Int(overshootProbability * 100))% by \(overshoot.lowerBound)-\(overshoot.upperBound), "
            + "start/end miss up to \(endMiss), smoothing \(smoothingHalfWidth), wobble sigma \(wobbleSigma), "
            + "thumb bias \(thumbBias.lowerBound)-\(thumbBias.upperBound)"
    }

    private typealias Point = (x: Double, y: Double)

    static func synthesise(
        _ word: String, fixture: SwipeFixture, pitch: Double, random: inout AutocorrectReplayTests.SplitMix64
    ) -> [CGPoint] {
        // 1. Key vertices, in pitches. A doubled letter is one vertex, or one with loops.
        var vertices: [Point] = []
        var isKey: [Bool] = []
        let letters = Array(word.filter { $0 != "'" })
        for (index, letter) in letters.enumerated() {
            let centre = fixture.centre(letter)
            let cx = Double(centre.x) / pitch, cy = Double(centre.y) / pitch
            if index > 0, letters[index - 1] == letter {
                if Double.random(in: 0..<1, using: &random) < skipLoopProbability { continue }
                let radius = Double.random(in: loopRadius, using: &random)
                let heading = Double.random(in: 0..<(2 * .pi), using: &random)
                for step in 1...10 {
                    let angle = 2 * Double.pi * Double(step) / 10
                    vertices.append((cx + radius * (cos(heading) - cos(heading + angle)),
                        cy + radius * (sin(heading) - sin(heading + angle))))
                    isKey.append(false)
                }
            } else {
                vertices.append((cx, cy))
                isKey.append(true)
            }
        }
        guard vertices.count >= 2 else { return [] }

        // 2. Corners: cut toward the chord, or overshoot a sharp turn.
        var shaped: [Point] = [vertices[0]]
        for index in 1..<(vertices.count - 1) {
            let previous = vertices[index - 1], here = vertices[index], next = vertices[index + 1]
            guard isKey[index] else {
                shaped.append(here)
                continue
            }
            let inX = here.x - previous.x, inY = here.y - previous.y
            let outX = next.x - here.x, outY = next.y - here.y
            let inLength = hypot(inX, inY), outLength = hypot(outX, outY)
            var turn = 0.0
            if inLength > 1e-9, outLength > 1e-9 {
                let cosine = min(max((inX * outX + inY * outY) / (inLength * outLength), -1), 1)
                turn = acos(cosine) * 180 / .pi
            }
            if turn > overshootTurnDegrees, Double.random(in: 0..<1, using: &random) < overshootProbability {
                let past = Double.random(in: overshoot, using: &random)
                shaped.append(here)
                shaped.append((here.x + past * inX / inLength, here.y + past * inY / inLength))
                continue
            }
            let toX = (previous.x + next.x) / 2 - here.x, toY = (previous.y + next.y) / 2 - here.y
            let distance = hypot(toX, toY)
            let pull = min(Double.random(in: cornerCut, using: &random), 0.9 * distance)
            if distance > 1e-9 {
                shaped.append((here.x + pull * toX / distance, here.y + pull * toY / distance))
            } else {
                shaped.append(here)
            }
        }
        shaped.append(vertices[vertices.count - 1])

        // 3. The ends: begin before the key or past its middle, lift early or long.
        func missEnd(_ end: Int, toward neighbour: Int) {
            let magnitude = Double.random(in: 0...endMiss, using: &random)
            let along = Double.random(in: 0..<1, using: &random) < endMissAlongPath
            let sign = Double.random(in: 0..<1, using: &random) < 0.5 ? -1.0 : 1.0
            let angle = Double.random(in: 0..<(2 * .pi), using: &random)
            let dx = shaped[neighbour].x - shaped[end].x, dy = shaped[neighbour].y - shaped[end].y
            let length = hypot(dx, dy)
            if along, length > 1e-9 {
                // Positive moves the end toward the path's next vertex (a short swipe), negative
                // away from it (an overshoot or an early start).
                let step = min(magnitude, 0.7 * length) * (sign > 0 ? 1 : -1)
                let moved: Point = (shaped[end].x + step * dx / length, shaped[end].y + step * dy / length)
                if step < 0 {
                    // The finger is already moving before it reaches the key: keep the vertex.
                    if end == 0 { shaped.insert(moved, at: 0) } else { shaped.append(moved) }
                } else {
                    shaped[end] = moved
                }
            } else {
                let moved: Point = (shaped[end].x + magnitude * cos(angle), shaped[end].y + magnitude * sin(angle))
                if end == 0 { shaped.insert(moved, at: 0) } else { shaped.append(moved) }
            }
        }
        missEnd(shaped.count - 1, toward: shaped.count - 2)
        missEnd(0, toward: 1)

        // 4. Round what is left with a moving average over a fixed arc each side.
        let dense = densify(shaped, spacing: 0.04)
        let window = max(Int((smoothingHalfWidth / 0.04).rounded()), 1)
        let rounded = (0..<dense.count).map { index -> Point in
            let low = max(0, index - window), high = min(dense.count - 1, index + window)
            let shrink = min(index - low, high - index)
            var sx = 0.0, sy = 0.0
            for k in (index - shrink)...(index + shrink) {
                sx += dense[k].x
                sy += dense[k].y
            }
            let count = Double(2 * shrink + 1)
            return (sx / count, sy / count)
        }

        // 5. Wobble and bias, then touch points at uneven spacing.
        let total = pathLength(rounded)
        let controls = max(Int(total.rounded(.up)) + 1, 2)
        let noise = (0..<controls).map { _ in
            (x: wobbleSigma * AutocorrectReplayTests.gaussian(&random), y: wobbleSigma * AutocorrectReplayTests.gaussian(&random))
        }
        let heading = Double.random(in: 0..<(2 * .pi), using: &random)
        let bias = Double.random(in: thumbBias, using: &random)
        let offsetX = bias * cos(heading), offsetY = bias * sin(heading)

        var points: [CGPoint] = []
        var cursor = 0
        var travelled = 0.0
        func emit(at distance: Double) {
            while cursor < rounded.count - 2,
                travelled + hypot(rounded[cursor + 1].x - rounded[cursor].x, rounded[cursor + 1].y - rounded[cursor].y)
                    < distance
            {
                travelled += hypot(rounded[cursor + 1].x - rounded[cursor].x, rounded[cursor + 1].y - rounded[cursor].y)
                cursor += 1
            }
            let a = rounded[cursor], b = rounded[cursor + 1]
            let length = hypot(b.x - a.x, b.y - a.y)
            let t = length > 0 ? min(max((distance - travelled) / length, 0), 1) : 0
            let position = distance / max(total, 1e-9) * Double(controls - 1)
            let low = min(Int(position), controls - 2)
            var f = position - Double(low)
            f = f * f * (3 - 2 * f)
            let nx = noise[low].x * (1 - f) + noise[low + 1].x * f
            let ny = noise[low].y * (1 - f) + noise[low + 1].y * f
            points.append(CGPoint(
                x: (a.x + t * (b.x - a.x) + nx + offsetX) * pitch,
                y: (a.y + t * (b.y - a.y) + ny + offsetY) * pitch))
        }
        var arc = 0.0
        while arc < total {
            emit(at: arc)
            arc += Double.random(in: 0.05...0.35, using: &random)
        }
        emit(at: total)
        return points
    }

    private static func densify(_ waypoints: [Point], spacing: Double) -> [Point] {
        var result: [Point] = [waypoints[0]]
        for index in 1..<waypoints.count {
            let a = waypoints[index - 1], b = waypoints[index]
            let length = hypot(b.x - a.x, b.y - a.y)
            let steps = max(Int((length / spacing).rounded(.up)), 1)
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                result.append((a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)))
            }
        }
        return result
    }

    private static func pathLength(_ points: [Point]) -> Double {
        var total = 0.0
        for index in 1..<points.count {
            total += hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
        }
        return total
    }
}
