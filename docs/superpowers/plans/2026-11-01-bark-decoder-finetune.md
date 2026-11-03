# Bark Clean Personal Fine-Tune Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Murmur collect (audio, corrected text) pairs from daily dictation, export them for a Colab fine-tune of Bark Clean's decoder and joint, and install the result beside the stock model with one-tap revert.

**Architecture:** Three layers. (1) Capture and labels: every non-compare hold keeps its audio buffers until delivery; `RunLog` writes a FLAC per run and stores `rawText`, `label`, `hasAudio`, `exportedAt` on `DictationRun`. (2) Export and import: `TrainingExport` writes a manifest + clips folder and zips it; `CustomDecoderSlot` verifies and installs a trained decoder/joint pair that `ParakeetModels.loadBarkClean` loads in place of the stock pair. (3) Training: a checked-in Colab notebook that unpacks `model.bark` into `transformers.ParakeetForTDT`, trains decoder and joint with the encoder frozen, gates on WER, and exports Core ML.

**Tech Stack:** Swift 6 / SwiftUI / AVFoundation (FLAC via `AVAudioFile`) / CryptoKit / FluidAudio 0.15.6 on the Mac; `transformers>=5.19`, `torch`, `coremltools`, `jiwer` in Colab.

Spec: `docs/superpowers/specs/2026-11-01-bark-decoder-finetune-design.md`. Read `AGENTS.md` first.

## Global Constraints

- Build only with `nice -n 15 make build CONFIG=debug`; tests with `nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch" --filter <Suite>`. Never bare `swift build`. Never `make install`.
- No git worktrees. Work in the repo root. Do not commit; the user commits.
- `RunLog` does all file I/O on its serial queue; nothing touches the history or recordings from the main actor.
- Views contain no literal values; use `DS.*` tokens and `Components.swift` pieces (`BrutalCard`, `Eyebrow`, `Note`, `ChoiceKeys`, `BrutalButtonStyle`, `Tag`, `BrutalTextField`).
- Yellow = selected (`BrutalButtonStyle(isSelected:)` / `ChoiceKeys`); red = recording only.
- Old `runs.jsonl` lines must keep decoding: every new `DictationRun` field is optional or defaulted and decoded with `decodeIfPresent`.
- Stock Bark files stay verified against `BarkModelStore.revision`. The custom slot never touches `Encoder.mlmodelc` or `Preprocessor.mlmodelc`.
- Core ML contract for the custom pair (from the installed `model.mil`): decoder inputs `targets [1,1] int32`, `target_length [1] int32`, `h_in [2,1,640] fp32`, `c_in [2,1,640] fp32`; joint inputs `encoder_step [1,1024,1] fp32`, `decoder_step [1,640,1] fp32`; vocabulary 8193 tokens.
- Em dashes are not used in any prose written for this project.

---

## File map

| File | Responsibility |
|---|---|
| `Sources/Murmur/Support/RunLog.swift` (modify) | `DictationRun` gains `rawText`, `label`, `hasAudio`, `exportedAt`; `RunLog.record(_:audio:)`, `setLabel`, `markExported`; retention keeps labelled runs; audio deleted with runs |
| `Sources/Murmur/Support/RecordingStore.swift` (create) | Writes/deletes FLAC files under `Recordings/`, reports folder size |
| `Sources/Murmur/Support/TrainingLabel.swift` (create) | Pure function: a run's training label from edit or dictionary |
| `Sources/Murmur/Support/TrainingExport.swift` (create) | Builds `export-<date>/` with manifests, clips, `export.json`, zips it |
| `Sources/Murmur/Transcription/CustomDecoderSlot.swift` (create) | Custom decoder/joint folder: manifest, verify, import, remove, list |
| `Sources/Murmur/Transcription/ParakeetEngine.swift` (modify) | `loadBarkClean` loads decoder and joint from the selected slot; shared stock encoder |
| `Sources/Murmur/Support/Settings.swift` (modify) | `keepRecordings`, `barkDecoder` |
| `Sources/Murmur/Core/DictationController.swift` (modify) | Keep audio for every hold; pass `rawText` and audio to `RunLog` |
| `Sources/Murmur/Core/EngineComparison.swift` (modify) | Fine-tuned Bark row when a slot is selected |
| `Sources/Murmur/UI/MainWindow.swift` (modify) | Edit field + Labelled chip on history rows |
| `Sources/Murmur/UI/SettingsPanel.swift` (modify) | Training card |
| `Sources/Murmur/Support/DecoderCheck.swift` (create) + `MurmurApp.swift` (modify) | `--decoder-check <slot> <audio>` |
| `training/bark_decoder_finetune.ipynb`, `training/README.md` (create) | Colab fine-tune and export |
| `Tests/MurmurAppTests/TrainingDataTests.swift` (create) | Run fields, retention, labels, recording store, export |
| `Tests/MurmurAppTests/CustomDecoderSlotTests.swift` (create) | Manifest verify, import, selection, revert |
| `AGENTS.md` (modify) | One paragraph on the training loop |

---

### Task 1: DictationRun training fields and retention

**Files:**
- Modify: `Sources/Murmur/Support/RunLog.swift` (struct `DictationRun`, `RunLog.retained`)
- Test: `Tests/MurmurAppTests/TrainingDataTests.swift`

**Interfaces:**
- Produces: `DictationRun.rawText: String?`, `label: String?`, `hasAudio: Bool`, `exportedAt: Date?`, computed `isLabelled: Bool` (true when `label` is non-empty or `corrections` is non-empty), and `RunLog.retained` keeping labelled, unexported runs with audio.

- [ ] **Step 1: Write the failing tests**

Create `Tests/MurmurAppTests/TrainingDataTests.swift`:

```swift
import Foundation
import Testing
@testable import Murmur
import MurmurDictionary

struct TrainingRunFieldTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

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
        #expect(Self.run(daysAgo: 0, corrections: [AppliedCorrection(from: "a", to: "b", count: 1)]).isLabelled)
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch" --filter TrainingRunFieldTests`
Expected: compile error, `label` / `hasAudio` / `exportedAt` / `rawText` / `isLabelled` not members of `DictationRun`.

- [ ] **Step 3: Add the fields**

In `Sources/Murmur/Support/RunLog.swift`, inside `struct DictationRun`, after `var cleanup: String?` add:

```swift
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
```

In `init(from decoder:)`, after the `cleanup` line add:

```swift
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        hasAudio = try container.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt)
```

Replace `RunLog.retained`:

```swift
    /// The runs `retention` keeps: every saved run, anything newer than the cutoff, and a
    /// labelled run whose audio has not been exported yet (it is training data in waiting).
    nonisolated static func retained(_ runs: [DictationRun], now: Date) -> [DictationRun] {
        let cutoff = now.addingTimeInterval(-retention)
        return runs.filter {
            $0.isSaved || $0.date >= cutoff || ($0.isLabelled && $0.hasAudio && $0.exportedAt == nil)
        }
    }
```

- [ ] **Step 4: Run tests**

Run: `nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch" --filter "TrainingRunFieldTests|HistoryRetentionTests|RunTimingTests"`
Expected: all pass.

---

### Task 2: RecordingStore (FLAC on disk)

