import Foundation
import MurmurKit

extension TrainingImport {
    /// Unzips an export from the iPhone with `/usr/bin/ditto`, which iOS does not have,
    /// merges it into the Mac's history, and removes the unpacked copy. The unzip, the reads
    /// and the audio copies run off the main actor; only the history append is on it.
    @MainActor
    static func merge(zip: URL) async throws -> ImportResult {
        let scratch = try await Task.detached { try unpack(zip: zip) }.value
        defer { Task.detached { try? FileManager.default.removeItem(at: scratch) } }
        return try await merge(folder: exportFolder(in: scratch))
    }

    /// Unzips into a fresh temporary folder and returns it; the caller removes it.
    private static func unpack(zip: URL) throws -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        do {
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, scratch.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "unzip failed (ditto exit \(ditto.terminationStatus))"])
            }
            return scratch
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
    }

    /// The export is zipped with its folder (`export-<date>/`), but accept a zip of the
    /// contents too.
    static func exportFolder(in root: URL) throws -> URL {
        let fileManager = FileManager.default
        func holdsRuns(_ url: URL) -> Bool {
            fileManager.fileExists(atPath: url.appendingPathComponent("runs.jsonl").path)
        }
        if holdsRuns(root) { return root }
        let children = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.first { holdsRuns($0) } ?? root
    }
}
