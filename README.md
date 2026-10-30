# Murmur

Push-to-talk dictation for macOS. Hold a key, talk, release — cleaned-up text lands in
whatever text field has focus. A Wispr Flow-shaped app, built native and fully on-device.

**Status:** working. Builds, launches, arms the hotkey, transcribes, cleans up, injects.

---

## Coexisting with another dictation app

This app is built to run alongside other dictation tools without colliding with them, which
is not automatic on macOS and is worth understanding before changing anything:

- **Bundle ID `ai.pivotstudio.murmur`** — TCC keys Accessibility and Microphone
  grants to the bundle ID, so granting or revoking a permission here has no effect on any
  other app, and vice versa.
- **Executable `Murmur`** — distinct enough that `pkill -x Murmur` cannot
  match a differently-named binary. The `Makefile` only ever targets `$(EXEC)`.
- **Hotkey is configurable** (Right ⌥ / fn / Right ⌘) precisely because another tool may
  already own the key you'd reach for first. The global monitor inspects only its own keycode
  and passes everything else through untouched.

If you run more than one dictation app, give each a different push-to-talk key. Two apps on
the same key both record, and whichever injects text will fight the other.

---

## Quick start

```bash
make install     # builds, bundles, signs, copies to /Applications, launches
```

Then grant two permissions. Neither is optional, and neither can be requested silently:

| Permission | Where | Needed for |
|---|---|---|
| **Accessibility** | System Settings ▸ Privacy & Security ▸ Accessibility | Global key monitoring and the AX text insert |
| **Microphone** | Prompted on first dictation | Audio capture |

Restart Murmur after granting Accessibility. Then hold **Right ⌥** and talk.

On first launch, Murmur copies the tracked starter vocabulary from
`Resources/default-dictionary.txt` into
`~/Library/Application Support/Murmur/dictionary.txt`. Existing dictionaries,
including empty ones, are never replaced. Edit entries in the Dictionary panel or choose
**Reveal Dictionary File** from the app menu.

### Why grants survive rebuilds here

TCC stores a *code-signing requirement* per entry, not just a path. An ad-hoc signature
changes on every build, so the rebuilt binary stops satisfying the stored requirement —
and the symptom is nasty: the Accessibility toggle still **shows as on** while the app is
reported untrusted, and flipping it changes nothing because the stale row is the problem.

The `Makefile` therefore signs with a stable Developer ID or Apple Development identity
(auto-detected via `security find-identity`, falling back to ad-hoc). A stable identity keeps
the local Accessibility requirement consistent across rebuilds. If the app reports that its
global keyboard monitor is unavailable, enable Murmur in Accessibility, then quit and
reopen it.

If a grant ever does get wedged, reset that one row and re-add — never toggle:

```bash
tccutil reset Accessibility ai.pivotstudio.murmur
tccutil reset Microphone   ai.pivotstudio.murmur
```

Always pass the bundle ID. A bare `tccutil reset Accessibility` wipes **every** app on the
machine. Then quit System Settings entirely (⌘Q) before reopening — that pane caches its
list and will otherwise show the row you just deleted.

> **Keep the build out of iCloud.** `~/Desktop` and `~/Documents` are file-provider synced
> on this machine; the sync engine can materialize/dematerialize files inside an `.app` and
> corrupt its signature. `make install` puts the running copy in `/Applications`.

Other targets: `make app` (bundle only), `make run` (run in place), `make clean`.

`make app` builds with `xcodebuild`, not `swift build`: S1-mini runs on MLX, and SwiftPM's
command line can't compile MLX's Metal kernels. `make build` and `make test` still use
SwiftPM and are fine for everything that doesn't touch the GPU.

## Cleanup

Settings → Cleanup picks the pass that runs between transcription and typing:

| Engine | What it does |
|---|---|
| Basic rules | Strips fillers, fixes spacing and punctuation. Instant, no model. |
| S1-mini by Superwhisper | 0.6B normalizer on the GPU via MLX. Applies spoken corrections, writes numbers/dates/emails, follows the profile. |
| Apple Intelligence | Apple's on-device model, when Apple Intelligence is ready on the Mac. |

S1-mini takes a **profile** (General, Email, Message, Notes), chosen from the main window,
Settings or the menu bar; it applies to the next hold. Load S1-mini once from Settings: it
downloads Superwhisper's 1.5 GB original, verifies it, converts it to a 331 MB 4-bit build on
the Mac and deletes the original. On an M2 a typical sentence cleans in about 0.2 s.

