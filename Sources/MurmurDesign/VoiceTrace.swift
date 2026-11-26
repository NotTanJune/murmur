import SwiftUI

/// Feeds a `VoiceTrace` and holds the model it reads. A reference type so the owner of the
/// dictation advances it from where the audio arrives, outside any draw closure.
///
/// Times are `Date.timeIntervalSinceReferenceDate`, the clock `TimelineView` reports, so the
/// view and the feeder agree without passing a clock around.
@MainActor
public final class VoiceTraceSource {
    public private(set) var model: VoiceTraceModel

    public init(parameters: VoiceTraceModel.Parameters = .init()) {
        model = VoiceTraceModel(parameters: parameters)
    }

    public nonisolated static var now: TimeInterval { Date.timeIntervalSinceReferenceDate }

    /// Forget the room and the history: call as a hold starts.
    public func reset() {
        model.reset()
    }

    /// A block of mono samples that ended at `time`.
    public func ingest(samples: [Float], rate: Double, at time: TimeInterval = VoiceTraceSource.now) {
        model.ingest(samples: samples, rate: rate, at: time)
    }

    /// A linear RMS level measured at `time`, for a source that does not hand over samples.
    public func ingest(rms: Float, at time: TimeInterval = VoiceTraceSource.now) {
        model.ingest(rms: rms, at: time)
    }

    /// `count` values from the newest (age 0) to `seconds` old, evenly spaced, one per column of
    /// a trace's half.
    func amplitudes(count: Int, seconds: TimeInterval, at time: TimeInterval) -> [Float] {
        model.trace(points: max(1, count - 1), seconds: seconds, at: time)
    }
}

