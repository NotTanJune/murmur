import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Which modifier key holds the mic open.
enum PushToTalkKey: String, CaseIterable, Sendable {
    case rightOption
    case fn
    case rightCommand

    var keyCode: Int64 {
        switch self {
        case .rightOption: Int64(kVK_RightOption)   // 61
        case .fn: Int64(kVK_Function)               // 63
        case .rightCommand: Int64(kVK_RightCommand) // 54
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: "Right ⌥"
        case .fn: "fn"
        case .rightCommand: "Right ⌘"
        }
    }

}

/// Watches for a held modifier key using AppKit's global and local event monitors.
///
/// `NSEvent` flags-changed events retain the physical virtual key code, so the monitor can
/// distinguish the configured right-hand key without relying on aggregate modifier flags.
/// Global key events require Accessibility permission. The monitor observes events and does
/// not suppress them, so holding a modifier alone cannot interfere with the focused app.
final class HotkeyMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isPressed = false

    private var storedKey: PushToTalkKey = .rightOption
    private var storedOnPress: (@Sendable () -> Void)?
    private var storedOnRelease: (@Sendable () -> Void)?

    var key: PushToTalkKey {
        get { withLock { storedKey } }
        set {
            withLock {
                storedKey = newValue
                isPressed = false
            }
        }
    }

    var onPress: (@Sendable () -> Void)? {
        get { withLock { storedOnPress } }
        set { withLock { storedOnPress = newValue } }
    }

    var onRelease: (@Sendable () -> Void)? {
        get { withLock { storedOnRelease } }
        set { withLock { storedOnRelease = newValue } }
    }

    /// - Returns: `false` if the global monitor couldn't be installed.
    @discardableResult
    func start() -> Bool {
        stop()

        let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(keyCode: Int64(event.keyCode))
        }
        guard let global else {
            Log.hotkey.error("global keyboard monitor unavailable; enable Accessibility for Murmur YouTube")
            return false
        }

        let key = self.key
        withLock {
            isPressed = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key.keyCode))
        }

        // Global monitors exclude events sent to this app, so observe its own window too.
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(keyCode: Int64(event.keyCode))
            return event
        }

        withLock {
            globalMonitor = global
            localMonitor = local
        }

        Log.hotkey.info("listening for \(self.key.displayName)")
        return true
    }

    func stop() {
        let monitors = withLock { () -> (Any?, Any?) in
            let monitors = (globalMonitor, localMonitor)
            globalMonitor = nil
            localMonitor = nil
            isPressed = false
            return monitors
        }

        if let globalMonitor = monitors.0 {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor = monitors.1 {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    // MARK: - Event monitor callback

    private func handle(keyCode: Int64) {
        let action: (@Sendable () -> Void)?

        lock.lock()
        guard keyCode == storedKey.keyCode else {
            lock.unlock()
            return
        }

        // A flags-changed event has no down/up field. Its keycode identifies the configured
        // physical key, so alternate the state for each matching event. Initialize from HID
        // state when starting so a key held during activation does not create a false press.
        let nowPressed = !isPressed
        isPressed = nowPressed
        action = nowPressed ? storedOnPress : storedOnRelease
        lock.unlock()

        if nowPressed {
            Log.hotkey.info("push-to-talk press received")
        } else {
            Log.hotkey.info("push-to-talk release received")
        }
        action?()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
