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

    /// Whether this key is down according to a flags-changed event.
    ///
    /// The right-hand modifiers have their own device-dependent bits (`NX_DEVICERALTKEYMASK`,
    /// `NX_DEVICERCMDKEYMASK` in IOLLEvent.h), so holding the left-hand twin cannot make the
    /// right one look pressed. fn has no left/right pair and uses the public flag.
    func isDown(in flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .rightOption: flags.rawValue & 0x40 != 0
        case .fn: flags.contains(.function)
        case .rightCommand: flags.rawValue & 0x10 != 0
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
///
/// Down/up comes from the event's own modifier bits, never from alternating on each event.
/// With alternation, one missed or duplicated event inverted press and release for the rest
/// of the session, and the microphone stayed open after the key came up. A watchdog covers
/// the remaining gap, a release that never arrives (secure input, a monitor re-arm mid-hold).
final class HotkeyMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isPressed = false
    private var watchdog: DispatchSourceTimer?
    /// The watchdog trusts `CGEventSource.keyState` only after it has reported this hold as
    /// down at least once, so a process that cannot read key state never fakes a release.
    private var watchdogSawDown = false
    private var watchdogUpReadings = 0

    /// Interval between hardware key-state checks while the key is held.
    private static let watchdogInterval: DispatchTimeInterval = .milliseconds(150)
    /// Consecutive "up" readings before the watchdog releases. Two readings leave the real
    /// flags-changed event, which arrives within milliseconds, room to win.
    private static let watchdogReleaseReadings = 2

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
            self?.handle(keyCode: Int64(event.keyCode), flags: event.modifierFlags)
        }
        guard let global else {
            Log.hotkey.error("global keyboard monitor unavailable; enable Accessibility for Murmur")
            return false
        }

        let key = self.key
        withLock {
            isPressed = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key.keyCode))
        }

        // Global monitors exclude events sent to this app, so observe its own window too.
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(keyCode: Int64(event.keyCode), flags: event.modifierFlags)
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
        stopWatchdog()

        if let globalMonitor = monitors.0 {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor = monitors.1 {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    // MARK: - Event monitor callback

    private func handle(keyCode: Int64, flags: NSEvent.ModifierFlags) {
        lock.lock()
        guard keyCode == storedKey.keyCode else {
            lock.unlock()
            return
        }
        let nowPressed = storedKey.isDown(in: flags)
        lock.unlock()
        transition(to: nowPressed, source: "event")
    }

    /// Applies a press or release once. A repeat of the current state is dropped, so a
    /// duplicated event can no longer start a second dictation or invert the next one.
    private func transition(to nowPressed: Bool, source: String) {
        let action: (@Sendable () -> Void)?

        lock.lock()
        guard nowPressed != isPressed else {
            lock.unlock()
            return
        }
        isPressed = nowPressed
        action = nowPressed ? storedOnPress : storedOnRelease
        lock.unlock()

        if nowPressed {
            Log.hotkey.info("push-to-talk press received (\(source, privacy: .public))")
            startWatchdog()
        } else {
            Log.hotkey.info("push-to-talk release received (\(source, privacy: .public))")
            stopWatchdog()
        }
        action?()
    }

    // MARK: - Release watchdog

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.watchdogInterval, repeating: Self.watchdogInterval)
        timer.setEventHandler { [weak self] in self?.checkHeldKey() }

        let previous = withLock { () -> DispatchSourceTimer? in
            let previous = watchdog
            watchdog = timer
            watchdogSawDown = false
            watchdogUpReadings = 0
            return previous
        }
        previous?.cancel()
        timer.resume()
    }

    private func stopWatchdog() {
        let timer = withLock { () -> DispatchSourceTimer? in
            let timer = watchdog
            watchdog = nil
            return timer
        }
        timer?.cancel()
    }

    private func checkHeldKey() {
        let key = self.key
        let down = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key.keyCode))

        let release = withLock { () -> Bool in
            guard isPressed else { return false }
            if down {
                watchdogSawDown = true
                watchdogUpReadings = 0
                return false
            }
            guard watchdogSawDown else { return false }
            watchdogUpReadings += 1
            return watchdogUpReadings >= Self.watchdogReleaseReadings
        }

        if release {
            Log.hotkey.notice("push-to-talk release event missing; key is up, releasing")
            transition(to: false, source: "watchdog")
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
