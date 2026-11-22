import SwiftUI

/// Bars that follow the input level. Each has a fixed phase offset, so the group
/// ripples instead of pumping in unison. Applies no gain: callers scale the level they pass.
public struct Waveform: View {
    let level: Float
    let isActive: Bool

    public init(level: Float, isActive: Bool) {
        self.level = level
        self.isActive = isActive
    }

    private static let barCount = DS.HUD.waveformBarCount
    /// Multiplying by about 1/golden-ratio spreads the offsets around the cycle, so no two
    /// neighbouring bars move together and no pattern repeats. Fixed for the process.
    private static let phases: [Double] = (0..<barCount).map {
        (Double($0) * 0.618).truncatingRemainder(dividingBy: 1)
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: DS.HUD.waveformInterval, paused: !isActive)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: DS.HUD.waveformBarSpacing) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: DS.HUD.waveformBarRadius, style: .continuous)
                        .fill(DS.Color.record)
                        .frame(
                            width: DS.HUD.waveformBarWidth,
                            height: height(for: index, at: t)
                        )
                }
            }
            .frame(width: DS.HUD.waveformWidth, height: DS.HUD.waveformHeight)
        }
    }

    private func height(for index: Int, at time: TimeInterval) -> CGFloat {
        guard isActive else { return DS.HUD.waveformFloorHeight }

        let phase = Self.phases[index]
        let wave = sin(time * DS.HUD.waveformFrequency + phase * .pi * 2)
        let envelope = DS.HUD.waveformEnvelopeFloor
            + DS.HUD.waveformEnvelopeRange
            * sin((Double(index) + 1) / Double(Self.barCount + 1) * .pi)
        let amplitude = Double(max(DS.HUD.waveformMinimumLevel, min(level, 1)))
        // The wave term below never reaches zero, so quiet input still moves the bars.
        let scaled = amplitude
            * (DS.HUD.waveformLevelFloor + DS.HUD.waveformLevelRange * Double(wave))
            * envelope
        return DS.HUD.waveformFloorHeight
            + max(0, CGFloat(scaled)) * DS.HUD.waveformAmplitude
    }
}
