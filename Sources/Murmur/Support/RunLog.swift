import MurmurDictionary
import Foundation

/// A finished hold, as stored in `runs.jsonl`.
struct DictationRun: Codable, Sendable, Identifiable {
    /// Stable identity, so one run can be deleted without matching on its text. Decoding is
    /// lenient: older lines have no id and get a fresh one, written out the next time the
    /// file is rewritten.
    var id: UUID = UUID()
    let date: Date
    /// The engine's display name when the run happened.
    let engine: String
    /// Seconds of audio captured for this hold.
    let audioSeconds: Double
    /// Seconds from key release to the final text being ready: the latency you feel.
    let processSeconds: Double
    var deliverySeconds: Double?
    var displayedLatency: Double { deliverySeconds ?? processSeconds }
    /// The final delivered transcript, after cleanup and dictionary.
    let text: String
    /// Shared by every engine that processed the same recording, so the comparison view can
    /// show them together. Nil for ordinary dictation.
    var group: String?
    /// Dictionary corrections that fired. Nil, not empty, when none did, and for runs
    /// recorded before the dictionary existed.
    var corrections: [AppliedCorrection]?

    /// Kept past the retention window. Absent in older lines, which decode as not saved.
    var isSaved: Bool = false

    /// The cleanup pass that ran, e.g. "S1-mini · Email". Nil for the rule pass, for raw
    /// output, and for lines written before this existed.
    var cleanup: String?

    /// The engine's own final transcript, before cleanup and dictionary. Training labels
    /// are derived from it, never from a cleaned rewrite. Nil for lines written before this.
    var rawText: String?
    /// The user's correction of this transcript, typed in history. Nil until edited.
    var label: String?
    /// Whether `RecordingStore` holds this run's audio.
    var hasAudio: Bool = false
    /// When this run was last included in a training export. Releases its audio to the
    /// normal retention rule.
    var exportedAt: Date?

    /// A run that can contribute a training pair: an edit, or at least one dictionary hit.
    var isLabelled: Bool {
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return !(corrections ?? []).isEmpty
    }

    /// How many times faster than real time the release was.
    var realtimeFactor: Double { audioSeconds / max(processSeconds, 0.0001) }
    var characters: Int { text.count }

    init(
        id: UUID = UUID(), date: Date, engine: String, audioSeconds: Double,
        processSeconds: Double, text: String, group: String? = nil,
        corrections: [AppliedCorrection]? = nil,
        deliverySeconds: Double? = nil,
        isSaved: Bool = false,
        cleanup: String? = nil
    ) {
        self.id = id
        self.date = date
        self.engine = engine
        self.audioSeconds = audioSeconds
        self.processSeconds = processSeconds
        self.deliverySeconds = deliverySeconds
        self.text = text
        self.group = group
        self.corrections = corrections
        self.isSaved = isSaved
        self.cleanup = cleanup
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        engine = try container.decode(String.self, forKey: .engine)
        audioSeconds = try container.decode(Double.self, forKey: .audioSeconds)
        processSeconds = try container.decode(Double.self, forKey: .processSeconds)
        deliverySeconds = try container.decodeIfPresent(Double.self, forKey: .deliverySeconds)
        text = try container.decode(String.self, forKey: .text)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        corrections = try container.decodeIfPresent([AppliedCorrection].self, forKey: .corrections)
        isSaved = try container.decodeIfPresent(Bool.self, forKey: .isSaved) ?? false
        cleanup = try container.decodeIfPresent(String.self, forKey: .cleanup)
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        hasAudio = try container.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt)
    }
}

