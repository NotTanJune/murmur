# Working on this repo

Read this before changing anything. It is written for a coding agent picking the project up
cold, and it is mostly a list of things that look wrong but aren't, plus things that look
fine and will bite you.

---

## What this is

Push-to-talk dictation. Hold a key, talk, release, and cleaned-up text is typed into
whatever had focus. macOS only: Swift 6 and SwiftUI; speech by Apple `SpeechAnalyzer` or
Bark/Parakeet via FluidAudio; cleanup by rules, S1-mini via MLX, or Apple Intelligence.
It works and is in daily use. (A Windows port in C# lived in `windows/` until 2026-11-03 and
was removed because it will never be used; it is in git history if ever needed.)

---

## The one rule that matters

**`Tests/MurmurDictionaryTests/dictionary-test-vectors.json` is the specification for
correction behaviour.** If you change how corrections work, change the vectors first, watch
them go red, then make them green.

```bash
swift test --filter VectorTests
```

---

## Things that look like bugs and are not

**`swift build` fails with "input file was modified during the build."** The repo lives in an
iCloud-synced folder and the sync engine touches files mid-compile. **Always build with
`make`**, which uses `--scratch-path` outside the synced tree. A bare `swift build` also
writes a `.build/` directory into iCloud, which makes every subsequent build minutes slower.
If you see this error, wait a few seconds and retry.

**Compare mode doesn't type anything.** By design — `Settings.compareMode` runs every engine
on one recording and shows them side by side. If both injected, two transcripts would fight
over one text field. This is the single most confusing behaviour in the app.

**The timing column isn't comparing like with like.** Apple and Parakeet are timed on local
compute with the clock started *after* model load. Wispr Flow's number is its own
`e2eLatency`, which includes a network round trip and its cleanup pass. Don't present them
as one ranking.

**`MainActor.assumeIsolated` will crash the process.** It does not check the claim, it
asserts it. Use `await MainActor.run` from any non-main-actor context. This took the app
down once already.

**Never mutate `@State` inside a `Canvas` draw closure.** It floods the log and corrupts
state. The old VU meter hit this; the current `LevelMeter` avoids `Canvas` entirely and
`PaperBackground`'s `Canvas` draws without touching state. Keep it that way.

---

## Design system

`Sources/Murmur/UI/DesignSystem.swift` defines every colour, size, radius, duration
and motion token; `Components.swift` builds the shared pieces from them. **Views must not
contain literal values.** If a component needs a number that isn't a token, add the token
rather than inlining it.

The direction is modelled on Wispr Flow's desktop hub (the aesthetic, not the brand: no
logo, mark, name or copy). A classical serif over a rounded geometric sans, a cream and
lavender light theme, a warm near-black dark theme, white cards with hairline borders, and
a sidebar beside an inset content pane.

- **Layout:** `MainWindow` is a custom sidebar plus an inset pane on the `chrome` colour,
  not `NavigationSplitView`. The sidebar holds the app name, navigation and the transport
  (record, counter, level, engine, profile, recording notice). The pane has a rounded
  top-leading corner and the appearance toggle above it. The title bar is hidden; the
  sidebar clears the traffic lights with `DS.Window.trafficLightClearance`.
- **Type:** EB Garamond (`display`, `stat`) only for big moments such as the word count and
  empty states; Figtree for everything else; `counter` stays SF monospaced so digits don't
  shift. The TTFs live in `Resources/Fonts/`, the `Makefile` copies them into
  `Contents/Resources/Fonts/`, and `ATSApplicationFontsPath = Fonts` in `Info.plist`
  activates them. There is no code registration. Each `DS.Font` role checks that its face
  resolved via `NSFont(name:size:)` and falls back to SF, so `swift build`, tests and a
  broken bundle still render. Figtree is resolved by PostScript name (`Figtree-Medium`);
  its nameID 1 reads "Figtree Light".
- **Cards:** `cardSurface()` is a flat fill with a hairline stroke. `Card` is an optional
  eyebrow title above one. Lists are one card per group with `divider` lines between rows.

Rules that are not negotiable:

- **Red means recording.** `DS.Color.record` on the record button, lamp, level meter and
  HUD bars. Nothing else.
