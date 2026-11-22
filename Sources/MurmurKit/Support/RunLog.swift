import Foundation
import MurmurDictionary

/// Where a run was recorded. Old lines carry none, which means the Mac.
public enum RunSource: String, Codable, Sendable {
    case mac, phone
}

/// A finished hold, as stored in `runs.jsonl`.
public struct DictationRun: Codable, Sendable, Identifiable {
    /// Stable identity, so one run can be deleted without matching on its text. Decoding is
    /// lenient: older lines have no id and get a fresh one, written out the next time the
    /// file is rewritten.
    public var id: UUID = UUID()
    public let date: Date
    /// The engine's display name when the run happened.
    public let engine: String
    /// Seconds of audio captured for this hold.
    public let audioSeconds: Double
    /// Seconds from key release to the final text being ready: the latency you feel.
    public let processSeconds: Double
    public var deliverySeconds: Double?
    public var displayedLatency: Double { deliverySeconds ?? processSeconds }
    /// The final delivered transcript, after cleanup and dictionary.
    public let text: String
    /// Shared by every engine that processed the same recording, so the comparison view can
    /// show them together. Nil for ordinary dictation.
    public var group: String?
    /// Dictionary corrections that fired. Nil, not empty, when none did, and for runs
    /// recorded before the dictionary existed.
    public var corrections: [AppliedCorrection]?

    /// Kept past the retention window. Absent in older lines, which decode as not saved.
    public var isSaved: Bool = false

    /// The cleanup pass that ran, e.g. "S1-mini · Email". Nil for the rule pass, for raw
    /// output, and for lines written before this existed.
    public var cleanup: String?

    /// The engine's own final transcript, before cleanup and dictionary. Training labels
    /// are derived from it, never from a cleaned rewrite. Nil for lines written before this.
    public var rawText: String?
    /// The user's correction of this transcript, typed in history. Nil until edited.
    public var label: String?
    /// Whether `RecordingStore` holds this run's audio.
    public var hasAudio: Bool = false
    /// When this run was last included in a training export. Releases its audio to the
    /// normal retention rule.
    public var exportedAt: Date?
    /// The device the run was recorded on. Nil in lines from before this existed and in the
    /// Mac's own new runs, which both mean the Mac; the iPhone keyboard sets `.phone` on its
    /// own runs, and a phone import sets it on the runs it adds.
    public var source: RunSource?

    /// A run that can contribute a training pair: an edit, or at least one dictionary hit.
    public var isLabelled: Bool {
        if let label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return !(corrections ?? []).isEmpty
    }

    /// How many times faster than real time the release was.
    public var realtimeFactor: Double { audioSeconds / max(processSeconds, 0.0001) }
    public var characters: Int { text.count }

    public init(
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

    public init(from decoder: any Decoder) throws {
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
        source = try container.decodeIfPresent(RunSource.self, forKey: .source)
    }
}


/// Owns `runs.jsonl` and the dashboard page the Mac rebuilds next to it.
///
/// The dashboard is a static HTML file the app rewrites after each run and the browser
/// reloads on a timer. A page opened from disk cannot load the history file itself
/// (cross-origin restrictions), so the app pushes the rendered result instead. Rendering is
/// Mac UI code, so the Mac installs `renderDashboard` at launch; iOS installs nothing.
///
/// **No file I/O on the main thread.** Every read, write and dashboard render runs on one
/// serial queue that owns the history in memory. Recording used to re-read the whole file
/// twice and re-render the HTML on the main actor after each dictation, which delayed the
/// next key press by an amount that grew with history. The queue publishes a snapshot to
/// `RunStore` after each change; `DispatchQueue.main` keeps those snapshots in order.
///
/// **Two processes may write the file.** On iOS the keyboard extension and the app both do.
/// Every change runs under `NSFileCoordinator`, first re-reads the file when another writer
/// changed it since this process last read, then applies itself, and finally posts
/// `didChangeNotification` so the other process reloads. See `RunFile`.
@MainActor
public enum RunLog {
    /// Darwin notification posted after every write to `runs.jsonl`, and observed by
    /// `prepare()`. It carries no sender, so a process also hears its own posts; reloading on
    /// one finds the file unchanged and only republishes.
    public nonisolated static let didChangeNotification = "ai.pivotstudio.murmur.runs-changed"

    /// Renders the dashboard page from the history, on the history queue and never on the
    /// main actor. Arguments: the runs, `Settings.compareMode` and the raw value of
    /// `Settings.pushToTalkKey`, both read on the main actor when the change was requested.
    /// Set once at launch, before `prepare()`. The Mac writes `dashboardURL`; iOS leaves it nil.
    public static var renderDashboard: (@Sendable ([DictationRun], _ compareMode: Bool, _ pushToTalkKeyRawValue: String) -> Void)?

