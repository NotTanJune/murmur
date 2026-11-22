import MurmurKit
import UIKit

/// The keyboard's haptics, beside its tones (`KeyboardSounds`): one firm tap when dictation
/// starts, the system's success pattern (a double tap) when the text is typed, and its error
/// pattern when a hold fails. `Settings.hapticsEnabled` turns them off; the Mac ignores it.
///
/// The generators are attached to the keyboard's view (`init(style:view:)`, iOS 17.5), which
/// is how UIKit now wants them made. A keyboard extension plays haptics only with Full Access,
/// which Murmur's keyboard already needs for the microphone. Whether they play while WebKit is
/// recording is unverified on a device.
///
/// Main actor only. Callers fire after the attach (start) or after `insert` (typed), never ahead
/// of them, so nothing here can delay capture or the typed text.
@MainActor
final class KeyboardHaptics {
    private var start: UIImpactFeedbackGenerator?
    private var outcome: UINotificationFeedbackGenerator?

    /// Called once by the view controller, with its root view.
    func attach(to view: UIView) {
        start = UIImpactFeedbackGenerator(style: .medium, view: view)
        outcome = UINotificationFeedbackGenerator(view: view)
    }

    private var isEnabled: Bool { Settings.shared.hapticsEnabled }

    /// Wakes the Taptic Engine at the press, so the start tap lands without its spin-up delay
    /// when the first samples arrive.
    func prepareStart() {
        guard isEnabled else { return }
        start?.prepare()
    }

    /// At the release, so the typed or failed pattern is ready when the text lands.
    func prepareOutcome() {
        guard isEnabled else { return }
        outcome?.prepare()
    }

    /// The microphone hears this hold: the same moment as the start tone.
    func started() {
        guard isEnabled else { return }
        start?.impactOccurred()
    }

    /// The hold's text was typed.
    func typed() {
        guard isEnabled else { return }
        outcome?.notificationOccurred(.success)
    }

    /// The hold failed: nothing will be typed.
    func failed() {
        guard isEnabled else { return }
        outcome?.notificationOccurred(.error)
    }
}
