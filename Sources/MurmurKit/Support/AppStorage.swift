import Foundation

public enum AppStorage {
    /// Where the app keeps its files: `MurmurEnvironment.storageRoot`, which is
    /// `Application Support/Murmur` on the Mac unless a host configured another folder.
    public static var directory: URL { MurmurEnvironment.storageRoot }

    public static func migrateFiles(from source: URL, to destination: URL) throws {
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
