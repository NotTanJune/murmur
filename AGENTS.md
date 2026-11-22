# Agent notes for Murmur

This is the briefing for a coding agent new to the project. Most of it covers traps: behaviour that
seems broken but is deliberate, and safe-looking changes that cause real damage.

---

## The project

Murmur is push-to-talk dictation for macOS, built with Swift 6 and SwiftUI. A held key records, and
on release the cleaned-up text goes into the focused app. Speech comes from Apple `SpeechAnalyzer`
or from Bark and Parakeet through FluidAudio. Cleanup comes from rules, S1-mini through MLX, or Apple
Intelligence. The app is in daily use. A Windows port in C# lived in `windows/` until 2026-11-03; it
was removed for good and remains in git history. An iPhone app and a dictation keyboard live in
`ios/` (see "iOS keyboard" below).

---

## Start with the dictionary vectors

`Tests/MurmurDictionaryTests/dictionary-test-vectors.json` defines correction behaviour. For any
change to how corrections work, edit the vectors first, see them fail, then make them pass.

```bash
swift test --scratch-path ~/Library/Caches/MurmurBuild/scratch --filter VectorTests
```

---

## Deliberate behaviour that can look like a bug

**"input file was modified during the build" from `swift build`.** Build with `make`, which keeps
all output in `~/Library/Caches/MurmurBuild`. In a synced folder the sync engine changes files
while the compiler reads them, and a bare `swift build` also fills a `.build/` directory that the
engine then has to process. If the error appears, retry after a few seconds.

**Compare mode types nothing.** `Settings.compareMode` sends one recording through several engines
and lists the results together. Injecting from each would put competing transcripts into one field,
so none of them inject.

**Compare timings are not one ranking.** Murmur's engines are timed on local compute, and the clock
starts once the model is loaded. Wispr Flow reports its own `e2eLatency`, which covers a network
round trip plus its cleanup.

**`MainActor.assumeIsolated` can crash the process.** It asserts isolation without checking first.
From non-main-actor code, use `await MainActor.run`. This bug has taken the app down before.

**Never mutate `@State` inside a `Canvas` draw closure.** It floods the log and corrupts
state. The old VU meter hit this; the current `LevelMeter` avoids `Canvas` entirely and
`PaperBackground`'s `Canvas` draws without touching state. Keep it that way.

---

## Design system

`Sources/MurmurDesign/DesignSystem.swift` defines every colour, size, radius, duration
and motion token; `Components.swift` builds the shared pieces from them. **Views must not
contain literal values.** If a component needs a number that isn't a token, add the token
rather than inlining it.

The direction is ink on paper: a warm paper ground, charcoal ink, an ochre accent, moss for
statistics, Fraunces for big moments over Figtree for everything else, white cards with
hairline borders, a sidebar beside an inset content pane, and a warm near-black dark theme.

- **Layout:** `MainWindow` is a custom sidebar plus an inset pane on the `chrome` colour,
  not `NavigationSplitView`. The sidebar holds the app name, navigation and the transport
  (record, counter, level, engine, profile, recording notice). The pane has a rounded
  top-leading corner and the appearance toggle above it. The title bar is hidden; the
  sidebar clears the traffic lights with `DS.Window.trafficLightClearance`.
- **Type:** Fraunces (`display`, `stat`) only for big moments such as the word count and
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

## macOS notes

**The signing identity has to stay stable.** TCC saves a code-signing requirement for each entry,
so a matching path is not enough. Ad-hoc signatures differ per build, so a rebuilt app no longer
meets the saved requirement, and the Accessibility toggle then shows **on** while the app is
untrusted. The `Makefile` finds a Developer ID through `security find-identity`. Keep that, and do
not switch to `--sign -`.

To clear a stuck grant, reset that single entry with its bundle ID. Toggling does not fix it:

```bash
tccutil reset Accessibility ai.pivotstudio.murmur
```

Leaving out the bundle ID resets Accessibility for every app on the Mac. Afterwards press ⌘Q in
System Settings before reopening it, because the Privacy pane keeps a cached list.

**Use `/usr/bin/log` by full path.** The user's shell may define its own `log`.

