import AppKit

/// Murmur's three interface sounds, played off the main thread.
///
/// `NSSound.play()` returns only after the sound has been handed to the output device. On
/// 2026-11-13 that took 0.22, 0.30 and 0.24 s on three presses in a row, on the main thread,
/// in the key-down handler: the model wake, the engine start and the HUD all waited behind
/// the start sound. Nothing here needs the main thread, so the sounds get a queue of their
/// own and the caller returns at once. The cue is heard no later than before.
enum Sounds {
    enum Cue: String, CaseIterable, Sendable {
        /// The hold began.
        case start = "Tink"
        /// The text was delivered.
        case delivered = "Pop"
        /// A comparison finished.
        case compared = "Glass"
    }

    private static let queue = DispatchQueue(label: "ai.pivotstudio.murmur.sounds", qos: .userInitiated)
    /// Loaded once and reused. Read and written on `queue` only.
    nonisolated(unsafe) private static var loaded: [Cue: NSSound] = [:]

    /// Loads the sounds ahead of the first press, so that press does not pay for the read.
    static func preload() {
        queue.async {
            for cue in Cue.allCases { _ = sound(for: cue) }
        }
    }

    /// Plays the cue from its start, cutting off an earlier play of the same cue.
    static func play(_ cue: Cue) {
        queue.async {
            let sound = sound(for: cue)
            sound?.stop()
            sound?.play()
        }
    }

    private static func sound(for cue: Cue) -> NSSound? {
        if let sound = loaded[cue] { return sound }
        let sound = NSSound(named: cue.rawValue)
        loaded[cue] = sound
        return sound
    }
}
