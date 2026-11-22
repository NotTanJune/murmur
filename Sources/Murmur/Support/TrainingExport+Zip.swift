import Foundation
import MurmurDictionary
import MurmurKit

extension TrainingExport {
    /// An export folder and the zip beside it, as the Settings button reports them.
    struct Summary: Equatable, Sendable {
        let labelled: Int
        let replay: Int
        let seconds: Double
        let folder: URL
        let zip: URL
    }

    /// Builds `root/export-<date>` through `writeFolder`, then zips it beside the folder with
    /// `/usr/bin/ditto`, which iOS does not have.
    static func write(
        runs: [DictationRun],
        corrector: DictionaryCorrector,
        recordings: RecordingStore,
        to root: URL,
        date: Date,
        barkRevision: String
    ) throws -> (Summary, exportedIDs: Set<UUID>) {
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        let folder = root.appendingPathComponent("export-\(day.string(from: date))", isDirectory: true)
        let built = try writeFolderSummary(
            runs: runs, corrector: corrector, recordings: recordings,
            to: folder, date: date, barkRevision: barkRevision
        )

        let zip = root.appendingPathComponent(folder.lastPathComponent + ".zip")
        try? FileManager.default.removeItem(at: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "zip failed (ditto exit \(ditto.terminationStatus))"])
        }

        return (
            Summary(labelled: built.labelled, replay: built.replay, seconds: built.seconds, folder: folder, zip: zip),
            built.exportedIDs
        )
    }
}
