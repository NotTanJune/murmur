import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

/// Murmur needs two grants, and neither can be worked around:
/// - **Microphone** (required): without it nothing can be captured.
/// - **Accessibility** — for global key monitoring and AX text insertion.
///
/// A third, **Input Monitoring**, is optional: without it the keyboards' own reports cannot
/// be read, so `HotkeyMonitor`'s watchdog can't tell when the push-to-talk key really came
/// up after its release event went missing.
///
/// Accessibility trust cannot be requested in code, the system only shows a prompt; the user
/// must toggle it in System Settings. TCC also keys on the code signature, so re-signing the
/// app resets the grant.
@MainActor
enum Permissions {
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    static var hasMicrophone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Asked of IOKit, whose answer is the one that decides whether `PhysicalKeyWatcher` can
    /// open the keyboards. On 2026-11-13 it and `CGPreflightListenEventAccess` both said yes
    /// while the system's permission database listed only Accessibility for Murmur, and the
    /// keyboards did open.
    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Shows the system Input Monitoring prompt once; later calls only report the state.
    /// macOS applies a new grant at the next launch.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    /// Shows the system Accessibility prompt and returns the current trust state.
    /// The option key is spelled as a literal because `kAXTrustedCheckOptionPrompt` imports as a
    /// mutable global, which strict concurrency rejects.
    @discardableResult
    static func promptForAccessibility() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
