import Foundation
import IOKit.hid
import MurmurKit

/// Whether one key is held, read from the keyboards' own HID reports.
///
/// The stuck-hold watchdog needs to know that the push-to-talk key came up when the
/// flags-changed event for it never arrived (2026-11-03: an event tap swallowed the key-up
/// and the session kept ⌘ held for 27 s). It asked `CGEventSource.keyState(.hidSystemState)`,
/// which read "up" through every hold on 2026-11-13: three holds of 2 to 13 s, never once
/// down. So the watchdog never trusted it and could never fire. A device's reports are
/// below every event tap and are not affected by events other apps post, which makes them
/// the reading the watchdog was after.
///
/// Needs Input Monitoring. Only the one key's element is matched, so no other key's value
/// is ever delivered to this process.
final class PhysicalKeyWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var manager: IOHIDManager?
    private var down = false
    private var open = false

    /// Whether the keyboards could be opened. False without Input Monitoring.
    var isWatching: Bool { withLock { open } }
    var isDown: Bool { withLock { down } }

    /// Starts reporting `usage` on the keyboard page (0xE7 is Right ⌘), replacing any
    /// earlier watch. Nil stops. Call on the main thread; reports arrive on its run loop.
    func watch(usage: UInt32?) {
        stop()
        guard let usage else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let keyboards: [[String: Any]] = [kHIDUsage_GD_Keyboard, kHIDUsage_GD_Keypad].map {
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, keyboards as CFArray)
        IOHIDManagerSetInputValueMatching(manager, [
            kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad,
            kIOHIDElementUsageKey: Int(usage),
        ] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let watcher = Unmanaged<PhysicalKeyWatcher>.fromOpaque(context).takeUnretainedValue()
            watcher.record(down: IOHIDValueGetIntegerValue(value) != 0)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        withLock {
            self.manager = manager
            open = result == kIOReturnSuccess
            down = false
        }
        if result != kIOReturnSuccess {
            Log.hotkey.notice("keyboard devices not readable (IOReturn \(String(UInt32(bitPattern: result), radix: 16), privacy: .public)); grant Input Monitoring so a missed key release can be detected")
        }
    }

    func stop() {
        let manager = withLock { () -> IOHIDManager? in
            let manager = self.manager
            self.manager = nil
            open = false
            down = false
            return manager
        }
        guard let manager else { return }
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func record(down: Bool) {
        withLock { self.down = down }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
