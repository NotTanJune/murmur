import CoreGraphics
import Foundation

/// The shape of the trail that follows a swiping finger: a ribbon that is widest under the
/// finger, thins to nothing behind it, and relaxes as it ages, so it flows after the finger
/// instead of tracing every touch sample.
///
/// The view feeds it the finger's points (`add`) and the time at every frame (`advance`), then
/// asks for an outline (`path`). It has no drawing of its own, so the shape is tested and
/// previewed on the Mac.
///
/// Three things make the shape:
///
/// - **Age.** A sample lives `seconds`. A sample's width falls with its age, so a resting
///   finger's trail drains into the finger and a fast one's is long.
/// - **Relaxing.** At each frame every sample but the newest moves a little towards the middle
///   of its neighbours, more the older it is. Corners round off and the tail straightens as it
///   ages, which is what reads as flowing. The finger's end never moves.
/// - **The outline.** One closed outline round the whole ribbon, plus a disc wherever the line
///   turns sharply and one under the finger, all wound the same way and filled together. An
///   outline alone folds over itself at a sharp turn (a swipe reverses at most letters) and
///   leaves a hole there; the disc fills it, so the shape is solid with no doubled colour.
public struct SwipeTrail: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// How long a sample is drawn.
        public var seconds: Double
        /// Samples closer to the last one than this are skipped.
        public var minimumStep: CGFloat
        /// How fast an old sample moves to the middle of its neighbours, per second at full age.
        public var relaxRate: Double

        public init(seconds: Double = 0.6, minimumStep: CGFloat = 1.5, relaxRate: Double = 16) {
            self.seconds = seconds
            self.minimumStep = minimumStep
            self.relaxRate = relaxRate
        }
    }

    public struct Sample: Sendable, Equatable {
        public var point: CGPoint
        public var time: TimeInterval
    }

    /// One filled copy of the outline. A view draws `layers` over each other, each at the same
    /// faint colour: the full trail, then slightly shorter and thinner copies whose overlap
    /// gives the trail a soft edge and a tail that fades, without a blur.
    public struct Layer: Sendable, Equatable {
        public var widthShare: CGFloat
        public var spanShare: Double
    }

    public static let layers = [
        Layer(widthShare: 1, spanShare: 1),
        Layer(widthShare: 0.86, spanShare: 0.9),
        Layer(widthShare: 0.72, spanShare: 0.8),
        Layer(widthShare: 0.58, spanShare: 0.7),
    ]

    public var configuration: Configuration
    /// The samples still drawn, oldest first. The last is under the finger.
    public private(set) var samples: [Sample] = []
    private var advancedAt: TimeInterval?

    /// The longest frame a relaxing step accounts for, so a stalled frame does not fold the trail.
    private static let longestStep = 0.05
    /// A bend sharper than this (in radians) gets a disc, so the joint is round.
    private static let roundJointAngle: CGFloat = 0.35
    /// A piece thinner than this is not drawn.
    private static let thinnestRadius: CGFloat = 0.15

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public var isEmpty: Bool { samples.isEmpty }

    public mutating func removeAll() {
        samples.removeAll(keepingCapacity: true)
        advancedAt = nil
    }

    /// The finger is at `point`.
    public mutating func add(_ point: CGPoint, at time: TimeInterval) {
        if let last = samples.last,
            hypot(point.x - last.point.x, point.y - last.point.y) < configuration.minimumStep
        {
            // The finger barely moved: the end follows it without a new sample.
            samples[samples.count - 1].point = point
            return
        }
        samples.append(Sample(point: point, time: time))
    }

    /// A frame passed: samples past their time go, and the rest relax.
    public mutating func advance(to time: TimeInterval) {
        let step = min(max(time - (advancedAt ?? time), 0), Self.longestStep)
        advancedAt = time
        let cutoff = time - configuration.seconds
        let expired = samples.firstIndex { $0.time >= cutoff } ?? samples.count
        if expired > 0 { samples.removeFirst(expired) }
        guard step > 0, samples.count > 2 else { return }
        let before = samples
        for index in 0..<(before.count - 1) {
            let age = min(max((time - before[index].time) / configuration.seconds, 0), 1)
            let pull = CGFloat(1 - exp(-configuration.relaxRate * age * step))
            let here = before[index].point
            let target: CGPoint
            if index == 0 {
                target = before[1].point
            } else {
                let a = before[index - 1].point, b = before[index + 1].point
                target = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            }
            samples[index].point = CGPoint(
                x: here.x + (target.x - here.x) * pull, y: here.y + (target.y - here.y) * pull)
        }
    }

    /// The trail's outline at `time`, `headWidth` wide under the finger. `spanShare` draws only
    /// the newest part of the trail (a share of `seconds`) and `widthShare` narrows it, so a
    /// view can lay a shorter, thinner copy over the full one for a core that is stronger
    /// towards the finger. Nil when there is nothing to draw.
    public func path(
        at time: TimeInterval, headWidth: CGFloat, widthShare: CGFloat = 1, spanShare: Double = 1
    ) -> CGPath? {
        let span = configuration.seconds * spanShare
        guard span > 0, let head = samples.last else { return nil }
        let live = samples.drop { time - $0.time > span }
        let headRadius = headWidth * widthShare / 2
        let path = CGMutablePath()
        guard live.count > 1 else {
            Self.addDisc(to: path, at: head.point, radius: headRadius)
            return path
        }

        // One round of corner cutting, so the newest stretch, which has not relaxed yet, bends
        // instead of turning at each touch sample. The ends stay where they are.
        var centre: [Sample] = []
        centre.reserveCapacity(live.count * 2)
        centre.append(live[live.startIndex])
        for index in live.indices.dropLast() {
            let a = live[index], b = live[index + 1]
            centre.append(Self.between(a, b, 0.25))
            centre.append(Self.between(a, b, 0.75))
        }
        centre.append(head)

        let radii = centre.map { sample -> CGFloat in
            let left = min(max(1 - (time - sample.time) / span, 0), 1)
            return headRadius * Self.width(remaining: CGFloat(left))
        }
        // Each centre point gets a point on either side, its radius out along the normal of the
        // line through its neighbours. One side forward, the other back: one outline.
        var near: [CGPoint] = []
        var far: [CGPoint] = []
        near.reserveCapacity(centre.count)
        far.reserveCapacity(centre.count)
        var direction = CGVector(dx: 1, dy: 0)
        for index in centre.indices {
            let before = centre[max(index - 1, 0)].point
            let after = centre[min(index + 1, centre.count - 1)].point
            let dx = after.x - before.x, dy = after.y - before.y
            let length = hypot(dx, dy)
            if length > 0 { direction = CGVector(dx: dx / length, dy: dy / length) }
            // The normal is the direction a quarter turn on, with the angle rising, so the
            // outline runs the same way round as a disc's edge.
            let nx = -direction.dy * radii[index], ny = direction.dx * radii[index]
            let point = centre[index].point
            near.append(CGPoint(x: point.x - nx, y: point.y - ny))
            far.append(CGPoint(x: point.x + nx, y: point.y + ny))
        }
        path.addLines(between: near + far.reversed())
        path.closeSubpath()
        // Where the line turns sharply the outline folds over itself and would leave a hole or
        // a notch; a disc there makes the joint round. The finger's end is a disc too.
        for index in centre.indices.dropFirst().dropLast() where radii[index] > Self.thinnestRadius {
            let a = centre[index - 1].point, b = centre[index].point, c = centre[index + 1].point
            let turn = abs(Self.angle(
                from: CGVector(dx: b.x - a.x, dy: b.y - a.y), to: CGVector(dx: c.x - b.x, dy: c.y - b.y)))
            if turn > Self.roundJointAngle { Self.addDisc(to: path, at: b, radius: radii[index]) }
        }
        Self.addDisc(to: path, at: head.point, radius: headRadius)
        return path
    }

    /// How wide the trail is where `remaining` of a sample's time is left (1 under the finger,
    /// 0 at the tail): full for the first stretch behind the finger, then easing down to a
    /// point, with no corner where the thinning starts or ends.
    static func width(remaining: CGFloat) -> CGFloat {
        let eased = remaining * remaining * (3 - 2 * remaining)
        return 0.35 * remaining + 0.65 * eased
    }

    private static func between(_ a: Sample, _ b: Sample, _ share: CGFloat) -> Sample {
        Sample(
            point: CGPoint(x: a.point.x + (b.point.x - a.point.x) * share, y: a.point.y + (b.point.y - a.point.y) * share),
            time: a.time + (b.time - a.time) * Double(share))
    }

    private static func angle(from a: CGVector, to b: CGVector) -> CGFloat {
        atan2(a.dx * b.dy - a.dy * b.dx, a.dx * b.dx + a.dy * b.dy)
    }

    /// A disc wound with its angle rising, the way the outline is wound.
    private static func addDisc(to path: CGMutablePath, at centre: CGPoint, radius: CGFloat) {
        guard radius > thinnestRadius else { return }
        path.move(to: CGPoint(x: centre.x + radius, y: centre.y))
        path.addArc(center: centre, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        path.closeSubpath()
    }
}