    public nonisolated static var directory: URL {
        let base = AppStorage.directory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    public nonisolated static var dashboardURL: URL { directory.appendingPathComponent("dashboard.html") }

    /// The history of this process's storage root, pinned the first time it is used.
    private nonisolated static let store = Store(directory: directory, recordings: .shared)

    /// Unsaved runs older than this are deleted.
    public nonisolated static let retention: TimeInterval = 30 * 24 * 60 * 60
    /// How often a long-running app re-applies `retention` when nothing else changes history.
    private static let pruneInterval: Duration = .seconds(60 * 60)
    private static var pruneTask: Task<Void, Never>?
    private static var isObservingOtherProcesses = false

    /// Loads history, drops expired runs and renders the dashboard in the background.
    /// Called at launch; also re-prunes hourly so expiry doesn't wait for the next dictation,
    /// and reloads whenever another process reports a write to the file.
    public static func prepare() {
        observeOtherProcesses()
        update(Change { _ in })
        guard pruneTask == nil else { return }
        pruneTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: pruneInterval)
                update(Change { _ in })
            }
        }
    }

    private static func observeOtherProcesses() {
        guard !isObservingOtherProcesses else { return }
        isObservingOtherProcesses = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                Task { @MainActor in RunLog.reloadAfterNotification() }
            },
            didChangeNotification as CFString, nil, .deliverImmediately
        )
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
    public static func setSaved(_ saved: Bool, for run: DictationRun) {
        update(.setSaved(saved, id: run.id))
    }

    /// Records a finished run and, when recordings are kept, its audio. The FLAC is written
    /// on the history queue so the key-up path never waits on disk.
    public static func record(_ run: DictationRun, audio: [AudioChunk]) {
        let keep = Settings.shared.keepRecordings && !audio.isEmpty
        update(.record(run, audio: keep ? audio : []))
    }

    /// Sets or clears the user's correction of a transcript.
    public static func setLabel(_ label: String?, for run: DictationRun) {
        update(.setLabel(label, id: run.id))
    }

    /// Stamps runs that went into an export, which lets their audio expire normally.
    public static func markExported(ids: Set<UUID>, at date: Date = Date()) {
        update(.markExported(ids: ids, at: date))
    }

    /// Deletes every recording and clears `hasAudio`, for the Settings toggle.
    public static func deleteAllRecordings() {
        update(.deleteAllRecordings())
    }

    /// Deletes the recordings of runs that are leaving history. Pure over its inputs so it
    /// can be tested with a throwaway store.
    nonisolated static func removeRecordings(of runs: [DictationRun], except kept: [DictationRun], in store: RecordingStore) {
        let keptIDs = Set(kept.map(\.id))
        for run in runs where run.hasAudio && !keptIDs.contains(run.id) {
            store.delete(id: run.id)
        }
    }

    public static func record(_ run: DictationRun) {
        record([run])
    }

    public static func record(_ runs: [DictationRun]) {
        update(.append(runs))
    }

    /// Re-reads the file only if another process changed it, then republishes the queue's
    /// current snapshot.
    public static func refresh() {
        update(renderDashboard: false, Change { _ in })
    }

    /// The Darwin notification also arrives for this process's own writes. Those leave the
    /// file as this process last saw it, so nothing is re-read and nothing is republished.
    private static func reloadAfterNotification() {
        update(renderDashboard: false, publishOnlyIfReloaded: true, Change { _ in })
    }

    /// Removes one run by id, never by text.
    public static func delete(_ run: DictationRun) {
        delete(ids: [run.id])
    }

    /// Every engine in a group transcribed one utterance, so removing that utterance
    /// removes all of its rows.
    public static func deleteGroup(_ group: String) {
        update(.deleteGroup(group))
    }

    public static func delete(ids: Set<UUID>) {
        update(.delete(ids: ids))
    }

    public static func clear() {
        update(.clear())
    }

    /// Synchronous read for tests and tools. The app itself reads `RunStore.shared.runs`.
    public nonisolated static func load() -> [DictationRun] {
        store.load()
    }

    /// Applies `change` on the history queue, then hands the result to the main actor.
    /// Settings are read here, on the main actor, because the queue cannot touch them.
    private static func update(renderDashboard: Bool = true, publishOnlyIfReloaded: Bool = false, _ change: Change) {
        var render: (@Sendable ([DictationRun]) -> Void)?
        if renderDashboard, let hook = Self.renderDashboard {
            let compareMode = Settings.shared.compareMode
            let key = Settings.shared.pushToTalkKeyRawValue
            render = { hook($0, compareMode, key) }
        }
        store.update(change, render: render, publishOnlyIfReloaded: publishOnlyIfReloaded) { snapshot in
            DispatchQueue.main.async {
                RunStore.shared.apply(snapshot)
            }
        }
    }
}