**Run the installed app, not a build in the repo.** A sync engine can break the signature of a
bundle inside a synced folder. `make install` copies the app to `/Applications`.

---

## Dictionary regexes

**Keep NFC normalization** in `DictionaryCorrector`. macOS returns decomposed strings, so
without it an accented trigger silently never fires.

---

## License and provenance

Murmur's source is GPL-3.0-only (`LICENSE`). The fork parent, `per-simmons/murmur-youtube`, has no
license, so its code was replaced from behaviour specs on 2026-11-06 and older commits are not covered
by the GPL grant. Never restore or copy code from those commits or from that repository. Third-party
terms live in `THIRD_PARTY.md`.

---

## Tried and not kept

**FluidAudio's vocabulary rescoring** (`VocabularyBoostingSession`, a Parakeet CTC 110M pass
that swaps transcript words for dictionary terms the audio fits better). Measured on
2026-11-13 over 82 recordings cut into 161 stretches, with the dictionary's 94 terms and
default thresholds: it changed 99 stretches and made 196 replacements, about 20 of them
right ("Kelpy" to "Kelpie", "Erickson" to "Ericsson", "excalibra" to "Excalidraw") and the
rest wrong ("not" to ".NET" eight times, "model" and "context" to "Codex", "app" to "API",
"run" to "Bun"). It did not recover "NUS" from "in U S", and cost 0.21 s per stretch. The
right ones are names a dictionary correction already fixes. Short terms that sound like
common words are what break it, so a retry would need a list of long, distinctive names only
and its own measurement.

**Fluid Speech Pro** (FluidVoice, `FluidVoice-Labs/fluid-speech-pro-coreml` at `3b9d38a9`,
a Parakeet v3 fine-tune, CC BY 4.0). Measured on 2026-11-20 with `bench/` over 173
recordings (63.8 min, 29 corrected), S1-mini General. Typed word errors against the
corrections: Bark 1.29%, Parakeet 3.14%, Fluid 3.26% paced; at 5 dB babble plus pink noise
Bark 11.99%, Parakeet 11.10%, Fluid 8.62%. Release to typed median 273, 326 and 340 ms. It
heard the same as stock Parakeet on 118 of 173 recordings, returned nothing for "Yeah.",
"No." and "Okay.", and its Core ML build has no clean mode, so fillers reach the cleanup.
Better only in noise; the model was deleted.

**Clear** (Desert Ant Labs speech enhancement, a fine-tuned DeepFilterNet 3, SDK
`desert-ant-core` v4.3.0, model v0.3.0) in front of recognition. Measured on 2026-11-21 with
`bench/` as a `preprocess` candidate over 175 recordings, Bark Clean streaming, S1-mini
General, loudness mastering bypassed. Typed word errors against the corrections, current /
`clear-natural` / `clear-studio`: 3.99 / 10.02 / 11.02% clean, 1.29 / 9.80 / 10.91% paced,
11.13 / 40.16 / 40.90% at 5 dB babble plus pink noise. Release to typed median 270, 353 and
365 ms; Clear itself 67 ms a clip. It returned nothing for "Okay.", "No." and "And she said.".
It is tuned for podcast sound, not recognition, and keeps babble because babble is speech.
Its licence (Desert Ant Labs Source-Available 1.0) is not GPL-compatible and its SDK checks
in with `events.desertant.com` on every model load. Everything was deleted.

## Benchmarking models

`bench/` (see its README) runs candidate models against the current setup, which it reads
from the installed app's Settings at run time, so adopting a model makes it the next
baseline. It is a `swift test` target that imports the app's code and is skipped without a
job file; it never ships in the app. Three seams in the app serve it and nothing else:
`ParakeetModels.Source.folder` (a Parakeet v3-layout folder, never downloads);
`MURMUR_S1_HELPER`, which points `S1MiniEngine` at the installed app's binary because a test
process has no `--s1-server`; and `MURMUR_SETTINGS_DOMAIN`, which points `Settings.shared` at
a copy of the app's domain, because the test process's own domain holds values earlier tests
wrote (it said `engine = apple` on 2026-11-20). Core ML would not reuse the app's compiled
models from the test process, so the runner keeps its own cache under `Benchmarks/ane-cache`
and must never be linked to the app's. Fetch candidates with `bench/fetch.py`, which pins
and verifies every file.