**Files:**
- Create: `Sources/Murmur/Support/RecordingStore.swift`
- Test: `Tests/MurmurAppTests/TrainingDataTests.swift` (append)

**Interfaces:**
- Produces: `struct RecordingStore: Sendable { let directory: URL; static let shared: RecordingStore; func url(for id: UUID) -> URL; func write(_ chunks: [AudioChunk], id: UUID) throws; func delete(id: UUID); func deleteAll(); func totalBytes() -> Int; func exists(id: UUID) -> Bool }`. Files are `<id>.flac`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/MurmurAppTests/TrainingDataTests.swift`:

```swift
import AVFoundation

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
```

- [ ] **Step 2: Run to verify it fails**

Run: `nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch" --filter RecordingStoreTests`
Expected: compile error, `RecordingStore` undefined.

- [ ] **Step 3: Implement**

Create `Sources/Murmur/Support/RecordingStore.swift`:

```swift
import AVFoundation
import Foundation

/// The audio behind each history run, one FLAC per run, for training exports.
///
/// Written on `RunLog`'s queue at delivery and deleted whenever the run is pruned or
/// deleted, so the folder never outgrows history. FLAC through `AVAudioFile` keeps the
/// 16 kHz capture lossless at about 1 MB per minute.
struct RecordingStore: Sendable {
    let directory: URL

    static let shared = RecordingStore(
        directory: AppStorage.directory.appendingPathComponent("Recordings", isDirectory: true)
    )

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).flac")
    }

    func exists(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    /// Writes the buffers in capture order. Buffers are converted from their own format
    /// (float32 or int16, whatever the engine asked capture for) by `AVAudioFile`.
    func write(_ chunks: [AudioChunk], id: UUID) throws {
        guard let first = chunks.first(where: { $0.buffer.frameLength > 0 }) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = first.buffer.format
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
        ]
        let file = try AVAudioFile(
            forWriting: url(for: id), settings: settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
        for chunk in chunks where chunk.buffer.frameLength > 0 {
            try file.write(from: chunk.buffer)
        }
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    func totalBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch" --filter RecordingStoreTests`
Expected: 2 passed. If `AVAudioFile(forWriting:)` throws for FLAC with float32 input, change `commonFormat:` to `.pcmFormatInt16` and `interleaved: true` (AVAudioFile converts) and rerun.

---

### Task 3: RunLog writes, deletes and labels audio

**Files:**
- Modify: `Sources/Murmur/Support/RunLog.swift` (`RunLog.record`, `setSaved` pattern, `RunFile.rewrite`, `pruneExpired`, `clear`)
- Test: `Tests/MurmurAppTests/TrainingDataTests.swift` (append)

**Interfaces:**
- Produces: `RunLog.record(_ run: DictationRun, audio: [AudioChunk])` (writes FLAC when `Settings.shared.keepRecordings`, sets `hasAudio`), `RunLog.setLabel(_ label: String?, for run: DictationRun)`, `RunLog.markExported(ids: Set<UUID>, at date: Date)`, `RunLog.deleteAllRecordings()`.
- Consumes: `RecordingStore.shared`; `Settings.keepRecordings` (Task 4; add the property now as a plain `var keepRecordings = true` stub if Task 4 is not done yet, then let Task 4 wire persistence).

- [ ] **Step 1: Write the failing test**

Append to `Tests/MurmurAppTests/TrainingDataTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch" --filter RunFileAudioTests`
Expected: compile error, `removeRecordings` undefined.

- [ ] **Step 3: Implement**

In `RunLog` (enum, `@MainActor`), add after `setSaved`:

```swift
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
```

In `RunFile.rewrite(_ kept:)`, before `runs = kept`, add:

```swift
        RunLog.removeRecordings(of: runs, except: kept, in: RecordingStore.shared)
```

In `RunFile.clear()`, add `RecordingStore.shared.deleteAll()` before `runs = []`.

If `Settings.keepRecordings` does not exist yet, add to `Settings` (temporary, Task 4 persists it):

```swift
    var keepRecordings: Bool = true
```

- [ ] **Step 4: Run tests and build**

Run: `nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch" --filter "RunFileAudioTests|HistoryRetentionTests"` then `nice -n 15 make build CONFIG=debug`
Expected: pass; build complete.

---

### Task 4: Settings for recordings and decoder slot

**Files:**
- Modify: `Sources/Murmur/Support/Settings.swift`
- Test: `Tests/MurmurAppTests/TrainingDataTests.swift` (append)

**Interfaces:**
- Produces: `Settings.keepRecordings: Bool` (key `keepRecordings`, default true), `Settings.barkDecoder: BarkDecoderChoice` (key `barkDecoder`, default `.stock`), `enum BarkDecoderChoice: Equatable, Sendable { case stock; case custom(String) }` with `rawValue` string form `"stock"` / `"custom:<folder-name>"` and `displayName`.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch" --filter TrainingSettingsTests`
Expected: compile error.

- [ ] **Step 3: Implement**

In `Settings.swift`, add at file scope:

```swift
/// Which decoder and joint Bark Clean runs with: the pinned stock pair, or a fine-tuned pair
/// installed from a training export, named by its folder.
enum BarkDecoderChoice: Equatable, Sendable {
    case stock
    case custom(String)

    var rawValue: String {
        switch self {
        case .stock: "stock"
        case .custom(let name): "custom:\(name)"
        }
    }

    init?(rawValue: String) {
        if rawValue == "stock" { self = .stock; return }
        guard rawValue.hasPrefix("custom:"), rawValue.count > 7 else { return nil }
        self = .custom(String(rawValue.dropFirst(7)))
    }

    var displayName: String {
        switch self {
        case .stock: "Stock"
        case .custom(let name): "Fine-tuned \(name)"
        }
    }
}
```

In `Settings`: replace the Task 3 stub with

```swift
    /// Keep each dictation's audio on disk for training exports.
    var keepRecordings: Bool {
        didSet { defaults.set(keepRecordings, forKey: Keys.keepRecordings) }
    }

    var barkDecoder: BarkDecoderChoice {
        didSet { defaults.set(barkDecoder.rawValue, forKey: Keys.barkDecoder) }
    }
```

Add keys `static let keepRecordings = "keepRecordings"` and `static let barkDecoder = "barkDecoder"`. In `init`:

```swift
        keepRecordings = defaults.object(forKey: Keys.keepRecordings) as? Bool ?? true
        barkDecoder = BarkDecoderChoice(rawValue: defaults.string(forKey: Keys.barkDecoder) ?? "") ?? .stock
```

- [ ] **Step 4: Run tests**

Run: `nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch" --filter TrainingSettingsTests`
Expected: pass.

---

### Task 5: Controller keeps audio and raw text

**Files:**
- Modify: `Sources/Murmur/Core/DictationController.swift` (`start` feedTask near line 541, `deliver`, `recordRun`)

**Interfaces:**
- Consumes: `RunLog.record(_:audio:)` (Task 3).

- [ ] **Step 1: Keep the recording for every hold**

In `start`, the feed task currently reads:

```swift
            let comparing = utterance.isComparing
            utterance.feedTask = Task.detached(priority: .userInitiated) {
                var recording: [AudioChunk] = []
                for await chunk in audioStream {
                    if comparing { recording.append(chunk) }
                    await engine.feed(chunk)
                }
                return recording
            }
```

