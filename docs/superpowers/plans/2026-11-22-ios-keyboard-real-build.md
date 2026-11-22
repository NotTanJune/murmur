# Murmur for iOS, real build: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Murmur's platform-neutral code into a shared `MurmurKit` library without changing the Mac app's behaviour, add the Mac's "Import from iPhone", and build the real iOS app and dictation keyboard on top of it, replacing `ios/spike/`.

**Architecture:** `Package.swift` gains library targets `MurmurKit` (text, speech, storage, settings, run log) and `MurmurDesign` (ink-on-paper tokens), both macOS 26 and iOS 26. The Mac executable imports them. `ios/` is an XcodeGen project whose app and keyboard depend on the local package's products. The keyboard records through `WebMicrophone` (ported from the spike) and runs Bark through the same engines the Mac uses.

**Tech Stack:** Swift 6, SwiftPM, SwiftUI, XcodeGen, FluidAudio 0.15.6, Speech (`SpeechAnalyzer`), FoundationModels, WebKit.

**Spec:** `docs/superpowers/specs/2026-11-21-ios-keyboard-design.md`

## Global Constraints

- Mac behaviour, file paths, `UserDefaults` keys and defaults do not change. `~/Library/Application Support/Murmur` stays the Mac's storage root.
- `MurmurKit` imports no AppKit, UIKit, MLX or SwiftUI. `MurmurDesign` may import SwiftUI and resolves fonts with `NSFont` on macOS, `UIFont` on iOS.
- iOS 26 minimum; App Group `group.ai.pivotstudio.murmur`; bundle IDs `ai.pivotstudio.murmur.ios` and `ai.pivotstudio.murmur.ios.keyboard`; team from git-ignored `ios/Local.xcconfig` (`DEVELOPMENT_TEAM = <your team ID>`).
- Entitlements are declared in `project.yml` under `entitlements.properties` (`com.apple.security.application-groups: [group.ai.pivotstudio.murmur]`), never as hand-written files.
- Bark loads with `MLModel.load` through `ParakeetModels.barkClean`, never `AsrModels.load(from:)`.
- Never `MainActor.assumeIsolated`; never mutate `@State` inside a `Canvas` closure.
- Views contain no literal sizes or colours: add tokens to `MurmurDesign`. Red (`DS.Color.record`) only for recording. Selection uses the existing cream treatment.
- Builds and tests run niced with few jobs: `nice -n 10`, `-jobs 4` / `-j 4`. SwiftPM scratch path `~/Library/Caches/MurmurBuild/scratch`. Use `make` and `make test`, not bare `swift build`.
- No git worktrees. No commits unless the user asks; each task ends with a verification step instead.
- GPL-3.0-only. Do not copy code from `stephancill/ios-keyboard-dictation`, Hex, or `per-simmons/murmur-youtube`.
- No simulator. iOS verification is an unsigned `generic/platform=iOS` compile; signed builds and `devicectl` installs only when the user asks.

## Review Focus

1. **Two processes write the run log.** The keyboard appends runs while the app edits labels or prunes; neither may drop the other's lines. Test: Task 3 `appendFromAnotherWriterSurvivesRewrite`.
2. **A tap that is really a short hold.** Released at 0.29 s locks; at 0.31 s it types. A touch while finishing is ignored. Test: Task 8 `touchStateMachine`.
3. **Importing the same phone zip twice.** The second import adds nothing and overwrites nothing. Test: Task 5 `duplicateIdIsSkipped`.
4. **The keyboard closes mid-recording.** Capture stops, no text is typed later, no run is written. Test: Task 8 `abandonWritesNothing`.
5. **Bark not downloaded or crash marker set.** Apple handles the hold, the run records engine "Apple", the key says why. Test: Task 8 `engineChoiceFallsBackToApple`.

---

### Task 1: `MurmurKit` target with the text pipeline

