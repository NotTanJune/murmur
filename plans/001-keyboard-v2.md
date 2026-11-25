# Plan 001: Murmur keyboard v2, a full keyboard with dictation in the strip

> **Executor instructions**: Follow this plan milestone by milestone, step by step. Run every
> verification command and confirm the expected result before moving on. If anything in
> "STOP conditions" occurs, stop and report; do not improvise. When a milestone is done, update
> its row in `plans/README.md`. Milestones marked **[device]** end with a check only the owner
> can do on their iPhone: finish the code, run the non-device gates, install if allowed (see
> "Git workflow"), then mark the row `WAITING ON DEVICE` and continue with the next milestone
> only if the README says it does not depend on that check.
>
> **Drift check (run first)**: `git diff --stat 6e58c78..HEAD -- ios/Keyboard ios/Shared ios/App Sources/MurmurKit Sources/MurmurDesign Package.swift ios/project.yml`
> If any of these changed since this plan was written, compare the "Current state" excerpts
> against the live code before proceeding; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L (ten milestones; each is S to M on its own)
- **Risk**: HIGH (replaces the keyboard's whole input surface; memory ceiling shared with Bark)
- **Depends on**: none
- **Category**: direction
- **Planned at**: commit `6e58c78`, 2026-11-25, branch `keyboard-v2`

## Why this matters

Murmur's iPhone keyboard today is dictation only: a large talk key, one row of punctuation, a
row of 123 / emoji / hide / space / return, and no letters. The owner has to switch to Apple's
keyboard for anything typed, so Murmur cannot be the keyboard that stays on. v2 makes Murmur a
complete keyboard that matches the stock iOS 26/27 keyboard key for key (letters, numbers,
symbols, emoji, shift and caps lock, key pop-ups, accents, the space-bar trackpad,
double-space period), adds swipe typing, autocorrect and word suggestions, and moves dictation
into a small orange **m** button in the suggestion strip that expands into the waveform.

Two things should make it better than Apple's keyboard rather than a copy:

1. **It learns from how the owner talks, not only how they type.** Murmur already stores every
   dictation's text (`runs.jsonl`) and a custom dictionary. Both seed the keyboard's word
   predictions, and dictionary terms are never autocorrected away.
2. **Correcting a dictation teaches the speech model.** When the owner fixes dictated text with
   the keyboard, the fixed text becomes a training label for that run, the same label the
   History editor writes today, so the Bark fine-tune loop fills itself.

## Decisions taken in this plan (the owner may overturn any before execution)

Each is the advisor's call, with the reason. Change the plan text before executing if the
owner disagrees.

| # | Decision | Reason |
|---|---|---|
| D1 | All typing logic lives in a new SwiftPM target `MurmurTyping` with no UIKit import; the iOS side only draws and forwards touches. | Lets the layout, touch state machine, autocorrect, swipe decoder and edit tracker be unit-tested on the Mac with `swift test`; only drawing needs the phone. Keeps the word list out of the Mac app (it does not link `MurmurTyping`). |
| D2 | The key area is one UIKit view (`KeyPlaneView`) that draws every key and tracks every touch itself (`isMultipleTouchEnabled`), not SwiftUI buttons. | Fast two-thumb typing sends overlapping touches. The project already replaced SwiftUI grids and lists with UIKit twice for touch accuracy (AGENTS.md, "The grid is UIKit", "The history list is UIKit too"). Hex's MIT keyboard uses the same single-plane design. |
| D3 | The **m** button sits at the trailing end of the 44 pt strip. Tapping or holding it turns the strip into a recording capsule: Liquid Glass tinted `DS.Keyboard.talkGlassTint`, 36 pt tall, growing leftwards from the m to 60% of the strip's width, with the red waveform inside. Quick tap locks, hold is push-to-talk (`HoldGesture`, unchanged). The keys stay usable under it. | The owner asked for the m "where the autocorrect suggestions usually come", expanding into the waveform, "not as wide or as tall" as today's 48 pt full-width talk key. Gboard, FluidVoice, Aqua and Raycast all put the dictation trigger at the strip's trailing end. |
| D4 | History moves to the strip's leading end (the clock icon), shown only while no word is being typed. | Today's history button sits beside the talk key, which is going away. |
| D5 | Bottom row is stock: `123`, emoji, space, return (the globe joins only when `needsInputModeSwitchKey` is true). The hide-keyboard key is removed. | The stock iOS 26/27 keyboard has no hide key; the owner wants one-to-one. |
| D6 | Word data v1 is SymSpell's English lists (MIT repo; data is Google Books Ngram intersected with Hunspell word lists, CC BY 3.0), pinned to commit `91fe939e9c1259813ee817e95239629c5badf8ec`, compiled by our own script into a memory-mapped binary. | Small (1.3 MB unigrams, 5.1 MB bigrams), already validity-filtered, licence verified (see Reference facts). A Leipzig-corpus rebuild can come later without changing the format. |
| D7 | Autocorrect is our own spatial noisy-channel decoder (tap Gaussians per key, beam search over the word list, bigram context, a margin before replacing), not `UITextChecker`. `UITextChecker` remains only as a fallback for words outside the list. | `UITextChecker` gives unscored one-edit guesses with no context. Hex measured its spatial decoder at 76.4% fewer word errors than raw taps against 35.3% for `UITextChecker` (French replay). |
| D8 | Swipe typing is our own SHARK2-style decoder (32 resampled points in key pitches, start/end-key pruning, location + shape channels, bigram weighting). | The best-documented on-device method; Hex reports 0.91 ms median decode and 97.1% top-1 on synthetic English swipes with this family of decoder. Neural swipe is deferred. |
| D9 | A transformer language model is Milestone 9, a gated spike: a small model (about 10 to 15 M parameters, int8, CPU) that reranks the top candidates and predicts the next word. It ships only if it beats the bigram model on the replay benchmark within the memory and latency budget. | Apple's iOS 17+ keyboard uses a transformer LM (about 34 M parameters by one reverse-engineering estimate). The extension's memory ceiling (about 50 to 70 MB) is shared with Bark (33 MB), so the LM must earn its bytes. |
| D10 | Correction capture labels only runs cleaned by the rule pass (`run.cleanup == nil`). Apple Intelligence runs are tracked for the typing model but never labelled. | A label must be "what was said, in Bark's form" (`TrainingLabel`). On a rule-pass run the typed text is that form; on an Apple Intelligence run it is a rewrite, so the owner's edit is an edit of the rewrite. |
| D11 | A captured label is stored with a new `labelSource = .keyboard` so History shows "From keyboard" and the owner can revert it; it is used for export like any other label. | A wrong label is worse than none for fine-tuning; the owner needs to see and undo what the keyboard inferred. |
| D12 | Learning (typing model and correction capture) is on by default, stays on the iPhone, never stores surrounding text, and has one switch and one "Erase what the keyboard learned" button in the app's Settings tab. | App Review guideline 4.4.1 allows keyboards to collect activity only to improve the keyboard on the device. Export to the Mac stays a manual action the owner starts, as today. |

## Current state

### Files and roles

- `ios/Keyboard/KeyboardViewController.swift` (161 lines): `UIInputViewController`. Configures
  `PhoneEnvironment` and `RunLog` in both inits, owns `WebMicrophone`, `KeyboardDictation`, the
  required height constraint (`DS.Keyboard.height`, 168 pt), and builds `KeyboardActions` for
  the SwiftUI root `KeyboardView`. Root view is `ClickingInputView` (adopts
  `UIInputViewAudioFeedback` so `playInputClick` works).
- `ios/Keyboard/KeyboardView.swift` (491 lines): SwiftUI. `KeyboardView` switches between
  `.keys`, `.emoji` (`EmojiPanel`) and `.history` (`HistoryPanel`). The `.keys` page is: row 1
  history icon + `TalkKey`; row 2 shift + punctuation (`@ . , ? ! ' -`) + `DeleteKey`; row 3
  globe? + page key + emoji + hide + space + `ReturnKey`. Also defines `KeyFace`,
  `CharacterKey`, `TextKey`, `IconKey`, `ReturnKey`, `DeleteKey`, `KeyPressStyle`,
  `PlainKeyStyle`, `GlobeKey`.
- `ios/Keyboard/KeyboardDictation.swift` (1115 lines): `@Observable @MainActor` dictation
  controller. Public surface used by the view: `state` (`.idle`, `.recording(level)`,
  `.finishing`, `.failed(...)`), `heardAudio`, `readinessCaption`, `isBusy`, `shiftNext`,
  `touchDown()`, `touchUp()`, `toggleDictation()`, `keyboardAppeared(hasFullAccess:)`,
  `keyboardDisappeared()`, `haptics`. `finish(_:)` (lines 909 to 995) inserts the text and
  files the run; `insert(_:)` (lines 1101 to 1114) types it.
- `ios/Keyboard/EmojiPanel.swift`, `EmojiGrid.swift`, `HistoryPanel.swift`,
  `HistoryList.swift`: stay as they are. `EmojiPanel`'s category bar has an `ABC` button that
  calls `close`, and a `DeleteKey`.
- `ios/Keyboard/KeyFeedback.swift`: `KeyFeedback.press()` plays the input click and a light
  haptic tap; `attach(to:)` once.
- `ios/Shared/KeyboardStatus.swift`: `Codable` status file the keyboard writes and the app's
  Setup tab reads; every field added after v1 is optional so old files decode.
- `Sources/MurmurKit/Support/Settings.swift`: `@Observable` settings over a shared
  `UserDefaults` suite. Pattern for a new key (copy it exactly, see `hapticsEnabled`):
  property with `didSet { persist(value, Keys.x) }`, a `Keys` constant, a `Snapshot` field read
  with `defaults.object(forKey:) as? Bool ?? <default>`, and assignment in both `init` and
  `reloadFromDefaults()`.
- `Sources/MurmurKit/Support/RunLog.swift`: `RunLog.record(_:audio:)` files a run;
  `RunLog.setLabel(_:for:)` sets a label (trimmed; empty clears). `DictationRun` (same file)
  has `id: UUID`, `text`, `rawText`, `label`, `cleanup` (nil for the rule pass), `source`.
- `Sources/MurmurKit/Support/TrainingLabel.swift`: `editAllowed(run)` is
  `run.cleanup == nil || rawText non-empty`; `editBase(run)` is `run.text` for rule-pass runs,
  `rawText` otherwise.
- `Sources/MurmurDesign/DesignSystem.swift`, `enum Keyboard` (from line 285): every keyboard
  size, colour and font. Views must not contain literal values (AGENTS.md, "Design system").
- `Package.swift`: products `MurmurKit`, `MurmurDictionary`, `MurmurDesign`; tests use Swift
  Testing (`import Testing`, `@Test`, `#expect`), e.g. `Tests/MurmurKitTests/HoldGestureTests.swift`.
- `ios/project.yml`: XcodeGen. Target `MurmurKeyboard` (app-extension) depends on package
  products `MurmurKit`, `MurmurDictionary` (and `MurmurDesign`). After editing it, run
  `make ios-project` and commit the regenerated `ios/Murmur.xcodeproj`.

### Excerpts to confirm you are looking at the right code

`ios/Keyboard/KeyboardDictation.swift:1101`:

```swift
    private func insert(_ text: String) -> Date? {
        guard let proxy = proxy() else { return nil }
        var output = text
        if shiftNext {
            output = output.prefix(1).uppercased() + output.dropFirst()
            shiftNext = false
        }
        if let last = proxy.documentContextBeforeInput?.last,
           last.isLetter || last.isNumber || ".,!?;:".contains(last) {
            output = " " + output
        }
        proxy.insertText(output)
        return Date()
    }
```

`ios/Keyboard/KeyboardDictation.swift:956` (inside `finish`):

```swift
            if let deliveredAt = insert(finished.text) {
                if settings.soundEnabled { KeyboardSounds.play(.done) }
                haptics.typed()
                var run = DictationRun(
                    date: released,
```

`Sources/MurmurKit/Support/RunLog.swift:205`:

```swift
    public static func setLabel(_ label: String?, for run: DictationRun) {
        update(.setLabel(label, id: run.id))
    }
```

`Sources/MurmurDesign/DesignSystem.swift` (keyboard tokens as of this plan):

```swift
        public static let rowSpacing: CGFloat = 11
        public static let keySpacing: CGFloat = 6
        public static let talkHeight: CGFloat = 48
        public static let keyHeight: CGFloat = 43
        public static let keyRadius: CGFloat = 10
```

### Conventions to match

- Swift 6 language mode, strict concurrency. Main-actor UI. Never `MainActor.assumeIsolated`
  from non-main code; use `await MainActor.run` (AGENTS.md).
- Comments explain *why*, in full sentences, as in `KeyboardView.swift`. Doc comments on every
  type.
- New design values go in `DS.Keyboard` as named tokens with a doc comment; no literals in views.
- Red (`DS.Color.record`) means recording only. Selection uses the cream treatment only in the
  app, not in the keyboard.
- Timers that must run while a finger scrolls use `.common` run-loop modes (AGENTS.md, heartbeat).
- Provenance (AGENTS.md, "License and provenance"; "Capture runs in WebKit"): Hex
  (`anomalyco/hex`, MIT), FlorisBoard (Apache-2.0) and AOSP LatinIME (Apache-2.0) may be read
  for behaviour only. **Do not paste or translate their code.** Never use KeyboardKit 10+
  (closed source) or anything from FUTO Keyboard (non-commercial licence).
- No em dashes in any written document (owner's rule).

## Commands you will need

Builds are CPU heavy on the owner's Mac: run them niced (`nice -n 15`), one at a time.

| Purpose | Command | Expected on success |
|---|---|---|
| Typing tests | `nice -n 15 swift test --scratch-path ~/Library/Caches/MurmurBuild/scratch --filter MurmurTypingTests` | exit 0, last line contains `passed` |
| All tests | `nice -n 15 make test` | exit 0 |
| Dictionary vectors | `nice -n 15 swift test --scratch-path ~/Library/Caches/MurmurBuild/scratch --filter VectorTests` | exit 0 |
| Regenerate Xcode project | `make ios-project` | exit 0; `git status` shows `ios/Murmur.xcodeproj` changes only when `project.yml` changed |
| iOS compile (the check you run) | `nice -n 15 make ios-build 2>&1 \| grep -E "error:\|BUILD (SUCCEEDED\|FAILED)"` | `** BUILD SUCCEEDED **`, no `error:` lines |
| Install on the owner's iPhone | `nice -n 15 make ios-install` | `App installed:` with `bundleID: ai.pivotstudio.murmur.ios` |
| Build the word model | `uv run Tools/build_typing_model.py --out Sources/MurmurTyping/Resources/en.mtm` | exit 0, prints word and pair counts |
| Mac design module | `nice -n 15 swift build --scratch-path ~/Library/Caches/MurmurBuild/scratch --target MurmurDesign -j 2` | `Build complete!` |

Never build for or run a simulator. Never run `swift build` without `--scratch-path` (a synced
folder breaks it; AGENTS.md).

## Suggested executor toolkit

- `write-swift` skill for Swift 6 concurrency and value modelling; `swiftui-pro` for the strip.
- Read, for behaviour only, Hex's keyboard spec pinned at commit `7a2c78ace23a`:
  `gh api repos/anomalyco/hex/contents/ios/docs/keyboard.md?ref=7a2c78ace23a --jq .content | base64 -d > ~/Library/Caches/MurmurBuild/hex-keyboard.md`
  Sections worth reading: "Size (full keyboard)", "Touch targets", "Spaces", "Smart
  punctuation", "Delete after an autocorrection", "Spatial autocorrect", "Swipe typing",
  "Learn how I type", "Auto-capitalization", "Slides from 123, #+= and shift". The file lives
  outside the repo; never commit it.
- SHARK2 paper: Kristensson and Zhai, UIST 2004, https://pokristensson.com/pubs/KristenssonZhaiUIST2004.pdf
- Goodman et al. 2002, "Language modeling for soft keyboards", https://cdn.aaai.org/AAAI/2002/AAAI02-064.pdf

## Scope

**In scope** (create or modify):

- `Package.swift` (new target, product, test target)
- `Sources/MurmurTyping/**` (create)
- `Tests/MurmurTypingTests/**` (create)
- `Tools/build_typing_model.py`, `Tools/typing-extra-words.tsv` (create); downloaded data lives
  in `~/Library/Caches/MurmurBuild/typing-data/`, never in the repo
- `ios/Shared/TypingFiles.swift` (create)
- `ios/Keyboard/**`
- `ios/Shared/KeyboardStatus.swift`
- `ios/App/SettingsView.swift`, `ios/App/SetupView.swift`, `ios/App/HistoryView.swift`, `ios/App/RunEditor.swift` (labels from the keyboard, settings)
- `ios/project.yml` and the regenerated `ios/Murmur.xcodeproj`, `ios/Keyboard/Info.plist`
- `Sources/MurmurDesign/DesignSystem.swift` (keyboard tokens only)
- `Sources/MurmurKit/Support/Settings.swift` (new keys only)
- `Sources/MurmurKit/Support/RunLog.swift` (`DictationRun.labelSource` only)
- `AGENTS.md` (iOS keyboard section), `THIRD_PARTY.md`, `ios/README.md`, `plans/README.md`

**Out of scope** (do not touch, even though they look related):

- `Sources/Murmur/**` (the Mac app). The Mac does not link `MurmurTyping`.
- `WebMicrophone.swift`'s capture graph, heartbeat and deadlines. The m button calls the same
  `KeyboardDictation` entry points the talk key calls today.
- `KeyboardDictation`'s Bark preparation, crash marker, warm microphone and idle close logic.
  Milestone 8 adds one hook after `insert`; nothing else in that file changes except removing
  `shiftNext` handling if the new shift state replaces it (Milestone 2, step 2.6).
- The haptic patterns in `KeyboardHaptics` (the owner designed them by feel; AGENTS.md).
- `EmojiGrid`, `HistoryList` internals.
- `bench/`, `training/`.

## Git workflow

- Work on branch `keyboard-v2` (the owner asked for a new branch; it already exists, created
  from `main` at `6e58c78`). Do not create other branches or worktrees.
- Commit per step group (at least once per milestone). Message style from `git log`: a plain
  imperative sentence, no prefix, then a body explaining why. Example:
  `Give the keyboard's keys the iOS 26 look and a return glyph`. No `Co-Authored-By` or any
  Claude attribution.
- Before each commit: `git diff --cached | grep -iE "DEVELOPMENT_TEAM|password|secret|api[_-]?key"`
  must print nothing (the signing team lives only in the git-ignored `ios/Local.xcconfig`).
- Push `keyboard-v2` to `origin` after each milestone: `git push -u origin keyboard-v2`. Never
  push to `main`, never merge.
- The owner's standing instruction (2026-11-22, recorded in the advisor's memory, overriding
  AGENTS.md's "Run `ios-install` only when the user asks"): "Now onwards, when you make changes,
  just install the app and commit and push the changes, if there are any issues, i will test it
  and tell you". So install on their iPhone with `make ios-install`. Do it at the end of each milestone if `make ios-install` can reach the
  phone; if it reports no device, skip it and say so in the README row.

## Reference facts (research, 2026-11-25)

Verified (V) means read at the source; U means reported or inferred.

**Stock keyboard geometry (from the owner's iPhone 15 Pro screenshot, iOS 27.2.1, 3x, measured
2026-11-25, V):** every key fill RGB 68 in dark; letter keycaps 32.7 pt wide, 42.7 pt tall;
6 pt between keys; 11 pt between rows; 123 and emoji keys 42 pt wide; space 187 pt; return 91
pt; shift and delete 44 pt; corner radius about 10 pt (continuous). Bottom letter row: shift,
about 14 pt gap, 7 letters, gap, delete. Row 2 (a to l) is inset half a key on each side.

**From Hex's spec (V as a document, measured by Hex on simulators):** prediction strip 44 pt,
then 8 pt to row 1 upright (6 turned); keyboard 253 pt on iPhone 17 / 17 Pro, 260 on SE, 272 on
Air / Pro Max; on 844 to 874 pt tall iPhones under iOS 27, 42 pt keycaps with 11 pt row gaps;
landscape 204 pt (32 pt keycaps on a 40 pt pitch). Apple's keys take taps about 8 pt above the
keycap; gaps split down the middle; outer keys reach the screen edge; the space bar takes taps
2.5 pt into row 3. Accent hold 0.36 s. Space-bar trackpad after a still hold of 0.35 s; a tap
that slides before then still types a space. Delete repeats after 0.36 s every 0.075 s,
accelerates at 0.85 s, deletes whole words after 1.4 s. Trackpad gain 1.4x at 400 pt/s, 2x at
1000, 2.6x at 2000. A suggestion types its own trailing space; a following space press is
swallowed but still counts toward double-space; `, . ! ? ; : )` after a suggestion take that
space. After an autocorrection, delete removes only the space and the strip's left slot offers
the original with an undo arrow; tapping it restores the original and rejects the fix for the
session. Smart quotes: ' and " open at the start, after a space, a bracket or an opening
quote, and close elsewhere; `--` becomes an em dash; a field's `smartQuotesType` or
`smartDashesType` of `.no` turns each off. Next-letter bias: the likelier next letter claims up
to 5 pt of a neighbour, 1.25 pt per e-fold of odds. iOS delays touches near the screen's side
edges unless the window's gesture recognizers have `delaysTouchesBegan = false` (U on hardware).

**Memory (V unless noted):** Apple documents only that extension limits are "much lower" and
vary by model. Measured elsewhere: active limit 90 MB on an A12X iPad (Dictus kernel log); a
dictation keyboard plateaued at 66 to 70 MB on an iPhone 15 Pro Max without a kill. Memory-
mapped read-only files cost almost nothing in `phys_footprint` (25 MB of mmapped n-grams
measured as 0 B dirty). Murmur's own spike: Bark 33 MB, Apple-engine hold peak 41 MB (iPhone 15
Pro). Working ceiling for this plan: **50 MB `phys_footprint`** until Milestone 0 measures the
real one.

**APIs (V):** keyboards get no system autocorrect or prediction API. Available:
`UITextChecker` (guesses, completions, learnWord), `requestSupplementaryLexicon` (Contacts
names, text replacements, common words), field traits on `textDocumentProxy`
(`autocorrectionType`, `spellCheckingType`, `smartQuotesType`, `smartDashesType`,
`autocapitalizationType`, `keyboardType`, `returnKeyType`), `documentContextBeforeInput` /
`AfterInput` (only text near the cursor, host dependent, U for exact limits),
`documentIdentifier` (changes with the field; U whether stable across keyboard switches),
`adjustTextPosition(byCharacterOffset:)` (UTF-16 offsets, asynchronous), `selectedText`
(partial for long selections). iOS replaces any third-party keyboard in secure fields and phone
pads. A keyboard cannot draw outside its own view.

**Licences (V):** SymSpell repo MIT; its dictionaries are Google Books Ngram (CC BY 3.0 Unported,
stated on storage.googleapis.com/books/ngrams/books/datasetsv2.html) intersected with Hunspell
word lists. FUTO swipe dataset MIT (huggingface.co/datasets/futo-org/swipe.futo.org). Hex MIT.
FlorisBoard and AOSP Apache-2.0. KeyboardKit 10+ closed; FUTO Keyboard code and model weights
not usable.

**Tuned constants worth starting from (AOSP `scoring_params.cpp`, V, values only):** edit costs
substitution 0.3806, proximity substitution 0.0694, omission 0.467, insertion 0.7248,
transposition 0.5608, space omission 0.1; language weight 1.1214; autocorrect threshold 1.0.

---

## Milestone 0: Measure the memory ceiling and add the typing module skeleton

### Step 0.1: Report the keyboard's memory footprint

Add to `ios/Keyboard/` a file `MemoryProbe.swift` with `enum MemoryProbe { static func footprintMB() -> Double }`
reading `task_vm_info` (`TASK_VM_INFO`, field `phys_footprint`) via `task_info(mach_task_self_, ...)`.
In `KeyboardDictation`, keep the peak seen; sample at each appearance, at each hold's finish
and every 10 s while visible (a `.common`-mode timer, cancelled in `keyboardDisappeared`).
Add optional fields `footprintMB: Double?` and `peakFootprintMB: Double?` to
`KeyboardStatus` and write them where the other fields are written. In `ios/App/SetupView.swift`,
in the keyboard card where "Last start: N ms" is shown, add a line
`Memory: N MB now · N MB peak` when present.

**Verify**: `nice -n 15 make ios-build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"` → `** BUILD SUCCEEDED **`

### Step 0.2: Create the `MurmurTyping` target and test target

In `Package.swift` add product `.library(name: "MurmurTyping", targets: ["MurmurTyping"])`, target

```swift
        // The keyboard's typing engine: layout, touches, autocorrect, swipe, learning. No UIKit,
        // so it is tested on the Mac; only the iPhone keyboard links it.
        .target(
            name: "MurmurTyping",
            dependencies: ["MurmurDictionary"],
            path: "Sources/MurmurTyping",
            exclude: ["Lexicon/MTMFormat.md"],
            resources: [.copy("Resources/en.mtm")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
```

and `.testTarget(name: "MurmurTypingTests", dependencies: ["MurmurTyping"], path: "Tests/MurmurTypingTests", swiftSettings: [.swiftLanguageMode(.v6)])`.
Until Milestone 4 builds the model, create a placeholder `Sources/MurmurTyping/Resources/en.mtm`
containing only the 16-byte header `MTM1` + three zero `u32`s, and a file
`Sources/MurmurTyping/MurmurTyping.swift` with a doc comment describing the module and
`public enum TypingResources { public static var modelURL: URL? { Bundle.module.url(forResource: "en", withExtension: "mtm") } }`.
The keyboard and the tests both load the model only through this (and, from Milestone 4,
`TypingModel.bundled()`), never through `Bundle.main`. Add one test `Tests/MurmurTypingTests/SmokeTests.swift` that `#expect(true)`.
In `ios/project.yml`, add `- package: Murmur` / `product: MurmurTyping` to `MurmurKeyboard`'s
dependencies. Run `make ios-project`.

**Verify**: `nice -n 15 swift test --scratch-path ~/Library/Caches/MurmurBuild/scratch --filter MurmurTypingTests` → exit 0, `passed`
**Verify**: `nice -n 15 make ios-build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"` → `** BUILD SUCCEEDED **`
**Verify**: `find ~/Library/Caches/MurmurBuild/ios -path "*MurmurKeyboard.appex*" -name "*MurmurTyping*.bundle"` → prints at least one path (the resource bundle reached the extension). If it prints nothing, STOP: the fallback (list `en.mtm` as a resource of `MurmurKeyboard` in `project.yml` and inject its URL into `TypingModel(url:)`) changes the loading contract and needs the owner's review.

### Step 0.3 [device]: Read the real ceiling

Commit, push, install. In the README row, ask the owner to: open the keyboard, dictate once
with Bark, open the emoji panel, then read Setup's "Memory" line and report both numbers.
Optionally, with the phone cabled: `/usr/bin/log collect --device --last 5m --output ~/Library/Caches/MurmurBuild/keyboard.logarchive`
right after switching to the keyboard, then
`/usr/bin/log show ~/Library/Caches/MurmurBuild/keyboard.logarchive --predicate 'process == "runningboardd"' | grep -i "memory limit"`
(U whether this shows the extension's limit). AGENTS.md requires `/usr/bin/log` by full path.

Record the owner's numbers in `plans/README.md` under "Measurements". **Budget rule for every
later milestone**: typing additions may add at most `(ceiling - 8 MB) - peak` MB of
`phys_footprint`, where `ceiling` is the measured limit, or 50 MB if none was found.

---

## Milestone 1: Layout, metrics and hit testing (pure logic)

Files to create in `Sources/MurmurTyping/Layout/`:

- `KeyKind.swift`: `enum KeyKind: Hashable, Sendable { case character(String), shift, delete, space, `return`, pageSwitch(Page), emoji, globe }`
  and `enum Page: Sendable { case letters, numbers, symbols }`.
- `KeyboardLayout.swift`: `struct KeyboardLayout: Sendable` with `static func rows(for page: Page, showsGlobe: Bool) -> [[KeyKind]]`.
  Rows (iOS English, US):
  - letters: `q w e r t y u i o p` / `a s d f g h j k l` / shift `z x c v b n m` delete / `123` (globe) emoji space return
  - numbers: `1 2 3 4 5 6 7 8 9 0` / `- / : ; ( ) $ & @ "` / `#+=` `. , ? ! '` delete / `ABC` (globe) emoji space return
  - symbols: `[ ] { } # % ^ * + =` / `_ \ | ~ < > € £ ¥ •` / `123` `. , ? ! '` delete / `ABC` (globe) emoji space return
- `KeyboardMetrics.swift`: `struct KeyboardMetrics: Sendable` built from `width: CGFloat`,
  `isLandscape: Bool`, passed a `MetricsConstants` struct (the iOS side fills it from
  `DS.Keyboard` tokens; `MurmurTyping` must not import `MurmurDesign`). Portrait constants:
  strip 44, strip gap 8, keycap height 42, row gap 11, key gap 6, side inset 6, bottom inset 0.
  Landscape: strip gap 6, keycap height 32, row gap 8. Derived: letter key width
  `(width - 2*6 - 9*6) / 10` (32.7 at width 393, matching the owner's screenshot), row 2 inset
  half a key plus half a gap on each side, shift and delete 44 pt wide (scaled by width / 393),
  bottom row: page key and emoji 42 each, return 91, space fills. Height = 44 + 8 + 4 × 42 +
  3 × 11 = **253 pt** at width 393 portrait (Hex's measured value for 393 pt iPhones on iOS 27).
  Coordinate origin: the top-left of the keyboard view, so the strip occupies y 0 to 44, the
  strip gap y 44 to 52 and row 1's keycaps start at y 52.
  Expose `func frames(for rows: [[KeyKind]]) -> [KeyFrame]` where
  `public struct KeyFrame: Sendable { let kind: KeyKind; let keycap: CGRect; let hitRect: CGRect }`.
  Hit rects: gaps split at the middle, outer keys reach the view's side edges, row 1 extends up
  to y 44 (the whole strip gap), the bottom row reaches the view's bottom edge, and the space bar
  extends 2.5 pt up into row 3 across its width (the only overlap).
- `HitTester.swift`: `func key(at point: CGPoint, frames: [KeyFrame], bias: [String: Double]) -> KeyFrame?`.
  `bias` maps a letter to log-odds of being the next letter; a likelier letter claims up to 5
  pt of a neighbour's hit rect, 1.25 pt per unit of log-odds difference (Reference facts).

**Tests** (`Tests/MurmurTypingTests/LayoutTests.swift`, pattern: `HoldGestureTests.swift`):

1. Letters page at width 393: 10/9/9/4 keys (or 5 with globe); height exactly 253; letter
   keycap width within 0.05 of 32.7.
2. Every point with y ≥ 44 hits at least one frame, and `HitTester` returns exactly one (the
   space bar wins where it overlaps row 3). Sample a 2 pt grid.
3. A point in the middle of the gap between `q` and `w` goes to the nearer key.
4. A point at y 45 above `q` hits `q`; a point at y 43 hits nothing (it is in the strip).
5. With `bias ["e": 3.0, "d": 0]`, a point 2 pt inside `d` toward `e` returns `e`; with no bias it returns `d`.
6. Numbers and symbols pages have the rows listed above.

**Verify**: typing tests → exit 0, 6 new tests pass.

---

## Milestone 2: The key plane, shift, pages, pop-ups, accents, delete, space trackpad **[device]**

### Step 2.1: Touch engine (pure logic)

Shared types in `Sources/MurmurTyping/Input/Types.swift`:
`public enum ShiftState: Sendable { case off, on, capsLock }`,
`public enum AutocapMode: Sendable { case none, words, sentences, allCharacters }`, and
`FieldTraits` (defined in Milestone 7's text, create it here).

Ownership: `TypingEngine` owns `Page` and `ShiftState` and the touch state. It does not see the
text. `TypingController` (iOS) owns the text-dependent rules: after applying each effect it
reads `documentContextBeforeInput`, runs `TextRules`, and sends the result back with
`engine.setShift(_:)`; it intercepts `.insert(" ", ...)` to apply `doubleSpacePeriod`, and
`.insert("'", ...)`, `.insert("\"", ...)`, `.insert("-", ...)` to apply smart punctuation.

`Sources/MurmurTyping/Input/TypingEngine.swift`: `public struct TypingEngine: Sendable` driven by
events, returning effects, with no clocks of its own (time comes in with every event so tests
are deterministic). `mutating func handle(_ event: TouchEvent, bias: [String: Double]) -> [TypingEffect]`
(the bias is the next-letter log-odds from step 5.6; pass `[:]` until then):

```swift
public enum TouchEvent: Sendable {
    case began(id: Int, point: CGPoint, time: TimeInterval)
    case moved(id: Int, point: CGPoint, time: TimeInterval)
    case ended(id: Int, point: CGPoint, time: TimeInterval)
    case cancelled(id: Int)
    case tick(time: TimeInterval)   // the view sends one every 25 ms while any touch is down
}

public enum TypingEffect: Equatable, Sendable {
    case insert(String, tap: CGPoint?)    // tap: where the finger lifted, for autocorrect
    case deleteBackward(count: Int)        // characters (grapheme clusters)
    case deleteWordBackward
    case moveCursor(utf16Offset: Int)
    case showPopup(KeyKind, alternates: [String], selected: Int?)
    case hidePopup
    case setPage(Page)
    case setShift(ShiftState)
    case trackpad(Bool)                    // keys blank while true
    case feedback                          // click + light haptic, at touch-down
    case showEmoji
    case globe
}
```

Rules (from Reference facts; each gets a test):

- A character key types at touch-up, at the touch-up point's key (a slide to a neighbour types
  the neighbour, like stock). Pop-up shows at touch-down, hides at touch-up.
- Rollover: a new touch-down while another key is held commits the held key first.
- Holding a letter with accents for 0.36 s shows the accent row; horizontal movement selects
  (cell width = popup width / count, minimum 20 pt); release types the selected one, or nothing
  if the finger left the popup downward. Accent table (iOS English, U until checked against
  stock on the device): a `à á â ä æ ã å ā`, c `ç ć č`, e `è é ê ë ē ė ę`, i `î ï í ī į ì`,
  l `ł`, n `ñ ń`, o `ô ö ò ó œ ø ō õ`, s `ß ś š`, u `û ü ù ú ū`, y `ÿ`, z `ž ź ż`;
  numbers/symbols: `.` `…`, `-` `U+2013 U+2014 •` (en dash, em dash, bullet), `$` `₽ ¥ € ¢ £ ₩`, `&` `§`, `?` `¿`, `!` `¡`,
  `0` `°`, `/` `\`, `'` `’ ‘ ‚ \``, `"` `” “ „ « »`, `%` `‰`.
- Delete: one deletion at touch-down; repeat after 0.36 s every 0.075 s; after 0.85 s faster
  (every 0.05 s); after 1.4 s whole words (`deleteWordBackward`). These become the only delete
  timings: set `DS.Keyboard.deleteRepeatDelay` to 360 ms and `deleteRepeatInterval` to 75 ms so
  the emoji panel's `DeleteKey` matches.
- Space: types at touch-up unless the finger stayed within 4 pt for 0.35 s, which starts the
  trackpad (`trackpad(true)`, no space typed). Trackpad x movement emits `moveCursor` with
  gain 1.4 at 400 pt/s, 2.0 at 1000, 2.6 at 2000 (interpolate linearly, 1.0 below 100 pt/s),
  one character per 7.5 pt of effective travel (vertical travel ignored in v2).
- Shift: tap toggles `.on` (one capital, then back to `.off`); double tap within 0.3 s sets
  `.capsLock`; tap while capsLock turns it off. Holding shift and sliding to a letter types its
  capital. Holding `123` and sliding to a key types that key and returns to the page it came
  from.
- Page keys switch page; emoji emits `showEmoji`; globe emits `globe` (the view needs the real
  `UIEvent`; see step 2.3).

`Sources/MurmurTyping/Input/TextRules.swift` (pure functions over the text before the cursor,
each tested):

- `autoShift(before: String, autocapitalization: AutocapMode) -> Bool`: true at the field's
  start, after `. ! ?` followed by a space or newline, when mode is `.sentences`; per word for
  `.words`; always for `.allCharacters`; never for `.none`.
- `doubleSpacePeriod(before: String, lastSpaceTime: TimeInterval?, now: TimeInterval) -> [TypingEffect]?`: a space within
  0.6 s of the previous space, after a letter or digit, replaces the space with `. `
  (`deleteBackward(1)` then `insert(". ")`) and turns shift on.
- `smartQuote(_ mark: Character, before: String, enabled: Bool) -> String`: opening at the
  start or after space, bracket or opening quote; closing elsewhere (`‘ ’ “ ”`).
- `smartDash(before: String, enabled: Bool) -> TypingEffect?`: `-` after `-` becomes U+2014
  (the em dash character; delete one, insert U+2014).
- `standaloneI`: "i" followed by space or punctuation becomes "I".

**Tests** (`Tests/MurmurTypingTests/TypingEngineTests.swift`, `TextRulesTests.swift`): one per rule
above, plus rollover (`a` down, `s` down, `a` up, `s` up types `as`), cancelled touch types
nothing, delete timings at 0.36 / 0.85 / 1.4 s, space slide before 0.35 s still types a space.

**Verify**: typing tests → exit 0.

### Step 2.2: Design tokens

Add to `DS.Keyboard` (doc comment each, values from Reference facts): `stripHeight 44`,
`stripGap 8`, `stripGapLandscape 6`, `keycapHeight 42`, `keycapHeightLandscape 32`,
`rowGap 11` (rename `rowSpacing` usages only in the new code; keep `rowSpacing` while the old
view exists), `sideInset 6`, `popupWidthScale 1.5`, `popupHeight 54`, `popupFont` (SF 30
regular), `letterFont` (SF 22.5), `mButtonCellWidth 59`, `recordingCapsuleHeight 36`,
`recordingCapsuleWidthFraction 0.6`, `trackpadKeyBlank 0.6` (keycaps fade 60% toward the
backdrop). Delete `talkHeight`, `keyHeight`, `height`, `historyWidth`, `labelInset`, `characterKeyWidth`
and `returnWidth` only after the old `.keys` page and every reference are gone (steps 2.5 and
2.6; `grep -rn "DS.Keyboard.<name>" ios Sources` must print nothing first).

**Verify**: Mac design module build → `Build complete!`

### Step 2.3: `KeyPlaneView` (UIKit)

`ios/Keyboard/KeyPlaneView.swift`: `final class KeyPlaneView: UIView`, `isMultipleTouchEnabled = true`.

- Draws each key as a `CALayer` with `cornerRadius = DS.Keyboard.keyRadius`,
  `cornerCurve = .continuous`, background
  `UIColor(DS.Keyboard.key).resolvedColor(with: traitCollection).cgColor` (recompute in
  `registerForTraitChanges([UITraitUserInterfaceStyle.self])`), and a `CATextLayer` or SF Symbol
  `CALayer` for the glyph (shift `shift`/`shift.fill`/`capslock.fill`, delete `delete.left`,
  return `return.left` or the word from `returnTitle`, emoji `face.smiling`, globe `globe`).
  Letters show lowercase unless shift or caps lock is on, as stock iOS 26 does.
- Pop-up: a separate layer above the plane, keycap width × `popupWidthScale`, drawn above the
  key; for row 1 it overlaps the strip (the strip is inside the same keyboard view, so it is
  not clipped).
- Forwards `touchesBegan/Moved/Ended/Cancelled` to `TypingEngine` with
  `CACurrentMediaTime()`, runs a 25 ms `CADisplayLink` or `.common` timer for `.tick` while any
  touch is down, and applies effects through a `TypingController` (step 2.4).
- Globe: keep the existing `UIButton`-based `GlobeKey` approach so a long press shows the
  keyboard list: place a transparent `UIButton` over the globe key's hit rect with
  `addTarget(_, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)` sent
  to the controller.
- Accessibility: expose one `UIAccessibilityElement` per key (label = the character or the
  key's name, trait `.keyboardKey`), rebuilt when the page or shift changes; swipe typing and
  the trackpad are off while VoiceOver runs (`UIAccessibility.isVoiceOverRunning`).
- In `KeyboardViewController.viewDidAppear`, set
  `view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }` (Reference
  facts; U on hardware; log once that it ran).

### Step 2.4: `TypingController`

`ios/Keyboard/TypingController.swift`, `@MainActor final class TypingController`. Owns the
`TypingEngine`, the current `Page` and `ShiftState`, and the proxy closure. Applies effects:
`insert` → `proxy.insertText`, `deleteBackward(n)` → `deleteBackward()` n times,
`deleteWordBackward` → count characters back to the previous word boundary in
`documentContextBeforeInput` and delete that many, `moveCursor` →
`adjustTextPosition(byCharacterOffset:)`, `feedback` → `KeyFeedback.press()`. After every
text change, recompute auto-shift from `documentContextBeforeInput` and the proxy's
`autocapitalizationType`. Also call it from `textDidChange(_:)` (forward from the view
controller). Read `smartQuotesType`, `smartDashesType` from the proxy at each appearance.

### Step 2.5: Wire into the view

Replace `KeyboardView`'s `.keys` content with: the strip (Milestone 3; for now an empty 44 pt
row holding the existing `TalkKey` scaled to the strip so dictation keeps working) above a
`UIViewRepresentable` wrapping `KeyPlaneView`. Remove `.padding(DS.Keyboard.padding)`
(`KeyboardView.swift:71`) for the keys panel only (the plane draws its own 6 pt side inset);
keep it for emoji and history.

Height: `KeyboardViewController` computes the key page height from
`KeyboardMetrics(width: view.bounds.width, isLandscape: view.bounds.width > view.bounds.height, constants:)`
in `viewDidLayoutSubviews` and sets the required height constraint when it changes. Replace
every use of `DS.Keyboard.height` (`KeyboardViewController.swift:72` and `:98`, `KeyboardView`'s
`height(for:)`) with that value, then delete `DS.Keyboard.height`. The emoji and history panels
keep `emojiPanelHeight` (260) and `emojiPanelHeightCompact`; the evidence check at line 98
becomes `requested != keyPageHeight`. The emoji panel's `ABC` returns to the letters page.

Pop-ups: add the pop-up layer to the keyboard view controller's root `view.layer` (above the
SwiftUI host view), not inside `KeyPlaneView`, so a row-1 pop-up can draw over the strip
without depending on SwiftUI's clipping. `KeyPlaneView` converts the key frame with
`convert(_:to:)` before positioning it.

### Step 2.6: Remove the old key page

Delete `CharacterKey`, `TextKey`, `IconKey`, `ReturnKey`, the old `.keys` rows and
`KeyboardDictation.shiftNext` (the dictation insert should instead ask `TypingController` for
the current shift state and clear it; keep `insert`'s leading-space rule). Keep `KeyFace`,
`DeleteKey`, `KeyPressStyle`, `PlainKeyStyle` only if `EmojiPanel` or `HistoryPanel` still use
them (`grep -rn "KeyFace\|DeleteKey\|KeyPressStyle\|PlainKeyStyle" ios/Keyboard`).

**Verify**: `grep -rn "CharacterKey\|shiftNext\|characterKeyWidth" ios Sources` → no matches
**Verify**: iOS compile → `** BUILD SUCCEEDED **`

### Step 2.7 [device]: Side-by-side check

Commit, push, install. README row asks the owner to type the sentence "The quick brown fox
jumps over 13 lazy dogs, doesn't it?" in Notes with Murmur and with Apple's keyboard, and to
screenshot both keyboards in light and dark. Owner reports anything that feels or looks off.

---

## Milestone 3: The suggestion strip and the m dictation button **[device]**

### Step 3.1: Strip view

`ios/Keyboard/SuggestionStrip.swift` (SwiftUI; taps here are infrequent, so SwiftUI is fine).
Layout across `stripHeight`:

- Leading cell (44 pt): history clock icon (`clock.arrow.circlepath`) while no word is being
  typed and nothing else is offered; opens the history panel.
- Middle: three suggestion cells sharing the width, SF 17 pt, text centred 25 pt from the
  top, 1 × 24 pt dividers between filled cells. Milestone 4 fills them; until then they are
  empty and the readiness caption (`dictation.readinessCaption`) shows centred in `captionFont`
  when not nil.
- Trailing cell (`mButtonCellWidth`): the **m**: `Text("m")` in `DS.Keyboard.wordmarkFont`
  sized for the strip (add token `mGlyphFont`, EB Garamond Italic about 26 pt, fallback SF
  italic), colour `DS.Keyboard.wordmark`, inside a 36 pt circle of
  `.glassEffect(.regular.tint(DS.Keyboard.talkGlassTint), in: .circle)`. Dimmed with
  `DS.Motion.disabledOpacity` while `dictation.isBusy`.

### Step 3.2: Recording capsule

Move `TalkKey`'s gesture code (the `DragGesture` with `@GestureState touching`, `isDown`,
`touchDown()`/`touchUp()`, the accessibility action calling `toggleDictation()`) onto one
`RecordControl` view that is both the m button and the capsule: it stays in the hierarchy in
every state and only changes its width and content, so a held touch keeps tracking and the
second tap of a locked recording lands on the same gesture. The m glyph stays visible at the
capsule's trailing end while recording. While `dictation.state` is `.recording`, overlay the strip with a capsule
anchored to the trailing edge, width `stripWidth * recordingCapsuleWidthFraction`, height
`recordingCapsuleHeight`, same glass and tint, containing `Waveform` exactly as `TalkKey`'s
`keyLabel` does today (flat `waveformFlat` until `heardAudio`, then red following the level).
Animate the width from the m's 36 pt with `DS.Motion` tokens (respect Reduce Motion: no
animation). The suggestion cells under the capsule hide; the leading cells stay. While
`.finishing`, the capsule shows a small `ProgressView` tinted `wordmark`. On `.failed`, the
strip shows the failure message and the "Open Murmur" button as `TalkKey.failure` does today.

### Step 3.3: Remove `TalkKey`

Delete `TalkKey` and the talk-key row. Keep its doc comments' content in the new strip code
where it still applies (glass not `.interactive()`, failed state uses `Color.clear` not
`EmptyView`, no `compositingGroup`).

**Verify**: `grep -rn "struct TalkKey" ios` → no matches; iOS compile → `** BUILD SUCCEEDED **`

### Step 3.4 [device]

Commit, push, install. Owner checks: tap m locks recording and the capsule grows from the m;
holding m records until release; text is typed at the cursor; the keys type while the capsule
shows; the history icon opens history.

---

## Milestone 4: Word model, completions and next-word predictions

### Step 4.1: Model builder

`Tools/build_typing_model.py` (run with `uv run`, standard library only, Python 3.11+). It never
downloads during a normal run; `--fetch` downloads the two pinned files into
`~/Library/Caches/MurmurBuild/typing-data/` and checks their SHA-256 (record the hashes in the
script after the first fetch; on a mismatch exit 1):

- `https://raw.githubusercontent.com/wolfgarbe/SymSpell/91fe939e9c1259813ee817e95239629c5badf8ec/SymSpell/frequency_dictionary_en_82_765.txt` (1,332,881 bytes)
- `https://raw.githubusercontent.com/wolfgarbe/SymSpell/91fe939e9c1259813ee817e95239629c5badf8ec/SymSpell/frequency_bigramdictionary_en_243_342.txt` (5,137,213 bytes)

Plus a committed hand list `Tools/typing-extra-words.tsv` (`word<TAB>count`) for contractions
(`don't can't won't I'm I'll I'd I've you're they're we're it's that's let's isn't aren't
wasn't weren't hasn't haven't didn't doesn't shouldn't wouldn't couldn't`), chat words (`ok
okay lol btw gonna wanna yeah`). Counts: each contraction gets the bigram count of its expanded
pair when the bigram file has it (`don't` = count of `do not`, `I'm` = `i am`, `can't` =
`can not` + `cannot`), else 10,000,000; chat words get 5,000,000. Contractions are stored
lowercase with a straight apostrophe (`don't`); the controller types `’` when smart quotes are
on and capitalises `i'm` to `I'm`.

Output format `.mtm` (little-endian, all offsets from file start, documented in
`Sources/MurmurTyping/Lexicon/MTMFormat.md`):

```
magic "MTM1" | u32 version=1 | u32 wordCount | u32 pairCount
u32 offsets[wordCount+1] into the string blob (words sorted by UTF-8 bytes, lowercase)
u8  unigram[wordCount]         q = clamp(round(-log10(p) * 25), 0, 255); p = count / total
u8  flags[wordCount]           bit1 contraction (bit0 reserved; SymSpell lists are lowercase,
                               so names are not marked in v1)
u32 firstLetterStart[27]       index ranges for a..z and "other"
u32 startEndBucket[26*26+1]    ranges into endIds, words grouped by (first, last) letter
u32 endIds[...]
u32 pairIndex[wordCount+1]     ranges into pairs, by first word id
(u32 secondId, u8 logp)[pairCount]
blob: UTF-8 words, no separators
```

Write `Sources/MurmurTyping/Resources/en.mtm`. Add the two source files' licence lines to
`THIRD_PARTY.md` under a new "Data" section: SymSpell (MIT) and Google Books Ngram (CC BY 3.0
Unported, attribution: "Google Books Ngram data, http://books.google.com/ngrams").

**Verify**: `uv run Tools/build_typing_model.py --fetch --out Sources/MurmurTyping/Resources/en.mtm` → exit 0; prints `words: ` ≥ 80000 and `pairs: ` ≥ 240000; file size under 8 MB (`ls -l`).

### Step 4.2: Reader

`Sources/MurmurTyping/Lexicon/TypingModel.swift`: `public final class TypingModel: Sendable`
with `public init(url: URL) throws` opening the file with `Data(contentsOf:options: .alwaysMapped)`
and `public static func bundled() throws -> TypingModel` using `TypingResources.modelURL`.
Never copy sections into Swift arrays. API (ids are indices in sorted-word order):
`id(of:) -> Int?` (binary search), `word(_ id: Int) -> String`, `unigram(_ id: Int) -> Float`
(log10 p), `range(ofPrefix: String) -> Range<Int>` (all ids whose word starts with the prefix,
by two binary searches; this range is the "trie node" the beam search in Milestone 5 walks),
`completions(prefix:limit:) -> [Int]` (top of that range by unigram),
`next(after id: Int, limit: Int) -> [Int]`, `pairLogP(_ a: Int, _ b: Int) -> Float?`,
`ids(first: Character, last: Character) -> some Collection<Int>` for swipe.

### Step 4.3: Suggestions without correction

`Sources/MurmurTyping/Suggest/SuggestionEngine.swift`: given the text before the cursor,
returns up to three `Suggestion { text, kind: .typed | .completion | .next | .correction }`.
Mid-word: slot 1 the typed word in quotes, slots 2 and 3 the best completions (bigram-weighted
by the previous word). After a space: three next-word predictions. In the strip, the most
likely goes in the centre (stock order). Tapping a suggestion replaces the current word and
types a trailing space, and the next space press is swallowed but counted for double-space
(Reference facts). Punctuation `, . ! ? ; : )` right after takes that space.

**Tests** (`SuggestionTests.swift`, using `TypingModel.bundled()`): "th" offers
"the" and "that"; after "I " next words include "am" or "have"; "don" completes to "don't";
tapping "the" after "th" yields "the " (pending-space behaviour is tested in step 4.4).

**Verify**: typing tests → exit 0. Memory check: add a test that opens the model and asserts
`TypingModel` holds no `[Int]`/`[String]` larger than 1,000 elements (inspect with `Mirror`)
so data stays mapped.

### Step 4.4: Pending space

`Sources/MurmurTyping/Suggest/PendingSpace.swift`: `public struct PendingSpace: Sendable` that
`TypingController` owns. `noteSuggestionInserted(at:)` arms it; `consumeSpace() -> Bool`
returns true once (swallow the space; the controller still records the press time for
double-space); `takesSpace(before mark: Character) -> Bool` is true for `, . ! ? ; : )` and
the controller then deletes the space before typing the mark; any other key disarms it. Tests
in `SuggestionTests.swift`: swallowed space, mark takes space, a letter disarms.

---

## Milestone 5: Spatial autocorrect and the undo chip **[device]**

### Step 5.1: Decoder

`Sources/MurmurTyping/Correct/TapDecoder.swift`. Input: the taps of the current word
(`[CGPoint]` in plane coordinates plus the key each resolved to), the key frames, the previous
word id, the model, a `UserLexicon` (step 5.3). Score for a candidate word `w` of the same length
(and with one insertion, omission or transposition, penalised):

```
score(w) = λ · log P(w | prev) + Σ_i log N(tap_i ; centre(key(w_i)), σx, σy) − editPenalty(w)
```

with `σx = 0.3 · keyWidth`, `σy = 0.4 · keyHeight`, `λ = 1.0`, bigram backoff to unigram with
weight 0.4, edit penalties: transposition 2.0, omission 2.0, insertion 3.0 nats (starting
values; Milestone 5.4 tunes them). Search: beam of 64 over word-list prefixes (use
`completions(prefix:)` ranges as the trie), keeping candidates whose every letter is within
2.5 σ of its tap. Also try one missed space by splitting the taps into two words.

### Step 5.2: Policy

`Sources/MurmurTyping/Correct/AutocorrectPolicy.swift`. On space or punctuation after a word,
replace the typed word with the top candidate only when:

- the field allows it: proxy `autocorrectionType != .no`, `keyboardType` not URL, email,
  number, phone or `.webSearch` treated as allowed, `spellCheckingType != .no`;
- the typed word is not in the model, the user lexicon, `UILexicon`, or the Murmur dictionary,
  and the top candidate's normalised posterior ≥ 0.85 and ≥ 5x the runner-up; or the typed
  word *is* a word and the posterior ≥ 0.97 with at most one edit;
- the word does not contain a digit, `@`, `#`, `/`, `.` inside, or start with a capital typed
  mid-sentence;
- the same correction was not rejected twice (persisted in `typing-rejections.json`, Milestone 7)
  or once this session.

Contractions: `im → I'm`, `dont → don't` etc. come from flag bit1 words and always apply.

### Step 5.3: User lexicon and the Murmur dictionary

`Sources/MurmurTyping/Personal/UserLexicon.swift`: a set of words that are never corrected
away and get a fixed bonus (+3 nats for a typed near-miss of a dictionary term, +1 for
`UILexicon` names): the Murmur dictionary's replacement terms (read through
`DictionaryStore.shared`, which `MurmurTyping` cannot import; the keyboard passes the terms in),
`requestSupplementaryLexicon` entries (`documentText`), and words the user kept (Milestone 7).

### Step 5.4: Undo chip and rejection

After an autocorrection, the controller remembers `(original, replacement, range)`. Delete
right after removes only the trailing space and shows the original in the strip's leading
slot (replacing the history icon while the offer is live) with `arrow.uturn.backward`
(SF Symbol). Tapping it restores the original (no space) and
rejects that pair for the session. Any other edit clears the offer.

### Step 5.5: Replay benchmark

`Tests/MurmurTypingTests/AutocorrectReplayTests.swift`, skipped unless
`MURMUR_TYPING_BENCH=1`: synthesises taps for 2,000 sentences (generate them from the
bigram file's most frequent pairs with a fixed seed, or from a committed
`Tests/MurmurTypingTests/replay-sentences.txt` you write by hand, 200 lines minimum) by drawing
each tap from a Gaussian around the intended key with noise the decoder does not assume
(σ × 1.3, plus a fixed per-run offset of 3 pt in a random direction, fixed seed), runs the decoder,
and prints: word error rate of raw taps, word error rate after autocorrect, and the share of
correctly typed words that were changed. **Gate**: errors reduced by at least 50% and correct
words changed under 1%. Tune σ, λ and the thresholds to pass; record final values and numbers
in `plans/README.md`.

**Verify**: `MURMUR_TYPING_BENCH=1 nice -n 15 swift test --scratch-path ~/Library/Caches/MurmurBuild/scratch --filter AutocorrectReplayTests` → prints the three numbers; gate holds.

### Step 5.6: Next-letter bias

Feed `HitTester` the log-odds of the next letter from the model given the current prefix
(sum of unigram probabilities of completions starting with prefix + letter), only in fields
that allow autocorrect.

### Step 5.7 [device]

Commit, push, install. Owner types normally for a day and reports wrong corrections.

---

## Milestone 6: Swipe typing **[device]**

Touch precedence (add to `TypingEngine`, with tests): a touch that goes down on a letter key
while swipe typing is enabled and VoiceOver is off becomes a swipe when it travels more than one
key pitch before the 0.36 s accent hold fires. Otherwise M2's rules apply unchanged (a short
slide types the key under the lift point; a hold shows accents). Shift, 123, delete and space
never start a swipe. No new `TouchEvent` cases; add effects
`case swipeUpdate([CGPoint])` (trail and live decode) and `case swipeEnded([CGPoint], times: [TimeInterval])`.
The controller runs the decoder on those.

