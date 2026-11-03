import AVFoundation
import Foundation
import Testing
@testable import Murmur
import MurmurDictionary

struct TrainingRunFieldTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    /// `AppliedCorrection` has no public memberwise initializer, so build one by decoding.
    static func correction(from: String = "a", to: String = "b") -> AppliedCorrection {
        let json = Data(#"{"from":"\#(from)","to":"\#(to)","count":1}"#.utf8)
        return try! JSONDecoder().decode(AppliedCorrection.self, from: json)
    }

    static func run(
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

    @Test("Old lines decode with no training fields; new fields round-trip")
    func coding() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = Data(#"{"date":"2026-10-01T10:00:00Z","engine":"Parakeet","audioSeconds":1,"processSeconds":0.2,"text":"hi"}"#.utf8)
        let old = try decoder.decode(DictationRun.self, from: legacy)
        #expect(old.rawText == nil)
        #expect(old.label == nil)
        #expect(old.hasAudio == false)
        #expect(old.exportedAt == nil)
        #expect(!old.isLabelled)

        var run = Self.run(daysAgo: 1, label: "Hello there", hasAudio: true, exportedAt: Self.now)
        run.rawText = "hello there"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let back = try decoder.decode(DictationRun.self, from: encoder.encode(run))
        #expect(back.rawText == "hello there")
        #expect(back.label == "Hello there")
        #expect(back.hasAudio)
        #expect(back.exportedAt != nil)
        #expect(back.isLabelled)
    }

    @Test("A dictionary hit or an edit makes a run labelled")
    func labelled() {
        #expect(!Self.run(daysAgo: 0).isLabelled)
        #expect(Self.run(daysAgo: 0, label: "x").isLabelled)
        #expect(!Self.run(daysAgo: 0, label: "").isLabelled)
        #expect(Self.run(daysAgo: 0, corrections: [Self.correction()]).isLabelled)
    }

    @Test("Labelled runs with unexported audio outlive the 30 days; exported or audio-less ones do not")
    func retention() {
        let plainOld = Self.run(daysAgo: 31)
        let labelledOldWithAudio = Self.run(daysAgo: 31, label: "x", hasAudio: true)
        let labelledOldExported = Self.run(daysAgo: 31, label: "x", hasAudio: true, exportedAt: Self.now)
        let labelledOldNoAudio = Self.run(daysAgo: 31, label: "x")
        let kept = RunLog.retained([plainOld, labelledOldWithAudio, labelledOldExported, labelledOldNoAudio], now: Self.now)
        #expect(kept.map(\.id) == [labelledOldWithAudio.id])
    }
}

struct RecordingStoreTests {
    private func chunk(seconds: Double) throws -> AudioChunk {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData?[0][i] = sinf(Float(i) * 0.05) * 0.3 }
        return AudioChunk(buffer: buffer)
    }

    @Test("Chunks are written as one FLAC named by the run id, and deleted by id")
    func writeAndDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(directory: root)
        let id = UUID()
        try store.write([try chunk(seconds: 0.5), try chunk(seconds: 0.5)], id: id)
        #expect(store.exists(id: id))
        #expect(store.url(for: id).lastPathComponent == "\(id.uuidString).flac")
        let file = try AVAudioFile(forReading: store.url(for: id))
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 1.0) < 0.01)
        #expect(store.totalBytes() > 0)
        store.delete(id: id)
        #expect(!store.exists(id: id))
        #expect(store.totalBytes() == 0)
    }

    @Test("Writing nothing creates no file")
    func emptyWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(directory: root)
        let id = UUID()
        try store.write([], id: id)
        #expect(!store.exists(id: id))
    }
}

struct RunFileAudioTests {
    @Test("Dropping runs removes their recordings; keeping them does not")
    func pruneDeletesAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(directory: root)
        let keep = TrainingRunFieldTests.run(daysAgo: 1, hasAudio: true)
        let drop = TrainingRunFieldTests.run(daysAgo: 40, hasAudio: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0]).write(to: store.url(for: keep.id))
        try Data([0]).write(to: store.url(for: drop.id))
        RunLog.removeRecordings(of: [keep, drop], except: [keep], in: store)
        #expect(store.exists(id: keep.id))
        #expect(!store.exists(id: drop.id))
    }
}