Change to keep every chunk (compare mode and training both need the ordered recording):

```swift
            utterance.feedTask = Task.detached(priority: .userInitiated) {
                // Kept for compare mode and for the training recording. Ordered because it
                // is collected inside the drain, not by a task per buffer.
                var recording: [AudioChunk] = []
                for await chunk in audioStream {
                    recording.append(chunk)
                    await engine.feed(chunk)
                }
                return recording
            }
```

Remove the now-unused `let comparing = utterance.isComparing` line if nothing else in that scope uses it.

- [ ] **Step 2: Pass raw text and audio to the run record**

In `recordRun`, change the signature to add `rawText: String` and replace `RunLog.record(DictationRun(...))` with:

```swift
        let audio = utterance.recorded
        utterance.recorded.removeAll(keepingCapacity: false)
        var run = DictationRun(
            date: releasedAt,
            engine: utterance.engineName,
            audioSeconds: releasedAt.timeIntervalSince(utterance.holdStarted),
            processSeconds: processSeconds,
            text: text,
            corrections: corrections.isEmpty ? nil : corrections,
            deliverySeconds: deliverySeconds,
            cleanup: utterance.cleanupLabel
        )
        run.rawText = rawText
        RunLog.record(run, audio: audio)
```

In `deliver`, the call becomes `recordRun(utterance, text: output, rawText: raw, corrections: corrections, readyAt: readyAt, deliveredAt: deliveredAt)`. The password-field and empty-output early returns stay above it, so those holds write nothing; add `utterance.recorded.removeAll(keepingCapacity: false)` on those two early-return paths so the buffers are released.

- [ ] **Step 3: Build**

Run: `nice -n 15 make build CONFIG=debug`
Expected: Build complete.

---

### Task 6: Training label resolution

**Files:**
- Create: `Sources/Murmur/Support/TrainingLabel.swift`
- Test: `Tests/MurmurAppTests/TrainingDataTests.swift` (append)

**Interfaces:**
- Produces: `enum TrainingLabel { enum Source: String { case edit, dictionary }; struct Resolved { let text: String; let source: Source }; static func resolve(_ run: DictationRun, corrector: DictionaryCorrector) -> Resolved? ; static func editAllowed(_ run: DictationRun) -> Bool }`.
- Rule: `editAllowed` is true when `run.cleanup == nil` (rule pass or none; S1-mini and Apple Intelligence runs carry a label). `resolve`: if `editAllowed` and `label` non-empty, `.edit`; else if `rawText` non-nil and `corrector.apply(to: rawText).applied` non-empty, `.dictionary` with the corrected raw text; else nil.

- [ ] **Step 1: Write the failing test**

```swift
struct TrainingLabelTests {
    private let corrector = DictionaryCorrector(entries: [
        DictionaryEntry(hear: "cloud code", write: "Claude Code"),
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
```

Check `DictionaryEntry`'s initializer in `Sources/MurmurDictionary/DictionaryEntry.swift` and adjust the test's construction to its real parameters (it has `hear`, `write`, `kind`, `isEnabled`; a correction is `kind: .correction`).

- [ ] **Step 2: Run to verify it fails**

Run: `nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch" --filter TrainingLabelTests`
Expected: compile error.

- [ ] **Step 3: Implement**

Create `Sources/Murmur/Support/TrainingLabel.swift`:

```swift
import Foundation
import MurmurDictionary

/// What a history run can teach the model, and where that came from.
///
/// An edit of a rules-cleaned transcript is a transcript: the user fixed what was heard. An
/// edit of an S1-mini or Apple Intelligence output is a rewrite, so those runs may only
/// contribute through the dictionary, which is applied to the engine's raw text.
enum TrainingLabel {
    enum Source: String, Sendable {
        case edit
        case dictionary
    }

    struct Resolved: Equatable, Sendable {
        let text: String
        let source: Source
    }

    /// Whether the history edit field is a transcript correction for this run.
    static func editAllowed(_ run: DictationRun) -> Bool {
        run.cleanup == nil
    }

    static func resolve(_ run: DictationRun, corrector: DictionaryCorrector) -> Resolved? {
        if editAllowed(run), let label = run.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return Resolved(text: label, source: .edit)
        }
        guard let raw = run.rawText, !raw.isEmpty else { return nil }
        let (corrected, applied) = corrector.apply(to: raw)
        guard !applied.isEmpty else { return nil }
        return Resolved(text: corrected, source: .dictionary)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch" --filter TrainingLabelTests`
Expected: pass.

---

### Task 7: History edit field and Labelled chip

**Files:**
- Modify: `Sources/Murmur/UI/MainWindow.swift` (`TranscriptionRow`, lines ~340-420, and the `ForEach(runs)` call site ~298)

**Interfaces:**
- Consumes: `RunLog.setLabel(_:for:)`, `TrainingLabel.editAllowed(_:)`.

- [ ] **Step 1: Add state and the chip**

In `TranscriptionRow` add:

```swift
    @State private var isEditing = false
    @State private var draft = ""
```

In the header `HStack`, after the `cleanup` tag add:

```swift
                if run.label != nil {
                    Tag(text: "Labelled", isHighlighted: true)
                }
```

- [ ] **Step 2: Replace the transcript text with an editable view**

Replace the `Text(run.text)` block with:

```swift
            if isEditing {
                TextField("Corrected transcript", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .padding(DS.Space.snug)
                    .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Color.ink, lineWidth: DS.Brutal.border)
                    )
                    .onSubmit { commitEdit() }
                    .onExitCommand { isEditing = false }
            } else {
                Text(run.label ?? run.text)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
```

Add the button beside `saveButton` in the header, only when `TrainingLabel.editAllowed(run)`:

```swift
                if TrainingLabel.editAllowed(run) {
                    editButton
                }
```

and the helpers:

```swift
    private var editButton: some View {
        Button {
            if isEditing {
                commitEdit()
            } else {
                draft = run.label ?? run.text
                isEditing = true
            }
        } label: {
            Label(isEditing ? "Done" : "Fix", systemImage: isEditing ? "checkmark" : "pencil")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(BrutalButtonStyle(isSelected: isEditing, compact: true))
        .help("Correct what was heard. Corrections train the model on the next export.")
    }

    private func commitEdit() {
        isEditing = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unchanged text is not a correction; clear any earlier label in that case.
        RunLog.setLabel(trimmed == run.text ? nil : trimmed, for: run)
    }
```

`onExitCommand` exists on macOS SwiftUI views; if it does not compile, drop that modifier.

- [ ] **Step 3: Build and eyeball**

Run: `nice -n 15 make build CONFIG=debug`
Expected: Build complete. No simulator; source inspection only.

---

### Task 8: TrainingExport

**Files:**
- Create: `Sources/Murmur/Support/TrainingExport.swift`
- Test: `Tests/MurmurAppTests/TrainingDataTests.swift` (append)

