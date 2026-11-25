import MurmurDesign
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
    /// The light impact at `DS.Keyboard.keyTapStrength` (0.7): the owner chose both by feel on
    /// 2026-11-25, after full strength made typing feel heavy.
    private static var tap: UIImpactFeedbackGenerator?

    /// Called once by the view controller, with its root view.
    static func attach(to view: UIView) {
        tap = UIImpactFeedbackGenerator(style: .light, view: view)
        tap?.prepare()
    }

    static func press() {
        UIDevice.current.playInputClick()
        guard Settings.shared.hapticsEnabled, let tap else { return }
        tap.impactOccurred(intensity: DS.Keyboard.keyTapStrength)
        // Keeps the Taptic Engine ready for the next key, so fast typing gets no late taps.
        tap.prepare()
    }
}