/// The listening trace: one smooth liquid body, drawn as a single filled vector shape. The middle
/// is now and older sound drifts out towards both edges, so a pause still shows the last words
/// leaving. Three long, slow strands cross each other like ribbons of mercury; the level is blurred
/// along the trace, so a syllable is a rounded bulge, and sets both a strand's swing and its
/// thickness, so louder is fatter. The ribbons and a body around them are one silhouette, filled
/// once, so overlaps never brighten and the edge is crisp. A faint wider copy under it is the rim:
/// no blur and no gradient.
///
/// Inactive, it is a hairline along the middle in `idleTint` and the clock is paused. Red means
/// recording, so the keyboard passes a neutral `idleTint` for the time before the hold has heard
/// audio.
public struct VoiceTrace: View {
    let source: VoiceTraceSource
    let isActive: Bool
    let tint: Color
    let idleTint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        source: VoiceTraceSource,
        isActive: Bool,
        tint: Color = DS.Color.record,
        idleTint: Color = DS.Color.record
    ) {
        self.source = source
        self.isActive = isActive
        self.tint = tint
        self.idleTint = idleTint
    }

    public var body: some View {
        // The sample count depends on the room the view is given, so the model is read here, below
        // the geometry, and the canvas gets plain values: its draw closure touches no state.
        GeometryReader { proxy in
            TimelineView(
                .animation(
                    minimumInterval: reduceMotion ? DS.HUD.waveformReducedInterval : DS.HUD.waveformInterval,
                    paused: !isActive
                )
            ) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let count = Int((proxy.size.width / 2 / DS.HUD.traceSampleSpacing).rounded(.up)) + 1
                let amplitudes = isActive
                    ? source.amplitudes(count: count, seconds: DS.HUD.traceSeconds, at: time)
                    : []
                let style = Style(
                    tint: tint,
                    idleTint: idleTint,
                    reduceMotion: reduceMotion,
                    time: time
                )
                Canvas { context, size in
                    Self.draw(amplitudes: amplitudes, size: size, style: style, in: &context)
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Shape

    struct Style: Sendable {
        let tint: Color
        let idleTint: Color
        let reduceMotion: Bool
        let time: TimeInterval
    }

    /// The silhouette's edges at evenly spaced x across the width (`DS.HUD.traceSampleSpacing`
    /// apart, ends included), as y in points from the top, plus the rim's width at each sample.
    struct Outline: Equatable, Sendable {
        var top: [CGFloat]
        var bottom: [CGFloat]
        var rim: [CGFloat]
    }

    /// Hermite smoothstep from 0 at `edge0` to 1 at `edge1`.
    nonisolated static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    /// A very slow swell in -1...1 along the trace (`x` in points from the middle) and in time.
    /// `seed` makes each strand's different.
    nonisolated static func wobble(x: Double, time: TimeInterval, seed: Double) -> Double {
        sin(2 * .pi * (x / DS.HUD.traceWritheLength - time * DS.HUD.traceWritheRate + seed))
    }

    /// `levels` blurred along the trace with a gaussian (`sigma` in samples). The first value is
    /// the middle and the history is mirrored there, so the blur never opens a notch at the
    /// middle; past the oldest value the last one is held.
    nonisolated static func smoothed(_ levels: [Float], sigma: Double) -> [Double] {
        guard sigma > 0.01, levels.count > 1 else { return levels.map(Double.init) }
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var weights = [Double](repeating: 0, count: radius * 2 + 1)
        var total = 0.0
        for slot in weights.indices {
            let offset = Double(slot - radius)
            weights[slot] = exp(-offset * offset / (2 * sigma * sigma))
            total += weights[slot]
        }
        var result = [Double](repeating: 0, count: levels.count)
        for index in levels.indices {
            var sum = 0.0
            for slot in weights.indices {
                let source = min(levels.count - 1, abs(index + slot - radius))
                sum += weights[slot] * Double(levels[source])
            }
            result[index] = sum / total
        }
        return result
    }

    /// The same blur over an edge's samples, with the ends held. Takes the creases out where one
    /// strand's edge crosses another's.
    nonisolated static func blurred(_ values: [Double], sigma: Double) -> [Double] {
        guard sigma > 0.01, values.count > 1 else { return values }
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var weights = [Double](repeating: 0, count: radius * 2 + 1)
        var total = 0.0
        for slot in weights.indices {
            let offset = Double(slot - radius)
            weights[slot] = exp(-offset * offset / (2 * sigma * sigma))
            total += weights[slot]
        }
        return values.indices.map { index in
            var sum = 0.0
            for slot in weights.indices {
                sum += weights[slot] * values[min(values.count - 1, max(0, index + slot - radius))]
            }
            return sum / total
        }
    }

    /// The samples' x positions for a width: at least two, the first at 0 and the last at `width`.
    nonisolated static func sampleCount(width: CGFloat) -> Int {
        max(2, Int((max(0, width) / DS.HUD.traceSampleSpacing).rounded(.up))) + 1
    }

    /// The silhouette for the level `levels[d]` at `d` samples from the middle (0...1, newest
    /// first; empty is silence), a size and a time for the motion. Pure, so a test can read it.
    ///
    /// Per sample each strand has a centre height and a half thickness; the silhouette is their
    /// envelope, and never thinner than a body that fills in around their mean as the level climbs.
    nonisolated static func outline(levels: [Float], width: CGFloat, height: CGFloat, time: TimeInterval, reduceMotion: Bool) -> Outline {
        let count = sampleCount(width: width)
        let half = Double(height) / 2
        let thin = DS.HUD.traceThinHalf
        let loud = DS.HUD.traceLoudHalf
        let limit = max(thin, half - 0.5)
        let strands = min(DS.HUD.traceStrandWavelengths.count, DS.HUD.traceStrandSpeeds.count, DS.HUD.traceStrandPhases.count)
        let clock = reduceMotion ? 0 : time
        let middle = Double(width) / 2
        // How far a strand's centre may swing and leave room for its own thickness.
        let room = max(0, min(half - loud, limit - loud))
        let sigma = DS.HUD.traceSmoothLength / Double(DS.HUD.traceSampleSpacing)
        let smooth = smoothed(levels, sigma: sigma)

        var top = [Double](repeating: 0, count: count)
        var bottom = [Double](repeating: 0, count: count)
        var voices = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let x = Double(width) * Double(index) / Double(count - 1)
            let distance = abs(x - middle)
            let age = middle > 0 ? min(1, distance / middle) : 1
            var level = 0.0
            if !smooth.isEmpty, strands > 0 {
                let position = distance / Double(DS.HUD.traceSampleSpacing)
                let lower = min(smooth.count - 1, Int(position))
                let upper = min(smooth.count - 1, lower + 1)
                level = smooth[lower] + (smooth[upper] - smooth[lower]) * (position - Double(lower))
            }
            // The mass thins smoothly onto the middle line at the edges.
            let close = 1 - smoothstep(1 - DS.HUD.traceEdgeTaper, 1, age)
            let voice = level * close
            voices[index] = voice
            guard voice > 0, strands > 0 else {
                top[index] = thin
                bottom[index] = -thin
                continue
            }
            let signed = x - middle
            var high = -Double.infinity
            var low = Double.infinity
            var mean = 0.0
            var swingSum = 0.0
            var halfSum = 0.0
            for strand in 0..<strands {
                let swell = 1 + DS.HUD.traceWritheDepth * wobble(x: signed, time: clock, seed: Double(strand) * 0.37)
                let speed = DS.HUD.traceStrandSpeeds[strand] * DS.HUD.traceCarrierSpeed
                let phase = signed / DS.HUD.traceStrandWavelengths[strand] - clock * speed + DS.HUD.traceStrandPhases[strand]
                let swing = min(room, voice * DS.HUD.traceReach * room * swell)
                let centre = swing * sin(2 * .pi * phase)
                let thickness = thin + (loud - thin) * min(1, voice * swell)
                high = max(high, centre + thickness)
                low = min(low, centre - thickness)
                mean += centre / Double(strands)
                swingSum += swing / Double(strands)
                halfSum += thickness / Double(strands)
            }
            let body = smoothstep(DS.HUD.traceBodyFrom, DS.HUD.traceBodyTo, voice)
            let bodyReach = DS.HUD.traceBodyReach * swingSum + halfSum
            high = max(high, high + (mean + bodyReach - high) * body)
            low = min(low, low + (mean - bodyReach - low) * body)
            top[index] = high
            bottom[index] = low
        }
        // Blur the edges a little, then keep them inside the room and never thinner than the
        // hairline. The top is stored as height above the middle, so flip it on the way out.
        let edgeSigma = DS.HUD.traceEdgeSmoothLength / Double(DS.HUD.traceSampleSpacing)
        let upper = blurred(top, sigma: edgeSigma)
        let lower = blurred(bottom, sigma: edgeSigma)
        var result = Outline(top: [], bottom: [], rim: [])
        for index in 0..<count {
            let up = min(limit, max(thin, upper[index]))
            let down = min(limit, max(thin, -lower[index]))
            result.top.append(CGFloat(half - up))
            result.bottom.append(CGFloat(half + down))
            let rimShare = smoothstep(0, DS.HUD.traceBodyFrom, voices[index])
            let room = max(0, limit - max(up, down))
            result.rim.append(CGFloat(min(room, DS.HUD.traceRimWidth * rimShare)))
        }
        return result
    }

    /// One closed shape through the outline: the top edge left to right, the bottom back. Quadratic
    /// curves run through the midpoints between samples, so the edge has no facets. `grow` pushes
    /// the edges outward by the rim's width times `grow`.
    nonisolated static func path(_ outline: Outline, width: CGFloat, grow: CGFloat) -> Path {
        let count = outline.top.count
        var path = Path()
        guard count > 1 else { return path }
        func x(_ index: Int) -> CGFloat { width * CGFloat(index) / CGFloat(count - 1) }
        func edge(_ values: [CGFloat], direction: CGFloat) -> [CGPoint] {
            (0..<count).map { CGPoint(x: x($0), y: values[$0] + direction * grow * outline.rim[$0]) }
        }
        func trace(_ points: [CGPoint], into path: inout Path, moveFirst: Bool) {
            if moveFirst { path.move(to: points[0]) } else { path.addLine(to: points[0]) }
            for index in 1..<points.count - 1 {
                let mid = CGPoint(
                    x: (points[index].x + points[index + 1].x) / 2,
                    y: (points[index].y + points[index + 1].y) / 2
                )
                path.addQuadCurve(to: mid, control: points[index])
            }
            path.addLine(to: points[points.count - 1])
        }
        trace(edge(outline.top, direction: -1), into: &path, moveFirst: true)
        trace(Array(edge(outline.bottom, direction: 1).reversed()), into: &path, moveFirst: false)
        path.closeSubpath()
        return path
    }

    /// Draws the rim, then the body, as two fills of one silhouette. `amplitudes` runs from the
    /// middle (the newest) to an edge; empty draws the idle hairline. Internal so a test can render it.
    static func draw(amplitudes: [Float], size: CGSize, style: Style, in context: inout GraphicsContext) {
        let active = !amplitudes.isEmpty
        let shape = outline(
            levels: amplitudes, width: size.width, height: size.height,
            time: style.time, reduceMotion: style.reduceMotion
        )
        guard active else {
            // No audio yet: a hairline and nothing that moves.
            context.fill(path(shape, width: size.width, grow: 0), with: .color(style.idleTint))
            return
        }
        context.fill(path(shape, width: size.width, grow: 1), with: .color(style.tint.opacity(DS.HUD.traceRimOpacity)))
        context.fill(path(shape, width: size.width, grow: 0), with: .color(style.tint))
    }
}