**Interfaces:**
- Produces: `struct TrainingExport { struct Summary: Equatable { let labelled: Int; let replay: Int; let seconds: Double; let folder: URL; let zip: URL }; static func pending(_ runs: [DictationRun], corrector: DictionaryCorrector) -> (count: Int, seconds: Double); static func write(runs: [DictationRun], corrector: DictionaryCorrector, recordings: RecordingStore, to root: URL, date: Date, barkRevision: String) throws -> (Summary, exportedIDs: Set<UUID>) }`. The zip is produced with `/usr/bin/ditto -c -k --keepParent`.
- Manifest line shape: `{"audio_filepath":"clips/<id>.flac","duration":<audioSeconds>,"text":<label>,"raw":<rawText>,"source":"edit"|"dictionary","date":<iso8601>}`. Replay line: same keys with `text` = `rawText`, `source` = `"replay"`.

- [ ] **Step 1: Write the failing test**

```swift
struct TrainingExportTests {
    @Test("Labelled runs with audio go to the manifest, unlabelled ones to replay, and the zip exists")
    func export() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordings = RecordingStore(directory: root.appendingPathComponent("Recordings"))
        try FileManager.default.createDirectory(at: recordings.directory, withIntermediateDirectories: true)
        let corrector = DictionaryCorrector(entries: [DictionaryEntry(hear: "cloud code", write: "Claude Code")])

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
```

- [ ] **Step 2: Run to verify it fails**

Run: `nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch" --filter TrainingExportTests`
Expected: compile error.

- [ ] **Step 3: Implement**

Create `Sources/Murmur/Support/TrainingExport.swift`:

```swift
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
```

- [ ] **Step 4: Run tests**

Run: `nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch" --filter TrainingExportTests`
Expected: pass.

---

### Task 9: CustomDecoderSlot

**Files:**
- Create: `Sources/Murmur/Transcription/CustomDecoderSlot.swift`
- Test: `Tests/MurmurAppTests/CustomDecoderSlotTests.swift`

**Interfaces:**
- Produces:

```swift
struct CustomDecoderManifest: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable { let path: String; let size: Int; let sha256: String }
    let trainedAt: String      // "yyyy-MM-dd"
    let clips: Int
    let heldOutWER: Double
    let replayWER: Double
    let baseRevision: String
    let files: [File]
}
enum CustomDecoderSlot {
    static var root: URL                                   // Models/bark-3.0-clean-custom
    static func installed() -> [String]                    // folder names, sorted
    static func directory(for name: String) -> URL
    static func readManifest(at folder: URL) throws -> CustomDecoderManifest
    static func verify(_ folder: URL, baseRevision: String) throws -> CustomDecoderManifest
    static func importFolder(_ source: URL, baseRevision: String) throws -> String   // returns slot name
    static func remove(_ name: String)
}
```

- Verification uses `BarkModelStore.verify(_:at:)` with `BarkModelStore.File(path, size, sha256)` for every manifest file, requires both `Decoder.mlmodelc/weights/weight.bin` and `JointDecisionv3.mlmodelc/weights/weight.bin` to be listed, and requires `manifest.baseRevision == baseRevision`. A folder containing `Encoder.mlmodelc` or `Preprocessor.mlmodelc` is refused.

- [ ] **Step 1: Write the failing tests**

Create `Tests/MurmurAppTests/CustomDecoderSlotTests.swift`:

```swift
import Foundation
import Testing
@testable import Murmur

struct CustomDecoderSlotTests {
    private let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private func makeFolder(baseRevision: String, extra: [String] = []) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for path in ["Decoder.mlmodelc/weights/weight.bin", "JointDecisionv3.mlmodelc/weights/weight.bin"] + extra {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("abc".utf8).write(to: url)
        }
        let manifest = CustomDecoderManifest(
            trainedAt: "2026-11-03", clips: 120, heldOutWER: 4.1, replayWER: 5.0, baseRevision: baseRevision,
            files: [
                .init(path: "Decoder.mlmodelc/weights/weight.bin", size: 3, sha256: abc),
                .init(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 3, sha256: abc),
            ]
        )
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        return folder
    }

    @Test("A matching folder verifies; wrong base revision, wrong bytes, or an encoder are refused")
    func verification() throws {
        let good = try makeFolder(baseRevision: "rev1")
        defer { try? FileManager.default.removeItem(at: good) }
        #expect(try CustomDecoderSlot.verify(good, baseRevision: "rev1").clips == 120)
        #expect(throws: (any Error).self) { try CustomDecoderSlot.verify(good, baseRevision: "rev2") }

        try Data("abd".utf8).write(to: good.appendingPathComponent("Decoder.mlmodelc/weights/weight.bin"))
        #expect(throws: (any Error).self) { try CustomDecoderSlot.verify(good, baseRevision: "rev1") }

        let withEncoder = try makeFolder(baseRevision: "rev1", extra: ["Encoder.mlmodelc/weights/weight.bin"])
        defer { try? FileManager.default.removeItem(at: withEncoder) }
        #expect(throws: (any Error).self) { try CustomDecoderSlot.verify(withEncoder, baseRevision: "rev1") }
    }

    @Test("Import copies a verified folder under its training date and remove deletes it")
    func importAndRemove() throws {
        let source = try makeFolder(baseRevision: "rev1")
        defer { try? FileManager.default.removeItem(at: source) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = try CustomDecoderSlot.importFolder(source, baseRevision: "rev1", root: root)
        #expect(name == "2026-11-03")
        #expect(CustomDecoderSlot.installed(root: root) == ["2026-11-03"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-11-03/manifest.json").path))
        CustomDecoderSlot.remove("2026-11-03", root: root)
        #expect(CustomDecoderSlot.installed(root: root).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch" --filter CustomDecoderSlotTests`
Expected: compile error.

- [ ] **Step 3: Implement**

Create `Sources/Murmur/Transcription/CustomDecoderSlot.swift`:

```swift
import Foundation

/// What a training export's result declares about itself. Written by the notebook.
struct CustomDecoderManifest: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let path: String
        let size: Int
        let sha256: String
    }

    let trainedAt: String
    let clips: Int
    let heldOutWER: Double
    let replayWER: Double
    let baseRevision: String
    let files: [File]
}

/// Fine-tuned decoder and joint pairs installed beside the stock Bark Clean files.
///
/// Only those two components are ever swapped. The encoder is the low-bit, bit-exact
/// Core ML palette build and is reused from the stock folder, so a swap costs a 0.3 s reload
/// and never a Neural Engine recompile. A folder that ships an encoder is refused outright.
enum CustomDecoderSlot {
    static let requiredWeights = [
        "Decoder.mlmodelc/weights/weight.bin",
        "JointDecisionv3.mlmodelc/weights/weight.bin",
    ]
    static let forbidden = ["Encoder.mlmodelc", "Preprocessor.mlmodelc"]

    static var root: URL {
        BarkModelStore.modelsRoot.appendingPathComponent("bark-3.0-clean-custom", isDirectory: true)
    }

    static func installed(root: URL = root) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent("\($0)/manifest.json").path) }.sorted()
    }

    static func directory(for name: String, root: URL = root) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    static func readManifest(at folder: URL) throws -> CustomDecoderManifest {
        try JSONDecoder().decode(CustomDecoderManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    }

    @discardableResult
    static func verify(_ folder: URL, baseRevision: String) throws -> CustomDecoderManifest {
        let manifest = try readManifest(at: folder)
        guard manifest.baseRevision == baseRevision else {
            throw TranscriptionError.modelInstallFailed("trained against Bark revision \(manifest.baseRevision.prefix(8)), installed is \(baseRevision.prefix(8))")
        }
        for name in forbidden where FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            throw TranscriptionError.modelInstallFailed("\(name) must not be replaced; only the decoder and joint are fine-tuned")
        }
        let listed = Set(manifest.files.map(\.path))
        for required in requiredWeights where !listed.contains(required) {
            throw TranscriptionError.modelInstallFailed("manifest does not list \(required)")
        }
        for file in manifest.files {
            try BarkModelStore.verify(.init(file.path, file.size, file.sha256), at: folder.appendingPathComponent(file.path))
        }
        return manifest
    }

    /// Verifies `source` and copies it to `<root>/<trainedAt>/`, replacing a slot of the
    /// same date. Returns the slot name.
    static func importFolder(_ source: URL, baseRevision: String, root: URL = root) throws -> String {
        let manifest = try verify(source, baseRevision: baseRevision)
        let name = manifest.trainedAt
        guard !name.isEmpty, !name.contains("/") else {
            throw TranscriptionError.modelInstallFailed("manifest trainedAt is not a usable folder name")
        }
        let destination = directory(for: name, root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        try verify(destination, baseRevision: baseRevision)
        return name
    }

    static func remove(_ name: String, root: URL = root) {
        try? FileManager.default.removeItem(at: directory(for: name, root: root))
    }
}
```