## Bark Clean against Parakeet v3

Measured on 2026-11-13 over 85 recordings (28.6 min, 27 corrected), S1-mini General, paced:

- **Speed is the same.** One architecture, one conversion: 49.7 s against 49.6 s of decoding
  for all of it. Release to typed text, median 247 ms for Bark and 279 ms for Parakeet (322
  against 443 ms on holds over 30 s), because Parakeet hands the cleanup more words.
- **Parakeet returns nothing for some short utterances.** "Yeah." twice, "Okay." and "One
  thousand fifty nine." came back empty, streaming and on release alike. Bark typed all four.
- **Parakeet is verbatim and the cleanup hides most of it.** It heard 116 fillers and typed
  none. False starts and "like" mostly survive, and once S1-mini cut a clause of 13 words
  that began with one.
- **Names are level once the dictionary has run.** Of 29 names and acronyms the corrections
  fixed, Parakeet heard 17 as written and Bark 1; typed, both got 23. Parakeet alone wrote
  "Playwright", "unslop" and "NUS"; Bark alone wrote "Jev", "compaction" and "NTU".
- Against the corrections Bark's typed text has 31 word errors in 2,495 and Parakeet's 86,
  but the corrections are edits of Bark's own text, so that count favours Bark. By place, 21
  differences are shared, Bark has 9 more (6 mishearings) and Parakeet 33 more: 7 are
  spelling ("workflow", "database"), 15 are words kept or cut around a false start, and 11
  are mishearings ("dry" for "drive", "n to" for "NTU", "writed").

These numbers give no reason to move the default off Bark. Its fine-tune is what drops
fillers and keeps one-word answers, and those are what a switch would lose.

## Shared code

`Package.swift` has three library products besides the Mac executable. `MurmurKit` holds what
the Mac and the iPhone both run: the text pipeline (`TextFormatter`, `TranscriptRepair`,
`CleanupPipeline`, `TranscriptFinisher`), the Bark and Parakeet engines and window seams,
`Settings`, `RunLog`, `RecordingStore`, the training export and import, and `CrashMarker`.
`MurmurDictionary` is the corrector and `MurmurDesign` is the design system. Pieces that exist
only for macOS input stay in `Sources/Murmur`: the hotkey, capture, injection, the main window,
S1-mini and its helper, and the check commands.

`MurmurEnvironment` says where storage and settings live. The iPhone app and keyboard call
`MurmurEnvironment.configure` (through `PhoneEnvironment.configure()`). **The Mac's `main.swift`
never does.** Unconfigured, the Mac uses `Application Support/Murmur` and the standard defaults,
or the suite named in `MURMUR_SETTINGS_DOMAIN`; configuring it would defeat that seam and the
`bench/` runner with it. `configure` must run once, before anything reads `Settings.shared` or a
store, because they pin the first answer; a second or late call is logged as a fault and trips
an assertion in debug builds.

Settings → Training on the Mac has an "Import from iPhone" button (`TrainingImport`). It unzips
an export from the phone with `/usr/bin/ditto`, which iOS does not have, and merges the runs
into the Mac's history and recordings.

## iOS keyboard

Added 2026-11-22. `ios/project.yml` is an XcodeGen spec for two targets: `MurmurPhone`, the app
(tabs Setup, History, Dictionary and Settings), and `MurmurKeyboard`, the keyboard extension it
embeds. The deployment target is iOS 26.0. The keyboard is dictation only: a talk key, a
history panel, punctuation and number pages, space, delete, return, globe, hide and an emoji
panel. It has no letters. S1-mini never runs on the phone, so the rule pass and Apple
Intelligence are its cleanup engines, and the phone defaults to Bark Clean where the Mac
defaults to Apple.

**Capture runs in WebKit, and Apple may close the path.** A keyboard extension cannot record:
it lacks the entitlement, so `AVAudioEngine` and audio queues fail inside it. A `WKWebView` in
the keyboard's own view hierarchy can still call `getUserMedia`, because WebKit records in its
own media process under the containing app's microphone permission. `WebMicrophone` hosts a
1x1 web view, and its page posts base64 Float32 samples back over a script message handler.
Several details are load-bearing:

