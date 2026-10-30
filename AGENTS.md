# Working on this repo

Read this before changing anything. It is written for a coding agent picking the project up
cold, and it is mostly a list of things that look wrong but aren't, plus things that look
fine and will bite you.

---

## What this is

Push-to-talk dictation. Hold a key, talk, release, and cleaned-up text is typed into
whatever had focus. Two independent implementations:

| | macOS | Windows |
|---|---|---|
| Language | Swift 6 | C# / .NET 10 |
| UI | SwiftUI | Avalonia |
| Speech | Apple `SpeechAnalyzer`, or Parakeet via FluidAudio | Parakeet via sherpa-onnx |
| Cleanup | Rules, S1-mini via MLX, or Apple Intelligence | Dictionary corrections only |
| Location | repo root | `windows/` |

**The macOS app works and is in daily use.**

**The Windows app is complete but has never run on real hardware.** Every layer exists;
CI builds it, runs 63 tests, publishes a single-file executable, launches it on Windows and
confirms the platform layer loads and constructs. What has never happened is a person
holding the key and speaking into a microphone. Describe it that way — not as "working",
not as "unfinished".

---

## The one rule that matters

**`shared/dictionary-test-vectors.json` is the specification for correction behaviour.**

Both implementations run it in CI. If you change how corrections work, change the vectors
first, watch both sides go red, then make them green. Changing one implementation to "fix"
a failing vector without changing the other is how the two silently diverge — and only one
of them can be exercised by hand.

```bash
swift test --filter VectorTests                    # macOS side
cd windows && dotnet test Murmur.CrossPlatform.slnf # Windows side, runs anywhere
```

The Swift copy at `Tests/MurmurDictionaryTests/dictionary-test-vectors.json` is a copy, and
CI fails if it drifts from `shared/`. After editing the shared file:

```bash
cp shared/dictionary-test-vectors.json Tests/MurmurDictionaryTests/
```

---

## Things that look like bugs and are not

**`dotnet build Murmur.sln` fails on macOS** with `NETSDK1073`. Expected —
`Murmur.Platform.Windows` targets `net10.0-windows`. Use `Murmur.CrossPlatform.slnf`, which
omits it; everything else, including the whole UI suite, builds and tests on macOS in about
half a second.

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
and material token; `Components.swift` builds the shared pieces from them. **Views must not
contain literal values.** If a component needs a number that isn't a token, add the token
rather than inlining it.

The direction is **Liquid Glass over neo-brutalism**, in two layers with one job each:

- **Glass is the control layer:** the main window's transport dock and the listening HUD.
  It uses `.glassEffect` with a thin ink outline (`outlinedGlass()`), and content scrolls
  beneath it, which is what makes it read as glass.
- **Brutalism is the content layer:** transcripts, dictionary entries, settings cards. Flat
  opaque fills, a 2 pt ink border, and a hard ink slab offset down-right with no blur
  (`brutalSurface()`). Heavy SF Pro type and uppercase eyebrows.

Rules that are not negotiable:

- **Red means recording.** The record button, lamp, level meter and HUD bars. Nothing else.
- **Yellow means selected.** Every "this one is on" state uses `BrutalButtonStyle(isSelected:)`
  or `ChoiceKeys`: yellow fill, sunk into its shadow, and a check glyph, so selection reads
  without color. Don't invent a second selection treatment.
- **No gradients and no soft shadows.** The only blur is the system's glass material.
- Choices with a handful of options are `ChoiceKeys`, not menus, so the active one is visible
  without opening anything. Long lists (the transcription engine) stay system pickers.

Settings is a tab of the main window (`SettingsPanel`), not a SwiftUI `Settings` scene.
`MainNavigation.shared` owns the selected tab; ⌘, (which replaces the `.appSettings`
command), the dock's gear, the recording notice and the menu bar all call
`MainNavigation.shared.show(.settings)`. Appearance (`Settings.appearance`: system, light,
dark) is applied app-wide through `NSApp.appearance` from `MurmurApp.init`, before any window
exists, so every window and the HUD switch together.

The main window hides its title bar. The paper strip over the traffic lights is sized from
the dock's measured position (`onGeometryChange`), not from the safe area, which the hidden
title bar reported inconsistently. `DashboardHTML` still uses its own older styling.

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

## Windows specifics

The specifics below were expensive to establish and several were found the hard way. Treat
them as load-bearing. Full detail in `windows/README.md` and `docs/PARAKEET-WINDOWS.md`.

**Three pinned versions that break silently at "latest":**

| Package | Pin | Why |
|---|---|---|
| `NAudio` | 2.3.0 | 3.x targets .NET 9+ and will not restore |
| `Avalonia.Headless.XUnit` | 11.3.20 | 12.x requires xUnit **v3**, a different package line |
| `org.k2fsa.sherpa.onnx` | 1.13.5 | Bundles ONNX Runtime — never also reference `Microsoft.ML.OnnxRuntime` |

