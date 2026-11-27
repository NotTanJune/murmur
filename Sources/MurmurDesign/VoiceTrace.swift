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

/// The listening trace: a silk line with fanned echoes (style A7 of the trace lab, chosen by the
/// owner on 2026-11-27). One crisp line is a slow sine whose height follows the voice now, pinned
/// flat at both ends; four fainter, thinner copies trail it, each a little later in phase and a
/// little lower, so they fan out like threads. No blur and no gradient: five strokes.
///
/// Inactive, it is one hairline along the middle in `idleTint` and the clock is paused. Red means
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
        // The model is read here and the canvas gets plain values: its draw closure touches no
        // state.
        TimelineView(
            .animation(
                minimumInterval: reduceMotion ? DS.HUD.waveformReducedInterval : DS.HUD.waveformInterval,
                paused: !isActive
            )
        ) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let amplitudes = isActive
                ? source.amplitudes(count: DS.HUD.traceLevelSamples, seconds: DS.HUD.traceLevelWindow, at: time)
                : []
            let style = Style(tint: tint, idleTint: idleTint, reduceMotion: reduceMotion, time: time)
            Canvas { context, size in
                Self.draw(amplitudes: amplitudes, size: size, style: style, in: &context)
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

    /// One line of the fan: y in points from the top at evenly spaced x across the width
    /// (`DS.HUD.traceSampleSpacing` apart, ends included), with its stroke width and opacity.
    struct Strand: Equatable, Sendable {
        var y: [CGFloat]
        var width: CGFloat
        var opacity: Double
    }

    /// Hermite smoothstep from 0 at `edge0` to 1 at `edge1`.
    nonisolated static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    /// The samples across a width: at least two, the first at 0 and the last at `width`.
    nonisolated static func sampleCount(width: CGFloat) -> Int {
        max(2, Int((max(0, width) / DS.HUD.traceSampleSpacing).rounded(.up))) + 1
    }

    /// The fan for a voice level (0...1) at a size and time, faintest first and the main line
    /// last. Pure, so a test can read it. Each line is a sine of `traceCycles` waves across the
    /// width travelling at `traceSpeed`; an echo's phase trails by `lag x traceEchoPhase` and its
    /// height drops by `lag x traceEchoFalloff`. Every line closes onto the middle over the outer
    /// `traceTaper` of each side.
    nonisolated static func strands(level: Double, width: CGFloat, height: CGFloat, time: TimeInterval, reduceMotion: Bool) -> [Strand] {
        let count = sampleCount(width: width)
        let middle = Double(height) / 2
        let voice = min(1, max(0, level))
        let clock = reduceMotion ? 0 : time
        let lines = min(DS.HUD.traceEchoLags.count, DS.HUD.traceEchoOpacities.count, DS.HUD.traceEchoWidths.count)
        // Room for the widest stroke's round cap, so the fan never leaves the view.
        let room = max(0, middle - Double(DS.HUD.traceEchoWidths.max() ?? 0) / 2)
        return (0..<lines).map { line in
            let lag = DS.HUD.traceEchoLags[line]
            let amplitude = min(room, Double(height) * DS.HUD.traceReach * voice * (1 - lag * DS.HUD.traceEchoFalloff))
            let ys = (0..<count).map { index -> CGFloat in
                let u = Double(index) / Double(count - 1)
                let edge = min(u, 1 - u) / DS.HUD.traceTaper
                let pin = edge >= 1 ? 1 : smoothstep(0, 1, edge)
                let phase = u * 2 * .pi * DS.HUD.traceCycles + clock * DS.HUD.traceSpeed - lag * DS.HUD.traceEchoPhase
                return CGFloat(middle + sin(phase) * amplitude * pin)
            }
            return Strand(y: ys, width: DS.HUD.traceEchoWidths[line], opacity: DS.HUD.traceEchoOpacities[line])
        }
    }

    /// An open path through a strand's samples. Quadratic curves run through the midpoints
    /// between samples, so the line has no facets.
    nonisolated static func path(_ ys: [CGFloat], width: CGFloat) -> Path {
        var path = Path()
        let count = ys.count
        guard count > 1 else { return path }
        func point(_ index: Int) -> CGPoint {
            CGPoint(x: width * CGFloat(index) / CGFloat(count - 1), y: ys[index])
        }
        path.move(to: point(0))
        for index in 1..<count - 1 {
            let here = point(index), next = point(index + 1)
            path.addQuadCurve(to: CGPoint(x: (here.x + next.x) / 2, y: (here.y + next.y) / 2), control: here)
        }
        path.addLine(to: point(count - 1))
        return path
    }

    /// Strokes the fan, faintest first. `amplitudes` are the levels of the last
    /// `DS.HUD.traceLevelWindow`; the loudest of them drives the fan, so a gap of a few
    /// milliseconds between syllables does not flatten it. Empty draws the idle hairline.
    /// Internal so a test can render it.
    static func draw(amplitudes: [Float], size: CGSize, style: Style, in context: inout GraphicsContext) {
        guard let level = amplitudes.max() else {
            // No audio yet: a hairline and nothing that moves.
            let flat = [CGFloat](repeating: size.height / 2, count: 2)
            context.stroke(
                path(flat, width: size.width), with: .color(style.idleTint),
                style: StrokeStyle(lineWidth: DS.HUD.traceIdleWidth, lineCap: .round)
            )
            return
        }
        for strand in strands(level: Double(level), width: size.width, height: size.height, time: style.time, reduceMotion: style.reduceMotion) {
            context.stroke(
                path(strand.y, width: size.width), with: .color(style.tint.opacity(strand.opacity)),
                style: StrokeStyle(lineWidth: strand.width, lineCap: .round, lineJoin: .round)
            )
        }
    }
}