Check it from the installed bundle without a microphone:

```bash
/Applications/Murmur.app/Contents/MacOS/Murmur --cleanup-check
```

S1-mini is Apache 2.0 with an extra term: it must be called "S1-mini" by "Superwhisper".
Its LICENSE and NOTICE are kept beside the converted weights.

---

## Architecture

```
 hold key ─► HotkeyMonitor ──► DictationController ◄── Settings
                                │
                     ┌──────────┼──────────┐
                     ▼          ▼          ▼
              AudioCapture  HUDPanel   TranscriptionEngine
                     │                      │
                (AudioChunk) ──ordered──► AppleSpeechEngine
                                            │
                                       (transcript)
                                            ▼
                                      TextFormatter
                                            ▼
                                      TextInjector ─► focused app
```

### Decisions worth knowing

**The HUD must never take focus.** `HUDPanel` is a `.nonactivatingPanel` with
`canBecomeKey == false`. This is the load-bearing detail of the whole app: if the overlay
took key status, the user's text field would lose focus and there'd be nothing left to
inject into. Everything else is replaceable; this isn't.

**The hotkey uses AppKit's global event monitor.** `flagsChanged` events include a virtual key
code, so the monitor can distinguish the configured right-hand modifier without decoding
aggregate modifier flags. Accessibility permission is a hard requirement because macOS
restricts global key monitoring to trusted apps.

**Audio ordering is explicit.** `AudioCapture` yields into an `AsyncStream` drained by a
single task. Spawning a `Task` per buffer would be simpler and would silently corrupt the
transcript, because unstructured tasks have no ordering guarantee.

**Buffers are copied, never borrowed.** `AVAudioEngine` recycles the buffer it hands to a
tap the instant the callback returns. `AudioChunk`'s `@unchecked Sendable` is only sound
because `AudioCapture` always allocates fresh storage before handing off.

**Two swappable seams.** `TranscriptionEngine` and `TextFormatter` are protocols so the
two components most likely to change can change without touching anything else.

### Layout

```
Sources/Murmur/
├── MurmurApp.swift              @main, AppDelegate, MenuBarExtra
├── Core/
│   ├── DictationController.swift   state machine, wires everything
│   ├── HotkeyMonitor.swift         NSEvent global/local monitors on .flagsChanged
│   ├── AudioCapture.swift          AVAudioEngine tap + format conversion + RMS
│   └── TextInjector.swift          AX insert, pasteboard+⌘V fallback
├── Transcription/
│   ├── TranscriptionEngine.swift   protocol + AudioChunk
│   └── AppleSpeechEngine.swift     SpeechAnalyzer / SpeechTranscriber
├── Formatting/
│   └── TextFormatter.swift         protocol + RuleBasedFormatter
├── UI/
│   ├── HUDPanel.swift              non-activating floating panel
│   └── HUDView.swift               outlined glass capsule, red waveform
└── Support/
    ├── Settings.swift, Permissions.swift, Log.swift
```

---

## Speech engines

Choose the engine in **Settings > Model** or the menu bar's **Engine** picker.
Apple remains the default. Turn off **Compare Apple vs Parakeet batch** to use the selected engine for dictation.

| Option | Processing | Model setup |
|---|---|---|
| Apple (streaming) | Recognizes while you speak; finalizes on release | OS-managed assets |
| Parakeet (batch) | Transcribes the recording after release | Existing Parakeet TDT v3 model |
| Bark 3.0 Clean (batch) | Parakeet v3 fine-tune that drops fillers, false starts and repeats; transcribes after release | Select it, then choose **Load model (downloads if needed)** |
| Parakeet EOU (streaming) | Cache-aware 120M model, 160 ms chunks | Select it, then choose **Load model (downloads if needed)** |
| Nemotron (streaming) | Cache-aware 0.6B model, 560 ms chunks | Select it, then choose **Load model (downloads if needed)** |

The two new streaming options use the existing FluidAudio 0.15.6 dependency and run locally on Apple Silicon.
Their first load downloads CoreML models from Hugging Face into FluidAudio's model cache. Audio is not uploaded.
Load status and failures appear in Settings and the menu. Models stay loaded between recordings; after relaunch,
use the load action again to load them from the disk cache. Loading both models retains both in memory.

