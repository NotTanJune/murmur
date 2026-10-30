import MurmurDictionary
import Foundation

/// One completed dictation.
struct DictationRun: Codable, Sendable, Identifiable {
    /// Stable identity, so a single run can be deleted without matching on its text.
    ///
    /// Decoded leniently: runs written before this existed have no `id` field, and failing
    /// their whole line would throw away the user's history to add a delete button. Those
    /// get a fresh id on load, which is then persisted the next time the file is rewritten.
    var id: UUID = UUID()

    let date: Date
    let engine: String
    /// How long the key was held.
    let audioSeconds: Double
    /// Release → final text ready. This is the latency you actually feel.
    let processSeconds: Double
    var deliverySeconds: Double?
    var displayedLatency: Double { deliverySeconds ?? processSeconds }
    let text: String
    /// Shared by every engine that processed the same recording, so the dashboard can
    /// present them as one side-by-side comparison instead of unrelated rows.
    var group: String?

    /// Dictionary corrections that fired on this transcript. Recorded so history can show
    /// whether the dictionary is actually doing anything, rather than leaving it to faith.
    ///
    /// Optional for backwards compatibility: runs recorded before the dictionary existed
    /// decode with this nil rather than failing the whole line.
    var corrections: [AppliedCorrection]?

    /// Kept past the retention window. Absent in older lines, which decode as not saved.
    var isSaved: Bool = false

    /// The cleanup pass that ran, e.g. "S1-mini · Email". Nil for the rule pass, for raw
    /// output, and for lines written before this existed.
    var cleanup: String?

    var realtimeFactor: Double { audioSeconds / max(processSeconds, 0.0001) }
    var characters: Int { text.count }

    init(
        id: UUID = UUID(),
        date: Date,
        engine: String,
        audioSeconds: Double,
        processSeconds: Double,
        text: String,
        group: String? = nil,
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
    }
}

/// Appends every dictation to a JSONL file and regenerates a dashboard beside it.
///
/// The dashboard is a plain file with a meta-refresh rather than a served page: `file://`
/// can't fetch its own data directory without tripping CORS, so instead of the page pulling
/// data, the app pushes a freshly rendered page after each run and the browser just reloads.
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

    /// The runs `retention` keeps: every saved run, and anything newer than the cutoff.
    nonisolated static func retained(_ runs: [DictationRun], now: Date) -> [DictationRun] {
        let cutoff = now.addingTimeInterval(-retention)
        return runs.filter { $0.isSaved || $0.date >= cutoff }
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

    /// Deletes one run.
    static func delete(_ run: DictationRun) {
        delete(ids: [run.id])
    }

    /// Deletes every run in a comparison group — the engines all transcribed one utterance,
    /// so removing that utterance means removing all of its rows.
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

    /// Replaces the whole file. Deleting can't be an append, and rewriting also persists the
    /// ids that older runs were assigned on load.
    func rewrite(_ kept: [DictationRun]) {
        let encoder = Self.encoder()
        let body = kept.compactMap { run -> String? in
            guard let data = try? encoder.encode(run) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")

        // Atomic: a partial write here would lose history that the user didn't ask to delete.
        try? (body.isEmpty ? "" : body + "\n")
            .write(to: Self.url, atomically: true, encoding: .utf8)
        runs = kept
    }

    func clear() {
        try? FileManager.default.removeItem(at: Self.url)
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
