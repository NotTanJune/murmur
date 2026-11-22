# iOS Keyboard Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A throwaway iOS app plus keyboard extension that records through a hidden `WKWebView`, transcribes with Bark Clean (Apple's transcriber standing in), types the rule-cleaned text, and shows the numbers the user's on-device check needs.

**Architecture:** `ios/spike/` holds an XcodeGen project. Both targets compile a fixed list of Mac source files by path plus a shim file that replaces their Mac-only neighbours (`AppStorage`, `Settings`, `DictionaryStore`). `MurmurDictionary` is built as a framework from its own sources. Nothing under `Sources/` changes.

**Tech Stack:** Swift 6 language mode, iOS 26, SwiftUI, UIKit (`UIInputViewController`), WebKit, AVFoundation, FluidAudio 0.15.6 (revision `4dbf4f9f`), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-21-ios-keyboard-design.md`, section "Build order", step 1.

## Global Constraints

- iOS deployment target 26.0. Swift language mode 6, no default main-actor isolation (same as the Mac target).
- Bundle IDs `ai.pivotstudio.murmur.ios` (app) and `ai.pivotstudio.murmur.ios.keyboard` (extension); App Group `group.ai.pivotstudio.murmur`.
- No file under `Sources/` or `Tests/` changes. `git diff --stat Sources Tests` is empty at the end.
- No simulator, no signed build, no install. Verification is an unsigned `generic/platform=iOS` build, niced, few jobs, derived data under `~/Library/Caches/MurmurBuild/ios-spike`.
- Never `MainActor.assumeIsolated` (AGENTS.md). Never `AsrModels.load(from:)` for Bark (the Mac's `ParakeetModels` already avoids it; reuse it).
- The team ID lives only in git-ignored `ios/spike/Local.xcconfig`.
- No commits unless the user asks (user's standing rule).
- GPL-3.0-only: write Murmur's own capture code; the reference repos are read for technique only.

## Review Focus

1. Page reports a capture rate other than 48 kHz (44.1 kHz on some routes, 16 kHz on Bluetooth HFP): the Swift side must resample from whatever rate the page reports, never assume one. Pinned by a `PCMBridge` test at 44.1 kHz.
2. Bark kills the extension for memory: the next keyboard launch must run Apple-only instead of loading Bark again into the same kill. Pinned by the `CrashMarker` test.
3. The keyboard disappears mid-hold: capture stops (native stop plus the page's 3 s heartbeat timeout), nothing is typed into a dead proxy.
4. A hold shorter than Bark's minimum audio: the engine returns empty; nothing is inserted and the readout says "no speech", not an error.
5. Full Access off: `getUserMedia` or the App Group read fails; the key shows the plain failure message from the spec instead of spinning.

---

### File structure

```
ios/spike/
├── project.yml              XcodeGen: MurmurDictionary framework, app, keyboard
├── Base.xcconfig            shared settings; `#include? "Local.xcconfig"`
├── Local.xcconfig           git-ignored: DEVELOPMENT_TEAM = <your team ID>
├── build.sh                 generate + unsigned compile
├── README.md                what the spike is, how the user installs and what to report
├── Package.swift            macOS-only test package for SpikeAudio (Task 2)
├── Shared/
│   ├── Shims.swift          AppStorage, Settings, BarkDecoderChoice, DictionaryStore stand-ins
│   ├── Core/SpikeReport.swift  Codable metrics the keyboard writes and the app reads
│   ├── Core/CrashMarker.swift  "Bark was loading" marker in the App Group
│   └── Audio/PCMBridge.swift  base64 Float32 → [Float] → AVAudioPCMBuffer → engine format
├── Keyboard/
│   ├── KeyboardViewController.swift
│   ├── SpikeKeyboardView.swift
│   ├── WebMicrophone.swift  carries forward to the real build
│   ├── SpikeDictation.swift engine choice, hold lifecycle, cleanup, insert, report
│   └── Footprint.swift      phys_footprint via task_vm_info
├── App/
│   ├── SpikeApp.swift
│   └── SetupView.swift      permissions, Bark download, setup steps, last report, test field
└── Tests/{SpikeAudioTests,SpikeCoreTests}/
```

Mac files compiled by path into both targets: `Transcription/{TranscriptionEngine,ParakeetEngine,IncrementalParakeetEngine,OverlapWindowRecognizer,WindowSeam,BarkModelStore,AppleSpeechEngine,CustomDecoderSlot}.swift`, `Formatting/{TextFormatter,TranscriptRepair}.swift`, `Support/Log.swift`.

### Task 1: Project scaffold that compiles the Mac speech files for iOS

**Files:** Create `ios/spike/{project.yml,Base.xcconfig,Local.xcconfig,build.sh}`, `ios/spike/Shared/Shims.swift`, placeholder `Keyboard/KeyboardViewController.swift` and `App/SpikeApp.swift`. Modify `.gitignore` (add `ios/spike/Local.xcconfig`, `ios/spike/*.xcodeproj`, `ios/spike/**/Info.plist`, `ios/spike/.build/`).

**Interfaces produced (Shims.swift):**
- `enum AppStorage { static let groupID = "group.ai.pivotstudio.murmur"; static var directory: URL }`: the App Group container's `Library/Application Support/Murmur`, falling back to the process's Application Support when the group is unavailable (unsigned or missing entitlement), logging the fallback once.
- `enum BarkDecoderChoice: Hashable, Sendable { case stock; case custom(String) }`
- `@MainActor final class Settings { static let shared; var barkDecoder: BarkDecoderChoice = .stock }`
- `@MainActor final class DictionaryStore { static let shared; var biasPhrases: [String] { [] } }`

- [ ] **Step 1:** Write `project.yml`: package `FluidAudio` at `https://github.com/FluidInference/FluidAudio.git` `exactVersion: 0.15.6`; framework target `MurmurDictionary` from `../../Sources/MurmurDictionary`; app `MurmurSpike` (embeds the framework and the extension) and app-extension `MurmurSpikeKeyboard` (`com.apple.keyboard-service`, `RequestsOpenAccess` true, `PrimaryLanguage` en-US, `IsASCIICapable` true, principal class `$(PRODUCT_MODULE_NAME).KeyboardViewController`), both with the Mac file list, `Shared/`, the App Group entitlement, `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`.
- [ ] **Step 2:** `build.sh` runs `xcodegen generate` then `nice -n 10 xcodebuild -project MurmurSpike.xcodeproj -scheme MurmurSpike -destination 'generic/platform=iOS' -derivedDataPath ~/Library/Caches/MurmurBuild/ios-spike -jobs 4 CODE_SIGNING_ALLOWED=NO build`.
- [ ] **Step 3:** Run `ios/spike/build.sh`. Expected: `** BUILD SUCCEEDED **`. A compile error inside a Mac file is fixed in the shim, never in `Sources/`; if a shim cannot fix it, stop and report.
- [ ] **Step 4:** `git diff --stat Sources Tests` prints nothing.