If the selected streaming model is not ready, pressing Record or the hotkey leaves recording idle without
starting microphone capture or flashing the waveform. A persistent notice in the main window and menu
explains the model state and offers **Open Model Settings**. The notice updates during loading or failure
and disappears when the model is ready. Recording never starts a download or switches engines automatically.

Audio is processed in capture order while recording. Release drains queued audio and flushes the model's remaining
buffer before inserting the final transcript. Partial results are never substituted for the final result.
Chunk duration is not a guarantee of release-to-text latency or accuracy. Compare these options with your own speech.

### Bark 3.0 Clean

[Underdog Bark 3.0 Clean](https://huggingface.co/ConwayResearch/Underdog-Bark-3.0-Clean) (Conway Research, CC-BY-4.0,
derived from NVIDIA Parakeet TDT 0.6B v3 and Moondream parakeet-ultra) runs through the same FluidAudio batch path as
Parakeet. The Core ML build comes from `FluidInference/bark-3.0-coreml`, pinned to one revision. Murmur downloads only
the Neural Engine encoder (about 450 MB in total) into `~/Library/Application Support/Murmur/Models/`, checks every
file's size and SHA-256, and moves the folder into place only after all files pass. The upstream `NOTICE` is kept
beside the weights.

The first load compiles the encoder for the Neural Engine, which took about 80 s on an M2. Core ML caches that
compile, so later launches load in under a second and Murmur loads the model automatically at launch when it is on
disk. Measured on an M2 with warm models: a 4.2 s clip in about 0.1 s and a 20.9 s clip in about 0.2 to 0.3 s.
The GPU encoder in the same repo was about 2× slower per utterance on that machine and spent about 8 s on its first
inference after every launch, so it is not used.

Bark writes `<unk>` where its training text had a quotation mark; Murmur removes it. When the model is loaded,
compare mode adds a Bark row beside Apple and Parakeet.

The end-to-end test is opt-in because it downloads the model:
`MURMUR_BARK_AUDIO=/path/to/16k-mono-float32.raw make test`.

New history rows show release-to-AX-insertion or release-to-paste-event timing, while retaining recognition and
cleanup timing separately in `runs.jsonl`. The target application's rendering time is not measured.
Legacy rows and the existing batch comparison retain their original timings.

## Build and verification

```bash
make test                 # dictionary contract and macOS 26 app regression tests
make build CONFIG=release # optimized executable, outside the workspace
make install              # release app bundle, stable signing, /Applications/Murmur.app
```

The app's bundle ID is `ai.pivotstudio.murmur`. Grant permissions to the renamed app.
On first launch, Murmur imports the old app's dictionary, history, and missing preferences without replacing
existing Murmur data. Original files remain untouched; history import is one-time so clearing history does not
restore old entries on the next launch. The legacy names remain only in the compatibility importer.

---

## Not built yet

1. **Cleanup while speaking** and picking the profile from the focused app.
2. **Command Mode.** Select text, hold a second hotkey, say "make this more formal."
   Needs AX read of `kAXSelectedTextAttribute` plus an LLM round-trip.
3. **Branding.** `Brand` in `HUDView.swift` is a two-color placeholder gradient. App icon,
   real palette, HUD motion design, onboarding.
4. **Onboarding.** A first-run window that walks through both permissions instead of
   relying on the menu's "Grant…" items.
5. **Developer ID signing + notarization.** Ends the TCC-reset churn and makes the app
   distributable.

---

## Verified

Driven with a synthetic Right ⌥ hold (`scratchpad/ptt/ptt2.swift` posts `flagsChanged`
events) and confirmed via `/usr/bin/log show --predicate 'subsystem ==
"ai.pivotstudio.murmur"'`:

- Builds clean under Swift 6 strict concurrency.
- Signs with Developer ID; grants survive rebuild + reinstall.
- Launches as an accessory app, no Dock icon, menu bar item present.
- Global keyboard monitor arms on grant without a restart (the poller catches it).
- Full state machine: `starting → listening → finishing → idle`, no errors.
- `SpeechAnalyzer` starts; models already installed, no download stall.
- Audio capture runs and converts native 48 kHz → 16 kHz for the engine.
- HUD renders bottom-center at `{{790, 96}, {340, 76}}` without taking focus.
- Silence produces an empty transcript and injects nothing.

**Not yet verified:** speech → transcript → cleanup → injection. Synthetic key events
can't produce audio, so this needs a human to hold the key and talk.

> `log` is shadowed in this shell — use `/usr/bin/log` explicitly or it returns nothing.
