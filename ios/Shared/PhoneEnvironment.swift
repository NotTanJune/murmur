import Foundation
import MurmurKit
import OSLog

/// Points MurmurKit at the App Group, so the app and the keyboard share files and settings.
///
/// The first statement in the app's and the keyboard's entry points: `MurmurEnvironment` must
/// be configured before anything reads storage or `Settings.shared`. The keyboard's view
/// controller can be made more than once in one process, so a repeat call is a no-op here
/// (`MurmurEnvironment` itself treats a repeat as a bug).
@MainActor
enum PhoneEnvironment {
    static let groupID = "group.ai.pivotstudio.murmur"
    /// The keyboard extension's bundle ID, which names it among the active input modes.
    static let keyboardBundleID = "ai.pivotstudio.murmur.ios.keyboard"

    private static var isConfigured = false

    static func configure() {
        guard !isConfigured else { return }
        isConfigured = true

        let defaults = UserDefaults(suiteName: groupID) ?? .standard
        // The phone defaults to Bark Clean; the Mac's default stays Apple. A stored choice
        // wins over a registered default. The key is `Settings`'s own "engine".
        defaults.register(defaults: ["engine": "barkClean"])

        let files = FileManager.default
        let root: URL
        if let group = files.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            root = group.appendingPathComponent("Library/Application Support/Murmur", isDirectory: true)
        } else {
            // Unsigned builds and a missing entitlement land here. The app and the keyboard
            // then see different folders, which the app's setup screen reports.
            root = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Murmur", isDirectory: true)
            Logger(subsystem: "ai.pivotstudio.murmur", category: "app")
                .error("App Group \(groupID, privacy: .public) unavailable; using this process's own Application Support")
        }
        try? files.createDirectory(at: root, withIntermediateDirectories: true)
        MurmurEnvironment.configure(storageRoot: root, defaults: defaults)
    }

    /// Whether storage is inside the App Group, so the keyboard and the app see the same files.
    static var isShared: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil
    }
}

/// Tuning, temporary: tells a keyboard that is already on screen that the app changed a value in
/// Settings, Keyboard tuning, so the owner sees each step at once. A Darwin notification, as the
/// run log uses: it crosses processes and carries nothing, and the keyboard then reads the shared
/// defaults. It goes with the tuning card.
@MainActor
enum KeyboardTuningSignal {
    private static let name = "ai.pivotstudio.murmur.keyboard-tuning-changed"
    private static var handler: (() -> Void)?
    private static var isObserving = false

    static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    /// One handler per process: the newest keyboard controller's.
    static func observe(_ handler: @escaping () -> Void) {
        self.handler = handler
        guard !isObserving else { return }
        isObserving = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                Task { @MainActor in KeyboardTuningSignal.handler?() }
            },
            name as CFString, nil, .deliverImmediately)
    }
}