**Right Alt is AltGr** on German, Polish, UK, Nordic and most Latin-American layouts. Binding
push-to-talk there — and especially suppressing it — breaks typing `@`, `€`, `\`, `|` for
those users. Default is **Right Ctrl**, and the hook **observes without swallowing**: if the
key-down is swallowed and the key-up escapes, the target app believes Ctrl is held forever.

**UI Automation cannot inject text.** `TextPattern` is documented read-only and
`ValuePattern` replaces a whole field rather than inserting at the caret. `SendInput` is the
primary path, not a fallback.

**`Murmur.App` loads the platform layer by reflection, not by reference.** A direct
reference would force the UI onto `net10.0-windows` and you would lose the ability to run it
on your own machine. Two consequences that have already bitten once: the assembly is
invisible to `PublishSingleFile`, so it is published as a loose file beside the exe *and*
resolved by an explicit `AssemblyLoadContext` handler; and the published self-test checks
this, because when it breaks the app starts perfectly and then does nothing at all when the
key is pressed.

**Keep `Murmur.Platform.Windows` logic-free.** Anything living there is code CI cannot
exercise. Retries, debouncing and device-change handling belong in the platform-neutral
projects behind an interface — those target plain `net10.0`, so `CA1416` turns any accidental
Win32 call into a build error.

**CI is the only place the Windows code is compiled.** Warnings are errors and the analyzers
are strict on purpose. `--no-incremental` is mandatory: Roslyn does not re-emit analyzer
warnings on a cached build, so without it the gate proves nothing.

---

## Regex, if you touch the dictionary

The two engines are not identical. Measured across 30 cases, **9 diverged**. Two affect this
code and are handled — don't remove either:

- `RegexOptions.CultureInvariant` on the C# side, or Turkish `İ` matches `i`.
- **NFC normalization on both sides.** macOS returns decomposed strings, so without it an
  accented trigger silently never fires.

Two more are unfixable and simply avoided: ICU folds `ß` to `ss` and .NET doesn't; .NET's `.`
splits surrogate pairs. Stay inside the safe subset — `\b`, `\d`, `\w`, `\s`, character
classes, greedy/lazy quantifiers, alternation, `(?<name>…)`, fixed-length lookbehind,
lookahead, `\p{L}`, and `$1`–`$9` in replacements. Nothing else.

---

## What isn't built

1. **Command Mode** — select text, hold a second key, "make this more formal."
2. **Onboarding** — a first-run window walking through the macOS permissions.
3. **Notarization** (macOS) and **code signing** (Windows). Both apps are unsigned for
   distribution, so Windows users will meet SmartScreen.
4. **An installer** for Windows, and model download from inside the app rather than by
   following `docs/PARAKEET-WINDOWS.md` by hand.

## What no amount of CI can verify

On Windows, nobody has yet held the key and spoken. Specifically unverified:

- Text injection landing in a foreground app — runners have an interactive desktop but
  cannot take the foreground.
- A real microphone: format negotiation, the OS privacy block, unplugging mid-capture.
- The keyboard hook firing on a physical keypress.
- Parakeet transcribing real speech, and whether ~2 GB resident is tolerable.

Everything those feed into is behind an interface and tested with fakes. The bindings
themselves are not. **First real-hardware run should start with `--selftest`, then a single
short dictation into Notepad.**

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
while it isn't on disk (a download is needed); once installed it is `.sleeping` until a press
wakes it (see `ModelResidency` below).

Parakeet v3 is gated the same way as Bark: `requiresPreparedModel` covers `.parakeet`.
`StreamingModelPreparation.loadIfInstalled` loads an on-disk model when the engine is picked,
and at launch only when `Settings.idleUnload` is "never"; it never starts a download.

Holds are pipelined. Each one is an `Utterance` owning its engine, tasks and transcript, so
a press while the previous hold is still finishing starts capture at once. The new hold's
`engine.start()` waits on `engineIdle` (the shared streaming sessions and Parakeet's one
model must not overlap), and delivery waits on `deliveryTail` so text lands in the order
spoken. Compare mode does not overlap. `HotkeyMonitor` takes down/up from the event's
device-dependent modifier bit, never by alternating, and a watchdog polls
`CGEventSource.keyState` to release a hold whose key-up was missed; it only trusts that
reading after seeing the key down once. `RunLog` does all file I/O and dashboard rendering
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
`AudioCapture` pins it with `kAudioOutputUnitProperty_CurrentDevice` on the input node's
AUHAL, then **must** set the node's output-scope stream format to the device's hardware rate:
after a switch the client side keeps the previous rate (44.1 kHz vs the SoloCast's 48 kHz),
the input node can't resample, and `engine.start()` fails with -10868. Devices plugged or
unplugged re-pin while idle, or after the current hold ends. `Murmur --mic-benchmark <file>
[seconds]` measures what an always-open mic would cost; on the M2 it was about 3–3.5% of one
core in `coreaudiod` plus `usbaudiod`, under 1% in Murmur, and about 1 MB of memory.

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

Models are resident only while used (`ModelResidency`). Nothing loads at launch (unless
`Settings.idleUnload` is "never"); a press wakes Bark and S1-mini in parallel with recording,
and after the idle timeout both are released. Installed models never gate recording, only
ones that would need a download. **S1-mini runs in a helper process**: the same executable
with `--s1-server` (`main.swift` branches before SwiftUI starts), speaking line-delimited JSON
over stdin/stdout (`S1MiniServer`, `S1MiniEngine` is the client, `S1MiniRuntime` is the MLX
code). Releasing it in-process left 40–100 MB of fragmented heap that grew with every load;
ending the helper returns all of it. Measured on an M2: app at rest about 52–74 MB, helper
start about 1.4 s, cleanup about 100 ms, Bark reload 0.2–0.5 s.
`Murmur --residency-check <file>` measures this. Builds and tests are CPU-heavy on the
user's Mac: batch edits and run them niced with few jobs.

`AppStorage` imports dictionary/history once without deleting originals or replacing
existing destination files. Its two legacy names are intentional compatibility references.
New runs preserve `processSeconds` and add optional `deliverySeconds`, measured through
AX insertion or posting the paste event, not the target app's rendering. The history UI
uses delivery timing when available. Clipboard restoration remains delayed and conditional
on the pasteboard generation; the fixed pre-paste delay is removed.