`Sources/MurmurTyping/Swipe/SwipeDecoder.swift` (our own SHARK2-style implementation):

1. A touch that goes down on a letter and travels more than one key pitch (key width + gap)
   becomes a swipe; its key no longer types. A swipe that lifts on its starting key within 1.6
   pitches is a tap.
2. Resample the path to 32 equidistant points, in key-pitch units.
3. Candidates: words whose first letter's key is among the 3 keys nearest the start point and
   last letter among the 3 nearest the end (`words(first:last:)`), and whose ideal path (the
   polyline through key centres, with a small loop for doubled letters) length is within 30%
   of the gesture's.
4. Location channel: mean distance from each gesture point to the ideal path, weights rising
   linearly toward both ends (SHARK2). Shape channel: both paths scaled so the bounding box's
   longest side is 1 and centred, mean pointwise distance. Convert each to a Gaussian
   log-likelihood (σ location = 0.5 pitch, σ shape = 0.25 to start), add λ · log P(w | prev).
5. Top 80 by that score get dynamic time warping on location to re-rank.
6. Decode off the main actor, at most every 70 ms while the finger moves (strip shows the
   current best), and once at lift. A second finger down ends the swipe first.
7. Insertion: the word goes in after a space unless the text before ends in a space, newline,
   or opening punctuation; shift capitalises the first letter, caps lock all. The strip then
   offers the next three readings. Delete right after removes the whole swiped word and its
   space. The space after the word stays pending: punctuation `, . ! ? ; : ) ] } ' - /` takes it.
