import Foundation
import MurmurDictionary

/// Packages labelled runs and their audio for the Colab fine-tune.
///
/// One folder per export with `manifest.jsonl` (labelled clips), `replay.jsonl` (unlabelled
/// clips with Bark's own text, up to three per labelled clip, newest first, so the fine-tune
/// stays anchored to current behaviour), `clips/`, `export.json`, and `runs.jsonl` (one full
/// `DictationRun` per clip, which `TrainingImport` reads to merge a phone's export into the
/// Mac's history; the notebook ignores it). This target builds the
/// folder; the Mac app zips it beside it (`TrainingExport+Zip.swift`), since zipping runs
/// `/usr/bin/ditto`. The app never uploads anything; the user drags the zip into the notebook.
public enum TrainingExport {
    /// What `writeFolder` put in the folder.
    public struct FolderSummary: Equatable, Sendable {
        public let labelled: Int
        public let replay: Int
        public let seconds: Double
        public let folder: URL
        /// The runs that went into the manifest, for `RunLog.markExported`.
        public let exportedIDs: Set<UUID>
    }

    public static let replayRatio = 3

    /// Labelled runs with audio that no export has included yet.
    public static func pending(_ runs: [DictationRun], corrector: DictionaryCorrector) -> (count: Int, seconds: Double) {
        let eligible = runs.filter { $0.hasAudio && $0.exportedAt == nil && TrainingLabel.resolve($0, corrector: corrector) != nil }
        return (eligible.count, eligible.reduce(0) { $0 + $1.audioSeconds })
    }

    /// Builds the export into `folder` (replacing one already there) and returns the ids of
    /// the labelled runs it contains.
    @discardableResult
    public static func writeFolder(
        runs: [DictationRun],
        corrector: DictionaryCorrector,
        recordings: RecordingStore = .shared,
        to folder: URL,
        date: Date = Date(),
        barkRevision: String = BarkModelStore.revision
    ) throws -> Set<UUID> {
        try writeFolderSummary(
            runs: runs, corrector: corrector, recordings: recordings,
            to: folder, date: date, barkRevision: barkRevision
        ).exportedIDs
    }

    /// `writeFolder` with the counts the Mac's export message reports.
    public static func writeFolderSummary(
        runs: [DictationRun],
        corrector: DictionaryCorrector,
        recordings: RecordingStore = .shared,
        to folder: URL,
        date: Date = Date(),
        barkRevision: String = BarkModelStore.revision
    ) throws -> FolderSummary {
        let clips = folder.appendingPathComponent("clips", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)

        let withAudio = runs.filter { $0.hasAudio && recordings.exists(id: $0.id) }
        var labelled: [(DictationRun, TrainingLabel.Resolved)] = []
        var unlabelled: [DictationRun] = []
        for run in withAudio {
            if let resolved = TrainingLabel.resolve(run, corrector: corrector) {
                labelled.append((run, resolved))
            } else if let raw = run.rawText, !raw.isEmpty {
                unlabelled.append(run)
            }
        }
        let replay = Array(unlabelled.sorted { $0.date > $1.date }.prefix(labelled.count * replayRatio))

        let stamp = ISO8601DateFormatter()
        func line(_ run: DictationRun, text: String, source: String) throws -> String {
            let object: [String: Any] = [
                "audio_filepath": "clips/\(run.id.uuidString).flac",
                "duration": run.audioSeconds,
                "text": text,
                "raw": run.rawText ?? "",
                "source": source,
                "date": stamp.string(from: run.date),
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }

        var manifest: [String] = []
        for (run, resolved) in labelled {
            manifest.append(try line(run, text: resolved.text, source: resolved.source.rawValue))
            try FileManager.default.copyItem(at: recordings.url(for: run.id), to: clips.appendingPathComponent("\(run.id.uuidString).flac"))
        }
        var replayLines: [String] = []
        for run in replay {
            replayLines.append(try line(run, text: run.rawText ?? "", source: "replay"))
            try FileManager.default.copyItem(at: recordings.url(for: run.id), to: clips.appendingPathComponent("\(run.id.uuidString).flac"))
        }
        try (manifest.joined(separator: "\n") + "\n").write(to: folder.appendingPathComponent("manifest.jsonl"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var runLines: [String] = []
        for run in labelled.map(\.0) + replay {
            runLines.append(String(decoding: try encoder.encode(run), as: UTF8.self))
        }
        try (runLines.joined(separator: "\n") + (runLines.isEmpty ? "" : "\n")).write(to: folder.appendingPathComponent("runs.jsonl"), atomically: true, encoding: .utf8)
        try (replayLines.joined(separator: "\n") + (replayLines.isEmpty ? "" : "\n")).write(to: folder.appendingPathComponent("replay.jsonl"), atomically: true, encoding: .utf8)

        let info: [String: Any] = [
            "murmurVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "barkRevision": barkRevision,
            "labelled": labelled.count,
            "replay": replay.count,
            "exportedAt": stamp.string(from: date),
        ]
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("export.json"))

        let seconds = labelled.reduce(0) { $0 + $1.0.audioSeconds }
        return FolderSummary(
            labelled: labelled.count, replay: replay.count, seconds: seconds,
            folder: folder, exportedIDs: Set(labelled.map(\.0.id))
        )
    }
}