- The view stays in the hierarchy at `alpha` 0.01. Hidden or removed, WebKit throttles it.
- The page loads from `https://murmur-keyboard.invalid/`, which is never fetched; the https
  origin only gives `getUserMedia` its secure context.
- The `AudioContext` is created when capture starts and not before: creating one can take
  audio focus or move a Bluetooth route while the keyboard is merely on screen.
- The page reports the context's own rate, which was 48 kHz in the spike and can arrive at
  other rates, for example a Bluetooth headset's 16 kHz. `PCMConverter` resamples to the
  engine's format, so nothing assumes a rate.
- **Heartbeat dead-man's switch.** Swift calls `murmurHeartbeat()` every second, and the page
  ends capture if none arrives for 3 s. A keyboard that froze or was killed does not leave the
  microphone open.
- `start()` ends with a reason if no audio message arrives within 3 s (Full Access off, or the
  app's microphone permission missing). The deadline is cancelled by the first `audio`
  message, not by the page's `started`, so a context that starts and delivers nothing fails too.
  The page also ends on a track ending, the `AudioContext`
  leaving `running`, an interrupted audio session or `pagehide`, and a terminated WebKit
  content process ends capture and reloads the page. Every failure reaches `onEnded` with a
  reason; nothing is swallowed, because a silent failure here looks like a dead key.
- The keyboard needs `RequestsOpenAccess` (Full Access) in its `Info.plist`; without it the
  "no audio within 3 s" deadline is what the user sees.

The technique was shown by Raycast in November 2026. `stephancill/ios-keyboard-dictation` and
Hex's keyboard (both MIT) were read for it; the code here is Murmur's own, as the provenance
rule above requires. Do not paste from either.

**Spike results** (2026-11-22, iPhone 15 Pro, iOS 27.2.1, from a throwaway target that has
since been deleted): WebKit capture ran inside the keyboard at 48 kHz. Bark Clean's first load
took 84.8 s (the Neural Engine compile) and left a 33 MB footprint; an Apple-engine hold peaked
at 41 MB. About 56 s of dictation with Bark read as accurate with good punctuation. That is one
device and one run. The real keyboard's memory with Bark loaded during a long hold has not been
measured.

**App Group layout.** Both targets declare `group.ai.pivotstudio.murmur`. `PhoneEnvironment`
points `MurmurEnvironment` at `Library/Application Support/Murmur` inside that container and at
a `UserDefaults` suite of the same name, and registers `engine = barkClean` as a default (a
stored choice wins). **`PhoneEnvironment.configure()` must be the first statement in both entry
points** (`MurmurPhoneApp.init` and `KeyboardViewController.init(nibName:bundle:)`), followed by
`RunLog.prepare()`. The keyboard's controller can be made more than once in one process, so a
repeat call is a no-op in `PhoneEnvironment`. Unsigned builds and a missing entitlement fall
back to the process's own Application Support, so the app and keyboard then see different
folders; the Setup tab reports `PhoneEnvironment.isShared`. Besides the Mac's files, the shared
root holds `bark-loading` (the crash marker) and `keyboard-status.json` (`KeyboardStatus`,
which the keyboard writes at each appearance and Bark state change and the Setup tab reads).
Without Full Access the keyboard has no shared container, so its status never reaches the app:
Setup shows "Not reported yet" with a hint to turn on Allow Full Access, and the "Full Access
off" branch is defensive.

**Settings are re-read, not cached.** The app and the keyboard share a `UserDefaults` suite but
not memory, and `Settings.shared` is a snapshot built in `init`. A keyboard that stays alive
would keep the values it launched with (`keepRecordings` after the app's Training toggle turned
it off, the engine, cleanup and timing). `Settings.reloadFromDefaults()` re-reads every key,
assigns without writing back and does not call `onAppearanceChange`; the keyboard calls it at
the top of `keyboardAppeared` and at the start of each press. A press also re-evaluates Bark when
the engine setting changed: leaving Bark reports `off` (a loaded or loading model stays in
memory), and returning to it reports the earlier load's state or starts one. The keyboard also
calls `DictionaryStore.reload()` at each appearance, because a keyboard that ran before the app
first launched has no working watcher on a dictionary file the app seeds later.

Entitlements are declared under `entitlements.properties` in `project.yml`, and XcodeGen writes
the checked-in `.entitlements` files from it. Left out, the files come out empty, which happened
in the spike's first build and drops the App Group. `ios/Local.xcconfig` (the signing team), the
generated `Murmur.xcodeproj` and the two `Info.plist` files are git-ignored.

**The run log has two writers.** The keyboard and the app both write `runs.jsonl`. Every change
runs under `NSFileCoordinator`, first re-reads the file if the other process changed it, then
applies itself, then posts the Darwin notification `ai.pivotstudio.murmur.runs-changed` only
when the change wrote to the file;
`RunLog.prepare()` observes it and reloads. The notification carries no sender, so a process
hears its own writes and reloads an unchanged file. An append is coordinated for merging and a
rewrite with no options; both exclude other writers. If coordination is refused the change is
applied anyway and logged, because losing a dictation from history is worse than an
uncoordinated write. Runs from the phone carry `source = .phone`.

**The crash marker.** iOS kills a keyboard that uses too much memory, with no callback. If Bark
was the cause, loading it on the next appearance would kill the keyboard every time.
`KeyboardDictation` therefore arms `CrashMarker` (the `bark-loading` file) before Bark loads,
and:

- disarms it after a Bark hold has been typed and recorded;
- disarms it when the load finishes while the keyboard is hidden, because nothing else would
  clear it;
- disarms it when the keyboard goes away after Bark has loaded, but only if this process armed
  it;
- disarms it when the load throws;
- **leaves it armed** if the keyboard goes away mid-load, since the load is the riskiest window.

A marker already armed at launch (`wasArmedAtLaunch`) means the last process died loading Bark.
`KeyboardEngineChoice` then picks Apple's transcriber, the history row names the engine as
Apple with Bark "stopped last time", and the marker stays armed until the Setup tab's "Try Bark
again" button clears it. Do not clear it from the keyboard: the next launch would load Bark
into the same kill. `wasArmedAtLaunch` is a per-process snapshot, so at each appearance the
keyboard also asks `CrashMarker.isArmed`, which reads the file now: if this process did not arm
the marker and the file is gone, the app cleared it, and Bark is allowed again (subject to the
engine setting) with the real state reported. The Setup tab treats the marker as a death only
when the keyboard's last reported Bark state is not `loading` or `ready`, or when it says
`loading` but its `lastSeen` is older than `SetupStatus.loadingStaleAfter` (2 minutes), which is
a keyboard that died mid-load. Bark does not gate a press. While it loads or
is not downloaded, Apple's transcriber takes the hold, as `Utterance.standIn` does on the Mac.

**Holds.** Touch-down starts recording at once. A quick tap locks recording on and the next tap
ends it; a long touch is a hold and ends on release (`HoldGesture`). A hold ends by itself at
`KeyboardDictation.maxHoldSeconds` (300 s) and finishes as if the key had come up, because the
engine, the recording and the run log each keep a copy of the audio in memory. A hold still in
flight when the keyboard disappears is abandoned: nothing is typed and no run is filed. A press
is ignored while the last hold finishes or its engine is being wound down, and the key dims to
say so. If a release's finish or an abandon's teardown has not completed
`KeyboardDictation.teardownTimeoutSeconds` (20 s) later, a watchdog logs a fault, drops the hold,
clears the busy state and writes nothing (no text, no run); a stuck engine would otherwise leave
the key dead for the life of the process. Holds are not pipelined on the phone. A hold uses
`CleanupPipeline` only with Apple Intelligence on and the General profile, fed with the engine's
stable text as on the Mac. A failed hold shows "Microphone unavailable" with an "Open Murmur"
button when the microphone is the cause and "Dictation failed. Try again." otherwise; the cause
goes to the log, not onto the key. The history panel lists the newest 30 runs.

**The key is a HUD, with no text.** While recording, the main key becomes the Mac's HUD: a dark
capsule with red `Waveform` bars that follow the input level. The user removed the live words
that briefly showed on it on 2026-11-22. Do not bring them back.

**Building.** Output goes under `~/Library/Caches/MurmurBuild/ios`, never the repo.

```bash
make ios-project   # XcodeGen: ios/Murmur.xcodeproj and the two Info.plists
make ios-build     # unsigned, generic/platform=iOS, both targets, no simulator
make ios-install   # Release, signed with ios/Local.xcconfig, installed on the first physical iPhone
```

`ios-build` (Debug) is the check an agent runs; `ios-install` builds Release and installs from
`Release-iphoneos`. **Run `ios-install` only when the user asks.** It
installs on their phone and needs the phone unlocked and trusted. Never use a simulator. What
the keyboard does on a device (capture, Bark's memory, the marker) is unverified until the user
runs it, and a report should say so. `swift Tools/makeicon.swift --ios <file.png>` writes the
iPhone icon, which lives at `ios/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png`.

## Not built yet

1. **Command Mode.** Holding a second key over selected text would rewrite it on request, such as
   "make this more formal."
2. **Onboarding on the Mac.** A first-run window would walk through the macOS permissions. The
   iPhone app already has this as its Setup tab.
3. **Notarization.** The app is signed with a Developer ID but not notarized for
   distribution.
4. **Automatic profiles.** The cleanup profile is chosen by hand, not from the focused app.
5. **Letters on the iPhone keyboard.** It has the talk key and no letters.

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
device-dependent modifier bit, never by alternating, and a watchdog releases a hold whose
key-up was missed; it only trusts a source after that source has seen the key down once.
It has two sources: `PhysicalKeyWatcher`, which reads the key's own element from the
keyboards' HID reports (below every event tap, matched to that one usage so no other key
reaches the process), and `CGEventSource.keyState`. The second alone read "up" through
every hold checked on 2026-11-13, so the watchdog had never been able to fire. Reading the
keyboards needs Input Monitoring, and `Permissions.hasInputMonitoring` asks IOKit
(`IOHIDCheckAccess`), whose answer decides whether the keyboards open. On 2026-11-13 it said
yes and they opened, although the system's permission database listed only Accessibility
for Murmur; why the key table read "up" regardless is not known. Every release logs `keyboard reported
the hold: true/false (device, key table, devices open)` so a blind watchdog shows up; false
with devices open means no keyboard sends that key (it is produced by another app). On 2026-11-03 WindowServer's own KeyboardEvent log
showed no Right ⌘ release for 27 s while the user had let go, so the session kept ⌘ held and a
trackpad click became ⌘-click before the paste. Active event taps on that Mac (Vorssaint with
keyboard debounce, openlogi-agent) can swallow a key-up. `HotkeyMonitor.releaseIfStuck` posts
the missing key-up when the keyboard says up but the session says held, after a watchdog
release and before every delivery. `RunLog` does all file I/O and dashboard rendering
on one serial queue and publishes snapshots to `RunStore`; keep it off the main actor.
The three interface sounds play through `Sounds` on a queue of their own: `NSSound.play()`
held the main thread for 0.22 to 0.30 s on every press, ahead of the model wake and the
engine start. `TextInjector` remembers for ten minutes an app that refused an accessibility
insert (`PasteOnlyApps`) and pastes there directly.
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
list of colloquial expansions for S1-mini only. Cleanup never gates recording. In the General profile an utterance
of three words or fewer takes the rule pass alone (`S1MiniFormatter.rulesSuffice`): the model
costs 0.11 to 0.20 s there and rewrote "NUS." as "Nus.". A cleanup that
arrives while S1-mini is still loading waits for it (`S1MiniEngine.waitUntilReady`); if the
helper fails or isn't installed, it falls back to the rule pass. `make app` builds with `xcodebuild` because SwiftPM's
command line can't compile MLX's Metal kernels, and copies every SwiftPM resource bundle into
`Contents/Resources`; a missing `mlx-swift_Cmlx.bundle` fails at the first GPU call, and a
missing generated bundle traps in `Bundle.module`. `Murmur --cleanup-check` verifies the
installed bundle end to end without a microphone.

`TranscriptRepair` (added 2026-11-08) runs under every cleanup engine and fixes three habits of
Bark's decoder measured on the run log. At a short pause Bark writes a period and leaves the
next word lowercase (123 times against 208 real sentence ends it capitalised itself, in batch
and streaming alike, so it is the model and not the window seam); `dropPausePeriods` removes a
period between a word of two or more letters and a lowercase word, sparing spelled letters,
"e.g.", "etc.", "vs.", ellipses and decimals. It runs in the rule pass before capitalisation
and on the input to S1-mini and Apple Intelligence, which otherwise capitalise the word.
`CleanupPipeline` likewise does not cut a piece at such a period. Bark Clean never writes
digits, and S1-mini writes them only sometimes on Bark's already-punctuated text, so
`writeNumerals` runs after every engine: ten and above and every multi-word number become
digits with thousands separators (`six thousand` → `6,000`), `point` makes a decimal, two
tens-groups read as a year or model number (`twenty twenty-six` → `2026`, `ten eighty` →
`1080`), a bare string of digits stays a string (`one two three` → `1 2 3`), and a lone word
under ten stays a word unless `to`, `through` or `or` joins it to a number that converted
(`six to eleven` → `6 to 11`). Ordinals and anything the grammar does not recognise stay as
spoken. Bark also spells acronyms out in three styles ("m. c. p.", "N T U", "x y z"), and
S1-mini then wrote "M.C.P.S." or "H-T-M-L"; `joinSpelledLetters` (2026-11-13) joins a run of
two or more into one uppercase word before the pause periods are dropped, in the rule pass
and on the input to both models. A bare "a" or "I" joins only beside bare letters, a
lowercase "s" closing a dotted run of four or more is a plural ("MCPs"; three letters
ending in "s" are an acronym, as in NUS and AWS), and "i. e." and "e. g."
are left alone. Dictionary triggers written as spaced letters ("C L I") still match the
joined word, because the corrector allows nothing between trigger words. Apple Intelligence's guard counts digits as invented words, so numerals come after it.
Pause-stutter repeats ("where. Where the", "Then, then") are left alone: without the audio
they cannot be told from a real sentence start, and they are what the decoder fine-tune is for.

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
  batch path). Its recognizer is Murmur's own `OverlapWindowRecognizer`, an `AsrManager`
  loaded with the **same** `AsrModels` the batch engine holds (`ParakeetModels.loadedModels()`),
  never a no-argument `loadModels()`, which would download NVIDIA's weights over Bark's. A
  window is 2 s of earlier audio, an 11 s centre and 2 s of later audio (15 s, the model's
  input), decoded on its own from a fresh decoder state through the public
  `AsrManager.transcribe`, exactly as the batch engine decodes a 15 s clip, so a window's
  text depends only on its samples. `WindowSeam.join` joins consecutive windows on a word
  both decoded within a second of the boundary between their centres (aimed half a second
  past it, where the earlier window still has 1.5 s of audio ahead), taking everything
  before that word from the earlier window and the rest from the later one; with no word in
  common it cuts by time on word midpoints. Words within a second of the next boundary are
  held back, so `stable` never changes. At release the audio left over (2 to 13 s once any
  window has been decoded) is one last window. **Do not go back to FluidAudio's
  `SlidingWindowAsrManager`.** It decodes each window to its last sample, keeps that text and
  removes the next window's copy as a duplicate, and Bark closes audio that stops mid-speech
  with the half word it heard plus a period, so the kept copy was the broken one:
  "inference.ringement", "act.tions", "to. do" (26 in 27 labelled runs, 2026-11-08 to
  11-13), and at release it cut again at every 11 s of leftover with no later audio, which
  put one in the last seconds of nearly every long hold. Replayed on 78 recordings
  (27 min) on 2026-11-13: 8 glued tokens before, none after, and every window-end period
  gone; word error against the 27 labels 4.09% before, 3.69% after, batch 4.28%. Release
  tail on a 22.8 s clip 0.18 s (0.24 s before). The engine's old seam rules
  (`compose`, "MacBookbook") went with the old recognizer. Compare mode still uses batch.
  `Murmur --incremental-check <audio-file>` runs both engines on a file at 2× real time;
  `--fast` skips the pacing and gives the same text.
