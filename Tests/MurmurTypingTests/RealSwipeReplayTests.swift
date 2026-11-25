import CoreGraphics
import Foundation
import Testing

@testable import MurmurTyping

/// Replays the owner's real swipes through the swipe decoder. `real-swipes.json` holds the first
/// ten words swiped on the device (2026-11-25, "this is a test of swipe typing on the new
/// keyboard", the "a" tapped): for each the word meant, the word before it, what the phone typed,
/// and the path in the engine's coordinates (the space of `KeyboardMetrics` frames, strip
/// included), in points, without timestamps.
///
/// The benchmark's swipes (`SwipeBenchTests`) are simulated; these are what a thumb does. Ten
/// words are far too few to tune on, so the gates are loose and the printed lines are the real
/// output: where each path's ends land, what each word decodes to, where the intended word is
/// dropped when it is not offered, and how the real paths' shape differs from the simulated ones.
@Suite struct RealSwipeReplayTests {
    struct File: Decodable {
        struct Swipe: Decodable {
            let intended: String
            let previous: String
            /// What the phone typed, and the strip's other readings, with the decoder of 66c2d94.
            let typed: String
            let alternatives: [String]
            let path: [[Double]]

            var points: [CGPoint] { path.map { CGPoint(x: $0[0], y: $0[1]) } }
        }
        let note: String
        let swipes: [Swipe]
    }