extension RunLog {
    /// A history file, its serial queue and its in-memory copy. `RunLog`'s static API uses
    /// one for the app's storage root; tests make their own over a temporary folder, so none
    /// of them touches `MurmurEnvironment`.
    final class Store: @unchecked Sendable {
        let url: URL
        private let queue = DispatchQueue(label: "ai.pivotstudio.murmur.runlog", qos: .utility)
        private let file: RunFile
        private let notifiesOtherProcesses: Bool

        init(directory: URL, recordings: RecordingStore? = nil, notifiesOtherProcesses: Bool = true) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("runs.jsonl")
            file = RunFile(url: url, recordings: recordings ?? RecordingStore(directory: directory.appendingPathComponent("Recordings", isDirectory: true)))
            self.notifiesOtherProcesses = notifiesOtherProcesses
        }

        /// Runs `change` on the queue under file coordination, then renders and publishes.
        func update(
            _ change: Change,
            render: (@Sendable ([DictationRun]) -> Void)? = nil,
            publishOnlyIfReloaded: Bool = false,
            publish: (@Sendable ([DictationRun]) -> Void)? = nil
        ) {
            let notifies = notifiesOtherProcesses
            queue.async { [file] in
                let (snapshot, wrote, reloaded) = file.apply(change, now: Date())
                render?(snapshot)
                if reloaded || wrote || !publishOnlyIfReloaded { publish?(snapshot) }
                if wrote && notifies { RunLog.postDidChange() }
            }
        }

        /// Waits for every change queued so far.
        func drain() {
            queue.sync {}
        }

        func load() -> [DictationRun] {
            RunFile.read(from: url)
        }
    }

    /// One change to the history. `isAppend` marks a pure append, coordinated with
    /// `.forMerging`; everything else replaces the file and is coordinated with no options.
    /// Coordinated write claims exclude each other either way. Recordings always go through
    /// the `RunFile`'s own store, so a change can never reach another folder's recordings.
    struct Change: @unchecked Sendable {
        var isAppend = false
        let apply: (RunFile) -> Void

        init(isAppend: Bool = false, _ apply: @escaping (RunFile) -> Void) {
            self.isAppend = isAppend
            self.apply = apply
        }

        static func append(_ runs: [DictationRun]) -> Change {
            Change(isAppend: true) { $0.append(runs) }
        }

        static func record(_ run: DictationRun, audio: [AudioChunk]) -> Change {
            Change(isAppend: true) { file in
                let recordings = file.recordings
                var stored = run
                if !audio.isEmpty {
                    do {
                        try recordings.write(audio, id: run.id)
                        stored.hasAudio = recordings.exists(id: run.id)
                    } catch {
                        Log.app.error("recording not written: \(error.localizedDescription)")
                    }
                }
                file.append([stored])
            }
        }

        static func setSaved(_ saved: Bool, id: UUID) -> Change {
            edit { stored in
                guard stored.id == id else { return stored }
                var updated = stored
                updated.isSaved = saved
                return updated
            }
        }

        static func setLabel(_ label: String?, id: UUID) -> Change {
            let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
            return edit { stored in
                guard stored.id == id else { return stored }
                var updated = stored
                updated.label = value
                return updated
            }
        }

        static func markExported(ids: Set<UUID>, at date: Date) -> Change {
            edit { stored in
                guard ids.contains(stored.id) else { return stored }
                var updated = stored
                updated.exportedAt = date
                return updated
            }
        }

        static func deleteAllRecordings() -> Change {
            Change { file in
                file.recordings.deleteAll()
                file.rewrite(file.runs.map { stored in
                    var updated = stored
                    updated.hasAudio = false
                    return updated
                })
            }
        }

        static func deleteGroup(_ group: String) -> Change {
            Change { file in file.rewrite(file.runs.filter { $0.group != group }) }
        }

        static func delete(ids: Set<UUID>) -> Change {
            Change { file in file.rewrite(file.runs.filter { !ids.contains($0.id) }) }
        }

        static func clear() -> Change {
            Change { file in file.clear() }
        }

        private static func edit(_ transform: @escaping (DictationRun) -> DictationRun) -> Change {
            Change { file in file.rewrite(file.runs.map(transform)) }
        }
    }

    nonisolated static func postDidChange() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(didChangeNotification as CFString), nil, nil, true
        )
    }
}