8. A trail (`CAShapeLayer`, last 0.45 s of points, `DS.Keyboard` colour token
   `swipeTrail`, ink at 35%) follows the finger.

**Benchmark** (`SwipeBenchTests.swift`, skipped unless `MURMUR_TYPING_BENCH=1`): synthesise
swipes for 2,000 frequent words (ideal path plus Gaussian noise σ 0.3 pitch, fixed seed) and,
if present, a subset of the FUTO swipe dataset (MIT) placed by hand at
`~/Library/Caches/MurmurBuild/typing-data/futo-swipe/` (never committed). Print top-1, top-3
and decode time p50/p99. **Gate**: synthetic top-1 ≥ 90%, p99 under 15 ms on the Mac.

**Tests**: "hello" ideal path decodes to "hello"; "pool" vs "poll" separated by the doubled-letter
loop; a slide shorter than a pitch is a tap.

Commit, push, install. Owner checks swiping in Notes and Messages.

---

## Milestone 7: Learning from typing, dictation history and the dictionary

`Sources/MurmurTyping/Personal/UserModel.swift`: unigram and bigram counts
`{word: (count: Float, lastUsed: Date)}` and `{(w1, w2): (count, lastUsed)}`, decayed with a
45-day half-life (`count · 0.5^(days/45)` applied on read), capped at 20,000 entries each
(drop the lowest decayed count). `MurmurTyping` cannot import `MurmurKit`, so the API takes
plain values: `public init(directory: URL)`, `fold(texts: [(text: String, date: Date)])`,
`learn(word:previous:)`, `save()`. The keyboard passes `AppStorage.directory`. The file names
`typing-model.json` and `typing-rejections.json` are constants in a new
`ios/Shared/TypingFiles.swift` (compiled into both the app and the keyboard), so the app's
Erase button can delete them without linking `MurmurTyping`. Written at most every 30 s and on
disappear, under `NSFileCoordinator` like `RunLog` (AGENTS.md, "The run log has two writers").
`typing-rejections.json` holds `[{original, replacement, count}]`; an entry with count ≥ 2 is
never applied (step 5.2).