- [ ] **Step 4: Run tests**

Run: `nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch" --filter CustomDecoderSlotTests`
Expected: pass.

---

### Task 10: Load the selected decoder pair

**Files:**
- Modify: `Sources/Murmur/Transcription/ParakeetEngine.swift` (`ParakeetModels`, `loadBarkClean` around line 240)

**Interfaces:**
- Produces: `ParakeetModels.barkClean` loads decoder and joint from `Settings.shared.barkDecoder`; `ParakeetModels.reloadBarkClean() async` (unload + load, used when the choice changes); `ParakeetModels.barkCleanCustom(name:)` factory for compare mode: `static func custom(_ name: String) -> ParakeetModels` with `Source.barkCleanCustom(String)`.

- [ ] **Step 1: Add the source case and slot-aware load**

In `enum Source` add `case barkCleanCustom(String)` with `label` `"Bark Clean (fine-tuned)"`. Replace `loadBarkClean()` with a version that takes the slot:

```swift
    private static func loadBarkClean(slot: BarkDecoderChoice) async throws -> AsrModels {
        let directory = try await BarkModelStore.ensureDownloaded()
        let pair: URL
        switch slot {
        case .stock:
            pair = directory
        case .custom(let name):
            pair = CustomDecoderSlot.directory(for: name)
            try CustomDecoderSlot.verify(pair, baseRevision: BarkModelStore.revision)
            Log.speech.info("Bark Clean: using fine-tuned decoder \(name, privacy: .public)")
        }
        Log.speech.info("Bark Clean: loading models (the first load compiles for the Neural Engine, about a minute)")

        func load(_ name: String, from folder: URL, _ units: MLComputeUnits) async throws -> MLModel {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try await MLModel.load(contentsOf: folder.appendingPathComponent(name), configuration: configuration)
        }

        let preprocessor = try await load("Preprocessor.mlmodelc", from: directory, .cpuOnly)
        let encoder = try await load("Encoder.mlmodelc", from: directory, .cpuAndNeuralEngine)
        let decoder = try await load("Decoder.mlmodelc", from: pair, .cpuAndNeuralEngine)
        let joint = try await load("JointDecisionv3.mlmodelc", from: pair, .cpuAndNeuralEngine)
        // vocabulary parsing unchanged from the current implementation, reading from `directory`
        ...
    }
```

Keep the vocabulary block exactly as it is today (it reads `parakeet_vocab.json` from `directory`). In `manager()`'s load task:

```swift
            case .barkClean:
                let slot = await MainActor.run { Settings.shared.barkDecoder }
                try await Self.loadBarkClean(slot: slot)
            case .barkCleanCustom(let name):
                try await Self.loadBarkClean(slot: .custom(name))
```

Add:

```swift
    /// The decoder choice changed: drop the loaded pair and load the selected one. The
    /// encoder file is unchanged, so this is a sub-second reload with no recompile.
    func reload() async throws {
        await unload()
        _ = try await manager()
    }

    static func custom(_ name: String) -> ParakeetModels { ParakeetModels(source: .barkCleanCustom(name)) }
```

Update `isDownloaded`/labels switch statements for the new case (`.barkCleanCustom` reports `BarkModelStore.isDownloaded`).

- [ ] **Step 2: Build**

Run: `nice -n 15 make build CONFIG=debug`
Expected: Build complete; fix any exhaustive-switch errors the new case introduces (`StreamingModelPreparation`, `EngineComparison`, `ResidencyCheck` only reference `.barkClean`; they need no change).

---

### Task 11: Training card in Settings

**Files:**
- Modify: `Sources/Murmur/UI/SettingsPanel.swift` (add a `BrutalCard(title: "Training")` after the Model card)

**Interfaces:**
- Consumes: `TrainingExport.pending`, `TrainingExport.write`, `RunLog.markExported`, `RunLog.deleteAllRecordings`, `RecordingStore.shared.totalBytes()`, `CustomDecoderSlot.installed/importFolder/remove/readManifest`, `Settings.barkDecoder`, `ParakeetModels.barkClean.reload()`, `RunStore.shared.runs`, `DictionaryStore.shared.corrector`.

- [ ] **Step 1: Add state and the card**

In `SettingsPanel` add `@State private var store = RunStore.shared`, `@State private var trainingMessage: String?`, `@State private var slots = CustomDecoderSlot.installed()`.

Add the card:

```swift
                BrutalCard(title: "Training") {
                    Toggle(isOn: Binding(
                        get: { settings.keepRecordings },
                        set: { on in
                            settings.keepRecordings = on
                            if !on { RunLog.deleteAllRecordings() }
                        }
                    )) {
                        Text("Keep recordings for training")
                            .font(DS.Font.bodyEmphasis)
                            .foregroundStyle(DS.Color.ink)
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Color.accent)
                    Note(text: settings.keepRecordings
                        ? "Each dictation's audio is kept on disk for 30 days (\(recordingsSize)), longer while it has a correction waiting to be exported. Nothing leaves this Mac."
                        : "No audio is kept. Corrections can't train the model without it.")

                    Eyebrow(text: "Export")
                    let pending = TrainingExport.pending(store.runs, corrector: DictionaryStore.shared.corrector)
                    HStack(spacing: DS.Space.base) {
                        Button("Export \(pending.count) labelled run\(pending.count == 1 ? "" : "s")") { export() }
                            .buttonStyle(BrutalButtonStyle())
                            .disabled(pending.count == 0)
                        Note(text: String(format: "%.1f minutes of corrected speech since the last export.", pending.seconds / 60))
                    }

                    Eyebrow(text: "Decoder")
                    ChoiceKeys(
                        options: [BarkDecoderChoice.stock] + slots.map { BarkDecoderChoice.custom($0) },
                        selection: Binding(
                            get: { settings.barkDecoder },
                            set: { choice in
                                settings.barkDecoder = choice
                                Task { try? await ParakeetModels.barkClean.reload() }
                            }
                        ),
                        title: \.displayName
                    )
                    .disabled(controller.state.isActive)
                    if case .custom(let name) = settings.barkDecoder,
                       let manifest = try? CustomDecoderSlot.readManifest(at: CustomDecoderSlot.directory(for: name)) {
                        Note(text: String(format: "Trained on %d clips. Held-out WER %.1f%% · replay WER %.1f%%.", manifest.clips, manifest.heldOutWER, manifest.replayWER))
                    }
                    HStack(spacing: DS.Space.base) {
                        Button("Install fine-tuned decoder…") { importSlot() }
                            .buttonStyle(BrutalButtonStyle())
                        if case .custom(let name) = settings.barkDecoder {
                            Button("Remove \(name)") {
                                settings.barkDecoder = .stock
                                CustomDecoderSlot.remove(name)
                                slots = CustomDecoderSlot.installed()
                                Task { try? await ParakeetModels.barkClean.reload() }
                            }
                            .buttonStyle(BrutalButtonStyle())
                        }
                    }
                    if let trainingMessage {
                        Note(text: trainingMessage)
                    }
                }
```

