import Foundation

enum AppStorage {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Murmur", isDirectory: true)

    static func prepare() throws {
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

    static func migrateFiles(from source: URL, to destination: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent(".legacy-imported")
        guard !files.fileExists(atPath: marker.path) else { return }
        for name in ["dictionary.txt", "runs.jsonl"] {
            let original = source.appendingPathComponent(name)
            let copy = destination.appendingPathComponent(name)
            guard files.fileExists(atPath: original.path), !files.fileExists(atPath: copy.path) else { continue }
            let before = try Data(contentsOf: original)
            try files.copyItem(at: original, to: copy)
            let after = try Data(contentsOf: copy)
            guard before == after else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: copy.path])
            }
            Log.app.notice("Migrated \(name, privacy: .public): 1 source file / 1 destination file, \(before.count) / \(after.count) bytes; contents match")
        }
        try Data().write(to: marker, options: .atomic)
    }
}