- **The last window is decoded at a pause** (`OverlapWindowRecognizer.anticipate`, added
  2026-11-13). The key comes up a median 0.50 s after the talking stops (81 recordings), so
  once the audio has been quiet for 0.26 s the audio so far is decoded exactly as release
  would decode it; if the key then comes up with only silence in between, that text is the
  result and release decodes nothing. Speech after the pause discards it. Silence is judged
  against the hold itself: the room is the quietest 0.2 s so far, speech the 95th percentile
  of 20 ms levels, and without a tenfold range between them the early decode stays off. Do
  not loosen that: an earlier rule (three times the 10th percentile) took the first 0.4 s of
  a quiet 0.8 s recording for the whole of it and typed "Yeah." for "Okay.". Bark's wording
  shifts a little with how much trailing silence it is given, in either direction, so an
  early decode is not word-for-word the release decode; `--incremental-check --fast` with and
  without `--no-anticipation` is the comparison to rerun after any change here.
- **Cleanup pipeline** (`CleanupPipeline`, General profile only): finished sentences from
  `stable` are cleaned while the key is held, at least 12 words per piece, each through the
  normal formatter with its guard, so one rejected piece falls back alone. A piece is
  never cut on a period that is the last stable word: what follows is not known yet, and
  cutting there typed "to. Do" at a pause. At release the
  final transcript must still begin with the pipelined words verbatim or the whole text is
  cleaned in one pass. Email, Notes and Message place greetings, bullets and the dropped
  final period from the whole text, so they are not pipelined. Measured on an idle M2:
  131-word paragraph, release tail 270 ms against 2.3 s whole (2026-11-06; an earlier run
  measured 109 ms against 2.1 s). Under heavy load from other apps the same text took 5 to
  7 s, which is why the S1-mini budget adapts to measured throughput (see `S1MiniEngine`).
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
dictionary hit) with unexported audio outlives the 30 days. A label is always what was said,
in Bark's form. On a rules-cleaned run the history edit starts from the typed text and the
row then shows the correction. S1-mini and Apple Intelligence rewrite, so their rows are
corrected against `rawText` (`TrainingLabel.editBase`): the editor opens on what Bark heard
under a "Heard" eyebrow, and once corrected the row shows the correction with a Labelled tag
(a row that reverted to the typed text read as the edit being lost). The row's copy button
copies what the row shows, `TrainingLabel.displayText`. Until
2026-11-09 those rows had no edit at all, which left the loop dead with S1-mini on (11 of 14
recorded runs could not be labelled). A model-cleaned run without `rawText` stays uneditable. Settings → Training exports
`Training/export-<date>.zip` (`TrainingExport`), and installs a fine-tuned decoder + joint
pair (`CustomDecoderSlot`, verified by size and SHA-256 and by `baseRevision ==
BarkModelStore.revision`; a folder with an encoder is refused). `loadBarkClean(slot:)` loads
the pair from the slot and the encoder from stock, so a switch is a 0.3 s reload with no
Neural Engine recompile. `training/finetune_local.py` (2026-11-13) runs the same fine-tune on the Mac's CPU from the
run log in place, in three stages (`prepare`, `train`, `export`), and marks nothing as
exported. It cuts recordings into segments of at most 14 s, because the transducer loss on a
90 s recording needs about 11 GB, and builds each segment's target as the stock model's own
text with only the user's edits laid over it: the untouched words of a correction are the
old streaming engine's wording and would teach noise. `export --stock` plus
`--decoder-check` proved the Core ML conversion (0 words differing). The first run, on 27
corrected recordings, exported nothing: the model either barely moved or memorised
(`training/README.md` has the table). The stock joint's `token_prob` is the softmax
probability of the chosen token, not the raw logit the notebook used to write.
`training/bark_decoder_finetune.ipynb` is the Colab side; its Core ML
export cells must be checked against the stock package's `metadata.json` on the first run, and
`Murmur --decoder-check <slot> <audio>` is how.

`AppStorage` imports dictionary/history once without deleting originals or replacing
existing destination files. Its two legacy names are intentional compatibility references.
New runs preserve `processSeconds` and add optional `deliverySeconds`, measured through
AX insertion or posting the paste event, not the target app's rendering. The history UI
uses delivery timing when available. Clipboard restoration remains delayed and conditional
on the pasteboard generation; the fixed pre-paste delay is removed.