- **Cream means selected.** Every "this one is on" state uses `FlowButtonStyle(isSelected:)`,
  `ChoiceKeys` or `OptionCard`: `selected` fill, `ink` 1.5 pt stroke and a check glyph, so
  selection reads without colour. Don't invent a second selection treatment.
- **No gradients.** Shadows exist only on floating surfaces (HUD, toasts, popovers) through
  `floatingShadow()`. Cards have none.
- Choices with a handful of options are `ChoiceKeys`, not menus, so the active one is
  visible without opening anything. Long lists (the transcription engine) stay system
  pickers.

Settings is a tab of the main window (`SettingsPanel`), not a SwiftUI `Settings` scene.
`MainNavigation.shared` owns the selected tab; ⌘, (which replaces the `.appSettings`
command), the recording notice and the menu bar all call
`MainNavigation.shared.show(.settings)`. Appearance (`Settings.appearance`: system, light,
dark) is applied app-wide through `NSApp.appearance` from `MurmurApp.init`, before any window
exists, so every window and the HUD switch together. `DashboardHTML` still uses its own
older styling.

---

## macOS specifics

**Code signing is load-bearing, not cosmetic.** TCC stores a code-signing *requirement* per
entry, not just a path. An ad-hoc signature changes every build, so the rebuilt binary stops
satisfying the stored requirement — and the symptom lies: the Accessibility toggle still
shows as **on** while the app is untrusted. The `Makefile` auto-detects a Developer ID via
`security find-identity`. Don't replace that with `--sign -`.

If a grant does get wedged, reset that one row — never toggle, and never omit the bundle ID:

```bash
tccutil reset Accessibility ai.pivotstudio.murmur
```

A bare `tccutil reset Accessibility` wipes every app on the machine. Then quit System
Settings entirely (⌘Q) before reopening; the Privacy pane caches its list.

**`log` may be shadowed in the user's shell.** Use `/usr/bin/log` explicitly.

**Don't run the `.app` from the repo folder.** It's iCloud-synced and the sync engine can
corrupt the signature. `make install` puts the running copy in `/Applications`.

---

## Regex, if you touch the dictionary

**Keep NFC normalization** in `DictionaryCorrector`. macOS returns decomposed strings, so
without it an accented trigger silently never fires.

---

## What isn't built

1. **Command Mode** — select text, hold a second key, "make this more formal."
2. **Onboarding** — a first-run window walking through the macOS permissions.
3. **Notarization.** The app is signed with a Developer ID but not notarized for
   distribution.

## Murmur streaming options and verification

The macOS product, executable, and source target are `Murmur`; the bundle ID is
`ai.pivotstudio.murmur`. Build output lives in `~/Library/Caches/MurmurBuild`.
`make` defaults to release, `make build CONFIG=debug` opts into debug, and `make test`
runs tests with the same external scratch directory. The app regression target is added
on macOS 26 and newer; it exercises the streaming adapter, settings choices, migration,
and timing decoding without downloading recognition models.

FluidAudio remains at the resolved 0.15.6 version. Its actual streaming API supports
Parakeet EOU at 160 ms and Nemotron at 560 ms minimum, not the Nemotron 160 ms option
shown in some indexed documentation. Use `.cpuAndNeuralEngine` for the int8 Nemotron
encoder; the generic factory otherwise supplies a `.all` configuration.

Streaming models (Parakeet EOU, Nemotron) are loaded explicitly from Settings or the menu
bar and retained for the process lifetime; unlike Bark and S1-mini they are not released on
idle. The adapter serializes load, reset, feed, and finish so actor
reentrancy cannot reset a decoder during inference. Release drains queued audio and
flushes the final buffer; partial snapshots are never substituted for final text.
The old comparison mode still compares Apple and Parakeet batch, not the streaming options;
it adds Bark 3.0 Clean only when that model is already loaded.

