import MurmurKit
import OSLog
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

    // TEMPORARY, the Haptic Lab: when its switch is on the start and done haptics are the user's
    // own Core Haptics patterns (`HapticLabStore`), read at play time, falling back to the
    // generators above on any failure. Delete with the lab (AGENTS.md, "Haptic lab").
    private let lab = HapticPlayer()
    private static let log = Logger(subsystem: "ai.pivotstudio.murmur", category: "speech")

    /// The lab's pattern for `slot`, when the lab is switched on and one is stored and non-empty.
    private func labPattern(_ slot: HapticSlot) -> HapticPattern? {
        guard HapticLabStore.isActive, let pattern = HapticLabStore.load(slot), !pattern.events.isEmpty else {
            return nil
        }
        return pattern
    }

    /// Plays the lab's pattern for `slot`. False means nothing was played and the caller falls
    /// back to the built-in haptic.
    private func playLab(_ slot: HapticSlot) -> Bool {
        guard let pattern = labPattern(slot) else { return false }
        if lab.play(pattern) {
            Self.log.info("haptic lab: played \(slot.rawValue, privacy: .public) pattern (\(pattern.events.count) events) via Core Haptics")
            return true
        }
        Self.log.error("haptic lab: \(slot.rawValue, privacy: .public) pattern failed, using the built-in haptic")
        return false
    }

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
        if labPattern(.start) != nil { lab.prepare() }
        start?.prepare()
    }

    /// At the release, so the typed or failed pattern is ready when the text lands.
    func prepareOutcome() {
        guard isEnabled else { return }
        if labPattern(.done) != nil { lab.prepare() }
        outcome?.prepare()
    }

    /// The microphone hears this hold: the same moment as the start tone.
    func started() {
        guard isEnabled else { return }
        if playLab(.start) { return }
        start?.impactOccurred()
    }

    /// The hold's text was typed.
    func typed() {
        guard isEnabled else { return }
        if playLab(.done) { return }
        outcome?.notificationOccurred(.success)
    }

    /// The hold failed: nothing will be typed.
    func failed() {
        guard isEnabled else { return }
        outcome?.notificationOccurred(.error)
    }
}
