import AudioToolbox
import AVFAudio

/// The keyboard's start and done tones, as the Mac's `Sounds.play(.start)` and `.delivered`.
///
/// The Mac plays Tink and Pop, which are macOS system files and cannot be bundled here, so the
/// phone uses iOS system sounds through `AudioServicesPlaySystemSound`. The API is public; the
/// IDs are not documented by Apple and are only known from the system's own sound list:
/// 1113 is the begin-recording tone and 1114 the end-recording tone. They play through the
/// system sound server, so they need no audio session of ours, follow the ringer switch and
/// volume, and do not touch the microphone's route. Whether they play inside a keyboard
/// extension, with and without Full Access, and while WebKit is recording, is unverified on a
/// device. If Apple renumbers them a sound simply does not play; nothing else depends on it.
enum KeyboardSounds {
    enum Cue: UInt32 {
        /// The hold began: `begin_record.caf`.
        case start = 1113
        /// The text was typed: `end_record.caf`.
        case done = 1114
    }

    /// Plays a cue off the main actor. `AudioServicesPlaySystemSound` returns at once, but the
    /// call still crosses to the system sound server; keeping it off the main actor means a slow
    /// answer there can never delay capture or the typed text. Callers invoke it after the
    /// attach (start) or after `insert` (done), never ahead of them.
    static func play(_ cue: Cue) {
        let id = cue.rawValue
        DispatchQueue.global(qos: .userInitiated).async {
            _ = allowDuringRecording
            AudioServicesPlaySystemSound(id)
        }
    }

    /// Best effort, once: iOS can silence system sounds while a recording session is active.
    /// This asks for them in this process's session. It never activates the session or changes
    /// its category, and the recording happens in WebKit's own session, so it may have no
    /// effect; the error is ignored. Unverified on a device.
    private static let allowDuringRecording: Void = {
        try? AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
    }()
}