**Files:**
- Modify: `Package.swift` (platforms add `.iOS(.v26)`; add `products: [.library(name: "MurmurKit", targets: ["MurmurKit"]), .library(name: "MurmurDictionary", targets: ["MurmurDictionary"])]`; target `MurmurKit` at `Sources/MurmurKit` depending on `MurmurDictionary`, `FluidAudio`; `Murmur` depends on `MurmurKit`; test target `MurmurKitTests` at `Tests/MurmurKitTests`)
- Move (git mv) into `Sources/MurmurKit/`: `Formatting/TextFormatter.swift`, `Formatting/TranscriptRepair.swift`, `Formatting/CleanupPipeline.swift`, `Formatting/FoundationModelFormatter.swift`, `Formatting/CleanupProfile.swift`, `Transcription/WindowSeam.swift`, `Support/Log.swift`
- Create: `Sources/MurmurKit/Audio/PCMConverter.swift` (from `ios/spike/Shared/Audio/PCMBridge.swift`), `Sources/MurmurKit/Support/CrashMarker.swift` (from `ios/spike/Shared/Core/CrashMarker.swift`)
- Move tests: `CleanupTests`, `CleanupPipelineTests`, `TranscriptRepairTests`, `WindowSeamTests` to `Tests/MurmurKitTests/` with `@testable import MurmurKit`; port `ios/spike/Tests/*` there too.

**Interfaces:**
- Produces: `public protocol TextFormatter`, `public struct RuleBasedFormatter`, `public struct PassthroughFormatter`, `public final class CleanupPipeline`, `public struct FoundationModelFormatter`, `public enum CleanupEngine`, `public enum CleanupProfile`, `public enum TranscriptRepair`, `public enum Log`, `public final class PCMConverter` (`init?(sourceRate: Double, target: AVAudioFormat)`, `convert(_ samples: [Float]) -> AVAudioPCMBuffer?`, `flush() -> AVAudioPCMBuffer?`), `public struct CrashMarker` (`init(directory: URL)`, `arm()`, `disarm()`, `wasArmedAtLaunch: Bool`), and the spike's base64 Float32 decoder under the same names it has in `PCMBridge.swift`.

- [ ] **Step 1:** Edit `Package.swift` and move the files. Mark `public` only what `Sources/Murmur` or the spike's keyboard code calls; leave the rest internal (tests use `@testable`).
- [ ] **Step 2:** Add `import MurmurKit` where the Mac target needs it.
- [ ] **Step 3:** Run `nice -n 10 make test`. Expected: all tests pass, including `VectorTests` and the moved tests, now under `MurmurKitTests`.
- [ ] **Step 4:** Run `nice -n 10 make`. Expected: the app builds.

### Task 2: Environment seam, speech engines and Settings move

