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

/// The listening trace: a dot matrix with three strands braided through it. The middle column is
/// now and older sound drifts out towards both edges, fading, so a pause still shows the last words
/// leaving. A strand's height at a column is the level (`VoiceTraceModel`) at that column's age times
/// half the grid's height, so silence closes the braid onto the bright middle row and speech swells
/// it. Dots near a strand are brighter and a little larger, with a halo; every dot is faintly drawn.
///
/// Inactive, it is the dim grid with a flat middle row in `idleTint` and the clock is paused. Red
/// means recording, so the keyboard passes a neutral `idleTint` for the time before the hold has
/// heard audio.
public struct VoiceTrace: View {
    let source: VoiceTraceSource
    let isActive: Bool
    let tint: Color
    let idleTint: Color
    let pitch: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        source: VoiceTraceSource,
        isActive: Bool,
        tint: Color = DS.Color.record,
        idleTint: Color = DS.Color.record,
        pitch: CGFloat = DS.HUD.traceDotPitch
    ) {
        self.source = source
        self.isActive = isActive
        self.tint = tint
        self.idleTint = idleTint
        self.pitch = pitch
    }

    public var body: some View {
        // The grid depends on the room the view is given, so the model is read here, below the
        // geometry, and the canvas gets plain values: its draw closure touches no state.
        GeometryReader { proxy in
            let grid = Grid(size: proxy.size, pitch: pitch)
            TimelineView(
                .animation(
                    minimumInterval: reduceMotion ? DS.HUD.waveformReducedInterval : DS.HUD.waveformInterval,
                    paused: !isActive
                )
            ) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let amplitudes = isActive
                    ? source.amplitudes(count: grid.middleColumn + 1, seconds: DS.HUD.traceSeconds, at: time)
                    : []
                let style = Style(
                    tint: tint,
                    idleTint: idleTint,
                    reduceMotion: reduceMotion,
                    time: time
                )
                Canvas { context, _ in
                    Self.draw(amplitudes: amplitudes, grid: grid, style: style, in: &context)
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    struct Style: Sendable {
        let tint: Color
        let idleTint: Color
        let reduceMotion: Bool
        let time: TimeInterval
    }

    /// Whole dots in the room given: an odd number of columns and rows, so there is a middle
    /// of each, centred in the space.
    struct Grid: Equatable, Sendable {
        let columns: Int
        let rows: Int
        let pitch: CGFloat
        let origin: CGPoint

        init(size: CGSize, pitch: CGFloat) {
            func odd(_ length: CGFloat) -> Int {
                let count = max(1, Int((max(0, length) / pitch).rounded(.down)))
                return count % 2 == 0 ? max(1, count - 1) : count
            }
            self.pitch = pitch
            columns = odd(size.width)
            rows = odd(size.height)
            origin = CGPoint(
                x: (size.width - CGFloat(columns) * pitch) / 2,
                y: (size.height - CGFloat(rows) * pitch) / 2
            )
        }

        var middleColumn: Int { columns / 2 }
        var middleRow: Int { rows / 2 }

        func center(column: Int, row: Int) -> CGPoint {
            CGPoint(
                x: origin.x + (CGFloat(column) + 0.5) * pitch,
                y: origin.y + (CGFloat(row) + 0.5) * pitch
            )
        }
    }

    /// Hermite smoothstep from 0 at `edge0` to 1 at `edge1`.
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    /// Brightness 0...1 of every dot, row-major (`row * columns + column`), for the level
    /// `amplitudes[d]` at `d` columns from the middle (0...1, newest first) and a time for the
    /// carrier. Pure, so a test can read it.
    static func brightness(amplitudes: [Float], grid: Grid, time: TimeInterval, reduceMotion: Bool) -> [Float] {
        var result = [Float](repeating: 0, count: grid.columns * grid.rows)
        let middle = grid.middleColumn
        guard middle > 0, !amplitudes.isEmpty else { return result }
        let halfRows = Double(grid.rows - 1) / 2
        let travel = reduceMotion ? 0 : time * DS.HUD.traceCarrierSpeed
        let strands = max(1, DS.HUD.traceStrands)
        let twoSigmaSquared = 2 * DS.HUD.traceStrandSigma * DS.HUD.traceStrandSigma
        var heights = [Double](repeating: 0, count: strands)

        for column in 0..<grid.columns {
            let distance = abs(column - middle)
            let age = Double(distance) / Double(middle)
            let level = Double(amplitudes[min(distance, amplitudes.count - 1)])
            // The strands close onto the middle row at the edges, as the old line did.
            let close = 1 - smoothstep(1 - DS.HUD.traceEdgeTaper, 1, age)
            let amplitude = level * halfRows * close
            let fade = DS.HUD.traceEdgeOpacity
                + (1 - DS.HUD.traceEdgeOpacity) * pow(1 - age, DS.HUD.traceFadeExponent)
            // Signed from the middle, so the two halves are not mirrors of each other.
            let phase = Double(column - middle) / DS.HUD.traceCarrierColumns - travel
            for strand in 0..<strands {
                heights[strand] = amplitude * sin(2 * .pi * (phase + Double(strand) / Double(strands)))
            }
            for row in 0..<grid.rows {
                let y = Double(grid.middleRow - row)
                var lit = 0.0
                for height in heights {
                    let offset = y - height
                    lit = max(lit, exp(-offset * offset / twoSigmaSquared))
                }
                result[row * grid.columns + column] = Float(lit * fade)
            }
        }
        return result
    }

    /// Draws the grid, then the lit dots by brightness. `amplitudes` runs from the middle (the
    /// newest) to an edge; empty draws the idle state. Internal so a test can render it.
    static func draw(amplitudes: [Float], grid: Grid, style: Style, in context: inout GraphicsContext) {
        let pitch = grid.pitch
        let active = !amplitudes.isEmpty
        let base = active ? style.tint : style.idleTint

        // The dim grid: every dot, one path, one fill.
        var dim = Path()
        let baseRadius = pitch * DS.HUD.traceBaseRadius
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                dim.addEllipse(in: dot(at: grid.center(column: column, row: row), radius: baseRadius))
            }
        }
        context.fill(dim, with: .color(base.opacity(DS.HUD.traceBaseOpacity)))

        guard active else {
            // No audio yet: a flat middle row and nothing that moves.
            var row = Path()
            let litRadius = pitch * DS.HUD.traceLitRadius
            for column in 0..<grid.columns {
                row.addEllipse(in: dot(at: grid.center(column: column, row: grid.middleRow), radius: litRadius))
            }
            context.fill(row, with: .color(base.opacity(DS.HUD.traceIdleRowOpacity)))
            return
        }

        let lit = brightness(amplitudes: amplitudes, grid: grid, time: style.time, reduceMotion: style.reduceMotion)
        let levels = max(1, DS.HUD.traceLevels)
        var centres = [[CGPoint]](repeating: [], count: levels)
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let value = Double(lit[row * grid.columns + column])
                guard value >= DS.HUD.traceLitThreshold else { continue }
                let level = min(levels - 1, Int((value * Double(levels)).rounded(.up)) - 1)
                centres[max(0, level)].append(grid.center(column: column, row: row))
            }
        }

        // Halos first, so a bright neighbour's glow never lies over a dot.
        for level in 0..<levels {
            let value = Double(level + 1) / Double(levels)
            guard !centres[level].isEmpty else { continue }
            let radius = pitch * (DS.HUD.traceLitRadius + (DS.HUD.traceHaloRadius - DS.HUD.traceLitRadius) * CGFloat(value))
            var halos = Path()
            for centre in centres[level] { halos.addEllipse(in: dot(at: centre, radius: radius)) }
            context.fill(halos, with: .color(style.tint.opacity(DS.HUD.traceHaloOpacity * value * value)))
        }
        for level in 0..<levels {
            let value = Double(level + 1) / Double(levels)
            guard !centres[level].isEmpty else { continue }
            let radius = pitch * (DS.HUD.traceBaseRadius + (DS.HUD.traceLitRadius - DS.HUD.traceBaseRadius) * CGFloat(value))
            var dots = Path()
            for centre in centres[level] { dots.addEllipse(in: dot(at: centre, radius: radius)) }
            let opacity = DS.HUD.traceBaseOpacity + (1 - DS.HUD.traceBaseOpacity) * value
            context.fill(dots, with: .color(style.tint.opacity(opacity)))
        }
    }

    private static func dot(at centre: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
    }
}