Bark 3.0 Clean (`SpeechEngineChoice.barkClean`) reuses `ParakeetEngine` with
`ParakeetModels.barkClean`. `BarkModelStore` pins `FluidInference/bark-3.0-coreml` to one
revision and verifies size and SHA-256 per file before publishing the folder. Bark's
components are loaded with `MLModel.load` directly, **not** `AsrModels.load(from:)`: on a
load failure FluidAudio purges the folder and re-downloads stock v3 into it, which would
silently replace Bark with NVIDIA's weights. Keep the ANE `Encoder.mlmodelc`; the repo's
`Encoder_lut3` GPU build measured about 2× slower on an M2. Bark gates recording only
while it isn't on disk (a download is needed); once installed it loads at launch and Apple's
transcriber stands in until it's ready (see `ModelResidency` below).

Parakeet v3 is gated the same way as Bark: `requiresPreparedModel` covers `.parakeet`.
`StreamingModelPreparation.loadIfInstalled` loads an on-disk model at launch and when the
engine is picked; it never starts a download.

Holds are pipelined. Each one is an `Utterance` owning its engine, tasks and transcript, so
a press while the previous hold is still finishing starts capture at once. The new hold's
`engine.start()` waits on `engineIdle` (the shared streaming sessions and Parakeet's one
model must not overlap), and delivery waits on `deliveryTail` so text lands in the order
spoken. Compare mode does not overlap. `HotkeyMonitor` takes down/up from the event's
device-dependent modifier bit, never by alternating, and a watchdog polls
`CGEventSource.keyState` to release a hold whose key-up was missed; it only trusts that
reading after seeing the key down once. That reading needs Input Monitoring (requested at
launch; `CGPreflightListenEventAccess`), and every release logs `keyboard reported the hold:
true/false` so a blind watchdog shows up. On 2026-11-03 WindowServer's own KeyboardEvent log
showed no Right ⌘ release for 27 s while the user had let go, so the session kept ⌘ held and a
trackpad click became ⌘-click before the paste. Active event taps on that Mac (Vorssaint with
keyboard debounce, openlogi-agent) can swallow a key-up. `HotkeyMonitor.releaseIfStuck` posts
the missing key-up when the keyboard says up but the session says held, after a watchdog
release and before every delivery. `RunLog` does all file I/O and dashboard rendering
on one serial queue and publishes snapshots to `RunStore`; keep it off the main actor.
History expires: unsaved runs older than `RunLog.retention` (30 days) are pruned on every
history change, at launch and hourly. `DictationRun.isSaved` (the row's Save chip) exempts
a run; lines written before the field existed decode as unsaved.
The paste fallback marks the transcript transient/concealed for clipboard managers, and
nothing is typed or filed when focus is an `AXSecureTextField`.

Cleanup has three engines (`CleanupEngine`): the rule pass, S1-mini by Superwhisper, and
Apple Intelligence; the old `smartCleanup` bool migrates to Apple Intelligence. S1-mini runs
through `MLXLMCommon` directly, **not** the FoundationModels `MLXLanguageModel` adapter: the
adapter measured the same speed but can't hold a prompt cache, and `S1MiniRuntime` caches each
profile's 69-token prefix (system prompt plus control line), which saved 40–60 ms per
utterance with token-identical output. Keep the system prompt verbatim and the control lines
inside the trained values; the model card warns it hallucinates otherwise, which is why
`CleanupProfile` is a closed enum. `enable_thinking` must be false or it returns nothing.
`S1MiniModelStore` pins commit `88f6b158` (the repo has no `v1` tag despite its card),
verifies size and SHA-256, converts BF16 to 4-bit affine g64 in-app (measured bit-identical
to `mlx_lm.convert`) and deletes the original. The cleanup guard exempts numerals and a short
list of colloquial expansions for S1-mini only. Cleanup never gates recording. A cleanup that
arrives while S1-mini is still loading waits for it (`S1MiniEngine.waitUntilReady`); if the
helper fails or isn't installed, it falls back to the rule pass. `make app` builds with `xcodebuild` because SwiftPM's
command line can't compile MLX's Metal kernels, and copies every SwiftPM resource bundle into
`Contents/Resources`; a missing `mlx-swift_Cmlx.bundle` fails at the first GPU call, and a
missing generated bundle traps in `Bundle.module`. `Murmur --cleanup-check` verifies the
installed bundle end to end without a microphone.

Capture never uses the system default input. `MicrophonePolicy` picks the HyperX SoloCast
when connected, otherwise the built-in mic, and nothing else (no Bluetooth, iPhone or other
USB devices; no allowed mic means recording refuses rather than falling back).
`AudioCapture` records through its own input-only AUHAL (`kAudioUnitSubType_HALOutput`,
output side disabled) with `kAudioOutputUnitProperty_CurrentDevice` set to that mic, and an
input callback that calls `AudioUnitRender`. **Never go back to `AVAudioEngine` for capture.**
Its input node follows the system default input (`AVAudioIONode.h` says so): a device set on
its audio unit is switched back to the default aggregate within about 50 ms whenever the
default is another device. On 2026-11-03, with a Bluetooth headset (16 kHz mono) as the
default, that revert landed between `prepare()` and `start()`, `installTapOnBus` raised an
Objective-C exception for the 48 kHz/16 kHz mismatch, AppKit swallowed it inside a main-actor
`Task`, Swift's executor tracking was left pointing at dead stack, and the next SwiftUI
tooltip hit-test (`MainActor.assumeIsolated`) crashed the app on every launch. The unit's
app-side format is Float32 at the device's own rate and channel count (AUHAL can't resample
input); `AVAudioConverter` takes it to the engine's format. Devices plugged or unplugged
re-pin while idle, or after the current hold ends. `Murmur --mic-benchmark <file>
[seconds]` measures what an always-open mic would cost; on the M2 it was about 3–3.5% of one
core in `coreaudiod` plus `usbaudiod`, under 1% in Murmur, and about 1 MB of memory (measured
with the earlier engine-based capture).

