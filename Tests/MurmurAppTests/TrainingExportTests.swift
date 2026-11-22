import Foundation
import Testing
@testable import Murmur
import MurmurDictionary
import MurmurKit

/// The folder itself is covered in `MurmurKitTests`; this is the Mac's zip around it.
struct TrainingExportTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    private static func run(
        daysAgo: Double, saved: Bool = false, label: String? = nil,
        corrections: [AppliedCorrection]? = nil, hasAudio: Bool = false, exportedAt: Date? = nil
    ) -> DictationRun {
        var run = DictationRun(
            date: now.addingTimeInterval(-daysAgo * day), engine: "Bark 3.0 Clean (batch)",
            audioSeconds: 2, processSeconds: 0.1, text: "hello", corrections: corrections, isSaved: saved
        )
        run.label = label
        run.hasAudio = hasAudio
        run.exportedAt = exportedAt
        return run
    }

    @Test("Labelled runs with audio go to the manifest, unlabelled ones to replay, and the zip exists")
    func export() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = RecordingStore(directory: root.appendingPathComponent("Recordings"))
        try FileManager.default.createDirectory(at: recordings.directory, withIntermediateDirectories: true)
        let corrector = DictionaryCorrector(entries: [DictionaryEntry.correction(hear: "cloud code", write: "Claude Code")])

        var labelled = Self.run(daysAgo: 1, hasAudio: true)
        labelled.rawText = "open cloud code"
        var replay = Self.run(daysAgo: 2, hasAudio: true)
        replay.rawText = "plain words"
        var noAudio = Self.run(daysAgo: 3, label: "x")
        noAudio.rawText = "x"
        for run in [labelled, replay] { try Data([0, 1]).write(to: recordings.url(for: run.id)) }

        let (summary, ids) = try TrainingExport.write(
            runs: [labelled, replay, noAudio], corrector: corrector, recordings: recordings,
            to: root, date: Date(timeIntervalSince1970: 1_800_000_000), barkRevision: "abc"
        )
        #expect(summary.labelled == 1)
        #expect(summary.replay == 1)
        #expect(ids == [labelled.id])
        let manifest = try String(contentsOf: summary.folder.appendingPathComponent("manifest.jsonl"), encoding: .utf8)
        #expect(manifest.contains("\"text\":\"open Claude Code\""))
        #expect(manifest.contains("\"source\":\"dictionary\""))
        let replayFile = try String(contentsOf: summary.folder.appendingPathComponent("replay.jsonl"), encoding: .utf8)
        #expect(replayFile.contains("\"text\":\"plain words\""))
        #expect(FileManager.default.fileExists(atPath: summary.folder.appendingPathComponent("clips/\(labelled.id.uuidString).flac").path))
        #expect(FileManager.default.fileExists(atPath: summary.zip.path))
        let export = try JSONSerialization.jsonObject(with: Data(contentsOf: summary.folder.appendingPathComponent("export.json"))) as? [String: Any]
        #expect(export?["barkRevision"] as? String == "abc")
    }

    @Test("The zip unpacks with ditto to a folder the importer finds, runs.jsonl included")
    func zipUnpacksToImportableFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = RecordingStore(directory: root.appendingPathComponent("Recordings"))
        try FileManager.default.createDirectory(at: recordings.directory, withIntermediateDirectories: true)
        var labelled = Self.run(daysAgo: 1, label: "Fixed.", hasAudio: true)
        labelled.rawText = "fixed"
        try Data([0, 1]).write(to: recordings.url(for: labelled.id))
        let (summary, _) = try TrainingExport.write(
            runs: [labelled], corrector: DictionaryCorrector(entries: []), recordings: recordings,
            to: root, date: Date(timeIntervalSince1970: 1_800_000_000), barkRevision: "abc"
        )

        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", summary.zip.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)

        let folder = try TrainingImport.exportFolder(in: unpacked)
        #expect(folder.lastPathComponent == summary.folder.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("runs.jsonl").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("clips/\(labelled.id.uuidString).flac").path))
    }

    @Test("Pending counts labelled, unexported runs with audio")
    func pending() {
        let corrector = DictionaryCorrector(entries: [])
        var a = Self.run(daysAgo: 1, label: "x", hasAudio: true)
        a.rawText = "x"
        let b = Self.run(daysAgo: 1, label: "x", hasAudio: true, exportedAt: Date())
        let c = Self.run(daysAgo: 1, label: "x")
        let pending = TrainingExport.pending([a, b, c], corrector: corrector)
        #expect(pending.count == 1)
        #expect(pending.seconds == 2)
    }
}
