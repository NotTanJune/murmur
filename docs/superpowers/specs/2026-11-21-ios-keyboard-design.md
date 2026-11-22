# Murmur for iOS: a dictation keyboard

Date: 2026-11-21. Status: approved; spike passed on 2026-11-22 (see "Spike report").

## Intent

Murmur on the Mac is hold-to-talk dictation: Bark Clean hears, a cleanup pass tidies, the
dictionary fixes names, and the text lands in the focused field. The user wants the same
thing on the iPhone, mostly for typing messages and email, without the "open the app, then
swipe back" dance that iOS dictation keyboards have needed until now.

Since 2026-11-19 that dance is avoidable. Raycast (Johan Thorell) showed that a keyboard
extension can host a `WKWebView` whose `getUserMedia` records in WebKit's own media process,
under the containing app's microphone permission. The keyboard itself never holds the
microphone, so the "extension lacks the record-audio entitlement" refusal does not apply.
Reference implementations: `stephancill/ios-keyboard-dictation` (MIT, `WebAudioCapture.swift`)
and Hex (`anomalyco/hex`, MIT, `HEXKeyboard/KeyboardLocalDictation.swift`, which also runs
Apple's `SpeechTranscriber` inside the keyboard at about 58 MB footprint). Read them for the
technique; write Murmur's own code (GPL-3.0-only, see `AGENTS.md`), do not paste theirs.

## Goals

1. A custom keyboard, "dictation-only", whose main key records with Bark Clean and types the
   cleaned text through `textDocumentProxy`, with no switch to the containing app.
2. The same text pipeline as the Mac: Bark's incremental windows and seams, `TranscriptRepair`
   (pause periods, spelled letters, numerals), the rule cleanup, then the dictionary.
3. A containing iOS app for setup, the Bark download, dictionary editing, history with audio,
   correction labels, and training export.
4. One shared code base for both platforms (`MurmurKit`), so a fix to seams, numerals or the
   dictionary reaches the phone without a port.

## Non-goals

- A full typing keyboard (letters, autocorrect, suggestions). Possibly a later project.
- S1-mini and cleanup profiles. Profiles do nothing without S1-mini; the user does not want
  them on iOS.
- Compare mode, the Wispr Flow reader, the model benchmark, Parakeet EOU and Nemotron
  streaming engines, and stock Parakeet v3 on iOS.
- Everything that exists to work around macOS input: the hotkey and its watchdog, HID key
  reading, `MicrophonePolicy`, `SystemInputGuard`, AX insert, the paste fallback,
  `PasteOnlyApps`, the login item, `CompileCacheGuard`'s Mac paths.
- Installing a fine-tuned decoder (`CustomDecoderSlot`) on the phone. Fine-tuning stays on the
  Mac; the phone only contributes labelled recordings, which the Mac imports (section 6).
  (Builder's call to revisit if it falls out for free.)
- App Store submission, notarization, TestFlight. The user signs and installs on their own
  device.

## Anti-goals

- The Mac app regresses. It is in daily use; every Mac test and the dictionary vectors must
  pass after the refactor, and `make install` must produce a working app.
- The microphone stays open behind the user's back. The page must stop capture by itself when
  the keyboard goes away (heartbeat), and nothing records except during a hold or a locked
  recording.
- Text from a dictation lands out of order or twice.

## Constraints

- **iOS 26 minimum.** Bark needs iOS 18; `SpeechAnalyzer`/`SpeechTranscriber` and
  Foundation Models need iOS 26. The user's phone runs a current iOS.
- **Keyboard memory.** iOS kills a keyboard extension that grows too large (roughly 120 to
  180 MB on current phones; Hex measured 58 MB used with 118 MB headroom). Bark's weights sit
  on the Neural Engine (the Mac app measures about 30 MB resident for Bark), so Bark inside the
  keyboard is plausible but unmeasured. This is the project's biggest unknown; see
  "Risks".
- **Full Access** is required (`RequestsOpenAccess = true`), and microphone and speech
  permissions are granted once in the containing app. Both `Info.plist`s carry
  `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`.
- **Fragility.** KeyboardKit expects Apple may close the WebKit path or reject updates. The
  design must degrade: if capture fails, the keyboard says so and offers the old route
  (open Murmur to dictate) rather than failing silently. Building that fallback route is
  builder's call for v1; the error message is not optional.
- **Shared storage.** The app and keyboard are separate processes with separate containers.
  Everything both read (settings, dictionary, history, recordings, Bark files) lives in an App
  Group container.
- **Verification without a device.** Per the user's standing rules: no simulator builds and
  no signed device builds by the agent. Verify with an unsigned generic iOS compile
  (`xcodebuild ... -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`), SwiftPM
  tests for `MurmurKit` on the Mac, the dictionary vectors, and the Mac suite. The user owns
  signing and on-device testing. Builds run niced with few jobs (the Mac gets hot).
- **Licence.** GPL-3.0-only. FluidAudio is Apache-2.0; Bark's weights carry their own terms
  already recorded in `THIRD_PARTY.md`; check the iOS app's About/licences screen lists them.

## Approaches considered

**A. Shared library target, both apps import it** (chosen by the user).
Move the platform-neutral code from `Sources/Murmur` into a new `MurmurKit` library target in
`Package.swift`, add `.iOS(.v26)` to the package platforms, and have the Mac executable and
the iOS targets import it. Costs a refactor of a daily-use Mac app; buys one place for every
pipeline fix.

**B. The iOS project compiles Mac files by path** with `#if os(iOS)` branches. No refactor,
but Mac-only edits silently break iOS and AppKit-touching files (settings, design tokens) fork
inside themselves.

**C. Copy the code into `ios/`.** Rejected: it drifts immediately, which defeats parity.

## Design

### 1. `MurmurKit` (shared library)

A new SwiftPM library target, Swift 6 language mode, macOS 26 and iOS 26. Depends on
`MurmurDictionary` and `FluidAudio` only. It must not import AppKit, UIKit, MLX or SwiftUI
(the design tokens are the one exception, see section 5).

Moves in (names as they are today):

| Area | Files |
|---|---|
| Text | `TextFormatter.swift` (`RuleBasedFormatter`, `PassthroughFormatter`), `TranscriptRepair.swift`, `CleanupPipeline.swift`, `FoundationModelFormatter.swift`, `CleanupProfile.swift` (`CleanupEngine` only matters on iOS; profiles stay for the Mac) |
| Speech | `TranscriptionEngine.swift`, `ParakeetEngine.swift` (incl. `ParakeetModels`), `IncrementalParakeetEngine.swift`, `OverlapWindowRecognizer.swift`, `WindowSeam.swift`, `AppleSpeechEngine.swift`, `BarkModelStore.swift` |
| Data | `RunLog.swift` (`DictationRun`, `RunLog`), `RecordingStore.swift`, `TrainingLabel.swift`, `TrainingExport.swift`, `DictionaryStore.swift` |
| Support | `Log.swift`, the platform-neutral part of `Settings.swift`, `ModelResidency.swift` if it has no Mac-only dependency |

Stays in the Mac target: everything in `Core/` except what the table lists, `S1Mini*`,
`EngineComparison`, `WisprReader`, `CompileCacheGuard`, `LoginItem`, `Permissions`,
`Sounds`, the HUD, `MainWindow` and the panels, and the `--*-check` entry points.

Seams the move needs:

- **Storage root.** `AppStorage.directory` becomes a value the host sets at launch. The Mac
  sets `~/Library/Application Support/Murmur` (unchanged); iOS sets the App Group container.
  `BarkModelStore.modelsRoot`, `RecordingStore`, `RunLog` and `DictionaryStore` already derive
  from it. `ParakeetEngine.swift:156` reads Application Support directly and must go through
  the root too. Mac paths must not change (existing users' data, the ANE cache symlink).
- **Settings.** Split `Settings.swift`: the observable settings model and the engine/timing
  enums move to `MurmurKit` with an injected `UserDefaults` (standard on the Mac, the App
  Group suite on iOS, `MURMUR_SETTINGS_DOMAIN` still honoured). `AppearanceChoice.nsAppearance`
  and `NSApplication.shared.appearance` stay in the Mac target as an extension. Keys and
  defaults must not change on the Mac.
- **Finishing a transcript.** `DictationController.deliver` currently does
  cleanup (pipeline or whole) then `DictionaryStore.shared.corrector.apply`. Extract that into a
  `MurmurKit` function or type (name is builder's call) that takes the raw transcript, the
  cleanup choice and an optional `CleanupPipeline`, and returns the output text plus applied
  corrections. The Mac controller calls it; the keyboard calls it. Ordering, injection, the
  secure-field check and run recording stay with each host.
- **Visibility.** Types used across the module boundary become `public`. Keep the public
  surface to what the two hosts actually call.

- **Mac-only references inside moved files.** `TrainingExport` zips with `/usr/bin/ditto`
  through `Process`, which iOS lacks: the shared part builds the export folder and each host
  zips it (the Mac keeps `ditto`; iOS uses `NSFileCoordinator` reading with `.forUploading`
  or another zip, builder's call after checking the API). `SpeechEngineChoice` references
  `FluidStreamingEngine`/`StreamingEngines`, and `RunLog` records `pushToTalkKey`; keep those
  members in Mac-target extensions so the shared types compile on iOS.

Tests: existing tests that cover moved code move with it into a `MurmurKitTests` target that
runs on the Mac. `MurmurAppTests` keeps what still tests Mac code. The `bench/` runner must
still compile against the new layout.

### 2. iOS project layout

`ios/` holds an XcodeGen `project.yml` (checked in) and generates `Murmur.xcodeproj`
(ignored by git, regenerated by a `make ios-project` or similar). Two targets:

- **MurmurPhone** (app): SwiftUI. Bundle ID proposal `ai.pivotstudio.murmur.ios`.
- **MurmurKeyboard** (custom keyboard extension, principal class a
  `UIInputViewController` subclass): bundle ID `ai.pivotstudio.murmur.ios.keyboard`.

Both: App Group `group.ai.pivotstudio.murmur`, depend on the local package's `MurmurKit`
product, ship the Fraunces and Figtree TTFs (`UIAppFonts`). The team ID and signing are left
blank or read from a local, git-ignored xcconfig so the user can fill them in; the agent never
needs them. The keyboard's `Info.plist` sets `RequestsOpenAccess = true`,
`PrimaryLanguage = en-US`, `IsASCIICapable = true`.

### 3. The keyboard

Layout (one row of chrome, two rows of keys, the globe below as iOS places it):

```
┌──────────────────────────────────────────────┐
│  ⟲   (            ● Murmur              )    │  main key
│ ⇧   @   .   ,   ?   !   '   ⌫               │
│ 123     ⌨↓   [      space      ]  [ return ] │
│ 🌐                                            │
└──────────────────────────────────────────────┘
```

Modelled on Granola's voice-only keyboard (screenshot supplied by the user). The bottom row
also has an emoji key (added 2026-11-22 at the user's request): a third-party keyboard cannot
open Apple's emoji panel, so Murmur draws its own picker from Unicode's `emoji-test.txt`
(Emoji 16.0, fully qualified, no skin-tone variants) in Apple's eight groups plus recents.

- **Main key.** Hold to talk: press starts capture, release finishes and types. A quick tap
  (released before a short threshold, builder's call around 0.3 s) locks recording on; a
  second tap finishes. While recording the key shows the Mac HUD's waveform (red bars on the
  HUD capsule); idle it reads "Murmur" and nothing else. While Bark is still loading,
  Apple's transcriber handles the hold and the app (not the key) says so.
- **⟲ History.** A panel over the key rows listing recent runs (text as the Mac row shows it,
  `TrainingLabel.displayText`); tap one to type it again. Editing and labelling live in the
  app, not the keyboard.
- **Punctuation row** types the character. **⇧** capitalises the first letter of the next
  dictated text or typed character, one shot. **⌫** deletes backward and repeats when held.
- **123** cycles the row: punctuation → digits 1 to 0 → symbols (`- / : ; ( ) $ & " #`) →
  punctuation. The key names the page it leads to (123, #+=, ABC).
- **⌨↓** calls `dismissKeyboard()`. **🌐** uses `handleInputModeList(from:with:)` so a long
  press shows the keyboard list; it is shown only when `needsInputModeSwitchKey` is true.
- **return** inserts `"\n"` and takes its title from `textDocumentProxy.returnKeyType`
  ("send", "search", "go"...).
- Key clicks through `UIDevice.current.playInputClick()` (`UIInputViewAudioFeedback`).
- Insertion: `textDocumentProxy.insertText`. A leading space is added when the character
  before the cursor (`documentContextBeforeInput`) is a letter, digit or sentence punctuation,
  so consecutive dictations do not run together. iOS swaps in the system keyboard for secure
  fields, so the Mac's password-field check has no counterpart.

#### Capture

A `WebMicrophone` (name is builder's call) owned by the keyboard's view controller:

- A `WKWebView` 1×1 pt at alpha 0.01, inside the keyboard's view hierarchy (not hidden or
  removed: WebKit throttles a web view outside a window).
- Inline HTML loaded with an `https://` base URL that is never fetched (secure context for
  `getUserMedia`). `WKUIDelegate.webView(_:requestMediaCapturePermissionFor:...)` grants
  microphone and denies camera.
- The page sets `navigator.audioSession.type = 'play-and-record'`, creates its
  `AudioContext` only when capture starts (creating one earlier can take audio focus or move
  a Bluetooth route while the keyboard is merely visible), taps the stream, and posts 16 kHz
  mono samples to Swift through a `WKScriptMessageHandler`. Encoding (base64 Int16 as in the
  reference, or Float32) and the tap (`ScriptProcessorNode` or an `AudioWorklet`) are builder's
  call; measure the latency either way.
- Swift wraps each message in an `AVAudioPCMBuffer` at the engine's preferred format and feeds
  the same `TranscriptionEngine` API the Mac uses.
- Dead-man's switch: native sends a heartbeat every second while capturing; the page stops
  the tracks and closes the context after 3 s without one. The page also stops on `pagehide`,
  on track end and on an audio-session interruption. Native stops capture in
  `viewWillDisappear` and when the extension is about to terminate.
- Start latency: the microphone opens on touch-down of the main key, not on recognising a
  hold. If measurement shows speech clipped at the start, the builder may keep the capture
  warm while the keyboard is on screen with a pre-roll capped at 0.3 s like the Mac's
  `CaptureRouter`, but only behind a setting that defaults off, because that shows the orange
  microphone dot whenever the keyboard is up.
- Failure: if `getUserMedia` rejects, or no audio arrives within a short timeout, the key
  shows a plain message ("Microphone unavailable. Open Murmur to check permissions.") and a
  button that opens the app's setup screen.

#### Recognition and text

- Bark Clean through `IncrementalParakeetEngine` when `Settings.transcribeTiming` is
  "while speaking" (the default), `ParakeetEngine` batch otherwise, exactly as on the Mac.
  Bark loads from the App Group's `Models/bark-3.0-clean` with `MLModel.load` (never
  `AsrModels.load(from:)`, which would replace Bark with stock weights on a failed load).
- Bark loads when the keyboard appears and is held for the extension's life. While it loads,
  `AppleSpeechEngine` stands in for the hold, as `Utterance.standIn = .apple` does on the Mac.
  If Bark is not downloaded, Apple's engine is used and the history row says so.
- If the extension is killed for memory with Bark loaded, the next appearance must not loop
  into the same kill. Record a "Bark crashed the keyboard" marker in the App Group before
  loading and clear it after a successful hold; if the marker is still set at the next launch,
  run Apple-only and tell the user in the app. (Mechanism is builder's call; the behaviour is
  not.)
- Cleanup: the rule pass by default; Apple Intelligence (`FoundationModelFormatter`) as an
  optional setting, off by default, falling back to rules when unavailable. Then the dictionary,
  always last. `CleanupPipeline` is used only with Apple Intelligence on, as on the Mac.
- **No live words** (decided 2026-11-22): while recording, the main key shows only the Mac
  HUD's waveform (dark `DS.Color.hud` capsule, red bars, the HUD's constants); idle, it reads
  "Murmur". A side-by-side Apple preview engine was approved and then dropped the same day,
  when the user removed the text it would have fed.
- Holds do not overlap on iOS in v1: a press while the previous hold is still finishing waits
  for it (simpler than the Mac's pipelined holds; the phone's usage is turn-based). Builder may
  port the pipelining if it comes cheaply.

#### Run log and audio

Each non-empty hold records a `DictationRun` and its audio (`Recordings/<id>.flac`) in the App
Group, as the Mac does, including `rawText` and timings. The keyboard and the app may both be
alive and both write (the keyboard appends runs; the app edits labels, saves, deletes and
prunes). Use `NSFileCoordinator` or an equivalent cross-process lock around every write and
re-read on change (a Darwin notification is enough to tell the other side). Unsaved runs
older than 30 days are pruned, as on the Mac.

### 4. The app

SwiftUI, one `TabView` or a sidebar-free navigation (builder's call), with:

- **Setup**: steps with live status: microphone permission, speech permission, keyboard added
  (detect via `UITextInputMode.activeInputModes` containing the extension's identifier, or a
  "last seen" timestamp the keyboard writes), Full Access (the keyboard writes
  `hasFullAccess` to the App Group), Bark downloaded. Buttons request permissions or open
  Settings.
- **Model**: Bark Clean download through `BarkModelStore` (pinned revision, size and SHA-256
  verified, excluded from backup), with progress, size on disk and delete. Engine choice:
  Bark Clean or Apple. Transcribe timing: while speaking or on release.
- **History**: the Mac's history list: text, engine, latency, Save chip, copy, the correction
  editor with `TrainingLabel.editBase` ("Heard" eyebrow for model-cleaned runs), audio
  playback, delete.
- **Dictionary**: add, edit, delete entries, same model and corrector as the Mac.
- **Settings**: cleanup on/off, Apple Intelligence toggle, sounds, appearance.
- **Training**: export labelled runs with audio as the Mac's `Training/export-<date>.zip`,
  handed to the share sheet so the user can AirDrop it to the Mac.

Dictionary and history do not sync with the Mac in v1.

### 5. Look

Ink on paper, as `AGENTS.md` describes. `DesignSystem.swift` imports AppKit only to check
fonts through `NSFont`; give it a `UIFont` branch (or split the tokens into a shared file plus
per-platform font resolution) so iOS uses the same tokens. Cream means selected, red means
recording, no gradients, shadows only on floating surfaces. The keyboard follows the system
light/dark setting; key sizes follow Apple's keyboard metrics so it sits naturally next to
the system keyboard. Views carry no literal values; add tokens instead.

### 6. Phone recordings into the Mac's training data

The user fine-tunes on the Mac with `training/finetune_local.py`, which reads the Mac's own run
log and `Recordings/` in place; only the Colab notebook reads an export zip. So the Mac gains an
import (chosen by the user over "phone zips go to Colab only"):

- The phone's export zip carries, beside the existing `manifest.jsonl`, `replay.jsonl`, `clips/`
  and `export.json`, a `runs.jsonl` with each exported run's full `DictationRun` line, so the
  import is lossless. The Colab notebook ignores the extra file.
- Mac Settings → Training gains "Import from iPhone…" (file picker on the zip). It merges runs
  by id: an id already in the log is skipped, never overwritten. Each imported run's audio is
  copied to `Recordings/<id>.flac`. Imported runs arrive with `exportedAt` cleared, so the
  Mac's own export and the local script both see them, and they keep their label so the 30-day
  pruning spares them as it spares any labelled run with unexported audio.
- Imported runs are marked as coming from the phone (field name builder's call; lines written
  before it existed decode as Mac runs) so the history can tag them.
- The import reports what it added and skipped. It writes through `RunLog`'s queue, as every
  history change does.

## Build order

The two unknowns (the WebKit microphone and Bark's memory inside a keyboard) can only be
proven on the user's phone, and the `MurmurKit` refactor is certain work on a daily-use Mac
app. So the build proves the unknowns first (chosen by the user):

1. **Spike: a first, throwaway keyboard build.** `ios/spike/` with its own XcodeGen project.
   It compiles the needed Mac files by path (approach B, temporarily): `ParakeetEngine`,
   `IncrementalParakeetEngine`, `OverlapWindowRecognizer`, `WindowSeam`, `BarkModelStore`,
   `AppleSpeechEngine`, `TranscriptionEngine`, `TranscriptRepair`, `TextFormatter`, plus
   whatever they pull in, with `#if` shims kept inside `ios/spike/`. No file under
   `Sources/` changes. The keyboard is one big hold-to-talk key plus a readout: engine used,
   Bark load time, time from release to text, and `phys_footprint` (peak during the hold). The
   app requests permissions and downloads Bark into the App Group. `WebMicrophone` is written
   as real code and carries forward; everything else in the spike is deleted after.
2. **Checkpoint: the user installs the spike and reports.** Microphone records inside the
   keyboard in two apps (Messages, Mail), Bark loads, footprint during a 60 s hold, start
   clipping, and whether the orange dot goes away after release. The agent makes no claim
   about on-device behaviour until this report.
   - Capture fails: stop and decide with the user (drop the project, or make "open Murmur to
     dictate" the v1 route). The Mac stays untouched.
   - Bark does not fit: continue with Apple speech in the keyboard and decide with the user
     whether Bark runs in the app instead.
3. **`MurmurKit` refactor and the Mac import** (sections 1 and 6), verified on the Mac.
4. **The real iOS app and keyboard** (sections 2 to 5) on top of `MurmurKit`; the spike is
   deleted.

## Spike report (2026-11-22, iPhone 15 Pro, iOS 27.2.1)

- Capture: WebKit `getUserMedia` recorded inside the keyboard at 48 kHz. Works.
- Bark: loaded inside the keyboard in 84.8 s the first time (Neural Engine compile), 33 MB
  footprint after load. An Apple-engine hold peaked at 41 MB.
- The user dictated about 56 s with Bark and judged accuracy and punctuation very good.
- The entitlement files were empty in the first spike build (XcodeGen writes them only from
  `entitlements.properties`); the App Group must be declared there.
- Installs: the user asks for on-device installs explicitly; the agent builds signed and
  installs with `devicectl` only when asked.

## Risks and how the build handles them

| Risk | Handling |
|---|---|
| Bark pushes the keyboard past its memory limit | Crash marker and Apple-only fallback (above). First on-device check measures footprint with Bark loaded and during a 60 s hold. |
| First Bark load compiles for the Neural Engine inside the keyboard and takes long | Apple stands in while it loads. The compile cache lives in the extension's own container; whether the app's load warms it is unknown and gets measured. |
| `getUserMedia` start latency clips the first word | Open on touch-down; optional warm mic with pre-roll behind a default-off setting. |
| Apple closes the WebKit path | Clear failure message and route to the app; nothing silent. |
| The refactor breaks the Mac app | Mac tests, dictionary vectors and `make install` before any iOS work is called done. |

## Left to the builder

Type and file names not fixed above; the exact tap/hold threshold; PCM encoding and the
JavaScript tap; app navigation structure; whether to port pipelined holds; whether the
open-the-app fallback route ships in v1; the cross-process lock mechanism; the Makefile
targets for generating and compiling the iOS project.

## Done means

0. Spike: both spike targets compile unsigned for `generic/platform=iOS`, `git diff Sources/`
   is empty, and the user's on-device report is recorded in this doc before step 3 starts.
1. Mac: `make test` passes (dictionary vectors included), `make` builds, and the built
   bundle passes `--cleanup-check` and `--incremental-check` (no microphone needed). Output of
   each recorded. `make install` overwrites the daily-use `/Applications/Murmur.app`, so the
   agent asks before running it, and live dictation on the Mac is the user's check.
2. `MurmurKitTests` pass on the Mac, including an import test: a phone zip merges into a
   scratch run log, a duplicate id is skipped, audio lands in `Recordings/`.
3. `ios/` generates with XcodeGen and both iOS targets compile unsigned for
   `generic/platform=iOS`.
4. `AGENTS.md` gains an iOS section: the WebKit capture trick and its fragility, the App Group
   layout, the memory fallback, and how to build.
5. On-device behaviour (capture, Bark in the keyboard, memory) is reported as **unverified**
   until the user runs it on their phone.