`SystemInputGuard` (on by default, `Settings.keepSystemInput`, Settings → Microphone) also
keeps the **system** default input on the same allowed mic for every app. macOS makes a
Bluetooth headset the default input whenever it connects; the guard listens for changes to
the default and to the device list, moves an unallowed default back, and gives up after 5
corrections in 30 s instead of fighting something else in a loop. It never touches the
default output.

The pinned device has listeners for `kAudioDevicePropertyDeviceIsAlive` and
`kAudioDevicePropertyNominalSampleRate`. While idle a change rebuilds the unit; while
capturing, `restartAfterRouteChange` rebuilds it on whichever allowed mic remains and starts
it again. The engine-based version looped every 2.4 s for 278 restarts on 2026-10-31 after a
Bluetooth headset changed state; the loop breaker (more than 6 restarts in 30 s stops capture
and reports an interruption) stays as a guard.

`Settings.alwaysOpenMic` (default on) keeps capture running between holds. In `beginDictation`
the attach (`openCapture`) must stay the first thing after the utterance is created: the
start sound and `ModelResidency.wake` ran before it once and delayed it by up to 0.67 s,
past the pre-roll, which clipped the start of speech. `CaptureRouter`
sends audio to the attached hold, or between holds into a pre-roll capped at 0.3 s, and a
press attaches with that pre-roll first, so the hold includes the moment before the key
landed. Nothing is stored beyond that in-memory buffer. The controller tracks the running
format as `captureKey`; a release detaches and `syncOpenMicrophone()` keeps, restarts or
closes capture to match the setting, engine and compare mode (observed with
`withObservationTracking`). Off, the mic opens at the press as before.

S1-mini is resident only while used (`ModelResidency`): it waits for the first press
(unless `Settings.idleUnload` is "never") and is released after the idle timeout. **Bark and
Parakeet load at launch and are never released**: they cost about 30 MB resident, and every
reload risks Core ML recompiling the encoder for the Neural Engine, which happened on
2026-10-31 after macOS dropped `~/Library/Caches/ai.pivotstudio.murmur/com.apple.e5rt.e5bundlecache`
and took 157 s at 100% CPU in `ANECompilerService` (the code's "about a minute" is
optimistic). `CompileCacheGuard.ensure()` (first thing at launch, before any model load) keeps the real
folder at `~/Library/Application Support/Murmur/Models/ane-cache` and makes the Caches path a
symlink to it; a purge removes only the link, which the next launch recreates. Measured
loads through the link: 0.3–0.5 s, same as direct, and a deleted link was repaired with no
recompile. It also deletes `*.tmp.<pid>_*.bundle` folders (400 MB each) that killed
compiles leave behind, when their pid is gone. While a batch model is `.loading`, a press is not blocked: `beginDictation`
sets `Utterance.standIn = .apple`, the hold runs on Apple's transcriber with its own input
format, the history row reads "Apple (streaming) · Bark 3.0 Clean (batch) preparing", and
the dock shows a highlighted tag. Only a model that would need a download blocks recording.
 **S1-mini runs in a helper process**: the same executable