### Task 2: PCM bridge from page samples to engine buffers

**Files:** Create `ios/spike/Shared/Audio/PCMBridge.swift`, `ios/spike/Package.swift` (macOS 26 library `SpikeAudio` at `Shared/Audio`, test target at `Tests/SpikeAudioTests`), `ios/spike/Tests/SpikeAudioTests/PCMBridgeTests.swift`.

**Interfaces produced:**
- `enum PCMBridge { static func decodeFloat32(base64: String) -> [Float]? }`: little-endian Float32; nil on bad base64 or a byte count not divisible by 4.
- `final class PCMConverter { init?(sourceRate: Double, target: AVAudioFormat); func convert(_ samples: [Float]) -> AVAudioPCMBuffer? }`: one `AVAudioConverter` per hold, kept across chunks so resampler state carries over; every call returns a freshly allocated buffer (AudioChunk's contract).

- [ ] **Step 1: Failing tests**

```swift
@Test func decodesLittleEndianFloat32() {
    // 0.0, 0.5, -1.0 as IEEE-754 little-endian bytes
    let bytes: [UInt8] = [0,0,0,0, 0,0,0,0x3F, 0,0,0x80,0xBF]
    #expect(PCMBridge.decodeFloat32(base64: Data(bytes).base64EncodedString()) == [0, 0.5, -1])
}
@Test func rejectsTruncatedSample() {
    #expect(PCMBridge.decodeFloat32(base64: Data([0,0,0]).base64EncodedString()) == nil)
}
@Test func resamples44_1kTo16kFloat() throws {
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let converter = try #require(PCMConverter(sourceRate: 44_100, target: target))
    var frames = 0
    for _ in 0..<10 { frames += Int(converter.convert([Float](repeating: 0.25, count: 4_410))?.frameLength ?? 0) }
    #expect(abs(frames - 16_000) <= 64)   // one second in, about one second out
}
@Test func convertsToInt16Target() throws {
    let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
    let converter = try #require(PCMConverter(sourceRate: 48_000, target: target))
    let out = try #require(converter.convert([Float](repeating: 0.5, count: 4_800)))
    #expect(out.format.commonFormat == .pcmFormatInt16)
}
```

- [ ] **Step 2:** `cd ios/spike && nice swift test --scratch-path ~/Library/Caches/MurmurBuild/ios-spike-tests -j 4`. Expected: FAIL (`PCMBridge` undefined).
- [ ] **Step 3:** Implement. Converter uses an input block that hands over each chunk once, then reports `.noDataNow`, so resampler history persists between calls.
- [ ] **Step 4:** Same command. Expected: 4 tests pass.

### Task 3: WebMicrophone

**Files:** Create `ios/spike/Keyboard/WebMicrophone.swift`.

**Interfaces produced:**
- `@MainActor final class WebMicrophone: NSObject` with `init()`, `func attach(to view: UIView)`, `func start()`, `func stop()`, `func tearDown()`, and callbacks `onStarted: ((Double) -> Void)?` (page capture rate), `onSamples: (([Float], Float) -> Void)?` (samples at that rate, RMS), `onEnded: ((String) -> Void)?` (reason), `private(set) var isReady: Bool`.

Behaviour fixed by the spec: 1×1 pt web view at alpha 0.01 in the keyboard's hierarchy; inline page loaded with `https://murmur-keyboard.invalid/` as base URL; `requestMediaCapturePermissionFor` grants microphone, denies camera; `navigator.audioSession.type = 'play-and-record'` and the `AudioContext` created only at start; the page posts native-rate Float32 base64 chunks (no resampling in JavaScript) plus `started` with `context.sampleRate`; heartbeat every 1 s from native, page stops after 3 s without one; page stops on `pagehide`, track end, context leaving `running`, audio-session interruption; re-load the page when the content process dies. Message handler class is `@MainActor`, holds its target weakly; no `assumeIsolated`.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** `ios/spike/build.sh` → `** BUILD SUCCEEDED **`. (Behaviour is on-device only; the README lists it for the user's check.)