struct TrainingSettingsTests {
    @MainActor
    @Test("Recording and decoder choices persist with safe defaults")
    func persistence() throws {
        let name = "murmur-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(Settings(defaults: defaults).keepRecordings)
        #expect(Settings(defaults: defaults).barkDecoder == .stock)
        let settings = Settings(defaults: defaults)
        settings.keepRecordings = false
        settings.barkDecoder = .custom("2026-11-03")
        #expect(defaults.string(forKey: "barkDecoder") == "custom:2026-11-03")
        #expect(Settings(defaults: defaults).keepRecordings == false)
        #expect(Settings(defaults: defaults).barkDecoder == .custom("2026-11-03"))
        defaults.set("garbage", forKey: "barkDecoder")
        #expect(Settings(defaults: defaults).barkDecoder == .stock)
    }
}

struct TrainingLabelTests {
    private let corrector = DictionaryCorrector(entries: [
        DictionaryEntry.correction(hear: "cloud code", write: "Claude Code"),
    ])

    private func run(cleanup: String?, raw: String?, label: String?) -> DictationRun {
        var run = DictationRun(date: Date(), engine: "Bark 3.0 Clean (batch)", audioSeconds: 1, processSeconds: 0.1, text: "x", cleanup: cleanup)
        run.rawText = raw
        run.label = label
        return run
    }

    @Test("An edit wins on rules-cleaned runs; cleaned rewrites fall back to the dictionary")
    func priority() {
        let edited = run(cleanup: nil, raw: "open cloud code", label: "Open Claude Code now")
        #expect(TrainingLabel.resolve(edited, corrector: corrector)?.text == "Open Claude Code now")
        #expect(TrainingLabel.resolve(edited, corrector: corrector)?.source == .edit)

        let s1 = run(cleanup: "S1-mini · General", raw: "open cloud code", label: "Rewritten by hand")
        #expect(!TrainingLabel.editAllowed(s1))
        let resolved = TrainingLabel.resolve(s1, corrector: corrector)
        #expect(resolved?.source == .dictionary)
        #expect(resolved?.text == "open Claude Code")
    }

    @Test("No edit and no dictionary hit means no label")
    func none() {
        #expect(TrainingLabel.resolve(run(cleanup: nil, raw: "nothing here", label: nil), corrector: corrector) == nil)
        #expect(TrainingLabel.resolve(run(cleanup: nil, raw: nil, label: nil), corrector: corrector) == nil)
    }
}

struct TrainingExportTests {
    @Test("Labelled runs with audio go to the manifest, unlabelled ones to replay, and the zip exists")
    func export() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = RecordingStore(directory: root.appendingPathComponent("Recordings"))
        try FileManager.default.createDirectory(at: recordings.directory, withIntermediateDirectories: true)
        let corrector = DictionaryCorrector(entries: [DictionaryEntry.correction(hear: "cloud code", write: "Claude Code")])

        var labelled = TrainingRunFieldTests.run(daysAgo: 1, hasAudio: true)
        labelled.rawText = "open cloud code"
        var replay = TrainingRunFieldTests.run(daysAgo: 2, hasAudio: true)
        replay.rawText = "plain words"
        var noAudio = TrainingRunFieldTests.run(daysAgo: 3, label: "x")
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

    @Test("Pending counts labelled, unexported runs with audio")
    func pending() {
        let corrector = DictionaryCorrector(entries: [])
        var a = TrainingRunFieldTests.run(daysAgo: 1, label: "x", hasAudio: true)
        a.rawText = "x"
        let b = TrainingRunFieldTests.run(daysAgo: 1, label: "x", hasAudio: true, exportedAt: Date())
        let c = TrainingRunFieldTests.run(daysAgo: 1, label: "x")
        let pending = TrainingExport.pending([a, b, c], corrector: corrector)
        #expect(pending.count == 1)
        #expect(pending.seconds == 2)
    }
}
