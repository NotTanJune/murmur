import AppKit
import Carbon.HIToolbox

/// Presses and releases Wispr Flow's push-to-talk key so one recording can feed Wispr and the
/// local engines at once.
///
/// Wispr offers no API, so its hotkey is the only way to make it record. The comparison
/// window's single Record button uses this to start Wispr on the same utterance. It depends
/// on Wispr's own binding (`prefs.user.shortcuts`, entry `ptt`, in
/// `~/Library/Application Support/Wispr Flow/config.json`); after a rebind it does nothing
/// until `keyCode` is updated.
@MainActor
enum WisprTrigger {
    static let keyCode = CGKeyCode(kVK_Command)

    /// `NX_DEVICELCMDKEYMASK`. macOS sets `.maskCommand` for either Command key, and Wispr
    /// binds left Command separately from right, so the device bit must be set too.
    private static let leftCommandDeviceBit: UInt64 = 0x0000_0008

    /// While a press is outstanding the system sees left Command held. There is no timeout
    /// here; the controller pairing `press` with `release` bounds it.
    private static var isHeld = false

    static func press() {
        guard !isHeld else { return }
        isHeld = true
        post(flags: CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | leftCommandDeviceBit))
    }

    static func release() {
        guard isHeld else { return }
        isHeld = false
        post(flags: [])
    }

    private static func post(flags: CGEventFlags) {
        // A bare event given the type and key code explicitly. Converting a keyboard event
        // made with `CGEvent(keyboardEventSource:...)` loses the key code and posts an event
        // that looks right but does nothing.
        guard let event = CGEvent(source: nil) else {
            Log.speech.error("Could not create the Wispr Flow trigger event")
            return
        }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
