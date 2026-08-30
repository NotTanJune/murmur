import SwiftUI

/// Brand palette. Deliberately minimal for the skeleton — this is the surface the real
/// branding pass will replace.
enum Brand {
    static let accent = Color(red: 0.42, green: 0.55, blue: 1.0)
    static let accentWarm = Color(red: 0.76, green: 0.47, blue: 1.0)

    static var gradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentWarm],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

struct HUDView: View {
    @Bindable var controller: DictationController

    var body: some View {
        Waveform(level: controller.level, isActive: controller.state.isActive)
            .frame(width: DS.HUD.waveformWidth, height: DS.HUD.waveformHeight)
            .frame(width: DS.HUD.width, height: DS.HUD.height)
            .background(DS.Color.deck, in: silhouette)
            .overlay {
                silhouette.strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            }
            .clipShape(silhouette)
            .shadow(
                color: DS.Shadow.hud.color,
                radius: DS.Shadow.hud.radius,
                x: DS.Shadow.hud.x,
                y: DS.Shadow.hud.y
            )
    }

    private var silhouette: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.HUD.cornerRadius, style: .continuous)
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
                        .fill(DS.Color.meterAmber)
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
