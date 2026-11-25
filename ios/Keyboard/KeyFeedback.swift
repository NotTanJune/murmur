import MurmurKit
import UIKit

/// What every ordinary key does when a finger lands on it, as the stock iOS keyboard does: the
/// input click and a light haptic tap. The key plane fires it on every `.feedback` effect of
/// the typing engine (touch-down, and each delete repeat); buttons fire it from `KeyPressStyle`
/// and `PlainKeyStyle` at touch-down, not at release; the globe key, emoji cells and history
/// rows call it themselves. The m keeps only the click, because its own start pattern
/// (`KeyboardHaptics`) plays moments later and a third tap would blur it.
/// `Settings.hapticsEnabled` gates the tap, not the click; the click follows the system's
/// Keyboard Clicks setting on its own. A keyboard extension plays haptics only with Full Access.
@MainActor
enum KeyFeedback {
    /// One generator per style the owner can pick while the key tap is being tuned (Settings,
    /// Keyboard tuning). Once chosen, one generator and one strength stay.
    private static var taps: [KeyTapStyle: UIImpactFeedbackGenerator] = [:]

    /// Called once by the view controller, with its root view.
    static func attach(to view: UIView) {
        taps = [
            .light: UIImpactFeedbackGenerator(style: .light, view: view),
            .soft: UIImpactFeedbackGenerator(style: .soft, view: view),
            .rigid: UIImpactFeedbackGenerator(style: .rigid, view: view),
        ]
        taps[Settings.shared.keyTapStyle]?.prepare()
    }

    static func press() {
        UIDevice.current.playInputClick()
        let settings = Settings.shared
        guard settings.hapticsEnabled, let tap = taps[settings.keyTapStyle] else { return }
        tap.impactOccurred(intensity: CGFloat(min(max(settings.keyTapStrength, 0.1), 1)))
        // Keeps the Taptic Engine ready for the next key, so fast typing gets no late taps.
        tap.prepare()
    }
}