Helpers on `SettingsPanel`:

```swift
    private var recordingsSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(RecordingStore.shared.totalBytes()), countStyle: .file)
    }

    private func export() {
        let root = AppStorage.directory.appendingPathComponent("Training", isDirectory: true)
        do {
            let (summary, ids) = try TrainingExport.write(
                runs: store.runs, corrector: DictionaryStore.shared.corrector, recordings: RecordingStore.shared,
                to: root, date: Date(), barkRevision: BarkModelStore.revision
            )
            RunLog.markExported(ids: ids)
            trainingMessage = "Exported \(summary.labelled) labelled and \(summary.replay) replay clips to \(summary.zip.lastPathComponent)."
            NSWorkspace.shared.activateFileViewerSelecting([summary.zip])
        } catch {
            trainingMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importSlot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder the notebook produced (Decoder.mlmodelc, JointDecisionv3.mlmodelc, manifest.json)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let name = try CustomDecoderSlot.importFolder(url, baseRevision: BarkModelStore.revision)
            slots = CustomDecoderSlot.installed()
            settings.barkDecoder = .custom(name)
            trainingMessage = "Installed fine-tuned decoder \(name)."
            Task { try? await ParakeetModels.barkClean.reload() }
        } catch {
            trainingMessage = "Not installed: \(error.localizedDescription)"
        }
    }
```

`TrainingExport.write` does file I/O; it runs on the main actor here because exports are a deliberate click, happen rarely, and copy tens of MB. Acceptable; note it in a comment.

`ChoiceKeys` requires `Option: Hashable`; add `Hashable` to `BarkDecoderChoice` in Task 4 if the compiler asks.

- [ ] **Step 2: Build**

Run: `nice -n 15 make build CONFIG=debug`
Expected: Build complete.

---

### Task 12: Compare-mode row and `--decoder-check`

**Files:**
- Modify: `Sources/Murmur/Core/EngineComparison.swift`
- Create: `Sources/Murmur/Support/DecoderCheck.swift`
- Modify: `Sources/Murmur/MurmurApp.swift` (dispatch before `--cleanup-check`)

- [ ] **Step 1: Compare-mode row**

In `EngineComparison.run`, after the Bark row:

```swift
        if await ParakeetModels.barkClean.isLoaded,
           case .custom(let name) = await MainActor.run({ Settings.shared.barkDecoder }) {
            engines.append(("Bark Clean (stock)", ParakeetEngine(models: ParakeetModels(source: .barkClean))))
            _ = name
        }
```

That is wrong on purpose if you copy it blindly: the loaded `barkClean` already carries the custom pair when the setting is custom. Implement instead: when the setting is `.custom`, the existing "Bark Clean" row is the fine-tuned one, so rename it `"Bark Clean (fine-tuned)"` and add a second row `("Bark Clean (stock)", ParakeetEngine(models: ParakeetModels.stockBarkClean))` where `ParakeetModels.stockBarkClean` is a new `static let stockBarkClean = ParakeetModels(source: .barkCleanStock)` with `Source.barkCleanStock` loading `loadBarkClean(slot: .stock)`. Encoder `MLModel` instances are separate but map the same compiled file; measured cost is the same ~30 MB resident per instance.

- [ ] **Step 2: Decoder check**

Create `Sources/Murmur/Support/DecoderCheck.swift`, modelled on `IncrementalCheck`:

```swift
import AVFoundation
import Foundation

/// `Murmur --decoder-check <slot-folder> <audio-file>`: transcribes the file with the stock
/// decoder pair and with the given fine-tuned pair over the same encoder, and prints both.
@MainActor
enum DecoderCheck {
    static func run(slot: String, path: String) async -> Bool {
        do {
            try CustomDecoderSlot.verify(URL(fileURLWithPath: slot), baseRevision: BarkModelStore.revision)
        } catch {
            print("FAIL verify: \(error.localizedDescription)")
            return false
        }
        let name = URL(fileURLWithPath: slot).lastPathComponent
        if !CustomDecoderSlot.installed().contains(name) {
            do { _ = try CustomDecoderSlot.importFolder(URL(fileURLWithPath: slot), baseRevision: BarkModelStore.revision) } catch {
                print("FAIL import: \(error.localizedDescription)")
                return false
            }
        }
        let chunks: [AudioChunk]
        do { chunks = try IncrementalCheck.load(path) } catch {
            print("FAIL audio: \(error.localizedDescription)")
            return false
        }
        var texts: [String] = []
        for (label, models) in [("stock", ParakeetModels.stockBarkClean), ("fine-tuned \(name)", ParakeetModels.custom(name))] {
            let engine = ParakeetEngine(models: models)
            do {
                let stream = try await engine.start()
                let started = Date()
                for chunk in chunks { await engine.feed(chunk) }
                await engine.finish()
                var text = ""
                for try await chunk in stream where chunk.isFinal { text = chunk.text }
                print(String(format: "%@: %.2fs", label, Date().timeIntervalSince(started)))
                print("  " + text)
                texts.append(text)
            } catch {
                print("FAIL \(label): \(error.localizedDescription)")
                return false
            }
        }
        let a = texts[0].split(whereSeparator: \.isWhitespace), b = texts[1].split(whereSeparator: \.isWhitespace)
        let changed = zip(a, b).filter { $0 != $1 }.count + abs(a.count - b.count)
        print("words differing: \(changed)")
        print("PASS")
        return true
    }
}
```

Make `IncrementalCheck.load(_:)` `static func` (not private) so this can reuse it. In `MurmurApp.swift` add before the `--incremental-check` branch:

```swift
        if let index = CommandLine.arguments.firstIndex(of: "--decoder-check"),
           CommandLine.arguments.indices.contains(index + 2) {
            let slot = CommandLine.arguments[index + 1]
            let path = CommandLine.arguments[index + 2]
            Task { @MainActor in exit(await DecoderCheck.run(slot: slot, path: path) ? EXIT_SUCCESS : EXIT_FAILURE) }
            return
        }
```

- [ ] **Step 3: Build and run the whole test suite**

Run: `nice -n 15 make build CONFIG=debug` then `nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch"`
Expected: Build complete; every suite passes.

---

### Task 13: Colab notebook and README

**Files:**
- Create: `training/README.md`, `training/bark_decoder_finetune.ipynb`