**Files:**
- Create: `Sources/MurmurKit/Support/MurmurEnvironment.swift`
- Move into `MurmurKit`: `Support/AppStorage.swift` (the `directory` and `migrateFiles`; `prepare()`'s MurmurYouTube migration stays in a Mac extension), `Transcription/TranscriptionEngine.swift`, `ParakeetEngine.swift`, `IncrementalParakeetEngine.swift`, `OverlapWindowRecognizer.swift`, `AppleSpeechEngine.swift`, `BarkModelStore.swift`, `CustomDecoderSlot.swift`, `Support/Settings.swift`, `Support/ModelResidency.swift` if it compiles without Mac types
- Create: `Sources/Murmur/Support/Settings+Mac.swift` (`AppearanceChoice.nsAppearance`, `SpeechEngineChoice.streamingEngine`, the `NSApp.appearance` application of the appearance setting)
- Modify: `Sources/Murmur/main.swift` (configure the environment first)
- Move tests: `BarkModelTests`, `CustomDecoderSlotTests`, `IncrementalParakeetEngineTests`, `AppStorageTests`, `EngineChoiceTests` (the parts on moved types)
- Test: `Tests/MurmurKitTests/MurmurEnvironmentTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum MurmurEnvironment {
      /// Call once, before anything reads storage or Settings. Unconfigured, both default to the Mac's values.
      public static func configure(storageRoot: URL, defaults: UserDefaults)
      public static var storageRoot: URL { get }   // default: Application Support/Murmur
      public static var defaults: UserDefaults { get } // default: MURMUR_SETTINGS_DOMAIN suite or .standard
  }
  ```
  `AppStorage.directory` returns `MurmurEnvironment.storageRoot`. `Settings.shared` is built from `MurmurEnvironment.defaults`. `ParakeetEngine.swift`'s direct Application Support read (around line 156) goes through `AppStorage.directory`. `public` on `Settings`, `SpeechEngineChoice`, `TranscribeTiming`, `AppearanceChoice`, `BarkDecoderChoice`, `TranscriptionEngine`, `TranscriptionChunk`, `AudioChunk`, `ParakeetEngine`, `IncrementalParakeetEngine`, `ParakeetModels`, `AppleSpeechEngine`, `BarkModelStore` as the hosts need.
- 
- [ ] **Step 1: Write the failing test** `MurmurEnvironmentTests`:
  `unconfiguredRootIsMacApplicationSupport` asserts `MurmurEnvironment.storageRoot.path.hasSuffix("Library/Application Support/Murmur")`; `configuredRootIsUsed` configures a temp folder and asserts `AppStorage.directory == temp` and `BarkModelStore` paths start with it (configure resets afterwards through an internal `resetForTesting()`).
- [ ] **Step 2:** Run `nice -n 10 make test`. Expected: FAIL, `MurmurEnvironment` undefined.
- [ ] **Step 3:** Implement the seam and the moves.
- [ ] **Step 4:** Run `nice -n 10 make test` and `nice -n 10 make`. Expected: PASS; the app builds; `grep -rn "applicationSupportDirectory" Sources/MurmurKit` shows only `MurmurEnvironment.swift`.

### Task 3: Run log, recordings, labels, export and dictionary move, safe across processes

**Files:**
- Move into `MurmurKit`: `Support/RunLog.swift`, `Support/RecordingStore.swift`, `Support/TrainingLabel.swift`, `Support/TrainingExport.swift` (folder building only), `Dictionary/DictionaryStore.swift`, `RunStore` (out of `UI/ComparisonWindow.swift` into `Sources/MurmurKit/Support/RunStore.swift`)
- Create: `Sources/Murmur/Support/TrainingExport+Zip.swift` (Mac zips with `/usr/bin/ditto`, as now)
- Modify: `RunFile` in `RunLog.swift`
- Test: `Tests/MurmurKitTests/RunLogSharingTests.swift`; move `TrainingDataTests`, `DictionaryStoreTests`, `RunTimingTests`

**Interfaces:**
- Produces: `public struct DictationRun` (unchanged fields, `public`), `public enum RunLog` (existing API), `public final class RunStore`, `public struct RecordingStore`, `public enum TrainingLabel`, `public enum TrainingExport` with `static func writeFolder(runs: [DictationRun], corrector: DictionaryCorrector, to folder: URL) throws -> Set<UUID>` (returns exported ids; the Mac wrapper zips the folder), `public final class DictionaryStore`.
- `RunLog.didChangeNotification = "ai.pivotstudio.murmur.runs-changed"` (Darwin notification name). Every write posts it; `RunLog.prepare()` observes it and reloads.
- `RunFile` rule: before any change, under `NSFileCoordinator` (`.forMerging` write), re-read the file if its size or modification date differs from the last read; then apply the change and write. Appends stay appends.

- [ ] **Step 1: Write the failing test** `appendFromAnotherWriterSurvivesRewrite`: with the environment rooted in a temp folder, `RunLog.record(a)`, then append run `b` straight to `runs.jsonl` as another process would, then `RunLog.setSaved(true, for: a)`; wait for the queue; assert `RunLog.load().map(\.id) == [a.id, b.id]` in file order and `a.isSaved`.
- [ ] **Step 2:** Run `nice -n 10 make test`. Expected: FAIL (`b` is lost by the rewrite).
- [ ] **Step 3:** Implement the moves, the coordinated re-read and the notification.
- [ ] **Step 4:** Run `nice -n 10 make test` and `nice -n 10 make`. Expected: PASS; app builds.

### Task 4: `TranscriptFinisher`

**Files:**
- Create: `Sources/MurmurKit/Formatting/TranscriptFinisher.swift`
- Modify: `Sources/Murmur/Core/DictationController.swift` (`deliver`, lines ~665-685, calls the finisher)
- Test: `Tests/MurmurKitTests/TranscriptFinisherTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct FinishedText: Sendable { public let text: String; public let applied: [AppliedCorrection] }
  public enum TranscriptFinisher {
      public static func finish(raw: String, cleanupEnabled: Bool, formatter: any TextFormatter,
                                pipeline: CleanupPipeline?, corrector: DictionaryCorrector) async -> FinishedText
  }
  ```
  Order exactly as `deliver` today: no cleanup → raw; pipeline → `pipeline.finish(transcript:)` with the formatter as fallback; else `formatter.format(raw)`; then `corrector.apply(to:)` always last.

- [ ] **Step 1: Write the failing tests:** `cleanupOffStillAppliesDictionary` (raw "use cloud code", corrector mapping "cloud code"→"Claude Code", cleanup off → "use Claude Code"); `rulesThenDictionary` (raw "um so the n u s campus" with rules → text contains "NUS"); `pipelineFallsBackToFormatter` (pipeline with no pieces gives the formatter's output).
- [ ] **Step 2:** Run `nice -n 10 make test`. Expected: FAIL, undefined.
- [ ] **Step 3:** Implement; replace the body in `deliver` with the call.
- [ ] **Step 4:** Run `nice -n 10 make test`, `nice -n 10 make`. Expected: PASS; app builds.

### Task 5: Phone runs into the Mac's training data

**Files:**
- Modify: `DictationRun` (add `public var source: RunSource?`, `enum RunSource: String, Codable { case mac, phone }`; nil decodes as Mac), `TrainingExport.writeFolder` (also writes `runs.jsonl`, one full `DictationRun` line per exported run)
- Create: `Sources/MurmurKit/Support/TrainingImport.swift`, `Sources/Murmur/Support/TrainingImport+Zip.swift` (unzip with `/usr/bin/ditto -x -k` into a temp folder)
- Modify: `Sources/Murmur/UI/SettingsPanel.swift` (Training section: "Import from iPhone…" with `fileImporter` for `.zip`, result line "Added N, skipped M"); history row shows a "Phone" tag when `source == .phone` (existing tag component)
- Test: `Tests/MurmurKitTests/TrainingImportTests.swift`

**Interfaces:**
- Produces: `public struct ImportResult: Sendable { public let added: Int; public let skipped: Int }`; `public enum TrainingImport { public static func merge(folder: URL) throws -> ImportResult }` reads `runs.jsonl` and `clips/`, copies each new run's audio to `RecordingStore` as `<id>.flac`, sets `source = .phone` and `exportedAt = nil`, records through `RunLog.record(_:)`.

- [ ] **Step 1: Write the failing tests:** `importAddsRunsAndAudio` (export two labelled runs with audio from root A, merge into root B: B's log has both ids, `Recordings/<id>.flac` exists for each, `source == .phone`, `exportedAt == nil`, label kept); `duplicateIdIsSkipped` (merge the same folder twice: second result `added == 0, skipped == 2`, log has 2 runs); `oldLinesDecodeAsMac` (a line without `source` decodes with `source == nil`).
- [ ] **Step 2:** Run `nice -n 10 make test`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `nice -n 10 make test`, `nice -n 10 make`. Expected: PASS.

### Task 6: Mac gate

- [ ] **Step 1:** Run `nice -n 10 make test`. Expected: all pass. Record the counts.
- [ ] **Step 2:** Run `nice -n 10 make app` (xcodebuild bundle). Expected: success.
- [ ] **Step 3:** Run the built bundle's `Murmur --cleanup-check` and `Murmur --incremental-check <a Recordings/*.flac>`. Expected: both report success. Record output.
- [ ] **Step 4:** Confirm `bench/` compiles (it is part of `make test`).
- [ ] **Step 5:** Ask the user before `make install` (it replaces `/Applications/Murmur.app`).

### Task 7: `MurmurDesign` target

**Files:**
- Modify: `Package.swift` (target and product `MurmurDesign` at `Sources/MurmurDesign`)
- Move: the `Waveform` view out of `Sources/Murmur/UI/HUDView.swift` into `Sources/MurmurDesign/Waveform.swift` (public, unchanged behaviour); `HUDView` uses it.
- Move: `Sources/Murmur/UI/DesignSystem.swift` → `Sources/MurmurDesign/DesignSystem.swift`; font resolution `#if canImport(AppKit)` `NSFont(name:size:)`, `#else` `UIFont(name:size:)`; colours that use `NSColor` get a `UIColor` branch
- Add keyboard tokens to `DS` under `DS.Keyboard` (the values in the spike's `KeyboardMetrics`)

- [ ] **Step 1:** Move and branch. `Components.swift` stays in the Mac target and imports `MurmurDesign`.
- [ ] **Step 2:** Run `nice -n 10 make test`, `nice -n 10 make`. Expected: PASS; the Mac looks unchanged (no token values changed: `git diff` on token values is empty).

### Task 8: iOS project and the keyboard's dictation core

**Files:**
- Create: `ios/project.yml`, `ios/Base.xcconfig` (`#include? "Local.xcconfig"`), `ios/Local.xcconfig` (ignored), `ios/Keyboard/WebMicrophone.swift` (from the spike), `ios/Keyboard/KeyboardDictation.swift`, `ios/Keyboard/HoldGesture.swift`, `ios/Shared/PhoneEnvironment.swift`
- Modify: `.gitignore` (`ios/*.xcodeproj`, `ios/**/Info.plist` generated, `ios/Local.xcconfig`), `Makefile` (`ios-project`, `ios-build` unsigned, `ios-install` signed + `devicectl` for the connected phone)
- Test: `Tests/MurmurKitTests/HoldGestureTests.swift` (pure logic lives in MurmurKit: `Sources/MurmurKit/Dictation/HoldGesture.swift`)

**Interfaces:**
- Consumes: Tasks 1 to 4.
- Produces:
  - `PhoneEnvironment.configure()` → `MurmurEnvironment.configure(storageRoot: <App Group>/Library/Application Support/Murmur, defaults: UserDefaults(suiteName: "group.ai.pivotstudio.murmur")!)`, called first in the app and the keyboard.
  - `public struct HoldGesture` (MurmurKit): `static let tapLimit: TimeInterval = 0.3`; `mutating func touchDown(at: Date, busy: Bool) -> Action` and `mutating func touchUp(at: Date) -> Action` with `enum Action { case start, lock, finish, none }`.
  - `@MainActor @Observable final class KeyboardDictation` with `state`, `isLocked`, `engineNote`, `shiftNext`, `touchDown()`, `touchUp()`, `keyboardAppeared()`, `keyboardDisappeared()`. Engine: Bark (`IncrementalParakeetEngine` for `.whileSpeaking`, `ParakeetEngine` for `.onRelease`) when `Settings.shared.engine == .barkClean`, Bark loaded and the crash marker clear; else `AppleSpeechEngine`. Text: `TranscriptFinisher.finish` with `RuleBasedFormatter`, or `FoundationModelFormatter` when `cleanupEngine == .appleIntelligence` and available. Each non-empty hold: `RunLog.record(run, audio:)` with `rawText`, engine name, timings, `source = .phone`.

- [ ] **Step 1: Write the failing test** `touchStateMachine`: down at 0 → `.start`; up at 0.29 → `.lock`; down at 1.0 → `.none`; up at 1.1 → `.finish`. Fresh: down at 0, up at 0.31 → `.finish`. Down while `busy` → `.none`, then up → `.none`.
- [ ] **Step 2:** Run `nice -n 10 make test`. Expected: FAIL.
- [ ] **Step 3:** Implement `HoldGesture`, then `KeyboardDictation` (spike `SpikeDictation` is the starting point; the measurements readout goes away, the crash marker stays). Add `abandonWritesNothing` and `engineChoiceFallsBackToApple` as tests over a `KeyboardDictation` built with injected engine and run-log closures (`init(microphone:, proxy:, makeEngine:, record:)`).
- [ ] **Step 4:** Run `nice -n 10 make test`. Expected: PASS.
- [ ] **Step 5:** Run `make ios-build`. Expected: `** BUILD SUCCEEDED **` for both targets, unsigned.

### Task 9: The keyboard UI

**Files:**
- Create: `ios/Keyboard/KeyboardViewController.swift`, `ios/Keyboard/KeyboardView.swift`, `ios/Keyboard/EmojiPanel.swift`, `ios/Keyboard/EmojiData.swift` (copy the spike's generated file), `ios/Keyboard/HistoryPanel.swift`

**Interfaces:**
- Consumes: `KeyboardDictation`, `DS.Keyboard`, `RunStore`, `TrainingLabel.displayText`.
- Layout and behaviour as the spike's `SpikeKeyboardView` (Granola rows; page key cycles 123 → #+= → ABC; emoji picker with recents in the App Group; ⇧ one-shot; ⌫ repeats; return title and blue when not default; globe only when `needsInputModeSwitchKey`). Differences: colours and sizes from `DS`; while recording the main key is the Mac HUD (`DS.Color.hud` capsule with the HUD `Waveform`, moved into `MurmurDesign` in Task 7 and shared by both platforms) and shows no text; idle it reads "Murmur" only; the emoji grid sizes its three rows from the height left above the category bar and hides the iOS 26 scroll edge effect (the spike's `EmojiPanel` does both); history lists the last 30 `RunStore.shared.runs` by `displayText`; the failure state shows "Microphone unavailable. Open Murmur to check permissions." with an "Open Murmur" button (`murmur://setup` URL scheme on the app, opened through the responder chain's `openURL`).

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Run `make ios-build`. Expected: succeeded.

### Task 10: The app

**Files:**
- Create under `ios/App/`: `MurmurPhoneApp.swift` (handles `murmur://setup`), `SetupView.swift`, `ModelView.swift`, `HistoryView.swift`, `RunEditor.swift`, `DictionaryView.swift`, `SettingsView.swift`, `TrainingView.swift`, `LicencesView.swift`, `Assets.xcassets` (spike's icon)

**Interfaces:**
- Consumes: `BarkModelStore` (download, progress, delete, size), `RunStore`/`RunLog` (save, label via `TrainingLabel.editBase`, delete, audio playback from `RecordingStore`), `DictionaryStore`, `Settings`, `TrainingExport.writeFolder` then zip with `NSFileCoordinator` `.forUploading` reading of the folder, handed to `ShareLink`, `CrashMarker` (show and clear).
- Tabs: Setup, History, Dictionary, Settings (Model, Cleanup: on/off and Apple Intelligence, Appearance, Training, Licences). Setup also shows the keyboard's engine status (Bark loading, ready, not downloaded, stopped last time), which the keyboard writes to the App Group. Setup rows: microphone, speech, keyboard added (`UITextInputMode.activeInputModes` contains the keyboard's identifier, or a `keyboardLastSeen` date the keyboard writes), Full Access (`hasFullAccess` the keyboard writes), Bark downloaded.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Run `make ios-build`. Expected: succeeded.

### Task 11: Remove the spike, document, hand over

- [ ] **Step 1:** Delete `ios/spike/` and its `.gitignore` lines. `Tools/makeicon.swift --ios` writes `ios/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png`.
- [ ] **Step 2:** `AGENTS.md`: an iOS section (WebKit capture and its fragility, App Group layout, crash marker, the HUD waveform on the main key, `make ios-*`, installs only on request); update "Not built yet" and the `MurmurKit` layout notes.
- [ ] **Step 3:** Run `nice -n 10 make test`, `nice -n 10 make`, `make ios-build`. Expected: all pass.
- [ ] **Step 4:** Report; signed install only when the user asks (`make ios-install`).
