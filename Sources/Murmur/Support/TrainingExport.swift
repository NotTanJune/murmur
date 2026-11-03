import Foundation
import MurmurDictionary

/// Packages labelled runs and their audio for the Colab fine-tune.
///
/// One folder per export with `manifest.jsonl` (labelled clips), `replay.jsonl` (unlabelled
/// clips with Bark's own text, up to three per labelled clip, newest first, so the fine-tune
/// stays anchored to current behaviour), `clips/`, and `export.json`. Zipped beside it. The
/// app never uploads anything; the user drags the zip into the notebook.
enum TrainingExport {
    struct Summary: Equatable, Sendable {
        let labelled: Int
        let replay: Int
        let seconds: Double
        let folder: URL
        let zip: URL
    }

    static let replayRatio = 3

    /// Labelled runs with audio that no export has included yet.
    static func pending(_ runs: [DictationRun], corrector: DictionaryCorrector) -> (count: Int, seconds: Double) {
        let eligible = runs.filter { $0.hasAudio && $0.exportedAt == nil && TrainingLabel.resolve($0, corrector: corrector) != nil }
        return (eligible.count, eligible.reduce(0) { $0 + $1.audioSeconds })
    }

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

        let seconds = labelled.reduce(0) { $0 + $1.0.audioSeconds }
        return (
            Summary(labelled: labelled.count, replay: replay.count, seconds: seconds, folder: folder, zip: zip),
            Set(labelled.map(\.0.id))
        )
    }
}