- [ ] **Step 1: README**

```markdown
# Fine-tuning Bark Clean's decoder on your dictation

1. In Murmur, Settings → Training → Export. A zip lands in
   `~/Library/Application Support/Murmur/Training/`.
2. Open `bark_decoder_finetune.ipynb` in Google Colab (free T4 is enough). Upload the zip
   when the first cell asks.
3. Run all cells. The notebook stops without exporting if the fine-tune is not better than
   stock on your held-out clips or drifts on replay clips; the tables tell you why.
4. Download `bark-decoder-<date>.zip`, unzip, and in Murmur choose Install fine-tuned
   decoder… and pick the folder. Switch Decoder to it. Revert with Stock any time.

Only the decoder and joint (35 MB) are trained. The encoder stays the stock low-bit build,
so acoustics do not change; what improves is which words the model writes for sounds it
already hears correctly.
```

- [ ] **Step 2: Notebook**

Write `training/bark_decoder_finetune.ipynb` as JSON with these code cells, in order. Each cell's source is given; wrap them in the standard `{"cells": [...], "metadata": {"kernelspec": {"name": "python3", "display_name": "Python 3"}}, "nbformat": 4, "nbformat_minor": 5}` envelope with `"cell_type": "code"`, `"metadata": {}`, `"outputs": []`, `"execution_count": null`.

Cell 1, setup:

```python
!pip -q install "transformers>=5.19" torch torchaudio coremltools "constriction>=0.5" soundfile soxr jiwer huggingface_hub
import os, json, zipfile, glob, shutil, hashlib, math, random
from google.colab import files
up = files.upload()
zip_name = next(iter(up))
shutil.rmtree("export", ignore_errors=True); os.makedirs("export")
zipfile.ZipFile(zip_name).extractall("export")
EXPORT = glob.glob("export/export-*")[0]
info = json.load(open(f"{EXPORT}/export.json")); print(info)
```

Cell 2, model:

```python
from huggingface_hub import snapshot_download
REPO = snapshot_download("ConwayResearch/Underdog-Bark-3.0-Clean", allow_patterns=["model.bark", "bark_loader.py", "mlx/*"])
import sys; sys.path.insert(0, REPO)
import torch, bark_loader
model = bark_loader.load_model(f"{REPO}/model.bark", device="cuda", dtype=torch.float32)
from transformers import AutoProcessor
processor = AutoProcessor.from_pretrained("nvidia/parakeet-tdt-0.6b-v3")
for n, p in model.named_parameters():
    p.requires_grad = not n.startswith("encoder.")
print("trainable:", sum(p.numel() for p in model.parameters() if p.requires_grad))
```

Cell 3, data:

```python
import soundfile as sf, soxr, numpy as np
def read(line):
    wav, sr = sf.read(f"{EXPORT}/{line['audio_filepath']}", dtype="float32", always_2d=True)
    wav = wav.mean(axis=1)
    if sr != 16000: wav = soxr.resample(wav, sr, 16000)
    return np.concatenate([np.zeros(4000, np.float32), wav])  # 0.25 s leading silence, as the model card uses
labelled = [json.loads(l) for l in open(f"{EXPORT}/manifest.jsonl") if l.strip()]
replay = [json.loads(l) for l in open(f"{EXPORT}/replay.jsonl") if l.strip()]
random.seed(0); random.shuffle(labelled)
n_test = max(10, len(labelled) // 10)
test, train_l = labelled[:n_test], labelled[n_test:]
assert train_l, "need more than %d labelled clips" % n_test
train = [(read(x), x["text"]) for x in train_l] + [(read(x), x["text"]) for x in replay]
test_set = [(read(x), x["text"]) for x in test]
replay_set = [(read(x), x["text"]) for x in replay[: max(10, len(replay) // 5)]]
print(len(train), "train clips;", len(test_set), "held-out;", len(replay_set), "replay eval")
```

