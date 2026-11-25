import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MurmurTyping

@Suite("Swipe trail")
struct SwipeTrailTests {
    private static let frame = 1.0 / 120

    /// A finger moving right at 600 pt a second for `seconds`, one sample per frame.
    private func swept(seconds: Double, into trail: inout SwipeTrail) -> TimeInterval {
        var time = 0.0
        while time < seconds {
            trail.add(CGPoint(x: 20 + 600 * time, y: 100), at: time)
            trail.advance(to: time)
            time += Self.frame
        }
        return time
    }

    @Test("A sample is dropped once it is older than the trail's span")
    func expiry() {
        var trail = SwipeTrail()
        let end = swept(seconds: 1.5, into: &trail)
        let oldest = trail.samples.first!.time
        #expect(end - oldest <= trail.configuration.seconds + 2 * Self.frame)
        trail.advance(to: end + trail.configuration.seconds + 0.01)
        #expect(trail.isEmpty)
        #expect(trail.path(at: end + 1, headWidth: 12) == nil)
    }

    @Test("The trail is as wide as asked under the finger and thinner behind it")
    func taper() {
        var trail = SwipeTrail()
        let end = swept(seconds: 1, into: &trail)
        let head = trail.samples.last!.point
        let path = trail.path(at: end, headWidth: 12)!
        #expect(path.contains(CGPoint(x: head.x, y: head.y + 5.5)))
        #expect(!path.contains(CGPoint(x: head.x, y: head.y + 6.5)))
        // Near the tail the same offset from the centre line is outside.
        let tail = trail.samples[2].point
        #expect(path.contains(tail) == false || !path.contains(CGPoint(x: tail.x, y: tail.y + 3)))
        #expect(SwipeTrail.width(remaining: 1) == 1)
        #expect(SwipeTrail.width(remaining: 0) == 0)
    }

    @Test("A sharp turn and a crossing fill solid, with no hole")
    func sharpTurn() {
        var trail = SwipeTrail()
        var time = 0.0
        // Out to the right and straight back over the same line.
        for step in 0..<40 {
            let x = step < 20 ? 100 + CGFloat(step) * 5 : 200 - CGFloat(step - 20) * 5
            trail.add(CGPoint(x: x, y: 100), at: time)
            trail.advance(to: time)
            time += Self.frame
        }
        let path = trail.path(at: time, headWidth: 14)!
        // Every sample still drawn at a visible width lies inside the filled shape.
        for sample in trail.samples.suffix(20) {
            #expect(path.contains(sample.point, using: .winding))
        }
    }

    @Test("An old corner rounds off while the finger's end stays put")
    func relaxes() {
        var trail = SwipeTrail()
        var time = 0.0
        for step in 0..<30 {
            // Right, then straight down: a square corner at (150, 100).
            let point = step < 15 ? CGPoint(x: 80 + CGFloat(step) * 5, y: 100) : CGPoint(x: 150, y: 100 + CGFloat(step - 14) * 5)
            trail.add(point, at: time)
            trail.advance(to: time)
            time += Self.frame
        }
        let head = trail.samples.last!.point
        let cornerBefore = trail.samples.min { hypot($0.point.x - 150, $0.point.y - 100) < hypot($1.point.x - 150, $1.point.y - 100) }!
        for _ in 0..<36 {
            time += Self.frame
            trail.advance(to: time)
        }
        #expect(trail.samples.last!.point == head)
        let nearest = trail.samples.map { hypot($0.point.x - 150, $0.point.y - 100) }.min()!
        #expect(nearest > hypot(cornerBefore.point.x - 150, cornerBefore.point.y - 100) + 1)
    }

    /// Draws the trail over a dark keyboard (a light one with `MURMUR_TRAIL_LIGHT` set) for a real
    /// swipe, at several moments, so its look can be judged on the Mac:
    /// `MURMUR_TRAIL_PREVIEW=<folder> swift test --filter trailPreview`.
    @Test("Preview frames", .enabled(if: ProcessInfo.processInfo.environment["MURMUR_TRAIL_PREVIEW"] != nil))
    func trailPreview() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MURMUR_TRAIL_PREVIEW"]!)
        let opacity = Double(ProcessInfo.processInfo.environment["MURMUR_TRAIL_OPACITY"] ?? "") ?? 0.09
        let headWidth = Double(ProcessInfo.processInfo.environment["MURMUR_TRAIL_WIDTH"] ?? "") ?? 15
        let light = ProcessInfo.processInfo.environment["MURMUR_TRAIL_LIGHT"] != nil
        struct Fixture: Decodable {
            struct Swipe: Decodable { let intended: String; let path: [[Double]] }
            let swipes: [Swipe]
        }
        let url = try #require(Bundle.module.url(forResource: "real-swipes", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let metrics = KeyboardMetrics(width: 393, isLandscape: false, constants: .portrait)
        let frames = metrics.frames(for: KeyboardLayout.rows(for: .letters, showsGlobe: false))
        let scale: CGFloat = 3

        for word in ["keyboard", "typing", "test"] {
            let swipe = try #require(fixture.swipes.first { $0.intended == word })
            let points = swipe.path.map { CGPoint(x: $0[0], y: $0[1]) }
            var trail = SwipeTrail()
            var time = 0.0
            // Frames of interest: a third and two thirds through, the lift, and after it.
            let stops: [Int: String] = [points.count / 3: "a", 2 * points.count / 3: "b", points.count - 1: "c"]
            func render(_ name: String) throws {
                let context = try #require(CGContext(
                    data: nil, width: Int(393 * scale), height: Int(metrics.height * scale), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                // Top-left origin, in points.
                context.translateBy(x: 0, y: metrics.height * scale)
                context.scaleBy(x: scale, y: -scale)
                let ground: CGFloat = light ? 0.82 : 0.13
                let key: CGFloat = light ? 1 : 0.267
                context.setFillColor(CGColor(red: ground, green: ground, blue: ground, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 393, height: metrics.height))
                context.setFillColor(CGColor(red: key, green: key, blue: key, alpha: 1))
                for frame in frames {
                    context.addPath(CGPath(roundedRect: frame.keycap, cornerWidth: 10, cornerHeight: 10, transform: nil))
                }
                context.fillPath()
                // The m's orange, `DS.Keyboard.wordmark` (0xF2A57E).
                context.setFillColor(CGColor(red: 0.949, green: 0.647, blue: 0.494, alpha: opacity))
                for layer in SwipeTrail.layers {
                    guard let path = trail.path(
                        at: time, headWidth: headWidth, widthShare: layer.widthShare, spanShare: layer.spanShare)
                    else { continue }
                    context.addPath(path)
                    context.fillPath(using: .winding)
                }
                let image = try #require(context.makeImage())
                let out = folder.appendingPathComponent("trail-\(word)-\(name).png")
                let destination = try #require(CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                #expect(CGImageDestinationFinalize(destination))
            }
            for (index, point) in points.enumerated() {
                trail.add(point, at: time)
                trail.advance(to: time)
                if let name = stops[index] { try render(name) }
                time += Self.frame
            }
            // After the lift the trail drains into where the finger left.
            for _ in 0..<18 {
                time += Self.frame
                trail.advance(to: time)
            }
            try render("d")
        }
    }
}