### Task 4: Dictation core

**Files:** Create `ios/spike/Keyboard/{SpikeDictation,Footprint}.swift`, `ios/spike/Shared/Core/{CrashMarker,SpikeReport}.swift`, `ios/spike/Tests/SpikeCoreTests/SpikeCoreTests.swift`; add a `SpikeCore` target at `Shared/Core` and its test target to `ios/spike/Package.swift`.

**Interfaces produced:**
- `struct SpikeReport: Codable, Sendable { var engine: String; var barkLoadSeconds: Double?; var releaseToTextSeconds: Double?; var holdSeconds: Double; var peakFootprintMB: Double; var restingFootprintMB: Double; var captureRate: Double?; var text: String; var note: String?; var date: Date }` with `static func read(from: URL) -> SpikeReport?` and `func write(to: URL) throws`; file `AppStorage.directory/spike-report.json`.
- `struct CrashMarker { init(directory: URL); func arm(); func disarm(); var wasArmedAtLaunch: Bool }`: `arm()` writes `bark-loading` before Bark loads, `disarm()` removes it after Bark's first successful hold; a marker present when the keyboard launches means the last load died.
- `enum Footprint { static func currentMB() -> Double }` via `task_info(TASK_VM_INFO)` `phys_footprint`.
- `@MainActor @Observable final class SpikeDictation` with `init(proxy: () -> UITextDocumentProxy)`, `var state: State` (`.idle`, `.loadingBark`, `.recording(level: Float)`, `.finishing`, `.failed(String)`), `var readout: String`, `func keyboardAppeared()`, `func pressDown()`, `func release()`, `func keyboardDisappeared()`.

