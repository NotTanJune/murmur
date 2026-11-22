import Foundation
import Testing
@testable import MurmurKit

/// The keyboard extension and the app are two processes writing one `runs.jsonl`. These tests
/// play the other process by writing the file directly, against a store over a temporary
/// folder so they never touch `MurmurEnvironment`.
struct RunLogSharingTests {
    private func makeStore(notifies: Bool = false) -> (store: RunLog.Store, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runlog-\(UUID().uuidString)", isDirectory: true)
        return (RunLog.Store(directory: folder, notifiesOtherProcesses: notifies), folder)
    }

    private func run(_ text: String, daysAgo: Double = 0) -> DictationRun {
        DictationRun(
            date: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60), engine: "Test",
            audioSeconds: 1, processSeconds: 0.1, text: text
        )
    }

    private func encoded(_ run: DictationRun) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(run) + Data([0x0A])
    }

    /// What another process does: opens the file and appends one line.
    private func appendAsAnotherProcess(_ run: DictationRun, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: encoded(run))
    }

    @Test("A run another process appended survives this process's rewrite")
    func appendFromAnotherWriterSurvivesRewrite() throws {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = run("from the app")
        let b = run("from the keyboard")

        store.update(.append([a]))
        store.drain()
        try appendAsAnotherProcess(b, to: store.url)
        store.update(.setSaved(true, id: a.id))
        store.drain()

        let stored = store.load()
        #expect(stored.map(\.id) == [a.id, b.id])
        #expect(stored.first?.isSaved == true)
        #expect(stored.last?.isSaved == false)
    }

    @Test("A change after another process rewrote the file builds on that file")
    func rewriteFromAnotherWriterIsReloaded() throws {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = run("first")
        let b = run("second")
        let c = run("third")

        store.update(.append([a, b]))
        store.drain()
        // The other process deleted `a` and added `c`.
        try (encoded(b) + encoded(c)).write(to: store.url, options: .atomic)
        store.update(.setLabel("Second.", id: b.id))
        store.drain()

        let stored = store.load()
        #expect(stored.map(\.id) == [b.id, c.id])
        #expect(stored.first?.label == "Second.")
    }

    @Test("Appends from both processes interleave without losing a line")
    func interleavedAppends() throws {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runs = (0..<6).map { run("run \($0)") }

        store.update(.append([runs[0]]))
        store.drain()
        try appendAsAnotherProcess(runs[1], to: store.url)
        store.update(.append([runs[2]]))
        store.drain()
        try appendAsAnotherProcess(runs[3], to: store.url)
        try appendAsAnotherProcess(runs[4], to: store.url)
        store.update(.append([runs[5]]))
        store.drain()
        store.update(.setSaved(true, id: runs[5].id))
        store.drain()

        #expect(store.load().map(\.id) == runs.map(\.id))
    }

    @Test("A refresh picks up another process's append and publishes it")
    func refreshPublishesSnapshot() throws {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = run("kept")
        store.update(.append([a]))
        store.drain()
        try appendAsAnotherProcess(run("other"), to: store.url)

        let published = Published()
        store.update(RunLog.Change { _ in }, publish: { published.set($0) })
        store.drain()
        #expect(published.value.count == 2)
        #expect(published.value.first?.id == a.id)
    }

    @Test("A notification for this process's own write republishes nothing; another process's does")
    func ownWriteNotificationIsSkipped() throws {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        store.update(.append([run("mine")]))
        store.drain()

        let afterOwn = Published()
        store.update(RunLog.Change { _ in }, publishOnlyIfReloaded: true, publish: { afterOwn.set($0) })
        store.drain()
        #expect(afterOwn.value.isEmpty)

        try appendAsAnotherProcess(run("theirs"), to: store.url)
        let afterOther = Published()
        store.update(RunLog.Change { _ in }, publishOnlyIfReloaded: true, publish: { afterOther.set($0) })
        store.drain()
        #expect(afterOther.value.map(\.text) == ["mine", "theirs"])
    }

    @Test("Two stores over one folder, writing at once, lose no run and no edit")
    func concurrentWritersLoseNothing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runlog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = RunLog.Store(directory: folder, notifiesOtherProcesses: false)
        let second = RunLog.Store(directory: folder, notifiesOtherProcesses: false)
        let seeds = (0..<4).map { run("seed \($0)") }
        first.update(.append(seeds))
        first.drain()
        second.update(RunLog.Change { _ in })
        second.drain()

        let perStore = 25
        let firstRuns = (0..<perStore).map { run("first \($0)") }
        let secondRuns = (0..<perStore).map { run("second \($0)") }
        DispatchQueue.concurrentPerform(iterations: 2) { side in
            let store = side == 0 ? first : second
            let mine = side == 0 ? firstRuns : secondRuns
            for (index, run) in mine.enumerated() {
                store.update(.append([run]))
                // Interleave rewrites: each store edits the other's seed runs and its own.
                if index % 5 == 0 {
                    store.update(.setSaved(true, id: seeds[side].id))
                    store.update(.setLabel("label \(side)", id: seeds[2 + side].id))
                }
            }
        }
        first.drain()
        second.drain()

        let stored = RunLog.Store(directory: folder, notifiesOtherProcesses: false).load()
        let ids = stored.map(\.id)
        #expect(Set(ids) == Set((seeds + firstRuns + secondRuns).map(\.id)))
        #expect(ids.count == Set(ids).count)
        #expect(stored.first { $0.id == seeds[0].id }?.isSaved == true)
        #expect(stored.first { $0.id == seeds[1].id }?.isSaved == true)
        #expect(stored.first { $0.id == seeds[2].id }?.label == "label 0")
        #expect(stored.first { $0.id == seeds[3].id }?.label == "label 1")
    }

    @Test("Clearing and deleting recordings stay inside the store's own folder")
    func recordingsFollowTheStore() throws {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = run("kept")
        let recordings = folder.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try Data([0]).write(to: recordings.appendingPathComponent("\(kept.id.uuidString).flac"))
        store.update(.append([kept]))
        store.update(.deleteAllRecordings())
        store.drain()
        #expect(!FileManager.default.fileExists(atPath: recordings.path))
        store.update(.clear())
        store.drain()
        #expect(store.load().isEmpty)
    }

    @Test("Expired runs are pruned after an append, and the other process's runs stay")
    func pruneAfterAppend() throws {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let kept = run("recent")
        let expired = run("old", daysAgo: 40)
        let other = run("other")

        store.update(.append([kept]))
        store.drain()
        try appendAsAnotherProcess(other, to: store.url)
        store.update(.append([expired]))
        store.drain()

        #expect(store.load().map(\.id) == [kept.id, other.id])
    }

    @Test("A write posts the change notification")
    func writesPostNotification() throws {
        let (store, folder) = makeStore(notifies: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let counter = Counter()
        let token = Unmanaged.passUnretained(counter).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), token,
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<Counter>.fromOpaque(observer).takeUnretainedValue().increment()
            },
            RunLog.didChangeNotification as CFString, nil, .deliverImmediately
        )
        defer { CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), token) }

        store.update(.append([run("written")]))
        store.drain()
        #expect(counter.waitForCount(atLeast: 1, timeout: 5))
    }

    @Test("The dashboard hook receives the snapshot on the history queue")
    func renderReceivesSnapshot() {
        let (store, folder) = makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rendered = Published()
        store.update(.append([run("shown")]), render: { rendered.set($0) })
        store.drain()
        #expect(rendered.value.map(\.text) == ["shown"])
    }
}

private final class Published: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [DictationRun] = []
    var value: [DictationRun] { lock.withLock { runs } }
    func set(_ new: [DictationRun]) { lock.withLock { runs = new } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }

    /// Darwin notifications arrive on the main run loop, which a synchronous test must spin.
    func waitForCount(atLeast target: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ count }) >= target { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return lock.withLock { count } >= target
    }
}
