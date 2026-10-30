import SwiftUI

/// The listening capsule: Liquid Glass with an ink outline, red bars because it only shows
/// while a hold is live. Glass rather than a card because it floats over other apps, and
/// glass is the one material that sits well over content you don't control.
struct HUDView: View {
    @Bindable var controller: DictationController

    var body: some View {
        Waveform(level: controller.level, isActive: controller.state.isActive)
            .frame(width: DS.HUD.waveformWidth, height: DS.HUD.waveformHeight)
            .frame(width: DS.HUD.width, height: DS.HUD.height)
            .glassEffect(.regular, in: .capsule)
            .overlay {
                Capsule().strokeBorder(DS.Color.ink.opacity(DS.Glass.outlineOpacity), lineWidth: DS.Glass.outline)
            }
            .padding(DS.HUD.margin)
    }
}

/// Level-reactive bars. Each bar gets a fixed phase offset so the group ripples rather
/// than pumping in unison.
private struct Waveform: View {
    let level: Float
    let isActive: Bool

    private static let barCount = DS.HUD.waveformBarCount
    private static let phases: [Double] = (0..<barCount).map { index in
        // Irrational multiplier keeps the offsets from lining up into a visible period.
        (Double(index) * 0.618).truncatingRemainder(dividingBy: 1)
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
        // Wave rides on top of the level so bars still breathe during quiet passages.
        let scaled = amplitude
            * (DS.HUD.waveformLevelFloor + DS.HUD.waveformLevelRange * Double(wave))
            * envelope
        return DS.HUD.waveformFloorHeight
            + max(0, CGFloat(scaled)) * DS.HUD.waveformAmplitude
    }
}