/// The history file and its in-memory copy. Touched only on one `RunLog.Store` queue.
///
/// Another process may append to or rewrite the file at any time, so `apply` never trusts
/// the in-memory copy blindly: under `NSFileCoordinator` it first re-reads the file when its
/// size or modification date differs from what this process last read or wrote, and only
/// then applies the change.
final class RunFile: @unchecked Sendable {
    let url: URL
    let recordings: RecordingStore

    private(set) var runs: [DictationRun] = []
    private var loaded = false
    /// The file as this process last saw it. Nil forces the next change to re-read.
    private var lastStamp: Stamp?
    /// Set by the writers below, so `apply` can tell the caller to post the notification.
    private var wrote = false
    /// Set when `syncFromDisk` re-read the file during this `apply`.
    private var reloaded = false

    init(url: URL, recordings: RecordingStore) {
        self.url = url
        self.recordings = recordings
    }

    /// Size and modification time, read with `stat` so nothing is cached.
    struct Stamp: Equatable {
        var size: Int64?
        var modified: timespec?

        static func == (lhs: Stamp, rhs: Stamp) -> Bool {
            lhs.size == rhs.size && lhs.modified?.tv_sec == rhs.modified?.tv_sec && lhs.modified?.tv_nsec == rhs.modified?.tv_nsec
        }

        static func of(_ url: URL) -> Stamp {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return Stamp(size: nil, modified: nil) }
            return Stamp(size: Int64(info.st_size), modified: info.st_mtimespec)
        }
    }

    /// Runs `change` under a coordinated write, then prunes expired runs. Returns the
    /// resulting history, whether the file was written and whether it was re-read.
    func apply(_ change: RunLog.Change, now: Date) -> (runs: [DictationRun], wrote: Bool, reloaded: Bool) {
        wrote = false
        reloaded = false
        // An append is coordinated for merging, a rewrite with no options; both exclude other writers.
        coordinated(change.isAppend ? .forMerging : []) {
            syncFromDisk()
            change.apply(self)
        }
        // Expiry rewrites the file, so it is always exclusive, even after an append.
        if RunLog.retained(runs, now: now).count != runs.count {
            coordinated([]) {
                syncFromDisk()
                let kept = RunLog.retained(runs, now: now)
                if kept.count != runs.count { rewrite(kept) }
            }
        }
        return (runs, wrote, reloaded)
    }

    private func coordinated(_ options: NSFileCoordinator.WritingOptions, _ body: () -> Void) {
        var failure: NSError?
        var ran = false
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &failure) { _ in
            ran = true
            body()
        }
        if !ran {
            // Coordination refused. Losing a dictation from history is worse than an
            // uncoordinated write, so apply the change anyway and say so.
            Log.app.error("history not coordinated: \(failure?.localizedDescription ?? "unknown error")")
            body()
        }
    }

    /// Re-reads the file when this process has not read it yet or another writer changed it.
    private func syncFromDisk() {
        let stamp = Stamp.of(url)
        if loaded, let last = lastStamp, last == stamp { return }
        // Stamped before reading: a write that lands during the read shows up next time.
        runs = Self.read(from: url)
        loaded = true
        lastStamp = stamp
        reloaded = true
    }

    func append(_ newRuns: [DictationRun]) {
        let encoder = Self.encoder()
        var lines = Data()
        for run in newRuns {
            guard let line = try? encoder.encode(run) else { continue }
            lines.append(line)
            lines.append(0x0A) // newline
        }

        let before = Stamp.of(url)
        let appended = Self.appendBytes(lines, to: url)
        let after = Stamp.of(url)
        // The file grew by exactly our bytes only if no other process appended meanwhile.
        // Otherwise forget what was read, so the next change re-reads the file.
        if !appended {
            lastStamp = nil
        } else if let was = before.size, let now = after.size, now - was == Int64(lines.count), lastStamp == before {
            lastStamp = after
        } else if before.size == nil, after.size == Int64(lines.count), lastStamp == before {
            lastStamp = after
        } else {
            lastStamp = nil
        }
        runs.append(contentsOf: newRuns)
        wrote = wrote || appended
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
            .write(to: url, atomically: true, encoding: .utf8)
        RunLog.removeRecordings(of: runs, except: kept, in: recordings)
        runs = kept
        lastStamp = Stamp.of(url)
        wrote = true
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
        recordings.deleteAll()
        runs = []
        lastStamp = Stamp.of(url)
        wrote = true
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

    /// One `write` on an `O_APPEND` descriptor, so concurrent appenders cannot overwrite each other.
    private static func appendBytes(_ data: Data, to url: URL) -> Bool {
        guard !data.isEmpty else { return true }
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 { return false }
                offset += written
            }
            return true
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