/// Owns `runs.jsonl` and the dashboard page rebuilt next to it.
///
/// The dashboard is a static HTML file the app rewrites after each run and the browser
/// reloads on a timer. A page opened from disk cannot load the history file itself
/// (cross-origin restrictions), so the app pushes the rendered result instead.
///
/// **No file I/O on the main thread.** Every read, write and dashboard render runs on one
/// serial queue that owns the history in memory. Recording used to re-read the whole file
/// twice and re-render the HTML on the main actor after each dictation, which delayed the
/// next key press by an amount that grew with history. The queue publishes a snapshot to
/// `RunStore` after each change; `DispatchQueue.main` keeps those snapshots in order.
@MainActor
enum RunLog {
    nonisolated static var directory: URL {
        let base = AppStorage.directory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    nonisolated static var dashboardURL: URL { directory.appendingPathComponent("dashboard.html") }

    private static let queue = DispatchQueue(label: "ai.pivotstudio.murmur.runlog", qos: .utility)
    private static let file = RunFile()

    /// Unsaved runs older than this are deleted.
    nonisolated static let retention: TimeInterval = 30 * 24 * 60 * 60
    /// How often a long-running app re-applies `retention` when nothing else changes history.
    private static let pruneInterval: Duration = .seconds(60 * 60)
    private static var pruneTask: Task<Void, Never>?

    /// Loads history, drops expired runs and renders the dashboard in the background.
    /// Called at launch; also re-prunes hourly so expiry doesn't wait for the next dictation.
    static func prepare() {
        update { _ in }
        guard pruneTask == nil else { return }
        pruneTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: pruneInterval)
                update { _ in }
            }
        }
    }

    /// The runs `retention` keeps: every saved run, anything newer than the cutoff, and a
    /// labelled run whose audio has not been exported yet (it is training data in waiting).
    nonisolated static func retained(_ runs: [DictationRun], now: Date) -> [DictationRun] {
        let cutoff = now.addingTimeInterval(-retention)
        return runs.filter {
            $0.isSaved || $0.date >= cutoff || ($0.isLabelled && $0.hasAudio && $0.exportedAt == nil)
        }
    }

    /// Saves a run past the retention window, or returns it to normal expiry.
    static func setSaved(_ saved: Bool, for run: DictationRun) {
        let id = run.id
        update { file in
            file.rewrite(file.runs.map { stored in
                guard stored.id == id else { return stored }
                var updated = stored
                updated.isSaved = saved
                return updated
            })
        }
    }

    /// Records a finished run and, when recordings are kept, its audio. The FLAC is written
    /// on the history queue so the key-up path never waits on disk.
    static func record(_ run: DictationRun, audio: [AudioChunk]) {
        let keep = Settings.shared.keepRecordings && !audio.isEmpty
        let store = RecordingStore.shared
        update { file in
            var stored = run
            if keep {
                do {
                    try store.write(audio, id: run.id)
                    stored.hasAudio = store.exists(id: run.id)
                } catch {
                    Log.app.error("recording not written: \(error.localizedDescription)")
                }
            }
            file.append([stored])
        }
    }

    /// Sets or clears the user's correction of a transcript.
    static func setLabel(_ label: String?, for run: DictationRun) {
        let id = run.id
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        update { file in
            file.rewrite(file.runs.map { stored in
                guard stored.id == id else { return stored }
                var updated = stored
                updated.label = value
                return updated
            })
        }
    }

    /// Stamps runs that went into an export, which lets their audio expire normally.
    static func markExported(ids: Set<UUID>, at date: Date = Date()) {
        update { file in
            file.rewrite(file.runs.map { stored in
                guard ids.contains(stored.id) else { return stored }
                var updated = stored
                updated.exportedAt = date
                return updated
            })
        }
    }

    /// Deletes every recording and clears `hasAudio`, for the Settings toggle.
    static func deleteAllRecordings() {
        let store = RecordingStore.shared
        update { file in
            store.deleteAll()
            file.rewrite(file.runs.map { stored in
                var updated = stored
                updated.hasAudio = false
                return updated
            })
        }
    }

    /// Deletes the recordings of runs that are leaving history. Pure over its inputs so it
    /// can be tested with a throwaway store.
    nonisolated static func removeRecordings(of runs: [DictationRun], except kept: [DictationRun], in store: RecordingStore) {
        let keptIDs = Set(kept.map(\.id))
        for run in runs where run.hasAudio && !keptIDs.contains(run.id) {
            store.delete(id: run.id)
        }
    }

    static func record(_ run: DictationRun) {
        record([run])
    }

    static func record(_ runs: [DictationRun]) {
        update { file in file.append(runs) }
    }

    /// Re-reads nothing; republishes the queue's current snapshot.
    static func refresh() {
        update(renderDashboard: false) { _ in }
    }

    /// Removes one run by id, never by text.
    static func delete(_ run: DictationRun) {
        delete(ids: [run.id])
    }

    /// Every engine in a group transcribed one utterance, so removing that utterance
    /// removes all of its rows.
    static func deleteGroup(_ group: String) {
        update { file in file.rewrite(file.runs.filter { $0.group != group }) }
    }

    static func delete(ids: Set<UUID>) {
        update { file in file.rewrite(file.runs.filter { !ids.contains($0.id) }) }
    }

    static func clear() {
        update { file in file.clear() }
    }

    /// Synchronous read for tests and tools. The app itself reads `RunStore.shared.runs`.
    nonisolated static func load() -> [DictationRun] {
        RunFile.read(from: RunFile.url)
    }

    /// Applies `change` on the history queue, then hands the result to the main actor.
    /// Settings are read here, on the main actor, because the queue cannot touch them.
    private static func update(
        renderDashboard: Bool = true,
        _ change: @escaping @Sendable (RunFile) -> Void
    ) {
        let compareMode = Settings.shared.compareMode
        let key = Settings.shared.pushToTalkKey.displayName
        let file = self.file
        queue.async {
            file.loadIfNeeded()
            change(file)
            file.pruneExpired(now: Date())
            let snapshot = file.runs
            if renderDashboard {
                try? DashboardHTML.render(runs: snapshot, compareMode: compareMode, key: key)
                    .write(to: dashboardURL, atomically: true, encoding: .utf8)
            }
            DispatchQueue.main.async {
                RunStore.shared.apply(snapshot)
            }
        }
    }
}