    static func load() throws -> File {
        let url = try #require(Bundle.module.url(forResource: "real-swipes", withExtension: "json"))
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    /// The keyboard asks for the typed word and three alternatives.
    static let limit = 4

    @Test("The recorded paths are in the frames' coordinates: their ends land by the intended keys")
    func geometryMatchesTheKeys() throws {
        let file = try Self.load()
        let fixture = try SwipeFixture()
        let pitch = fixture.decoder.pitch
        var worst = 0.0
        var interior: [Double] = []
        var offsetY: [Double] = []
        for swipe in file.swipes {
            let path = swipe.points
            let letters = Array(swipe.intended)
            let start = fixture.centre(letters[0]), end = fixture.centre(letters[letters.count - 1])
            let ds = Double(hypot(path[0].x - start.x, path[0].y - start.y)) / pitch
            let de = Double(hypot(path[path.count - 1].x - end.x, path[path.count - 1].y - end.y)) / pitch
            worst = max(worst, ds, de)
            var parts: [String] = []
            for letter in letters {
                let nearest = RealSwipeShape.nearest(on: path, to: fixture.centre(letter))
                parts.append(String(format: "%@ %.2f", String(letter), Double(nearest.distance) / pitch))
                interior.append(Double(nearest.distance) / pitch)
                offsetY.append(Double(nearest.point.y - fixture.centre(letter).y) / pitch)
            }
            print(String(format: "REAL-SWIPE geometry %@: start %.2f from %@, end %.2f from %@; path to keys: %@",
                swipe.intended, ds, String(letters[0]), de, String(letters[letters.count - 1]),
                parts.joined(separator: ", ")))
        }
        let meanNear = interior.reduce(0, +) / Double(interior.count)
        let meanY = offsetY.reduce(0, +) / Double(offsetY.count)
        print(String(format: "REAL-SWIPE geometry: mean distance from the path to an intended key %.2f pitches, mean vertical offset %+.2f, worst end %.2f",
            meanNear, meanY, worst))
        // A path in another coordinate space (the key plane's own, a strip height higher) would
        // put every key a row away: more than a pitch.
        #expect(meanNear < 0.4, "mean \(meanNear)")
        #expect(abs(meanY) < 0.25, "vertical offset \(meanY)")
        #expect(worst < 1.3, "worst end \(worst)")
    }

    @Test("The owner's real swipes decode to the words meant")
    func replay() throws {
        let file = try Self.load()
        var configuration = SwipeDecoder.Configuration.tuned
        if let tune = ProcessInfo.processInfo.environment["MURMUR_TYPING_TUNE"] {
            SwipeBenchTests.apply(tune, to: &configuration)
        }
        let fixture = try SwipeFixture(configuration: configuration)
        let model = fixture.model
        var top1 = 0, top3 = 0, top4 = 0, same = 0
        for swipe in file.swipes {
            let previous = model.id(of: swipe.previous)
            let candidates = fixture.decoder.decode(
                path: swipe.points, times: nil, previous: previous, limit: Self.limit)
            let texts = candidates.map(\.text)
            if texts.first == swipe.intended { top1 += 1 }
            if texts.prefix(3).contains(swipe.intended) { top3 += 1 }
            if texts.contains(swipe.intended) { top4 += 1 }
            if texts.first == swipe.typed { same += 1 }
            print("REAL-SWIPE \(swipe.intended) (after \"\(swipe.previous)\"): \(texts.joined(separator: ", "))"
                + "  [phone: \(swipe.typed), \(swipe.alternatives.joined(separator: ", "))]")
            if !texts.contains(swipe.intended) {
                let stage = fixture.decoder.pruneStage(of: swipe.intended, path: swipe.points)
                print("REAL-SWIPE   \(swipe.intended) is not offered; the cuts before scoring: \(stage.rawValue)")
            }
        }
        let n = file.swipes.count
        print("REAL-SWIPE top-1 \(top1) of \(n), top-3 \(top3) of \(n), top-4 \(top4) of \(n); first reading as on the phone \(same) of \(n)")

        #expect(n == 10)
        #expect(top1 >= Gate.top1, "top-1 \(top1) of \(n)")
        #expect(top3 >= Gate.top3, "top-3 \(top3) of \(n)")
    }

    /// The phone decoded "typing" after the wrong word it had just typed for "swipe"; the fixture
    /// holds the word that was meant.
    @Test("Typing after the word the phone really had before it")
    func typingAfterTheWrongWord() throws {
        let file = try Self.load()
        let fixture = try SwipeFixture()
        let swipe = try #require(file.swipes.first { $0.intended == "typing" })
        for previous in ["swipe", "serious"] {
            let candidates = fixture.decoder.decode(
                path: swipe.points, times: nil, previous: fixture.model.id(of: previous), limit: Self.limit)
            print("REAL-SWIPE typing after \"\(previous)\": \(candidates.map(\.text).joined(separator: ", "))")
            #expect(candidates.map(\.text).contains("typing"), "after \(previous): \(candidates.map(\.text))")
        }
    }

    /// How the real paths differ from the simulated ones, on the same measures. Printed for the
    /// report; the only gate is that the measures exist for all ten swipes.
    @Test("The shape of the real swipes beside the simulated ones")
    func shapeAgainstTheSimulation() throws {
        let file = try Self.load()
        let fixture = try SwipeFixture()
        let pitch = fixture.decoder.pitch
        var real = RealSwipeShape.Tally()
        for swipe in file.swipes {
            real.add(RealSwipeShape.measure(swipe.intended, path: swipe.points, fixture: fixture, pitch: pitch))
        }
        print("REAL-SHAPE real (\(file.swipes.count) swipes)")
        real.printLines(prefix: "REAL-SHAPE   ")

        // The sloppy benchmark's swipes for its own sentences, the same seed and order.
        var random = AutocorrectReplayTests.SplitMix64(seed: SloppySwipe.seed)
        var simulated = RealSwipeShape.Tally()
        for sentence in try AutocorrectReplayTests.sentences() {
            for word in sentence.split(separator: " ").map(String.init) {
                guard word.count >= 2, fixture.model.id(of: word) != nil else { continue }
                let path = SloppySwipe.synthesise(word, fixture: fixture, pitch: pitch, random: &random)
                simulated.add(RealSwipeShape.measure(word, path: path, fixture: fixture, pitch: pitch))
            }
        }
        print("REAL-SHAPE simulated, the sloppy benchmark's model (\(simulated.count) swipes)")
        simulated.printLines(prefix: "REAL-SHAPE   ")
        #expect(real.count == 10)
    }

    /// What the decoder of commit 66c2d94 does, as a floor: eight of ten first, "typing" fourth
    /// and "swipe" not offered. Ten words of one sentence: one word either way is noise, and an
    /// exact ranking would break at the next tuning.
    enum Gate {
        static let top1 = 8
        static let top3 = 8
    }

}

/// Measurements of a swipe's shape against the word it was meant for, in key pitches, for
/// comparing real swipes with the simulated ones.
enum RealSwipeShape {
    /// One swipe against the word it was meant for. Distances are in pitches.
    struct Measure {
        /// From the path's first point to the first key, and from its last to the last key.
        var startMiss = 0.0
        var endMiss = 0.0
        /// The same along the word's direction there: positive when the path begins part of the
        /// way to the second key, and when it runs on past the last key.
        var startAhead = 0.0
        var endPast = 0.0
        /// Across the keyboard and up or down it, for the first point.
        var startX = 0.0
        var startY = 0.0
        /// From each key between the first and the last to the nearest point of the path, and
        /// from the first and the last key.
        var interior: [Double] = []
        var firstKey = 0.0
        var lastKey = 0.0
        /// The path's length over the ideal path's (no loops).
        var lengthRatio = 0.0
        /// The mean distance from the path, sampled evenly, to the ideal path.
        var offPath = 0.0
        /// The size of the mean offset of the path from the keys it passes: a hand held off centre.
        var bias = 0.0
    }