Behaviour: `keyboardAppeared` loads Bark (`ParakeetModels.barkClean.loadedModels()`) when `BarkModelStore.isDownloaded` and the crash marker was not armed at launch, timing the load; otherwise Apple only, with the reason in `readout`. A hold uses `IncrementalParakeetEngine(models: .barkClean)` if Bark finished loading, else `AppleSpeechEngine()`. `pressDown` starts the microphone at once; each `onSamples` goes through `PCMConverter` into `engine.feed`. `release` stops the microphone, calls `engine.finish()`, reads the stream to its final chunk, runs `RuleBasedFormatter().format`, inserts with a leading space when the character before the cursor is a letter, digit or `.,!?;:`, writes a `SpikeReport`. Footprint sampled every 0.25 s during the hold, peak kept. Empty text inserts nothing and reports "no speech". A press during `.finishing` is ignored.

- [ ] **Step 1: Failing tests** (`SpikeCoreTests`): `CrashMarker` armed then a new instance on the same directory reports `wasArmedAtLaunch == true`; after `disarm()` a new instance reports false. `SpikeReport` written then read round-trips equal.
- [ ] **Step 2:** `swift test` in `ios/spike` → fails (types undefined).
- [ ] **Step 3:** Implement the four files.
- [ ] **Step 4:** `swift test` → all pass; `build.sh` → `** BUILD SUCCEEDED **`.

### Task 5: Keyboard UI

**Files:** `ios/spike/Keyboard/KeyboardViewController.swift`, `ios/spike/Keyboard/SpikeKeyboardView.swift`.

`KeyboardViewController: UIInputViewController` hosts `SpikeKeyboardView` in a `UIHostingController`, owns `SpikeDictation` and `WebMicrophone` (attached to `view`), calls `keyboardAppeared` in `viewWillAppear` and `keyboardDisappeared` in `viewWillDisappear`, height about 260 pt. View: one large key (press via `DragGesture(minimumDistance: 0)`: `onChanged` first event → `pressDown`, `onEnded` → `release`), red while recording (literal colours are acceptable in the throwaway spike), a level bar, the readout text in a small monospaced font, a globe key shown when `needsInputModeSwitchKey` using `handleInputModeList(from:with:)`, delete and return keys.

- [ ] **Step 1:** Implement. **Step 2:** `build.sh` → `** BUILD SUCCEEDED **`.

### Task 6: Containing app

**Files:** `ios/spike/App/SpikeApp.swift`, `ios/spike/App/SetupView.swift`.

One screen: microphone permission (`AVAudioApplication.requestRecordPermission`), speech permission (`SFSpeechRecognizer.requestAuthorization`), Bark download via `BarkModelStore.ensureDownloaded()` with the size (`BarkModelStore.totalBytes`) shown before starting and a delete button, whether the App Group resolved (`AppStorage.directory` path), step text for adding the keyboard and Full Access with a button opening `UIApplication.openSettingsURLString`, the last `SpikeReport` (refresh on foreground), and a multi-line `TextField` to dictate into.

- [ ] **Step 1:** Implement. **Step 2:** `build.sh` → `** BUILD SUCCEEDED **`.

### Task 7: Hand-over

**Files:** `ios/spike/README.md`.

- [ ] **Step 1:** README: what the spike is and that it is deleted after; how to install (open the project in Xcode, pick the phone, Run, with the team already in `Local.xcconfig`); setup order; the checks to report (records in Messages and Mail, Bark loads and its time, peak footprint in a 60 s hold, first word clipped or not, orange dot off after release, any keyboard crash).
- [ ] **Step 2:** Final evidence: `build.sh` succeeded, `swift test` counts, `git diff --stat Sources Tests` empty, `git status --short`.
