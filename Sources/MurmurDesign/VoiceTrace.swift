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

    func trace(points: Int, at time: TimeInterval) -> [Float] {
        model.trace(points: points, at: time)
    }

    var historySeconds: TimeInterval { model.parameters.historySeconds }
}

/// The listening trace: one red line across the capsule. The middle is now and older sound
/// drifts out towards both edges, fading, so a pause still shows the last words leaving.
/// Its height is the level between the room's floor and the speech peak (`VoiceTraceModel`),
/// and a sine carrier running along the line makes it read as a live trace.
///
/// Inactive, it is a flat line in `idleTint` and the clock is paused. Red means recording, so
/// the keyboard passes a neutral `idleTint` for the time before the hold has heard audio.
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
        TimelineView(
            .animation(
                minimumInterval: reduceMotion ? DS.HUD.waveformReducedInterval : DS.HUD.waveformInterval,
                paused: !isActive
            )
        ) { timeline in
            // The model is read here, in the view's body, and the canvas gets plain values, so
            // the draw closure touches no state.
            let time = timeline.date.timeIntervalSinceReferenceDate
            let values = isActive ? source.trace(points: DS.HUD.traceSegmentsPerSide, at: time) : []
            let style = Style(
                tint: isActive ? tint : idleTint,
                reduceMotion: reduceMotion,
                time: time
            )
            Canvas { context, size in
                Self.draw(values: values, style: style, in: &context, size: size)
            }
        }
        .frame(width: DS.HUD.waveformWidth, height: DS.HUD.waveformHeight)
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    struct Style: Sendable {
        let tint: Color
        let reduceMotion: Bool
        let time: TimeInterval
    }

    /// Opacity at `index` of `count` steps from the middle: 1 for the newest, fading to the edge value.
    static func opacity(index: Int, of count: Int) -> Double {
        guard count > 0 else { return 1 }
        let age = Double(index) / Double(count)
        return DS.HUD.traceEdgeOpacity + (1 - DS.HUD.traceEdgeOpacity) * pow(1 - age, DS.HUD.traceFadeExponent)
    }

    /// The carrier at distance `x` along the line, in -1...1: a sine that travels with time, plus
    /// a faster, fainter one, so the line is not a pure tone.
    static func carrier(x: CGFloat, time: TimeInterval, reduceMotion: Bool) -> CGFloat {
        let travel = reduceMotion ? 0 : time * DS.HUD.traceCarrierSpeed
        let cycles = Double(x / DS.HUD.traceCarrierWavelength)
        let base = sin(2 * .pi * (cycles - travel))
        let harmonic = sin(2 * .pi * (cycles * DS.HUD.traceHarmonicRatio + travel * DS.HUD.traceHarmonicDrift + DS.HUD.traceHarmonicPhase))
        let share = DS.HUD.traceHarmonicShare
        return CGFloat((1 - share) * base + share * harmonic)
    }

    /// Draws the line, then a blurred copy behind it. `values` runs from the middle (the newest)
    /// to an edge; empty draws a flat line. Internal so a test can render it.
    static func draw(values: [Float], style: Style, in context: inout GraphicsContext, size: CGSize) {
        let steps = values.count - 1
        let middle = size.height / 2
        let amplitude = middle - DS.HUD.traceLineWidth
        let half = size.width / 2

        guard steps > 0 else {
            var flat = Path()
            flat.move(to: CGPoint(x: 0, y: middle))
            flat.addLine(to: CGPoint(x: size.width, y: middle))
            context.stroke(
                flat,
                with: .color(style.tint),
                style: StrokeStyle(lineWidth: DS.HUD.traceLineWidth, lineCap: .round)
            )
            return
        }

        // One point per slot from the left edge to the right edge; the age index counts out from the middle.
        let points: [(point: CGPoint, index: Int)] = (-steps...steps).map { offset in
            let index = abs(offset)
            let x = half + CGFloat(offset) / CGFloat(steps) * half
            let y = middle - CGFloat(values[index]) * amplitude
                * carrier(x: x, time: style.time, reduceMotion: style.reduceMotion)
            return (CGPoint(x: x, y: y), index)
        }

        // Runs of `traceFadeRun` segments share an opacity and are stroked as one path, so a
        // round cap never doubles a translucent joint into a bead. The fade is in those steps.
        func stroke(into layer: inout GraphicsContext, width: CGFloat, scale: Double) {
            var run = Path()
            var runKey = -1
            var runAge = 0
            func flush(_ layer: inout GraphicsContext) {
                guard runKey >= 0 else { return }
                layer.stroke(
                    run,
                    with: .color(style.tint.opacity(opacity(index: runAge, of: steps) * scale)),
                    style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
                )
                run = Path()
            }
            for pair in zip(points, points.dropFirst()) {
                // The segment takes the age of its older end, so the line never brightens outward.
                let age = max(pair.0.index, pair.1.index)
                let key = age / DS.HUD.traceFadeRun
                if key != runKey {
                    flush(&layer)
                    runKey = key
                    runAge = key * DS.HUD.traceFadeRun
                    run.move(to: pair.0.point)
                }
                run.addLine(to: pair.1.point)
            }
            flush(&layer)
        }

        if !style.reduceMotion {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: DS.HUD.traceGlowBlur))
                stroke(into: &layer, width: DS.HUD.traceGlowWidth, scale: DS.HUD.traceGlowOpacity)
            }
        }
        stroke(into: &context, width: DS.HUD.traceLineWidth, scale: 1)
    }
}
