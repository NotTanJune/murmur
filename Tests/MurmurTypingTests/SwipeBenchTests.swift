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
@Suite struct SwipeBenchTests {
    static let enabled = ProcessInfo.processInfo.environment["MURMUR_TYPING_BENCH"] == "1"

    static let requiredTop1 = 0.90
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
            case "sigmaShape": configuration.sigmaShape = value
            case "locationEvidence": configuration.locationEvidence = value
            case "shapeEvidence": configuration.shapeEvidence = value
            case "endWeightRatio": configuration.endWeightRatio = value
            case "languageWeight": configuration.languageWeight = value
            case "loopRadius": configuration.loopRadius = value
            case "coarseLimitPitches": configuration.coarseLimitPitches = value
            case "rerankMargin": configuration.rerankMargin = value
            case "keyReachPitches": configuration.keyReachPitches = value
            case "lengthTolerance": configuration.lengthTolerance = value
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
