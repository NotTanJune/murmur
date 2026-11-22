import CoreHaptics
import MurmurKit
import OSLog
import UIKit

/// The keyboard's haptics, beside its tones (`KeyboardSounds`). The start and done patterns are
/// the user's own, designed by feel on the phone on 2026-11-22 and played through Core Haptics:
///
///     start: tap@0 i1.00 s0.50 | tap@70 i1.00 s0.50
///     done:  buzz@0 i1.00 s0.20 d50 | tap@80 i1.00 s0.50 | tap@120 i1.00 s0.50
///
/// (`tap@T` is a transient at T ms, `buzz@T ... dD` a continuous event of D ms, `i` intensity and
/// `s` sharpness.) A pattern Core Haptics refuses falls back to the UIKit generators: one
/// `.medium` impact for the start, the system's success pattern for done. A failed hold always
/// plays the system's error pattern. `Settings.hapticsEnabled` turns all of it off; the Mac
/// ignores it.
///
/// The generators are attached to the keyboard's view (`init(style:view:)`, iOS 17.5), which
/// is how UIKit now wants them made. A keyboard extension plays haptics only with Full Access,
/// which Murmur's keyboard already needs for the microphone.
///
/// Main actor only. Callers fire after the attach (start) or after `insert` (typed), never ahead
/// of them, so nothing here can delay capture or the typed text.
@MainActor
final class KeyboardHaptics {
    private var start: UIImpactFeedbackGenerator?
    private var outcome: UINotificationFeedbackGenerator?
    private let player = HapticPlayer()
    private static let log = Logger(subsystem: "ai.pivotstudio.murmur", category: "speech")

    private static let startPattern = makePattern([
        .tap(atMs: 0, intensity: 1.0, sharpness: 0.5),
        .tap(atMs: 70, intensity: 1.0, sharpness: 0.5),
    ])

    private static let donePattern = makePattern([
        .buzz(atMs: 0, intensity: 1.0, sharpness: 0.2, durationMs: 50),
        .tap(atMs: 80, intensity: 1.0, sharpness: 0.5),
        .tap(atMs: 120, intensity: 1.0, sharpness: 0.5),
    ])

    private enum Event {
        case tap(atMs: Int, intensity: Float, sharpness: Float)
        case buzz(atMs: Int, intensity: Float, sharpness: Float, durationMs: Int)

        var hapticEvent: CHHapticEvent {
            switch self {
            case let .tap(atMs, intensity, sharpness):
                return CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: Self.parameters(intensity, sharpness),
                    relativeTime: TimeInterval(atMs) / 1000
                )
            case let .buzz(atMs, intensity, sharpness, durationMs):
                return CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: Self.parameters(intensity, sharpness),
                    relativeTime: TimeInterval(atMs) / 1000,
                    duration: TimeInterval(durationMs) / 1000
                )
            }
        }

        private static func parameters(_ intensity: Float, _ sharpness: Float) -> [CHHapticEventParameter] {
            [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ]
        }
    }

    /// Nil, logged, when Core Haptics refuses the events; the generators then stand in.
    private static func makePattern(_ events: [Event]) -> CHHapticPattern? {
        do {
            return try CHHapticPattern(events: events.map(\.hapticEvent), parameters: [])
        } catch {
            log.error("haptics: pattern refused: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Called once by the view controller, with its root view.
    func attach(to view: UIView) {
        start = UIImpactFeedbackGenerator(style: .medium, view: view)
        outcome = UINotificationFeedbackGenerator(view: view)
    }

    private var isEnabled: Bool { Settings.shared.hapticsEnabled }

    /// Plays `pattern` through Core Haptics. False means nothing played and the caller falls
    /// back to its generator.
    private func play(_ pattern: CHHapticPattern?) -> Bool {
        guard let pattern else { return false }
        return player.play(pattern)
    }

    /// Wakes the haptic engine at the press, so the start pattern lands without its spin-up
    /// delay when the first samples arrive.
    func prepareStart() {
        guard isEnabled else { return }
        player.prepare()
        start?.prepare()
    }

    /// At the release, so the typed or failed pattern is ready when the text lands.
    func prepareOutcome() {
        guard isEnabled else { return }
        player.prepare()
        outcome?.prepare()
    }

    /// The microphone hears this hold: the same moment as the start tone.
    func started() {
        guard isEnabled else { return }
        if play(Self.startPattern) { return }
        start?.impactOccurred()
    }

    /// The hold's text was typed.
    func typed() {
        guard isEnabled else { return }
        if play(Self.donePattern) { return }
        outcome?.notificationOccurred(.success)
    }

    /// The hold failed: nothing will be typed.
    func failed() {
        guard isEnabled else { return }
        outcome?.notificationOccurred(.error)
    }
}