Cell 4, evaluation helper (greedy decode through the model's own generate) and baseline:

```python
import jiwer
@torch.no_grad()
def transcribe(wavs):
    out = []
    for wav in wavs:
        inputs = processor(wav, sampling_rate=16000, return_tensors="pt").to("cuda")
        ids = model.generate(**inputs)
        out.append(processor.batch_decode(ids, skip_special_tokens=True)[0].strip())
    return out
norm = jiwer.Compose([jiwer.ToLowerCase(), jiwer.RemovePunctuation(), jiwer.RemoveMultipleSpaces(), jiwer.Strip()])
def wer(pairs):
    hyp = transcribe([w for w, _ in pairs]); ref = [t for _, t in pairs]
    return 100 * jiwer.wer(ref, hyp, truth_transform=norm, hypothesis_transform=norm)
model.eval()
base_test, base_replay = wer(test_set), wer(replay_set)
print(f"stock: held-out WER {base_test:.2f}  replay WER {base_replay:.2f}")
```

Cell 5, training:

```python
from torch.utils.data import DataLoader
tok = processor.tokenizer
def collate(batch):
    wavs = [w for w, _ in batch]; texts = [t for _, t in batch]
    inputs = processor(wavs, sampling_rate=16000, return_tensors="pt", padding=True)
    labels = tok(texts, return_tensors="pt", padding=True, add_special_tokens=False).input_ids
    labels[labels == tok.pad_token_id] = -100
    inputs["labels"] = labels
    return inputs
loader = DataLoader(train, batch_size=8, shuffle=True, collate_fn=collate)
opt = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=1e-5, weight_decay=0.01)
best = (base_test, None)
for epoch in range(3):
    model.train()
    for step, batch in enumerate(loader):
        batch = {k: v.to("cuda") for k, v in batch.items()}
        loss = model(**batch).loss
        loss.backward(); opt.step(); opt.zero_grad()
        if step % 20 == 0: print(f"epoch {epoch} step {step} loss {loss.item():.3f}")
    model.eval()
    t, r = wer(test_set), wer(replay_set)
    print(f"epoch {epoch}: held-out WER {t:.2f}  replay WER {r:.2f}")
    if t < best[0]:
        best = (t, {k: v.detach().cpu().clone() for k, v in model.state_dict().items() if not k.startswith("encoder.")})
        best_replay = r
```

Cell 6, gate:

```python
assert best[1] is not None, f"no epoch beat stock held-out WER {base_test:.2f}; nothing exported"
assert best_replay <= base_replay + 0.5, f"replay WER rose from {base_replay:.2f} to {best_replay:.2f}; nothing exported"
model.load_state_dict(best[1], strict=False)
print(f"exporting: held-out WER {best[0]:.2f} (stock {base_test:.2f}), replay WER {best_replay:.2f} (stock {base_replay:.2f})")
```

Cell 7, Core ML export. Reference `FluidInference/mobius`, `models/stt/parakeet-tdt-v3-0.6b/coreml/convert-parakeet.py`, for the decoder and joint wrapper modules; the shapes below are the installed contract.

```python
import coremltools as ct
model.cpu().eval()
class DecoderWrap(torch.nn.Module):
    def __init__(self, dec): super().__init__(); self.dec = dec
    def forward(self, targets, target_length, h_in, c_in):
        emb = self.dec.embed(targets)                       # [1,1,640]
        out, (h, c) = self.dec.lstm(emb, (h_in, c_in))      # 2-layer LSTM, hidden 640
        return out.transpose(1, 2), h, c                    # decoder [1,640,1], h_out, c_out
class JointWrap(torch.nn.Module):
    def __init__(self, joint): super().__init__(); self.joint = joint
    def forward(self, encoder_step, decoder_step):
        enc = self.joint.encoder_proj(encoder_step.transpose(1, 2))   # [1,1,640]
        dec = self.joint.decoder_proj(decoder_step.transpose(1, 2))   # [1,1,640]
        logits = self.joint.head(torch.relu(enc + dec))               # [1,1,8193+durations]
        V = 8193
        token_logits, dur_logits = logits[..., :V], logits[..., V:]
        token_id = token_logits.argmax(-1).to(torch.int32)
        duration = dur_logits.argmax(-1).to(torch.int32)
        return token_id, token_logits.max(-1).values, duration
# Attribute names (embed / lstm / encoder_proj / decoder_proj / head) must be checked against
# `print(model.decoder)` and `print(model.joint)` and corrected before tracing.
dec = DecoderWrap(model.decoder).eval()
ex = (torch.zeros(1, 1, dtype=torch.int32), torch.ones(1, dtype=torch.int32), torch.zeros(2, 1, 640), torch.zeros(2, 1, 640))
dec_traced = torch.jit.trace(dec, ex)
dec_ml = ct.convert(dec_traced, convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS15,
    inputs=[ct.TensorType(name="targets", shape=(1, 1), dtype=np.int32), ct.TensorType(name="target_length", shape=(1,), dtype=np.int32),
            ct.TensorType(name="h_in", shape=(2, 1, 640)), ct.TensorType(name="c_in", shape=(2, 1, 640))],
    outputs=[ct.TensorType(name="decoder"), ct.TensorType(name="h_out"), ct.TensorType(name="c_out")])
jt = JointWrap(model.joint).eval()
jt_traced = torch.jit.trace(jt, (torch.zeros(1, 1024, 1), torch.zeros(1, 640, 1)))
jt_ml = ct.convert(jt_traced, convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS15,
    inputs=[ct.TensorType(name="encoder_step", shape=(1, 1024, 1)), ct.TensorType(name="decoder_step", shape=(1, 640, 1))],
    outputs=[ct.TensorType(name="token_id"), ct.TensorType(name="token_prob"), ct.TensorType(name="duration")])
```

Before this cell is trusted, the implementer must open the installed stock package's `metadata.json` for Decoder and JointDecisionv3 (`~/Library/Application Support/Murmur/Models/bark-3.0-clean/<rev>/*.mlmodelc/metadata.json`) and copy the exact output names and dtypes into the `outputs=` lists above; the input names are known, the output names must match what FluidAudio reads (`extractFeatureValue(from:key:)` in `AsrManager.swift` lists them).

Cell 8, package:

```python
from coremltools.models.utils import compile_model
OUT = f"bark-decoder-{info['exportedAt'][:10]}"; shutil.rmtree(OUT, ignore_errors=True); os.makedirs(OUT)
dec_ml.save("Decoder.mlpackage"); jt_ml.save("JointDecisionv3.mlpackage")
for name in ["Decoder", "JointDecisionv3"]:
    compiled = compile_model(f"{name}.mlpackage")
    shutil.copytree(compiled, f"{OUT}/{name}.mlmodelc")
def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""): h.update(chunk)
    return h.hexdigest()
entries = []
for root, _, fs in os.walk(OUT):
    for f in fs:
        p = os.path.join(root, f); rel = os.path.relpath(p, OUT)
        entries.append({"path": rel, "size": os.path.getsize(p), "sha256": sha(p)})
manifest = {"trainedAt": info["exportedAt"][:10], "clips": len(train_l), "heldOutWER": round(best[0], 2),
            "replayWER": round(best_replay, 2), "baseRevision": info["barkRevision"], "files": entries}
json.dump(manifest, open(f"{OUT}/manifest.json", "w"), indent=2)
shutil.make_archive(OUT, "zip", ".", OUT)
files.download(f"{OUT}.zip")
```

- [ ] **Step 3: Validate the notebook JSON**

Run: `python3 -I -c "import json; nb=json.load(open('training/bark_decoder_finetune.ipynb')); print(len(nb['cells']), 'cells')"`
Expected: `8 cells`.

Note in `training/README.md` that cells 7 and 8 were written against the documented contract and must be verified on the first real run: compile, then run `Murmur --decoder-check <folder> <audio>` on the Mac; a load failure there means an output name or dtype differs from the stock package's `metadata.json`.

---

### Task 14: AGENTS.md

**Files:**
- Modify: `AGENTS.md` (append after the "Long holds" bullet list)

- [ ] **Step 1: Add the paragraph**

```markdown
Training loop (added 2026-11-01). Every non-compare hold keeps its audio; `RunLog.record(_:audio:)`
writes `Recordings/<id>.flac` on the history queue and deletes it with the run. `DictationRun`
gained `rawText`, `label`, `hasAudio`, `exportedAt`; a labelled run (history edit, or a
dictionary hit) with unexported audio outlives the 30 days. Edits are transcript corrections
only on rules-cleaned runs (`TrainingLabel.editAllowed`); S1-mini and Apple Intelligence runs
contribute only through the dictionary applied to `rawText`. Settings → Training exports
`Training/export-<date>.zip` (`TrainingExport`), and installs a fine-tuned decoder + joint
pair (`CustomDecoderSlot`, verified by size and SHA-256 and by `baseRevision ==
BarkModelStore.revision`; a folder with an encoder is refused). `loadBarkClean(slot:)` loads
the pair from the slot and the encoder from stock, so a switch is a 0.3 s reload with no
Neural Engine recompile. `training/bark_decoder_finetune.ipynb` is the Colab side; its Core ML
export cells must be checked against the stock package's `metadata.json` on the first run, and
`Murmur --decoder-check <slot> <audio>` is how.
```

- [ ] **Step 2: Final full build and tests**

Run: `nice -n 15 make build CONFIG=debug && nice -n 15 swift test --scratch-path "$HOME/Library/Caches/MurmurBuild/scratch"`
Expected: Build complete; all suites pass. Then `nice -n 15 make app` and `~/Library/Caches/MurmurBuild/Murmur.app/Contents/MacOS/Murmur --incremental-check <any aiff>` still PASS (regression check that the Bark load path is intact).

---

## Self-review

- Spec coverage: capture (T2, T3, T5), run fields and retention (T1), labels and edit UI (T6, T7), export (T8), import and slot (T9, T10, T11), compare row and decoder check (T12), notebook (T13), docs (T14). The spec's "Delete all" dialog already deletes recordings through `RunFile.clear()` (T3).
- Known uncertainty, stated in the plan rather than hidden: the notebook's export cells (T13 cells 7 and 8) depend on `ParakeetForTDT`'s decoder/joint attribute names and on FluidAudio's expected output names; both are to be read from source on the first run, and `--decoder-check` is the test.
- Type consistency: `TrainingLabel.Resolved` / `.Source` used in T8; `BarkDecoderChoice` in T4, T10, T11; `CustomDecoderSlot` signatures identical in T9, T10, T11, T12; `RunLog.record(_:audio:)` in T3 and T5.
