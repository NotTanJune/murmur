import Foundation
import ServiceManagement

/// Opens Murmur at login through `SMAppService.mainApp`, listed in System Settings → General →
/// Login Items. The system's status is the source of truth: Settings shows it and changes it,
/// and Murmur registers itself only once, so removing it in System Settings sticks.
@MainActor
enum LoginItem {
    private static let registeredOnceKey = "loginItemRegisteredOnce"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.app.info("open at login: \(enabled, privacy: .public)")
        } catch {
            Log.app.error("couldn't change open at login: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The first launch of the installed copy registers it. A build run from the staging folder
    /// never does, or the login item would point at a copy that `make clean` deletes.
    static func registerOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: registeredOnceKey),
              Bundle.main.bundleURL.path.hasPrefix("/Applications/")
        else { return }
        set(true)
        defaults.set(true, forKey: registeredOnceKey)
    }
}
