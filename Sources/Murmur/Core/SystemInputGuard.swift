import CoreAudio
import Foundation

/// Keeps the Mac's default input on the microphone `MicrophonePolicy` allows (the SoloCast,
/// otherwise the built-in mic), for every app, not only Murmur.
///
/// macOS makes a Bluetooth headset the default input each time it connects. Any app that then
/// opens the default mic records through the headset's call-quality microphone and drops its
/// output into call mode too. On 2026-11-03 that default also broke Murmur's own capture while
/// it still ran on `AVAudioEngine`. With `Settings.keepSystemInput` on, every change of the
/// default or of the device list is checked and an unallowed default is moved back.
@MainActor
final class SystemInputGuard {
    static let shared = SystemInputGuard()

    private var isObserving = false
    /// Corrections in the last `window`. If something keeps moving the default back, give up
    /// after `limit` rather than fight it in a loop.
    private var corrections: [Date] = []
    private static let limit = 5
    private static let window: TimeInterval = 30

    private init() {}

    func start() {
        if !isObserving {
            isObserving = true
            MicrophonePolicy.observeDefaultInput { Task { @MainActor in SystemInputGuard.shared.enforce() } }
            MicrophonePolicy.observeDeviceChanges { Task { @MainActor in SystemInputGuard.shared.enforce() } }
        }
        enforce()
    }

    /// Moves the default input to the allowed microphone if it is anything else.
    func enforce() {
        guard Settings.shared.keepSystemInput else { return }
        let current = MicrophonePolicy.defaultInput()
        guard let target = MicrophonePolicy.correction(forDefault: current, among: MicrophonePolicy.inputDevices())
        else { return }

        let now = Date()
        corrections = corrections.filter { now.timeIntervalSince($0) < Self.window }
        guard corrections.count < Self.limit else {
            Log.audio.error("system input moved away \(Self.limit) times in \(Int(Self.window)) s — leaving it")
            return
        }
        corrections.append(now)

        let status = MicrophonePolicy.setDefaultInput(target)
        if status == noErr {
            Log.audio.info("system input was device \(current ?? 0) — moved to \(target.name, privacy: .public)")
        } else {
            Log.audio.error("couldn't make \(target.name, privacy: .public) the system input (Core Audio error \(status))")
        }
    }
}