Learning sources:

- **Typing**: a word counts when it is committed by space or punctuation in a field that allows
  autocorrect and is not secure. Never store anything but the word and its previous word.
- **Dictation history**: on the keyboard's first appearance after the run log changed, the
  keyboard reads `RunStore`'s runs, maps each to `(label ?? text, date)` and calls
  `fold(texts:)`; `UserModel` keeps the newest date folded and ignores older ones, so each run
  counts once.
- **Murmur dictionary**: terms are added to `UserLexicon` (Milestone 5.3), not counted.
- **Kept words**: a word the owner typed that autocorrect wanted to change and the owner
  restored twice becomes a kept word (never corrected again).

Scoring: the decoders use `log(P_model(w|prev) + α · P_user(w|prev))` with α = 0.3 to start.

Settings (in `Settings.swift` following the `hapticsEnabled` pattern, default true):
`keyboardLearning` ("Learn from my typing and dictation"). `ios/App/SettingsView.swift` gets
the toggle plus a button "Erase what the keyboard learned" that deletes `typing-model.json` and
the rejection list after a confirmation built into the page.

**Tests**: decay halves a count after 45 days; cap evicts the weakest; folding the same run twice
counts once; secure-field words are never learned (controller-level test with a stub proxy is
not possible in `MurmurTyping`, so test the policy function
`TypingLearningPolicy.allows(_ field: FieldTraits)`, where `public struct FieldTraits: Sendable`
holds `autocorrectionAllowed`, `spellCheckingAllowed`, `isSecure`, `keyboardKind` (enum:
`default`, `url`, `email`, `number`, `phone`, `webSearch`), `autocapitalization: AutocapMode`,
`smartQuotes`, `smartDashes`; the controller builds it from the proxy's traits).
Add `keyboardLearning` to `Tests/MurmurKitTests/SettingsReloadTests.swift` following the
existing keys there.

---

## Milestone 8: Correction capture to training labels **[device]**

### Step 8.1: Tracker (pure logic)

`Sources/MurmurTyping/Capture/DictationEditTracker.swift`:

- `begin(runID:, inserted:, before: String, after: String)` stores in memory only: the run id,
  the inserted text, up to 24 characters of anchor text before and after (taken from the
  context reads around the insert), and the time. Never persists context.
- `observe(before: String, after: String, now:)` re-locates the span: find the before-anchor's
  last occurrence in `before + after` and the after-anchor's first occurrence after it. Mark
  each edge `certain` only if its anchor is found exactly once, and `uncertain` if the context
  is shorter than the anchor (host truncation) or the anchor is missing.
- `settle(reason:) -> CaptureOutcome` with outcomes `kept`, `edited(final: String)`,
  `rewritten`, `deleted`, `unknown`. Settles on: keyboard disappearing, a changed
  `documentIdentifier`, the next dictation, the field emptied (a send: outcome `kept`), or 90 s
  after the last observed change.

`Sources/MurmurTyping/Capture/EditDiff.swift`: word-level LCS between inserted and final.
`edited` requires: both edges certain at the last observation; 1 to 50% of words changed;
at least one changed word; ignoring a case-only change of the first word and trailing
punctuation-only changes. More than 50% changed is `rewritten` (no label).

**Tests** (`CaptureTests.swift`): exact keep; one-word fix ("in U S" → "NUS", within 50%);
a rewrite; anchor duplicated (uncertain → unknown); truncated context (unknown); case-only
change of the first word (kept); text appended after the span (edges certain, appended text
excluded from the final).

### Step 8.2: Wiring

In `KeyboardDictation`, change `insert(_:)` to return `(date: Date, typed: String)?`, where
`typed` is the exact string passed to `insertText` (with its leading space and shift
capital). In `finish`, read `proxy.documentContextBeforeInput` and `AfterInput` just before
`insert`, keep building the run after `insert` exactly as now (its `deliverySeconds` needs the
returned date), call `RunLog.record` first, then call a new
`onDelivered: ((DictationRun, String) -> Void)?` closure with the run and `typed`. The
controller then waits 150 ms (`Task.sleep`, main actor) and reads the context again to call
`tracker.begin(runID: run.id, inserted: typed, before:, after:)`. Because `record` was queued
first on RunLog's serial queue, a later `setLabel` finds the run. The label base is `run.text`
(decision D10 limits labels to rule-pass runs, where `TrainingLabel.editBase` is `run.text`).
`TypingController` owns the tracker: calls `observe` after each of its own text effects and on
`textDidChange` (debounced 0.3 s), and `settle` on the events above.

On `edited(final)` for a run where `run.cleanup == nil` (decision D10) and
`Settings.shared.keyboardLearning` is true, call `RunLog.setLabel(final, for: run)` and set
`labelSource = .keyboard`. On any outcome, also feed substitutions to `UserModel` (Milestone 7).

### Step 8.3: Label source

In `DictationRun` add `public var labelSource: LabelSource?` with
`public enum LabelSource: String, Codable, Sendable { case history, keyboard }` (optional so old
lines decode as nil, meaning history). `DictationRun` has a hand-written `init(from:)`
(`RunLog.swift:86` to `102`): add `labelSource = try container.decodeIfPresent(LabelSource.self, forKey: .labelSource)`
there and the key to `CodingKeys`. Add public `RunLog.setLabel(_ label: String?, for run: DictationRun, source: LabelSource)`
and `Change.setLabel(_:id:source:)`; the existing `setLabel(_:for:)` calls it with `.history`.
When the label is nil or empty, `labelSource` is cleared too. History's row (`ios/App/HistoryView.swift`) shows a small
"From keyboard" tag beside "Labelled" when `labelSource == .keyboard`; the editor
(`RunEditor.swift`) keeps "Revert" working (setting nil clears both fields). The Mac reads the
field through the same struct; do not change the Mac UI (out of scope).

**Tests**: in `Tests/MurmurKitTests/` add a decode test for an old line without `labelSource`,
and a `setLabel(..., source: .keyboard)` round trip (pattern: `RunLogSharingTests.swift`).

**Verify**: `nice -n 15 make test` → exit 0.

### Step 8.4 [device]: Host probe

Before trusting captures, add a debug-only log (category `capture`) of: host context lengths
before/after, whether `textDidChange` fired after our own edits, and each settle outcome. The
owner dictates and corrects a sentence in Notes, Messages, Mail, Safari (a textarea), WhatsApp
and Slack, then the executor collects the log with the phone attached:
`/usr/bin/log collect --device --last 15m --output ~/Library/Caches/MurmurBuild/capture.logarchive`
and reads it with `/usr/bin/log show <archive> --predicate 'category == "capture"'`. Record per host whether labels were captured. **If no
host yields certain edges, STOP** and report: capture would need a different design.

---

## Milestone 9: Transformer language model spike (gated)

Only start after Milestones 4 to 7 pass their gates and the owner says go.

1. Train a small decoder-only model on the Mac with MLX (Python, `uv`), outside the app:
   about 10 to 15 M parameters (6 layers, hidden 256 to 384, 8k to 16k SentencePiece
   vocabulary, context 64 tokens). Corpus: licence-clean only (Leipzig English corpora CC BY 4.0,
   Wikipedia CC BY-SA 4.0, Tatoeba CC BY 2.0), recorded in a `training/typing-lm/README.md`
   with URLs and licences. No web scrapes of unclear licence.
2. Export to Core ML (`coremltools`), int8 weights, `computeUnits = .cpuOnly` (a Neural Engine
   compile took 84.8 s on first load in the Bark spike; a keyboard cannot wait for that).
3. Use it only to rerank the top 8 candidates from `TapDecoder`/`SwipeDecoder` and to
   predict next words after a space, never per keystroke.
4. **Ship gate** (all must hold, measured on the replay benchmark and on the phone):
   word error rate after autocorrect at least 10% lower than the bigram model; p95 rerank
   latency under 15 ms on the iPhone; added `phys_footprint` within the Milestone 0 budget;
   model file under 20 MB. Otherwise record the numbers in AGENTS.md under "Tried and not
   kept" and stop.

### Change of course, 2026-11-25: a pretrained model first

The owner called the bigram predictions "comically bad" and asked for a better model, soon.
Training our own (step 1 above) takes days, and the memory ceiling measured in Milestone 0 is
177 MB with about 50 MB used, not the 50 to 70 MB this milestone assumed. So the first attempt
is a pretrained model under a licence that GPL-3.0 distribution allows, converted to Core ML,
predicting the next word once per word boundary with the bigram model as the fallback. Three
candidates are measured on the Mac against the bigram engine: `distilbert/distilgpt2` (Apache-2.0,
88 M parameters), `EleutherAI/pythia-70m` (Apache-2.0, 96 M with untied embeddings) and
`HuggingFaceTB/SmolLM2-135M` (Apache-2.0, 135 M). Its gate: next-word top-three hit rate at
least 1.3 times the bigram engine's, model file at most 60 MB, added footprint at most 80 MB and
95th percentile latency at most 40 ms on the Mac's CPU. Memory and latency inside the keyboard on
the phone decide whether it stays.

### Fallbacks, researched and not built (2026-11-25)

Kept ready in case the pretrained model does not perform. Licences and parameter counts are
from the Hugging Face model index on 2026-11-25; nothing below has been run.

| | A. DialoGPT-small | B. Our own small model | C. A 4-gram model |
|---|---|---|---|
| What it is | GPT-2 small fine-tuned by Microsoft on Reddit conversations | The decoder-only model of step 1: 10 to 15 M parameters, an 8k to 16k vocabulary, trained on the Mac | Modified Kneser-Ney counts of up to four words, read from a memory-mapped file like `en.mtm` |
| Licence | MIT | Ours; corpora Tatoeba (CC BY 2.0 FR), Leipzig English (CC BY 4.0), Wikipedia (CC BY-SA 4.0), as listed in step 1 | Same corpora as B |
| Size on disk | 124 M parameters; about 60 MB at 4 bits, 120 MB at 8 | About 10 to 15 MB at 8 bits | About 20 to 40 MB after pruning rare counts (estimate) |
| Speed | 12 layers: about twice distilgpt2's time per pass | A few milliseconds per pass (estimate) | Well under a millisecond; no Core ML at all |
| Why it could be better | Conversational text, which is what gets typed. Same tokenizer and conversion as distilgpt2, so it drops into the same code | Small enough to leave Bark its memory; its vocabulary can be built from our own word list so most words are one token; can later be tuned on the owner's own writing (Milestone 7) | Cannot fail to load, cannot be killed for memory, and already far better than pairs: it sees three words back |
| Why it could be worse | Likely over the size and latency gates; Reddit's tone | Quality unknown until trained; likely below a pretrained model on general text | Still drifts after three or four words; no sense of the sentence as a whole |
| Cost to build | Hours: swap the model in the fetch script and re-measure | One to two days: corpus preparation, tokenizer, training, export | About a day: counting, pruning, a new section in the model file and its reader |

**Which one, by what goes wrong:**

- **The words are still poor** (the model runs fine but predicts badly for chat): try A, since it
  is the same pipeline; if A is too heavy, B trained on conversational text.
- **Too much memory or too slow on the phone**: B. A larger pretrained model can label or
  generate text for B to learn from (distillation), which is the usual way to get a small
  model's quality up.
- **Core ML will not run acceptably inside the keyboard at all**: C, which needs no neural
  runtime.

**Looked at and ruled out:** `google/gemma-3-270m` (Gemma terms and gated access; use
restrictions that do not fit GPL-3.0 distribution), `facebook/MobileLLM-125M` (non-standard
licence, gated), `LiquidAI/LFM2-350M` (its own licence), `HuggingFaceTB/SmolLM2-360M` and
`Qwen/Qwen2.5-0.5B` (Apache-2.0 but 360 M and 494 M parameters: too large beside Bark under a
177 MB ceiling), `roneneldan/TinyStories-33M` (no licence stated; children's stories only), and
FUTO's keyboard model (licence, already rejected above).

---

## Milestone 10: Documentation

- `AGENTS.md`, "iOS keyboard": replace the dictation-only description with the v2 design: the
  plane, the strip and m button, `MurmurTyping`, the `.mtm` format, autocorrect policy, swipe,
  learning and its privacy rules, capture rules (D10, D11), measured numbers. Keep the existing
  WebKit capture, crash marker, warm microphone and haptics sections. Update "Not built yet"
  item 5 (letters) as done.
- `ios/README.md`: the keyboard is now a full keyboard; how to switch learning off.
- `THIRD_PARTY.md`: Data section (step 4.1).
- `plans/README.md`: final status and measurements.

**Verify**: `grep -n "It has no letters" AGENTS.md` → no matches (today it matches at line 244).

---

## Test plan (summary)

| File | Covers |
|---|---|
| `Tests/MurmurTypingTests/LayoutTests.swift` | rows, metrics height, hit rects, bias |
| `TypingEngineTests.swift` | rollover, pop-ups, accents, delete timings, trackpad, shift, page slides |
| `TextRulesTests.swift` | auto-shift, double-space period, smart quotes and dashes, standalone I |
| `SuggestionTests.swift` | completions, next words, suggestion spacing |
| `AutocorrectTests.swift` | policy rules, contractions, rejection, dictionary terms protected |
| `AutocorrectReplayTests.swift` | benchmark gate (env-gated) |
| `SwipeDecoderTests.swift`, `SwipeBenchTests.swift` | decoding, gate (env-gated) |
| `UserModelTests.swift` | decay, cap, folding runs once |
| `CaptureTests.swift` | tracker and diff outcomes |
| `Tests/MurmurKitTests/RunLogSharingTests.swift` (extend) | `labelSource` decode and round trip |

Minimum new tests by file: Layout 6, TypingEngine 12, TextRules 8, Suggestion 7, Autocorrect 8,
SwipeDecoder 3, UserModel 4, Capture 7 (55 in `MurmurTypingTests`), plus 2 in
`RunLogSharingTests` and 1 in `SettingsReloadTests`.

Pattern for all: `Tests/MurmurKitTests/HoldGestureTests.swift` (Swift Testing, deterministic
times passed in, no sleeps).

## Done criteria

All must hold at the end of Milestone 8 (Milestone 9 has its own gate):

- [ ] `nice -n 15 make test` exits 0
- [ ] `nice -n 15 swift test --scratch-path ~/Library/Caches/MurmurBuild/scratch --filter MurmurTypingTests` exits 0 with at least 55 tests
- [ ] `MURMUR_TYPING_BENCH=1` autocorrect gate: errors reduced ≥ 50%, correct words changed < 1%
- [ ] `MURMUR_TYPING_BENCH=1` swipe gate: synthetic top-1 ≥ 90%, p99 < 15 ms (Mac)
- [ ] `make ios-build` prints `** BUILD SUCCEEDED **`
- [ ] `grep -rn "struct TalkKey\|CharacterKey\|shiftNext" ios Sources` → no matches
- [ ] `ls -l Sources/MurmurTyping/Resources/en.mtm` under 8 MB
- [ ] `git status --short` shows no modified tracked files (the pre-existing untracked
      `kk992.txt` is not ours; leave it); branch pushed; nothing pushed to `main`
- [ ] Owner's device checks recorded in `plans/README.md` for Milestones 0, 2, 3, 5, 6, 8
- [ ] Peak `phys_footprint` reported by Setup stays within the Milestone 0 budget with Bark loaded

## STOP conditions

Stop and report back, do not improvise, if:

- The drift check shows changes to in-scope files and the excerpts above no longer match.
- Milestone 0 measures a peak above the ceiling minus 8 MB before any typing code exists (no
  room for the keyboard next to Bark; the owner must choose between Bark-in-keyboard and
  typing features).
- `KeyPlaneView` cannot receive touches in the top 8 pt above row 1 or the pop-up for row 1 is
  clipped on the device (would need a different strip/plane arrangement).
- Any step seems to need code from Hex, FlorisBoard, AOSP, KeyboardKit or FUTO pasted or
  translated line by line.
- A data file's licence differs from Reference facts when fetched (e.g. SymSpell's licence
  file changed at the pinned commit).
- `en.mtm` exceeds 8 MB or the model reader copies sections into heap arrays.
- The autocorrect or swipe gate fails after tuning σ, λ, thresholds and penalties for at most
  three rounds each.
- Milestone 8.4 shows no host with certain edges.
- A verification fails twice after a reasonable fix.
- Anything requires a simulator, `make install` (the Mac app), pushing to `main`, or a signed
  build other than `make ios-install`.

## Maintenance notes

- `MurmurTyping` must stay free of UIKit and `MurmurDesign` so its tests run on the Mac. Pass
  geometry and colours in from the iOS side.
- Stock keyboard geometry changes between iOS releases (Hex documents different rows on iOS 26
  and 27). Keep all metrics in `KeyboardMetrics` and `DS.Keyboard`; re-measure from a stock
  screenshot after each iOS major.
- Autocorrect constants are tuned on synthetic taps. When typing logs exist (a later plan), retune
  on real taps and record the numbers in AGENTS.md.
- Correction capture depends on host behaviour that Apple does not document. Re-run the
  Milestone 8.4 probe after iOS updates; if a host starts truncating differently, captures fall
  to `unknown`, which is safe.
- The extension's memory is shared with Bark. Any new resident structure must be measured with
  the Setup "Memory" line before merging.
- Deferred: languages other than English; a Leipzig-built word model; neural swipe decoding
  trained on the FUTO MIT dataset; per-user touch offsets (Hex's adaptive touch); the two-thumb
  selection; iPad layout.
