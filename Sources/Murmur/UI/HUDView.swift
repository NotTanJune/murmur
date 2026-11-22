import SwiftUI
import MurmurDesign

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
