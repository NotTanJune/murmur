import Foundation

/// What a merge did, for the line under the Import button.
public struct ImportResult: Equatable, Sendable {
    /// Runs appended to the history.
    public let added: Int
    /// Runs left out: the id was already there (or repeated in the file), or the run would
    /// be pruned by `RunLog.retained` the moment it landed.
    public let skipped: Int
    /// Lines of `runs.jsonl` that did not decode as a run.
    public let failed: Int

    public init(added: Int, skipped: Int, failed: Int = 0) {
        self.added = added
        self.skipped = skipped
        self.failed = failed
    }

    /// "Added 2, skipped 1", with ", unreadable 3" appended only when a line failed.
    public var summary: String {
        "Added \(added), skipped \(skipped)" + (failed > 0 ? ", unreadable \(failed)" : "")
    }
}

/// Merges an export folder from another device into this one's history, so the Mac's local
/// fine-tune (`training/finetune_local.py`, which reads `runs.jsonl` and `Recordings/` in
/// place) sees the phone's corrections.
///
/// The folder is what `TrainingExport.writeFolder` builds: `runs.jsonl` holds one full
/// `DictationRun` per exported clip, and `clips/<id>.flac` is that run's whole recording
/// (the export copies the file, it never cuts it), so a run's audio is found by its id.
/// Each run not already in the history is added with `source = .phone` and no `exportedAt`,
/// so the Mac's next export includes it. A run whose id is already in the history is skipped
/// and never overwritten, which makes importing the same zip twice harmless.
///
/// Reading and copying (`prepare`) is plain file work with no actor; only the final append
/// to the shared history is main-actor, so a large zip never holds the interface.
public enum TrainingImport {
    /// A `runs.jsonl` larger than this is refused. A year of dictation is a few MB.
    static let maxRunsFileBytes = 64 * 1024 * 1024
    /// A clip larger than this is not copied; its run is imported without audio.
    static let maxClipBytes = 200 * 1024 * 1024

    public enum Failure: LocalizedError, Equatable {
        case noRunsFile
        case runsFileTooLarge(bytes: Int)
        case unreadable(lines: Int)

        public var errorDescription: String? {
            switch self {
            case .noRunsFile:
                "This export has no runs.jsonl. Export again from Murmur on the iPhone."
            case .runsFileTooLarge(let bytes):
                "runs.jsonl is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), over the \(ByteCountFormatter.string(fromByteCount: Int64(maxRunsFileBytes), countStyle: .file)) limit. This does not look like a Murmur export."
            case .unreadable(let lines):
                "None of the \(lines) line\(lines == 1 ? "" : "s") in runs.jsonl could be read. The file may be cut short or corrupt."
            }
        }
    }

    /// What `prepare` found: the runs to append and the counts to report.
    struct Prepared: Sendable {
        let result: ImportResult
        let runs: [DictationRun]
    }

    /// Merges `folder` into the app's own history and recordings. The file work runs off the
    /// main actor.
    @MainActor
    public static func merge(folder: URL) async throws -> ImportResult {
        let prepared = try await Task.detached {
            try prepare(folder: folder, existing: Set(RunLog.load().map(\.id)), recordings: .shared)
        }.value
        return commit(prepared)
    }

    /// Appends the prepared runs to the app's history.
    @MainActor
    static func commit(_ prepared: Prepared) -> ImportResult {
        if !prepared.runs.isEmpty { RunLog.record(prepared.runs) }
        return prepared.result
    }

    /// `merge` into a history of its own, for tests and any caller with a store of its own.
    static func merge(folder: URL, into store: RunLog.Store, recordings: RecordingStore) throws -> ImportResult {
        store.drain()
        let existing = Set(store.load().map(\.id))
        let prepared = try prepare(folder: folder, existing: existing, recordings: recordings)
        if !prepared.runs.isEmpty {
            store.update(.append(prepared.runs))
            store.drain()
        }
        return prepared.result
    }

    /// Reads the folder, copies the audio of every run that will stay in the history and
    /// whose id is not in `existing`, and returns the runs to append. Writes nothing to the
    /// history itself.
    static func prepare(
        folder: URL, existing: Set<UUID>, recordings: RecordingStore, now: Date = Date()
    ) throws -> Prepared {
        let file = folder.appendingPathComponent("runs.jsonl")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw Failure.noRunsFile }
        guard size <= maxRunsFileBytes else { throw Failure.runsFileTooLarge(bytes: size) }
        guard let data = try? Data(contentsOf: file) else { throw Failure.noRunsFile }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var seen = existing
        var added: [DictationRun] = []
        var skipped = 0
        var failed = 0
        var decoded = 0
        for line in data.split(separator: 0x0A) {
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continue }
            guard var run = try? decoder.decode(DictationRun.self, from: Data(line)) else {
                failed += 1
                continue
            }
            decoded += 1
            guard seen.insert(run.id).inserted else {
                skipped += 1
                continue
            }
            run.source = .phone
            run.exportedAt = nil

            // Retention depends on the audio, so judge it on the clip as it would arrive and
            // copy only for a run that stays: one pruned on landing is not added, and its
            // audio is not copied.
            let clip = clipSource(for: run.id, in: folder)
            run.hasAudio = clip != nil
            guard RunLog.retained([run], now: now).count == 1 else {
                skipped += 1
                continue
            }
            if let clip {
                run.hasAudio = place(clip, for: run.id, in: recordings)
                guard RunLog.retained([run], now: now).count == 1 else {
                    skipped += 1
                    continue
                }
            }
            added.append(run)
        }
        if decoded == 0 && failed > 0 { throw Failure.unreadable(lines: failed) }
        return Prepared(result: ImportResult(added: added.count, skipped: skipped, failed: failed), runs: added)
    }

    /// `clips/<id>.flac` when it is a regular file within the size limit. Named by the run's
    /// own id, never by a path from the data, and never a link, which could point at a file
    /// outside the zip.
    private static func clipSource(for id: UUID, in folder: URL) -> URL? {
        let source = folder.appendingPathComponent("clips", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).flac")
        let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return nil }
        guard let size = values?.fileSize, size <= maxClipBytes else {
            Log.app.error("import skipped clip over \(maxClipBytes) bytes for run \(id.uuidString)")
            return nil
        }
        return source
    }

    /// Copies the clip to `Recordings/<id>.flac` and says whether the run now has its audio.
    /// A file already there is never replaced or deleted: it counts as this run's audio only
    /// when it is the same size as the clip.
    private static func place(_ source: URL, for id: UUID, in recordings: RecordingStore) -> Bool {
        let destination = recordings.url(for: id)
        func size(_ url: URL) -> Int? { try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize }
        if FileManager.default.fileExists(atPath: destination.path) {
            let same = size(destination) != nil && size(destination) == size(source)
            if !same { Log.app.error("import kept a different recording already at \(destination.lastPathComponent)") }
            return same
        }
        do {
            try FileManager.default.createDirectory(at: recordings.directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            return true
        } catch {
            // Nothing was at the destination before this call, so a partial file is ours.
            try? FileManager.default.removeItem(at: destination)
            return false
        }
    }
}
