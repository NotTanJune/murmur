import Foundation
import MurmurDictionary
import Testing
@testable import MurmurKit

/// A phone's export folder merged into a Mac's history. Each side is a temporary root with
/// its own `RunLog.Store` and recordings, so nothing touches `MurmurEnvironment`.
struct TrainingImportTests {
    private struct Root {
        let folder: URL
        let store: RunLog.Store
        let recordings: RecordingStore

        init() {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
            recordings = RecordingStore(directory: folder.appendingPathComponent("Recordings", isDirectory: true))
            store = RunLog.Store(directory: folder, recordings: recordings, notifiesOtherProcesses: false)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: folder) }
    }

    private let corrector = DictionaryCorrector(entries: [])

    private func labelledRun(_ label: String, raw: String, daysAgo: Double = 0) -> DictationRun {
        var run = DictationRun(
            date: Date().addingTimeInterval(-daysAgo * 24 * 60 * 60), engine: "Bark 3.0 Clean (batch)", audioSeconds: 2,
            processSeconds: 0.1, text: raw
        )
        run.rawText = raw
        run.label = label
        run.hasAudio = true
        return run
    }

    /// Puts runs into `root` with a stand-in clip each, as the phone's recorder would have.
    private func seed(_ runs: [DictationRun], in root: Root) throws {
        try FileManager.default.createDirectory(at: root.recordings.directory, withIntermediateDirectories: true)
        for run in runs { try Data("flac \(run.id)".utf8).write(to: root.recordings.url(for: run.id)) }
        root.store.update(.append(runs))
        root.store.drain()
    }

    private func export(_ runs: [DictationRun], from root: Root) throws -> URL {
        let folder = root.folder.appendingPathComponent("export", isDirectory: true)
        try TrainingExport.writeFolder(runs: runs, corrector: corrector, recordings: root.recordings, to: folder)
        return folder
    }

    @Test("Imported runs and their audio land in the destination, marked as from the phone")
    func importAddsRunsAndAudio() throws {
        let phone = Root(), mac = Root()
        defer { phone.cleanUp(); mac.cleanUp() }
        let a = labelledRun("Open Claude Code.", raw: "open cloud code")
        let b = labelledRun("Send it Friday.", raw: "send it friday")
        try seed([a, b], in: phone)
        let folder = try export([a, b], from: phone)

        let result = try TrainingImport.merge(folder: folder, into: mac.store, recordings: mac.recordings)

        #expect(result.added == 2)
        #expect(result.skipped == 0)
        let stored = mac.store.load()
        #expect(Set(stored.map(\.id)) == [a.id, b.id])
        for run in stored {
            #expect(run.source == .phone)
            #expect(run.exportedAt == nil)
            #expect(run.hasAudio)
            #expect(mac.recordings.exists(id: run.id))
        }
        #expect(stored.first { $0.id == a.id }?.label == "Open Claude Code.")
        #expect(stored.first { $0.id == b.id }?.label == "Send it Friday.")
        #expect(try Data(contentsOf: mac.recordings.url(for: a.id)) == Data(contentsOf: phone.recordings.url(for: a.id)))
    }

    @Test("A run whose id is already in the log is skipped, never overwritten")
    func duplicateIdIsSkipped() throws {
        let phone = Root(), mac = Root()
        defer { phone.cleanUp(); mac.cleanUp() }
        let a = labelledRun("One.", raw: "one")
        let b = labelledRun("Two.", raw: "two")
        try seed([a, b], in: phone)
        let folder = try export([a, b], from: phone)

        _ = try TrainingImport.merge(folder: folder, into: mac.store, recordings: mac.recordings)
        mac.store.update(.setLabel("Edited on the Mac.", id: a.id))
        mac.store.drain()
        let second = try TrainingImport.merge(folder: folder, into: mac.store, recordings: mac.recordings)

        #expect(second.added == 0)
        #expect(second.skipped == 2)
        let stored = mac.store.load()
        #expect(stored.count == 2)
        #expect(stored.first { $0.id == a.id }?.label == "Edited on the Mac.")
    }

    @Test("A run the Mac already has keeps its own audio and fields")
    func existingMacRunIsUntouched() throws {
        let mac = Root(), phone = Root()
        defer { phone.cleanUp(); mac.cleanUp() }
        let own = labelledRun("Mine.", raw: "mine")
        try seed([own], in: mac)
        // The same id exported from elsewhere, with different audio and label.
        var other = own
        other.label = "Theirs."
        try seed([other], in: phone)
        let folder = try export([other], from: phone)

        let result = try TrainingImport.merge(folder: folder, into: mac.store, recordings: mac.recordings)

        #expect(result.added == 0)
        #expect(result.skipped == 1)
        let stored = try #require(mac.store.load().first)
        #expect(stored.label == "Mine.")
        #expect(stored.source == nil)
        #expect(try Data(contentsOf: mac.recordings.url(for: own.id)) == Data("flac \(own.id)".utf8))
    }

    @Test("The export carries every exported run, labelled and replay, in runs.jsonl")
    func exportWritesRunsFile() throws {
        let phone = Root()
        defer { phone.cleanUp() }
        let labelled = labelledRun("Fixed.", raw: "fixed")
        var replay = DictationRun(date: Date(), engine: "Bark", audioSeconds: 1, processSeconds: 0.1, text: "plain words")
        replay.rawText = "plain words"
        replay.hasAudio = true
        var noAudio = labelledRun("No clip.", raw: "no clip")
        noAudio.hasAudio = false
        try seed([labelled, replay], in: phone)
        let folder = try export([labelled, replay, noAudio], from: phone)

        let lines = try String(contentsOf: folder.appendingPathComponent("runs.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try lines.map { try decoder.decode(DictationRun.self, from: Data($0.utf8)) }
        #expect(decoded.map(\.id) == [labelled.id, replay.id])
        #expect(decoded.first?.label == "Fixed.")
        #expect(decoded.first?.rawText == "fixed")
    }

    @Test("Replay runs come across too, and a run with no clip is added without audio")
    func replayAndMissingClip() throws {
        let phone = Root(), mac = Root()
        defer { phone.cleanUp(); mac.cleanUp() }
        let labelled = labelledRun("Fixed.", raw: "fixed")
        var replay = DictationRun(date: Date(), engine: "Bark", audioSeconds: 1, processSeconds: 0.1, text: "plain words")
        replay.rawText = "plain words"
        replay.hasAudio = true
        try seed([labelled, replay], in: phone)
        let folder = try export([labelled, replay], from: phone)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("clips/\(replay.id.uuidString).flac"))

        let result = try TrainingImport.merge(folder: folder, into: mac.store, recordings: mac.recordings)

        #expect(result.added == 2)
        let stored = mac.store.load()
        #expect(stored.first { $0.id == labelled.id }?.hasAudio == true)
        #expect(stored.first { $0.id == replay.id }?.hasAudio == false)
        #expect(!mac.recordings.exists(id: replay.id))
    }

    @Test("A clip that is a symbolic link is not followed")
    func symlinkClipIsIgnored() throws {
        let phone = Root(), mac = Root()
        defer { phone.cleanUp(); mac.cleanUp() }
        let a = labelledRun("One.", raw: "one")
        try seed([a], in: phone)
        let folder = try export([a], from: phone)
        let secret = phone.folder.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        let clip = folder.appendingPathComponent("clips/\(a.id.uuidString).flac")
        try FileManager.default.removeItem(at: clip)
        try FileManager.default.createSymbolicLink(at: clip, withDestinationURL: secret)

        let result = try TrainingImport.merge(folder: folder, into: mac.store, recordings: mac.recordings)

        #expect(result.added == 1)
        #expect(mac.store.load().first?.hasAudio == false)
        #expect(!mac.recordings.exists(id: a.id))
    }

    @Test("A folder without runs.jsonl is refused with a readable error")
    func missingRunsFile() throws {
        let mac = Root()
        defer { mac.cleanUp() }
        let folder = mac.folder.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: TrainingImport.Failure.self) {
            try TrainingImport.merge(folder: folder, into: mac.store, recordings: mac.recordings)
        }
        #expect(mac.store.load().isEmpty)
    }

    @Test("Lines written before the source field decode with no source")
    func oldLinesDecodeAsMac() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = Data(#"{"date":"2026-10-01T10:00:00Z","engine":"Parakeet","audioSeconds":1,"processSeconds":0.2,"text":"hi"}"#.utf8)
        #expect(try decoder.decode(DictationRun.self, from: legacy).source == nil)

        let tagged = Data(#"{"date":"2026-10-01T10:00:00Z","engine":"Parakeet","audioSeconds":1,"processSeconds":0.2,"text":"hi","source":"phone"}"#.utf8)
        #expect(try decoder.decode(DictationRun.self, from: tagged).source == .phone)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var run = DictationRun(date: Date(), engine: "x", audioSeconds: 1, processSeconds: 1, text: "t")
        #expect(!String(decoding: try encoder.encode(run), as: UTF8.self).contains("source"))
        run.source = .mac
        #expect(try decoder.decode(DictationRun.self, from: encoder.encode(run)).source == .mac)
    }

    // MARK: Fix round 1

    private func rewriteRunsFile(in folder: URL, _ transform: (String) -> String) throws {
        let url = folder.appendingPathComponent("runs.jsonl")
        try transform(String(contentsOf: url, encoding: .utf8)).write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("The same id twice in one file imports once and counts the repeat as skipped")
    func repeatedIdInOneFileImportsOnce() throws {
        let phone = Root(), mac = Root()
        defer { phone.cleanUp(); mac.cleanUp() }
        let a = labelledRun("One.", raw: "one")
        try seed([a], in: phone)
        let folder = try export([a], from: phone)
        try rewriteRunsFile(in: folder) { $0 + $0 }

        let result = try TrainingImport.merge(folder: folder, into: mac.store, recordings: mac.recordings)

        #expect(result == ImportResult(added: 1, skipped: 1, failed: 0))
        #expect(mac.store.load().map(\.id) == [a.id])
    }

    @Test("A line that does not decode is counted and the rest still import")
    func malformedLineIsCountedAndRestImports() throws {
        let phone = Root(), mac = Root()
        defer { phone.cleanUp(); mac.cleanUp() }
        let a = labelledRun("One.", raw: "one")
        let b = labelledRun("Two.", raw: "two")
        try seed([a, b], in: phone)
        let folder = try export([a, b], from: phone)
        try rewriteRunsFile(in: folder) { "{\"date\":\"2026-10\n" + $0 + "not json at all\n\n" }

        let result = try TrainingImport.merge(folder: folder, into: mac.store, recordings: mac.recordings)

        #expect(result.added == 2)
        #expect(result.skipped == 0)
        #expect(result.failed == 2)
        #expect(result.summary == "Added 2, skipped 0, unreadable 2")
        #expect(ImportResult(added: 1, skipped: 3).summary == "Added 1, skipped 3")
        #expect(Set(mac.store.load().map(\.id)) == [a.id, b.id])
    }

    @Test("A file with lines and none readable throws instead of reporting nothing")
    func allLinesMalformedThrows() throws {
        let mac = Root()
        defer { mac.cleanUp() }
        let folder = mac.folder.appendingPathComponent("cut", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{\"id\":\"truncated\nnot json\n".utf8).write(to: folder.appendingPathComponent("runs.jsonl"))

        #expect(throws: TrainingImport.Failure.unreadable(lines: 2)) {
            try TrainingImport.merge(folder: folder, into: mac.store, recordings: mac.recordings)
        }
        #expect(mac.store.load().isEmpty)
    }

    @Test("A recording already at a new run's path is kept, and counts as its audio only if the size matches")
    func existingRecordingIsNotDeleted() throws {
        let phone = Root(), mac = Root()
        defer { phone.cleanUp(); mac.cleanUp() }
        let differs = labelledRun("Differs.", raw: "differs")
        let matches = labelledRun("Matches.", raw: "matches")
        try seed([differs, matches], in: phone)
        let folder = try export([differs, matches], from: phone)
        try FileManager.default.createDirectory(at: mac.recordings.directory, withIntermediateDirectories: true)
        try Data([9]).write(to: mac.recordings.url(for: differs.id))
        let sameBytes = try Data(contentsOf: phone.recordings.url(for: matches.id))
        try sameBytes.write(to: mac.recordings.url(for: matches.id))

        let result = try TrainingImport.merge(folder: folder, into: mac.store, recordings: mac.recordings)

        #expect(try Data(contentsOf: mac.recordings.url(for: differs.id)) == Data([9]))
        #expect(try Data(contentsOf: mac.recordings.url(for: matches.id)) == sameBytes)
        #expect(result.added == 2)
        let stored = mac.store.load()
        #expect(stored.first { $0.id == matches.id }?.hasAudio == true)
        #expect(stored.first { $0.id == differs.id }?.hasAudio == false)
    }

    @Test("Runs that retention would prune on landing are skipped, not counted, and get no audio")
    func prunedRunsAreNotCounted() throws {
        let phone = Root(), mac = Root()
        defer { phone.cleanUp(); mac.cleanUp() }
        let recentLabelled = labelledRun("Recent.", raw: "recent")
        let oldLabelled = labelledRun("Old but labelled.", raw: "old labelled", daysAgo: 40)
        let oldNoClip = labelledRun("Old, clip lost.", raw: "old no clip", daysAgo: 40)
        var oldReplay = DictationRun(date: Date().addingTimeInterval(-40 * 24 * 60 * 60), engine: "Bark", audioSeconds: 1, processSeconds: 0.1, text: "old plain")
        oldReplay.rawText = "old plain"
        oldReplay.hasAudio = true
        var recentReplay = DictationRun(date: Date(), engine: "Bark", audioSeconds: 1, processSeconds: 0.1, text: "recent plain")
        recentReplay.rawText = "recent plain"
        recentReplay.hasAudio = true
        let all = [recentLabelled, oldLabelled, oldNoClip, oldReplay, recentReplay]
        // Clips only: the phone's own log would prune the old replay run and its audio.
        try FileManager.default.createDirectory(at: phone.recordings.directory, withIntermediateDirectories: true)
        for run in all { try Data("flac \(run.id)".utf8).write(to: phone.recordings.url(for: run.id)) }
        let folder = try export(all, from: phone)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("clips/\(oldNoClip.id.uuidString).flac"))

        let result = try TrainingImport.merge(folder: folder, into: mac.store, recordings: mac.recordings)

        #expect(result == ImportResult(added: 3, skipped: 2, failed: 0))
        let stored = mac.store.load()
        #expect(Set(stored.map(\.id)) == [recentLabelled.id, oldLabelled.id, recentReplay.id])
        #expect(mac.recordings.exists(id: oldLabelled.id))
        #expect(!mac.recordings.exists(id: oldReplay.id))
        #expect(!mac.recordings.exists(id: oldNoClip.id))
    }

    @Test("A runs.jsonl over the limit is refused")
    func oversizedRunsFileIsRefused() throws {
        let mac = Root()
        defer { mac.cleanUp() }
        let folder = mac.folder.appendingPathComponent("big", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("runs.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(TrainingImport.maxRunsFileBytes + 1))
        try handle.close()

        #expect(throws: TrainingImport.Failure.runsFileTooLarge(bytes: TrainingImport.maxRunsFileBytes + 1)) {
            try TrainingImport.merge(folder: folder, into: mac.store, recordings: mac.recordings)
        }
    }

    @Test("A clip over the limit is not copied; its recent run still imports without audio")
    func oversizedClipIsSkipped() throws {
        let phone = Root(), mac = Root()
        defer { phone.cleanUp(); mac.cleanUp() }
        let a = labelledRun("One.", raw: "one")
        var recent = DictationRun(date: Date(), engine: "Bark", audioSeconds: 1, processSeconds: 0.1, text: "plain")
        recent.rawText = "plain"
        recent.hasAudio = true
        try seed([a, recent], in: phone)
        let folder = try export([a, recent], from: phone)
        let clip = folder.appendingPathComponent("clips/\(recent.id.uuidString).flac")
        let handle = try FileHandle(forWritingTo: clip)
        try handle.truncate(atOffset: UInt64(TrainingImport.maxClipBytes + 1))
        try handle.close()

        let result = try TrainingImport.merge(folder: folder, into: mac.store, recordings: mac.recordings)

        #expect(result.added == 2)
        #expect(mac.store.load().first { $0.id == recent.id }?.hasAudio == false)
        #expect(!mac.recordings.exists(id: recent.id))
        #expect(mac.recordings.exists(id: a.id))
    }
}