    static func measure(_ word: String, path: [CGPoint], fixture: SwipeFixture, pitch: Double) -> Measure {
        var letters: [Character] = []
        for letter in word where letter != "'" && letters.last != letter { letters.append(letter) }
        let keys = letters.map { fixture.centre($0) }
        var result = Measure()
        guard keys.count >= 2, path.count >= 2 else { return result }
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) / pitch }
        func along(_ point: CGPoint, from: CGPoint, toward: CGPoint) -> Double {
            let dx = Double(toward.x - from.x), dy = Double(toward.y - from.y)
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 1e-9 else { return 0 }
            return (Double(point.x - from.x) * dx + Double(point.y - from.y) * dy) / length / pitch
        }
        let first = path[0], last = path[path.count - 1]
        result.startMiss = distance(first, keys[0])
        result.endMiss = distance(last, keys[keys.count - 1])
        result.startAhead = along(first, from: keys[0], toward: keys[1])
        result.endPast = -along(last, from: keys[keys.count - 1], toward: keys[keys.count - 2])
        result.startX = Double(first.x - keys[0].x) / pitch
        result.startY = Double(first.y - keys[0].y) / pitch
        var offsetX = 0.0, offsetY = 0.0
        for (index, key) in keys.enumerated() {
            let near = nearest(on: path, to: key)
            let d = Double(near.distance) / pitch
            if index == 0 { result.firstKey = d } else if index == keys.count - 1 { result.lastKey = d } else { result.interior.append(d) }
            offsetX += Double(near.point.x - key.x) / pitch
            offsetY += Double(near.point.y - key.y) / pitch
        }
        result.bias = (offsetX * offsetX + offsetY * offsetY).squareRoot() / Double(keys.count)
        func length(_ points: [CGPoint]) -> Double {
            var total = 0.0
            for index in 1..<points.count { total += distance(points[index], points[index - 1]) }
            return total
        }
        result.lengthRatio = length(path) / max(length(keys), 1e-9)
        let samples = SwipeDecoder.resample(path, count: 64)
        result.offPath = samples.map { Double(nearest(on: keys, to: $0).distance) / pitch }.reduce(0, +) / 64
        return result
    }

    struct Tally {
        var measures: [Measure] = []
        var count: Int { measures.count }
        mutating func add(_ measure: Measure) { measures.append(measure) }

        static func summary(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "-" }
            let sorted = values.sorted()
            let mean = values.reduce(0, +) / Double(values.count)
            func q(_ p: Double) -> Double { sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)] }
            return String(format: "mean %+.2f  p10 %+.2f  p50 %+.2f  p90 %+.2f", mean, q(0.1), q(0.5), q(0.9))
        }

        static func spread(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "-" }
            let rms = (values.map { $0 * $0 }.reduce(0, +) / Double(values.count)).squareRoot()
            return String(format: "rms %.2f", rms)
        }

        func printLines(prefix: String) {
            print(prefix + "start to first key      " + Self.summary(measures.map(\.startMiss)))
            print(prefix + "  across / up-down      " + Self.spread(measures.map(\.startX)) + " / " + Self.spread(measures.map(\.startY)))
            print(prefix + "  ahead toward 2nd key  " + Self.summary(measures.map(\.startAhead)))
            print(prefix + "end to last key         " + Self.summary(measures.map(\.endMiss)))
            print(prefix + "  past the last key     " + Self.summary(measures.map(\.endPast)))
            print(prefix + "path to first key       " + Self.summary(measures.map(\.firstKey)))
            print(prefix + "path to middle keys     " + Self.summary(measures.flatMap(\.interior)))
            print(prefix + "path to last key        " + Self.summary(measures.map(\.lastKey)))
            print(prefix + "length over ideal       " + Self.summary(measures.map(\.lengthRatio)))
            print(prefix + "path off the ideal path " + Self.summary(measures.map(\.offPath)))
            print(prefix + "bias                    " + Self.summary(measures.map(\.bias)))
        }
    }

    /// The point of the polyline nearest `target`, its distance, and how far along the path it is
    /// (0 to 1).
    static func nearest(on path: [CGPoint], to target: CGPoint) -> (point: CGPoint, distance: CGFloat, at: Double) {
        var best = (point: path[0], distance: CGFloat.infinity, at: 0.0)
        var travelled: CGFloat = 0
        var total: CGFloat = 0
        for index in 1..<path.count { total += hypot(path[index].x - path[index - 1].x, path[index].y - path[index - 1].y) }
        for index in 0..<(path.count - 1) {
            let a = path[index], b = path[index + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            var t: CGFloat = 0
            if lengthSquared > 1e-12 { t = min(max(((target.x - a.x) * dx + (target.y - a.y) * dy) / lengthSquared, 0), 1) }
            let point = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            let distance = hypot(point.x - target.x, point.y - target.y)
            if distance < best.distance {
                best = (point, distance, total > 0 ? Double((travelled + t * lengthSquared.squareRoot()) / total) : 0)
            }
            travelled += lengthSquared.squareRoot()
        }
        return best
    }
}