with `--s1-server` (`main.swift` branches before SwiftUI starts), speaking line-delimited JSON
over stdin/stdout (`S1MiniServer`, `S1MiniEngine` is the client, `S1MiniRuntime` is the MLX
code). Releasing it in-process left 40–100 MB of fragmented heap that grew with every load;
ending the helper returns all of it. Measured on an M2: app at rest about 52–74 MB, helper
start about 1.4 s, cleanup about 100 ms, Bark reload 0.2–0.5 s.
`Murmur --residency-check <file>` measures this. Builds and tests are CPU-heavy on the
user's Mac: batch edits and run them niced with few jobs.

Long holds no longer pay for their length at release (added 2026-10-31). Three pieces:

- **Incremental Bark/Parakeet** (`IncrementalParakeetEngine`, default via
  `Settings.transcribeTiming = .whileSpeaking`; "On release" keeps the old `ParakeetEngine`
  batch path). It wraps FluidAudio's `SlidingWindowAsrManager` loaded with the **same**
  `AsrModels` the batch engine holds (`ParakeetModels.loadedModels()`), never its no-argument
  `loadModels()`, which would download NVIDIA's weights over Bark's. The manager is single-use
  (its input stream is created in `init`), so one is made per hold. Windows are 11 s with 2 s
  context each side and land about every 11 s; each partial chunk carries `stable`, the text
  of every window so far. The engine composes the transcript itself from the windows
  (`compose(_:adding:)`) instead of taking the recognizer's final string: each window's first
  token says whether it starts a word (Bark's vocabulary marks that with a leading space, not
  "▁"; FluidAudio accepts both and so does this), and three seam rules drop what the 2 s of
  overlap re-decoded: a glued fragment equal to the previous word's ending ("MacBook" +
  "book" typed "MacBookbook" on 2026-11-01), a first word equal to the last word or its
  ending, and a cut-off word that prefixes the next ("blind blindsided"). Windows flushed at
  release go into the final text, never into a partial. Measured on 57 s of synthesized
  speech: release tail 0.10 s against the batch engine's 0.34 s for the whole file. Other
  seam artifacts remain ("All Also", "I think. that's fair"), so the setting stays
  user-visible. Compare mode still uses batch.
  `Murmur --incremental-check <audio-file>` runs both engines on a file at 2× real time.
- **Cleanup pipeline** (`CleanupPipeline`, General profile only): finished sentences from
  `stable` are cleaned while the key is held, at least 12 words per piece, each through the
  normal formatter with its guard, so one rejected piece falls back alone. At release the
  final transcript must still begin with the pipelined words verbatim or the whole text is
  cleaned in one pass. Email, Notes and Message place greetings, bullets and the dropped
  final period from the whole text, so they are not pipelined. Measured: 131-word paragraph,
  release tail 109 ms against 2.1 s whole.
- **Prompt-lookup decoding** in `S1MiniRuntime` (`Decoding.promptLookup`, the default;
  `.greedy` is the reference and `--cleanup-check` runs both). Drafts the next tokens from the
  transcript by n-gram match and verifies them in one pass, rolling the KV cache back with
  `trim`. On an M2 a pass over 1 + k tokens costs about one single-token pass plus a third
  of one per extra token, so the draft length adapts (2…12) and the gain is 1.1–2.2× on short
  texts and about nothing on long paragraphs; the pipeline, not this, is what makes long
  holds fast. Both decoders are greedy but round differently, so a near tie can land either
  way; the check reports that as DIFFERENT without failing.

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

`AppStorage` imports dictionary/history once without deleting originals or replacing
existing destination files. Its two legacy names are intentional compatibility references.
New runs preserve `processSeconds` and add optional `deliverySeconds`, measured through
AX insertion or posting the paste event, not the target app's rendering. The history UI
uses delivery timing when available. Clipboard restoration remains delayed and conditional
on the pasteboard generation; the fixed pre-paste delay is removed.
