import MurmurKit
import UIKit

/// What every ordinary key does when a finger lands on it, as the stock iOS keyboard does: the
/// input click and a light haptic tap. Buttons fire it from `KeyPressStyle` and `PlainKeyStyle`
/// at touch-down, not at release; the delete key, the globe key, emoji cells and history rows
/// call it themselves. The talk key keeps only the click, because its own start pattern
/// (`KeyboardHaptics`) plays moments later and a third tap would blur it.
/// `Settings.hapticsEnabled` gates the tap, not the click; the click follows the system's
/// Keyboard Clicks setting on its own. A keyboard extension plays haptics only with Full Access.
@MainActor
enum KeyFeedback {
    private static var tap: UIImpactFeedbackGenerator?

    /// Called once by the view controller, with its root view.
    static func attach(to view: UIView) {
        tap = UIImpactFeedbackGenerator(style: .light, view: view)
        tap?.prepare()
    }

    static func press() {
        UIDevice.current.playInputClick()
        guard Settings.shared.hapticsEnabled, let tap else { return }
        tap.impactOccurred()
        // Keeps the Taptic Engine ready for the next key, so fast typing gets no late taps.
        tap.prepare()
    }
}
