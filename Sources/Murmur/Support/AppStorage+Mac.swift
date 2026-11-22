import Foundation
import MurmurKit

extension AppStorage {
    /// Mac launch work: imports the MurmurYouTube fork's files and settings once.
    static func prepare() throws {
        let directory = AppStorage.directory
        let legacy = directory.deletingLastPathComponent().appendingPathComponent("MurmurYouTube", isDirectory: true)
        try migrateFiles(from: legacy, to: directory)
        let defaults = UserDefaults.standard
        let old = defaults.persistentDomain(forName: "ai.pivotstudio.murmur-youtube") ?? [:]
        for key in ["pushToTalkKey", "engine", "cleanupEnabled", "smartCleanup", "compareMode", "soundEnabled", "comparisonWindowOpen"] {
            if defaults.object(forKey: key) == nil, let value = old[key] {
                defaults.set(value, forKey: key)
            }
        }
    }
}