/// The history file and its in-memory copy. Touched only on `RunLog`'s serial queue.
private final class RunFile: @unchecked Sendable {
    static var url: URL { RunLog.directory.appendingPathComponent("runs.jsonl") }

    private(set) var runs: [DictationRun] = []
    private var loaded = false

    func loadIfNeeded() {
        guard !loaded else { return }
        runs = Self.read(from: Self.url)
        loaded = true
    }

    func append(_ newRuns: [DictationRun]) {
        let encoder = Self.encoder()
        var lines = Data()
        for run in newRuns {
            guard let line = try? encoder.encode(run) else { continue }
            lines.append(line)
            lines.append(0x0A) // newline
        }

        if let handle = try? FileHandle(forWritingTo: Self.url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lines)
        } else {
            try? lines.write(to: Self.url)
        }
        runs.append(contentsOf: newRuns)
    }

    /// Removing records means replacing the whole file. That also writes out the ids that
    /// older records were given when they were loaded.
    func rewrite(_ kept: [DictationRun]) {
        let encoder = Self.encoder()
        let body = kept.compactMap { run -> String? in
            guard let data = try? encoder.encode(run) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")

        // Atomic, so a failed write cannot truncate history the user did not ask to remove.
        try? (body.isEmpty ? "" : body + "\n")
            .write(to: Self.url, atomically: true, encoding: .utf8)
        RunLog.removeRecordings(of: runs, except: kept, in: RecordingStore.shared)
        runs = kept
    }

    func clear() {
        try? FileManager.default.removeItem(at: Self.url)
        RecordingStore.shared.deleteAll()
        runs = []
    }

    /// Rewrites the file only when something actually expired.
    func pruneExpired(now: Date) {
        let kept = RunLog.retained(runs, now: now)
        guard kept.count != runs.count else { return }
        rewrite(kept)
    }

    static func read(from url: URL) -> [DictationRun] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // A line that fails to decode (a truncated tail after a crash, a missing key) is
        // skipped without stopping the ones after it.
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(DictationRun.self, from: Data(line))
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
