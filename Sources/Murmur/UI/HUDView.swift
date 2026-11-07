import SwiftUI

/// The listening capsule: a dark pill with a soft shadow and red bars, because it only
/// shows while a hold is live. Opaque, because it floats over other apps' content.
struct HUDView: View {
    @Bindable var controller: DictationController

    var body: some View {
        Waveform(level: controller.level, isActive: controller.state.isActive)
            .frame(width: DS.HUD.waveformWidth, height: DS.HUD.waveformHeight)
            .frame(width: DS.HUD.width, height: DS.HUD.height)
            .background(DS.Color.hud, in: .capsule)
            .floatingShadow()
            .padding(DS.HUD.margin)
    }
}

/// Bars that follow the input level. Each has a fixed phase offset, so the group
/// ripples instead of pumping in unison.
private struct Waveform: View {
    let level: Float
    let isActive: Bool

    private static let barCount = DS.HUD.waveformBarCount
    /// Multiplying by about 1/golden-ratio spreads the offsets around the cycle, so no two
    /// neighbouring bars move together and no pattern repeats. Fixed for the process.
    private static let phases: [Double] = (0..<barCount).map {
        (Double($0) * 0.618).truncatingRemainder(dividingBy: 1)
    }

    var body: some View {
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
