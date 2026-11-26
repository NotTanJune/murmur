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
  HUD trace. Nothing else.
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

**Apple's sentence embedding for emoji search** (`NLEmbedding.sentenceEmbedding(for: .english)`,
blended under the keyword ranker, with a cached table of one vector per emoji). Measured on
2026-11-26 on the Mac: over 51 in-sample queries the first five held an accepted emoji 94% of the
time with keywords alone and 96% blended; over 20 held-out queries 15 against 14. Embedding the
1,906 emoji took about 6 s. It added nothing held out, and it was the only memory risk in the
keyboard besides Bark, so the owner chose keyword-only search and the code, its cache file and
its tests were deleted. A retry would need a model that beats keywords on the held-out set
before it is worth a load in the extension.

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
embeds. The deployment target is iOS 26.0. Version 1 was dictation only (a talk key and no
letters). On the `keyboard-v2` branch it is a full keyboard: letters, number and symbol pages, an
emoji panel, autocorrect, suggestions and swipe typing, with dictation on the **m** in the
suggestion strip (`plans/001-keyboard-v2.md`). Sections below that describe the talk key are
version 1's and partly superseded. **The iPhone app is the owner's own**, installed from this
Mac with `make ios-install`: there is no TestFlight or App Store build to prepare for
(2026-11-26), so the Xcode Cloud notes below describe set-up that is not in use, and the
language model can stay a local file outside git. S1-mini never runs on the phone, so the rule pass and Apple
Intelligence are its cleanup engines, and the phone defaults to Bark Clean where the Mac
defaults to Apple.

**The emoji picker is Murmur's own, built to resemble Apple's.** `UIInputViewController` offers
no way to show Apple's emoji keyboard (only the next-keyboard and keyboard-list calls), so
`EmojiPanel` draws one, laid out as iOS 26's is (2026-11-26): a "Describe an Emoji" search field
at the top (a capsule with a magnifying glass; tapping it opens search mode, below), a grid that
scrolls sideways, and the category bar. There is no section title any more: the selected
category in the bar names the section. The field takes the title's place and is taller, so the
panel fits four rows in portrait and three turned, where it fitted five and three. The
panel matches the stock keyboard's size (measured 2026-11-26 from the owner's screenshots, iPhone
15 Pro, 393 pt): 7 columns (pitch about 56 pt, `emojiColumns`), glyphs about 37 pt wide on
screen (a 40 pt font), a row pitch of about 54 pt, four rows, and a keyboard about 40 pt taller
than the stock letters keyboard. In portrait the keyboard is therefore `emojiExtraHeight` (48 pt)
taller while the grid shows (305 pt; `TypingController.setEmojiPanelShown`, called from
`KeyboardView.show`, added in `keyboardHeight` only in portrait and never together with search's
own extra height), which leaves the grid 213 pt, four rows of about 53 pt. Landscape is
unchanged. There is no
Genmoji button, by the owner's decision. Its data is `Sources/MurmurKit/Emoji/EmojiData.swift`,
generated by `Tools/gen_emoji.py`. **Order and membership are Apple's** (2026-11-26): the
sequence and the categories come from this Mac's private EmojiFoundation `EMFEmojiCategory`,
read by `swift Tools/apple_emoji_order.swift`, and only the resulting list of public emoji
sequences is committed (`Tools/apple-emoji-order.txt`); nothing private ships. The sequences are
matched to Unicode 17.0's `emoji-test.txt`
(`https://www.unicode.org/Public/17.0.0/emoji/emoji-test.txt`) and named from CLDR 48; the script
never downloads, and its header gives the URLs. Update with `make emoji UNICODE=<v> CLDR=<v>`
after Apple ships new emoji (usually an x.4 release, and this Mac updates). The generator fails
if Unicode is behind Apple (an Apple entry `emoji-test.txt` lacks). 41 `emoji-test` bases that
Apple hides are left out: the gendered families, the family 👪, 🧑‍🤝‍🧑 and ten flags. The glyph is
40 pt in portrait and `emojiGlyphSizeCompact` 30 pt in landscape (rows of about 37 pt), the tone
row's glyph 35 pt (26 scaled by 40 / 30) and the minimum cell height `emojiMinCellHeight` 40 pt.
The new size has not been seen on a device.
Skin tones cover single-modifier forms only, so couples and two-tone handshakes show their base
form with no variants. A long press shows the tone row; the choice is remembered per base emoji
in the shared defaults (`EmojiTonePreference`), the grid shows that form, and Frequently Used
records the typed form. The tone row cannot rise above the keyboard's top edge, so for the first
row it opens below the pressed emoji instead (above it everywhere else). **Press, hold and slide** (2026-11-26, unverified on a device): the grid's
long-press recognizer keeps reporting after it opens the row, and forwards the finger's location
in the panel's coordinates (`onToneDrag`) and its lift (`onToneRelease`). While it is down the
grid's scrolling is switched off, and the row highlights the tone under the finger (the current
tone's fill) with a `KeyFeedback` tick at each change. Lifting over a tone chooses it as a tap
does; lifting after sliding onto the row and away closes it and types nothing; lifting without
ever reaching the row leaves it open for a tap. `ToneRowLayout` in `EmojiPanel` is the one
source of the row's position and cells for drawing and hit testing. **Changing a chosen tone**
(fixed the same day): the grid shows the remembered toned form, so `showTones` always resolves
the base with `EmojiCatalog.base(ofToned:)`; it had treated a non-Frequently-Used emoji as its
own base, found no tones for a toned form and returned without opening the row.

**The grid is UIKit, not SwiftUI.** `EmojiGrid` (`ios/Keyboard/EmojiGrid.swift`) is a horizontal
`UICollectionView` with its own `EmojiGridLayout`: one section per category, each starting on a
fresh column, cells recycled as a `UILabel` with the glyph and nothing else. The first version
was a `LazyHGrid` of about 1,900 SwiftUI cells, each with a tap and a long-press gesture, and it
scrolled badly on a Release build on an iPhone 15 Pro. Category taps also failed while it was
moving, because `ScrollPosition.scrollTo(id:)` does not interrupt momentum and a 400 ms guard
(`isScrollingToSection`) then swallowed the offset updates. Do not go back to it. The grid tells
SwiftUI only three things: the section in view changed (`onSection`, called on a change and never
per frame), an emoji was chosen, or skin tones were asked for (a long press or the VoiceOver
"Skin tones" action). A category tap (`EmojiGridController.scroll(toSection:)`) stops any
deceleration or running scroll with `setContentOffset(current, animated: false)`, then animates
to the section's first column; every tap is honoured at once, and until the finger takes the
grid again the offset does not move the highlight away from the tapped section (the last
sections cannot reach the leading edge). `EmojiPanel` keeps the search field, the category bar and
the tone row. The grid reloads only when its `reloadToken` changes, which search uses for its one
row of results (`rows: 1`); the picker's own grid never changes it.

**Emoji search** (2026-11-26; nothing here has run on a device). Tapping the field switches
`KeyboardView` to its `.search` panel. The top of the keyboard becomes a Cancel button and the
field (the query drawn by the panel with its own caret, not a text field, because the keys are
Murmur's and the host's proxy is not the query), with one row of results under it
(`EmojiSearchPanel`, which reuses `EmojiGrid` with one row; Frequently Used while the query is
empty), and the key plane stays visible below on the letters page. Choosing a result types it
through the grid's path (`actions.insert`, `EmojiRecents.record`, `KeyFeedback.press`) and keeps
search open; the grid shows the user's remembered skin tone for each result, and long press on a
result does nothing. Return (the plane shows "search") and Cancel close search back to the grid,
as does the plane's emoji key, and the keyboard going away mid-search. **The seam is
`TypingController.searchSink`**: `beginSearch` sets it, and `apply` hands every insertion,
delete (repeats included), word delete and return to it before any text rule, autocorrect,
suggestion, swipe or auto-shift code runs; a touch-down while it is set does not recheck shift,
turn swiping on or ask for the next-letter bias, and `runTextRefresh` does nothing until
`endSearch`, which asks for the pass again. The m, the strip and its history button are not shown
in search, so there is no dictation. **The keyboard is taller while searching**:
`TypingController.keyboardHeight` adds `searchExtraHeight` (`DS.Keyboard.emojiSearchRegionHeight`
less the strip's 44 pt, 40 pt in portrait: 297 pt in all) and the plane keeps its own height,
through the same required height constraint as everything else, which `onHeightChange` re-lays
out. A taller keyboard after it first appeared was observed to apply on the owner's phone on
2026-11-26 (search opened and the keyboard grew by its extra height; an earlier ignored growth, on
2026-11-22, was before the constraint was required); the panel still lays out in the height it
gets, and with less than the region needs it puts the field and the results
in one row (`EmojiSearchPanel.compact`), where Cancel is missing and the emoji key and return go
back. **The engine** is `EmojiSearch` (`Sources/MurmurKit/Emoji`, pure and tested), over
`EmojiNames.swift`, which `Tools/gen_emoji.py` generates from the CLDR 48 English annotations
(`common/annotations/en.xml` and `annotationsDerived/en.xml`, Unicode License v3, in
`THIRD_PARTY.md`): each base emoji's name and keywords. Search is keyword only, with no model.
It tokenises and stems the query ("crying", "cries" and "cry" agree), drops filler words, and
scores a whole-name match above a name word, a keyword and prefixes of each (only the last query
word may be a prefix, as it is being typed), rewards matching more of the query's words, and
breaks ties by a short hand-written list of the most common emoji and by fewer words in the
entry. It is synchronous and runs on the main actor at each key, with no debounce: a query took
a median 2.5 ms and at most 5.6 ms in a debug build on the Mac (`EmojiSearchModel`). Results
show the remembered skin tone, and the results row has no long press and no tone action
(`EmojiGrid` is made without `onTones` there). **Measured on the Mac**
(`MURMUR_EMOJI_EVAL=1 swift test --filter EmojiSearchEvaluation`, 51 queries plus 20 held-out
descriptive ones): an accepted emoji is first for 45 of 51 and in the first five for 48 of 51
(94%); held out, first for 12 and in the first five for 15 of 20. The ranker was tuned on the
51 queries, so those numbers are in-sample. Vague wording ("take care", "my bad", "sounds
great") is where it misses. Unverified on a device: everything about the taller keyboard and the
look of the field.

**The history list is UIKit too.** `HistoryList` (`ios/Keyboard/HistoryList.swift`) is a
`UITableView` inside `HistoryPanel`, which keeps the header and the empty state. The SwiftUI
version, a `ScrollView` of `Button`s with `KeyPressStyle`, felt inaccurate on a device on
2026-11-22: a short flick could end as a tap that typed a row and closed the panel, and the
list did not follow the finger like a system list. That cause is inferred from how SwiftUI
buttons arbitrate inside a scroll view, not traced on the device. The table reloads only when
the rows change, so a SwiftUI pass never resets the scroll, and its iOS 26 edge effects are
hidden as the SwiftUI list's were. The emoji category bar keeps `DS.Keyboard.keySpacing`
before its delete key; without it the selected category's fill met the key's edge.

**The keyboard's height constraint is required, and the panel fits the height it gets.** On
2026-11-22 the emoji panel on an iPhone 15 Pro showed five rows with the top one cut in half,
no section title and no category bar. The keyboard had stayed 168 pt (the key page) while
`KeyboardView` forced a 260 pt frame, so SwiftUI centred the content and the keyboard clipped
46 pt off each end: padding, title, spacing and 16 pt of the first row above, spacing, bar and
padding (exactly 46) below. The height constraint on the controller's `view` (the
`UIInputView`) was at priority 999. The first size the system measures honoured it (the key
page came out at 168), but the system also pins the input view with its own required
`UIView-Encapsulated-Layout-Height` (other keyboards' conflict logs show it, for example
KeyboardKit issue 88), and an optional constraint never beats a required one, so changing the
constant did nothing and logged nothing. That mechanism is inferred from the screenshot's
geometry and those logs, not traced on this device. The constraint is now required, as Apple's custom keyboard guide writes it
("change its primary view's height constraint"); UIKit logs a constraint conflict while the
system's size and ours differ, and that log is expected. Separately, `KeyboardView` fills the
height it is given instead of a fixed frame, and `EmojiPanel` keeps the search field and bar at their
sizes and gives the grid the rest, dropping rows so none is under `DS.Keyboard.emojiMinCellHeight`
(40 pt), down to `emojiMinRows` (3): a 168 pt keyboard shows three rows, not a clipped panel.
The grid's vertical offset is pinned to 0 in `scrollViewDidScroll`. The key page, and so
every panel, is 257 pt in portrait, and the owner's phone reported 257 requested and 257 shown
on 2026-11-26, so the required constraint does resize the keyboard there. (The report that
showed it went with the diagnostics.)

**Capture runs in WebKit, and Apple may close the path.** A keyboard extension cannot record:
it lacks the entitlement, so `AVAudioEngine` and audio queues fail inside it. A `WKWebView` in
the keyboard's own view hierarchy can still call `getUserMedia`, because WebKit records in its
own media process under the containing app's microphone permission. `WebMicrophone` hosts a
1x1 web view, and its page posts base64 Float32 samples back over a script message handler.
Several details are load-bearing:

- The view stays in the hierarchy at `alpha` 0.01. Hidden or removed, WebKit throttles it.
- The page loads from `https://murmur-keyboard.invalid/`, which is never fetched; the https
  origin only gives `getUserMedia` its secure context.
- The `AudioContext` is created when the microphone opens and not before: creating one can take
  audio focus or move a Bluetooth route while the keyboard is merely loaded. With "Keep
  microphone ready" on (the default) that is at each appearance, so the route can move then.
- The page reports the context's own rate, which was 48 kHz in the spike and can arrive at
  other rates, for example a Bluetooth headset's 16 kHz. `PCMConverter` resamples to the
  engine's format, so nothing assumes a rate.
- **Capture modes, and why (the Dynamic Island).** The island showed a speaker icon beside the
  orange microphone dot whenever the keyboard was up. The dot is the microphone in use and
  cannot be hidden; the speaker is most likely WebKit reporting the page as playing audio,
  because the page's `ScriptProcessorNode` fed a zero-gain `GainNode` into `context.destination`
  under `navigator.audioSession.type = 'play-and-record'`. `WebMicrophone.CaptureMode` has two
  setups. `recordOnly` (the first try) connects the processor to an `AnalyserNode` with no
  output, which a context pulls on its own, so nothing reaches `context.destination`.
  `playAndRecord` is the original graph, known to deliver audio. **`audioSession.type =
  'record'` is not a valid value** (the spec lists `auto`, `playback`, `transient`,
  `transient-solo`, `ambient` and `play-and-record`), so the page's attempt is ignored and the
  session stays `play-and-record` in both modes: record-only differs only in the audio graph.
  Whether that removes the speaker icon is pending a device check. If both modes look the same
  on the phone, remove the machinery (the mode, the fallback, the status field and the Setup
  line) and keep the original graph. Whether this WebKit processes a `ScriptProcessorNode`
  without an output path is also unverified, and an `AudioWorkletNode` is no better (WebKit
  pulls it from the destination too), so the fallback is automatic: a `recordOnly` open that
  delivers no audio within 1.5 s of the page's `started` message, or within the 3 s start
  deadline, stops the page and restarts it once in `playAndRecord` (once per open, even if
  record-only worked on an earlier open), without calling `onEnded`, so it cannot show the
  permissions message. A silence after the fallback fails as before and puts the mode back to
  the last one that worked. The permissions message therefore takes about 4.5 s when a started
  page stays silent and about 6 s when the page never posts `started`. The first audio of an
  open stores the mode in the shared defaults (`keyboardCaptureMode`); the owner's phone
  reported `recordOnly` on 2026-11-26. Every process starts in `recordOnly` even when `playAndRecord`
  is stored, so one transient silence cannot pin the fallback for good; the result of that
  open decides the mode for the rest of the process, at the cost of up to about 1.5 s on
  the first open of a process on a phone where record-only never works. The log line `web
  microphone starting in <mode> mode` and the page's reported audio session type say which
  ran. Every page message carries a run number and a stopped run's late messages are dropped,
  so a fallback's old run cannot cancel the new run's deadline. `WebMicrophone` is created
  before `PhoneEnvironment.configure()` runs (a stored property of the controller), so it reads
  the shared defaults only in `attach(to:)`.
- **Heartbeat dead-man's switch.** Swift calls `murmurHeartbeat()` every second, and the page
  ends capture if none arrives for 3 s. A keyboard that froze or was killed does not leave the
  microphone open. It runs whenever capture is open, warm or attached to a hold.
- The heartbeat and the deadlines are timers in the `.common` run-loop modes. In the default
  mode only, a `ScrollView` tracking a finger (emoji, history) stops them and about 3 s of
  scrolling starved the page's watchdog.
- The 3 s deadline starts when the page is asked to start (`begin()`), so page load and
  WebContent launch do not count; a page that never loads fails after 10 s.
- `open()` ends with a reason if no audio message arrives within 3 s (Full Access off, or the
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
root holds `bark-loading` (the crash marker) and `keyboard-status.json` (`KeyboardStatus`:
Bark's state, the language model's state, Full Access and when it was written), which the
keyboard writes at each appearance and at each change of either state and the Setup tab reads.
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
in the spike's first build and drops the App Group. `ios/Local.xcconfig` (the signing team) is
git-ignored. The generated `Murmur.xcodeproj` (with its shared `MurmurPhone` scheme and a copy of
`Package.resolved` under `project.xcworkspace/xcshareddata/swiftpm`) and the two `Info.plist`
files are committed, because Xcode Cloud builds the checked-in project and resolves no packages
itself: after editing `project.yml` or `Package.resolved`, run `make ios-project` and commit the
result. `ios/ci_scripts/ci_post_clone.sh` writes `Local.xcconfig` on Xcode Cloud from
`CI_TEAM_ID` and `CI_BUILD_NUMBER` (TestFlight needs a rising build number) and turns off macro
and plugin fingerprint checks. Both targets read `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` from `Base.xcconfig`, and the app declares
`ITSAppUsesNonExemptEncryption = false` (only HTTPS is used), so TestFlight asks no export
question. The App Store Connect app is "Murmur", bundle ID `ai.pivotstudio.murmur.ios`.

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

**The microphone is warm.** The first version opened capture at touch-down, which ran
`getUserMedia`, a new `AudioContext`, `resume()` and the first 2048-frame block before anything
was recorded, so the start of speech was lost while the key already showed red. It now does what
the Mac does with `Settings.alwaysOpenMic` and `CaptureRouter`. With `alwaysOpenMic` on (the
default; Settings → Microphone → "Keep microphone ready"), `keyboardAppeared` calls
`WebMicrophone.open()` and the page delivers samples until `close()`. Between holds they go into
a `PreRollBuffer` (MurmurKit, 0.3 s, at the page's own rate; a rate change clears it), and a press
drains it into the start of the hold's `pending` audio before any live block. The pre-roll is
never written anywhere else: not to the recording, the run log or the status file. A press while
the microphone is still `warming` attaches at once and takes samples as they arrive, so nothing
the microphone could have heard after the press is lost. With the setting off, or after a failed
open, the press opens the microphone as before and release closes it. The setting is read at each
appearance and not at each press. `keyboardDisappeared` always closes the microphone and drops
the pre-roll. A warm microphone that ends after it had delivered audio (a content-process kill,
a call or Siri, a lapsed heartbeat, backgrounding) is treated as transient: the key shows
"Microphone paused · press to start" and the keyboard reopens it once after 1 s, at most 3 times
in 30 s (`maxAutoReopens`, `autoReopenWindow`; after that only a press reopens it). An open that
never delivered audio shows the failure message with "Open Murmur", and a press retries as a cold
open. A microphone that ends while a released hold is finishing never abandons it: `finish`
still types the dictation, and a reopen then does not relabel that hold's rate. One that ends
under a hold still listening fails the hold: "Dictation failed. Try again." if audio had flowed
(and the same automatic reopen), the permissions message if none had. The cost is a base64 message about 23 times a second for as long
as the microphone is open, and iOS shows its microphone indicator for the same time; the Settings
footnote says so.

**The warm microphone closes when idle.** An open microphone keeps the Dynamic Island's indicator
lit, so "Keep microphone ready" no longer holds for as long as the keyboard is up.
`KeyboardDictation.warmIdleSeconds` (30) after the last hold finished, or after the keyboard
appeared if no hold has run, `closeIdleMicrophone` closes it and drops the pre-roll. The timer
(`idleCloseTask`) restarts at the end of every hold (`finish`, `fail`, `holdTimedOut`) and at each
appearance, and is cancelled by a press and by `keyboardDisappeared`. The idle close is not a
failure: `micState` goes to `off`, the key shows no caption, nothing reopens it (a pending
automatic reopen is cancelled when the idle clock fires, and a reopen that does run starts a
new idle clock), and the next press
opens it cold as it does with the setting off (a cold open, so the start of that first hold can be
clipped). A `failed` microphone is left as it is, and a hold in flight or an engine being wound
down defers the close. The pre-roll exists only while the microphone is warm and delivering.

**Sounds.** A hold plays a start tone once the microphone hears: after `attachMicrophone` returns
when the microphone was already `live` (capture first, as on the Mac), and otherwise at the
hold's first live samples (`noteHeard`), so a cold open does not beep before it listens
(`.warming` has no audio, so it waits). It plays a done tone right after `insert` succeeds, both through `KeyboardSounds` and gated by
`Settings.soundEnabled` (the Mac's key, default on, shared through the defaults suite; Settings
tab → Sounds on the phone). The Mac's Tink and Pop are macOS system files and cannot ship on
iOS, so the phone uses `AudioServicesPlaySystemSound` with iOS system sounds 1113
(`begin_record.caf`) and 1114 (`end_record.caf`). The API is public; the IDs are not documented
by Apple, and an ID that stops existing plays nothing. The call is dispatched to a global queue
so it cannot delay capture or the typed text. Once, before the first sound, it also calls
`AVAudioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)` on the process's shared
session, ignoring the result and never activating it or changing its category; the recording
is in WebKit's own session, so this may have no effect, and it is unverified. The page uses `echoCancellation`, but the start
tone can still reach the recording because the microphone is already open when it plays, and
Bark has to ignore it, as the Mac's engines ignore its Tink. Unverified on a device: whether
system sounds play while WebKit holds a recording session (`AVAudioSession` can mute system
sounds during recording), in a keyboard extension with Full Access, and whether the tones are
audible without being picked up by the microphone.

**Haptics.** `KeyboardHaptics` plays the user's own patterns through Core Haptics
(`HapticPlayer`, one lazily made `CHHapticEngine`), at the same moment as the start tone
(`playStartTone`) and right after `insert` succeeds. The user designed them by feel on the phone on
2026-11-22, in a temporary in-app lab that has since been deleted: start `tap@0 i1.00 s0.50 |
tap@70 i1.00 s0.50` (two firm taps 70 ms apart) and done `buzz@0 i1.00 s0.20 d50 | tap@80 i1.00
s0.50 | tap@120 i1.00 s0.50` (a 50 ms soft buzz, then two taps). Do not change them without the
user. If Core Haptics refuses a pattern or the engine fails, the UIKit generators stand in: a
`.medium` impact for start, the system's success pattern for done. A failed hold (`fail`, a
release with no audio, the finish watchdog) plays the system's error pattern. The generators are
attached to the keyboard's view (`init(style:view:)`); the engine and the start generator are
prepared right after the attach, and the outcome ones at the release. Main actor only, and always
after the attach or the insert, never ahead of them. `Settings.hapticsEnabled` (key
`hapticsEnabled`, default on, re-read by `reloadFromDefaults`) gates them, as Settings tab →
Haptics on the phone; the Mac ignores it. A keyboard extension plays haptics only with Full
Access. Unverified on a device: whether Core Haptics plays in the keyboard while WebKit holds a
recording session (a silent success cannot be detected, so the fallback does not cover it). The
lab's keys `hapticLabStart`, `hapticLabDone` and `hapticLabActive` may linger in the shared
defaults on the user's phone; nothing reads them.

**Key taps.** Every ordinary key gives the input click and a light haptic tap
(`UIImpactFeedbackGenerator`, `.light`, at strength 0.7) at touch-down, as the stock keyboard does, through
`KeyFeedback` (`ios/Keyboard/KeyFeedback.swift`). SwiftUI buttons get it from `KeyPressStyle` or
`PlainKeyStyle` (the emoji category bar) when `isPressed` turns true, so the feedback no longer
waits for the release; the delete key (on each repeated deletion too), the globe key
(`.touchDown`), emoji cells, the tone row and history rows call it themselves. The talk key keeps
only the click, because its start pattern follows within moments. `Settings.hapticsEnabled` gates
the tap; the system's Keyboard Clicks setting governs the click. Unverified on a device.

**Readiness is shown on the key.** `KeyboardDictation.micState` is `off`, `warming` (opened, no
samples yet), `live` or `failed`, and `heardAudio` is true once the current hold has its first
samples, pre-roll included. While recording, the `VoiceTrace` is a flat line in `DS.Keyboard.waveformFlat`
until `heardAudio`, then the red trace, so it never claims a microphone that is not hearing yet
(`VoiceTrace` takes an `idleTint`, red by default, so the Mac's HUD is unchanged).
Idle, "Murmur" has a caption under it only while something is not ready: "Starting
microphone…" while `warming`, "Loading Bark · Apple until ready", "Bark not downloaded · using
Apple" and the stopped and failed equivalents. Nothing shows when all is ready.

**Start latency is not measured any more.** The first-audio timing, its log line and its Setup
line went with the diagnostics on 2026-11-26. No device number was ever recorded for it.

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

**The key is a HUD, with no text.** While recording, the main key becomes the Mac's HUD: the
glass capsule below with the `VoiceTrace` (a grey flat line until the hold has audio, then the
red trace; see "The listening trace"). The user removed the live words that briefly showed on it on
2026-11-22. Do not bring them back.

**The keys follow the iOS 26 keyboard.** Measured from a screenshot of the stock keyboard on
2026-11-25: every key has one flat fill (`DS.Keyboard.key`, RGB 68 in dark), with no drop shadow
and 10 pt continuous corners. The punctuation page's seven keys
(`@ . , ? ! ' -`) are the stock letter width (`characterKeyWidth`, 33 pt, shrinking to fit a
375 pt phone), between shift at the leading edge and delete at the trailing one, as in the stock
keyboard's bottom letter row, so the gaps either side match it (six keys left 26 pt gaps); the digit and symbol pages fill
the row. Return shows the `return.left` glyph for a plain new line and a word ("send", "go") only
when the field names a job. Light mode uses white keys, which is inferred, not measured.

**Geometry is measured from the owner's screenshots (iPhone 15 Pro, 393 pt, 2026-11-25).** Stock
keycaps are 43 pt tall on a 54 pt row pitch (11 pt between rows), 32.7 pt wide with 6 pt gaps;
stock lowercase letters have a 12.3 pt x-height (`letterUIFont` is 24.5 pt) and are centred on
the keycap by that x-height. The strip is 44 pt and its gap 8 pt, so the first row starts 52 pt
below the keyboard's top edge, where the stock keyboard's starts (51 pt), and the portrait
keyboard is 44 + 8 + 4 x 43 + 3 x 11 = 257 pt. A first measurement through the SwiftUI-hosted
plane showed about 16 pt of extra space above the keyboard and the strip was cut to 30 pt to
compensate; once the plane was a UIKit subview that space was gone and the strip sat against the
panel's top edge (2026-11-25), so it went back to 44. Landscape
keeps the older 44 + 6 strip and 32 pt keys (`stripHeightLandscape`). The m circle and the
recording capsule are 36 pt (`mCircleDiameter`, `recordingCapsuleHeight`). The m is lifted by
`DS.Keyboard.mGlyphLift` so its x-height, not its line box, is centred in the circle. A
first-row pop-up has only the strip plus gap (38 pt) above its key inside the view, so its head
is shorter than the stock one; unverified on a device. Key glyphs are placed by optical band
(`KeyPlaneView.textFrame`): x-height for a lowercase letter, cap height for anything else.

**The key plane is UIKit, outside SwiftUI.** `KeyPlaneView` is a direct subview of the
controller's root view, above the SwiftUI hosting view, pinned to the bottom with the height of
the keyboard less the strip. The hosting view keeps the strip and the emoji and history panels,
with a clear space where the plane is; `typing.setPlaneVisible` hides the plane while a panel
shows. Touches go from UIKit's hit test to the plane to `TypingController.handle` to
`TypingEngine`. It was a `UIViewRepresentable` first, and the owner lost letters when typing
fast. Suspected causes, all changed: SwiftUI's gesture handling on the hosting view (a cancelled
character touch types nothing), a lift that hit no key typing nothing (it now types the touch's
last key), and per-key work on the main thread (shift and suggestions are one pass per run-loop
turn, `scheduleTextRefresh`, and the strip is published only when it changed). Which one was the
cause is unmeasured, and none of them was the main one: see the next paragraph.

**The keyboard is never clear anywhere.** iOS routes a touch to a keyboard extension only where
the keyboard has drawn something. On a fully clear point the touch goes to the host app's
`_UIRemoteView` and never enters the keyboard's process: no hit test, no touch, nothing in any
log of ours. The key plane was clear between its keycap layers, so a fast tap that landed in a
6 pt gap, on a keycap's edge or in the strip gap above the first row was lost. Measured on
2026-11-25 with a typing lab in the app (since removed), which logged touches in the app's own
windows while a lab field was typed in: two Murmur lines lost eight letters, the app saw exactly eight touches
in `_UIRemoteView`, each at the lost key's place and each in a gap or within a point of a
keycap's edge. Apple's keyboard and Gboard typed the same sentence 41 for 41, and Murmur with
the warm microphone and haptics off still lost four, so neither of those is involved. Ruled out
on the way: SwiftUI cancelling touches, a busy main thread (0 stalls over 34 ms), two fingers at
once (`alllll` typed while `a` was held), the system's double-tap recognizer and the strip's
redraws. The root `UIInputView` and `KeyPlaneView` are therefore filled with
`DS.Keyboard.touchBackingUIColor` (alpha 0.001), and the plane overrides `draw(_:)` with an empty
body so its layer has a bitmap. **Do not set either back to `.clear`, and do not remove the empty
`draw`.** Whether a fill that faint counts as drawn is unverified until a lab run shows no
`_UIRemoteView` touches; if it does not, raise the alpha or draw the keyboard's own backdrop.

**The top row reaches into the strip while typing.** For `DS.Keyboard.typingStripReachSeconds`
(0.35 s) after any finger lands on the key plane, the plane also takes a touch in the strip's
lowest `typingStripReach` (12 pt) and types the top-row key under it (`KeyPlaneView.point(inside:with:)`;
the touch-down is clamped to the row's top edge and logged as `reach`). On 2026-11-25, with the
lost taps fixed, a pangram came out 41 for 41 at 7 keys a second, and in the free sentence after
it the `e` of "the" landed 0.3 pt above the plane, went to the strip's SwiftUI view and was not
typed. One sample; the reach and the window are guesses, unverified on a device. A suggestion
tapped in its lowest 12 pt within 0.35 s of a key types a letter instead, which is the cost.

**Swipe typing.** Added 2026-11-25 (Milestone 6 of `plans/001-keyboard-v2.md`). The decoder is
`SwipeDecoder` (`Sources/MurmurTyping/Swipe`); the touch rules are in `TypingEngine`, which stays
pure. **Precedence.** A touch that lands on a letter of the letters page while `swipeEnabled` is
set is a candidate; the controller sets the flag at touch-down only, so a touch keeps the answer it
was born with. A candidate becomes a swipe at the first move that has carried it more than one key
pitch (q to w across) from where it landed, provided that move is within 0.36 s of touch-down
(`accentHoldDelay`) and no accent row has opened. From then on its key never types, its pop-up is
hidden, no accent row can open however long it dwells, and every move emits `swipeUpdate(path)`
with the whole path so far. Any touch that stays within one pitch, or travels later than 0.36 s,
is the old touch exactly: it types the key it landed on unless it slid more than
`slideCommitDistance` (12 pt), then the key under the lift. `TypingEngineTests` is unchanged and
`TypingEngineSwipeTests` compares the effects of one touch with the setting on and off. Shift,
123, delete, space, return, emoji and globe never start a swipe, and neither does any page but
letters. **Ending.** At the lift a path that comes back to its starting key and never went past
1.6 pitches (`SwipeDecoder.isTap`) types that key as a tap, at the point where the finger landed.
Anything else emits `swipeEnded(path, times:)` and types nothing itself. A second finger landing
on a key ends the swipe first (`swipeEnded`, then the new finger's own effects, in one batch). A
cancelled swipe emits `swipeUpdate([])`, which only clears the trail. **Decode.** While the finger
moves the controller decodes off the main thread at most every `swipeLiveDecodeSeconds` (70 ms)
and shows the best reading in the strip's centre cell (`swipePreview`); a result overtaken by a
newer one or by the end of the swipe is dropped by a generation counter. At the lift it decodes
once on the main thread, because the benchmark's 99th percentile is 0.54 ms in a release build
on a Mac (2026-11-25; a phone is slower, unmeasured) and the word must be in the field before any
later effect or key. **What
is typed.** The word goes in after a space unless the text before the cursor is empty, ends in
whitespace or ends in an opening mark (`SwipeInsertion.needsLeadingSpace`). A word typed just
before it is finished first, as a space would finish it (autocorrect, a lone "i"), unless that word
was itself swiped. Shift capitalises the first letter and is spent like a typed capital, caps lock
uppercases all, and the sentence-start rule is judged on the text with the swipe's own space in.
**The space after the word is owed, not typed** (`SwipeOffer`, the reverse of `PendingSpace`):
the next swipe types it, a typed letter types it first, and the space key, `, . ! ? ; : ) ] } ' -
/` and the rest sit against the word, so there is no space to take back. A delete after a swipe
removes one character, like any other delete, and ends the offer: the first version took the
whole word and its space, and the owner asked for a backspace per character (2026-11-25).
The strip then shows up to three other readings (best in the centre), and a tap swaps the word
for one, offering the old word back. Any other edit, or a field that no longer ends with the word,
drops the offer. A swipe resets the word-tap tracker; while its own offer stands the strip shows no revert chip, and `CorrectionHistory` keeps its entries. **Where it is off:** the
setting `Settings.swipeTyping` (Settings tab, default on), VoiceOver running, a secure, number or
phone field, a word model that has not loaded, and any page but letters. It was also off wherever
autocorrect is (`AutocorrectPolicy.allows`), until the owner asked for it in web and email
address fields and in mail apps' message fields, which turn autocorrection off (2026-11-25): a
swipe is how the word is typed, not a correction. In a web or email address field
(`TypingController.swipesJoin`) swiped words go in with no space before or after and with no
previous word as context, because an address has none. The trail is a `CAShapeLayer`
in `KeyPlaneView` over the keys, the last 0.45 s of the path. The owner uses it daily and
calls typing with it good (2026-11-26). **Not measured on a device:** the 0.36 s window and the one-pitch threshold against real thumbs, the
trail's width and look, whether the lift-time decode is quick enough on a phone, how often the
live preview flickers, the decoder's accuracy on real swipes (its noise model is synthetic), and
whether the owed-space rules feel right in Notes and Messages.

**The swipe decoder is tuned on sloppy swipes, which are still simulated.** The owner found
swiping inaccurate unless exact (2026-11-25). The first benchmark swiped neat paths with no
previous word. `SwipeBenchTests.sloppySentences` swipes 229 sentences word by word with the
previous word as context and with cut corners, overshoot, missing doubled-letter loops, ends up
to 0.6 pitch off the key and a constant thumb offset; odd sentences are held out. Held-out
first-choice accuracy with context went from 70.8% to 85.3% (top three 78.6% to 94.2%); the neat
benchmark is 92.65%. What changed: the decoder reads the five nearest keys at each end within
1.8 pitches (three within 1.2 before, which threw away about 10% of intended words), allows 50%
plus 0.6 pitch of length difference, ranks cheaply first on how near the finger passed each key
in order and re-scores the best 36, and scores a doubled letter with and without its loop.
Both stages read their tables through bare pointers (2026-11-25, scoring unchanged to the last
digit), which took the debug build's 99th percentile from 12 to 14 ms down to 5 to 6 ms, and that
paid for `scanBudget` 8,000 words read (4,000 before): held-out first choice 85.3% to 86.0%, top
three 94.2% to 95.2%, the neat benchmark 92.65% to 92.60% (one word in 2,000), debug 99th
percentile about 9 to 11 ms. The cost: an exact swipe of a rare word can lose to a common
look-alike ("swipe" reads "store" first). The noise model is a guess, so these numbers say
nothing certain about a thumb; real swipes from the owner's phone are what to tune on next
(the recorder that collected them is in git history, see "The diagnostics are gone").

**The first real swipes: 8 of 10, and what they showed.** On 2026-11-25 the owner swiped "this
is a test of swipe typing on the new keyboard" with the swipe recorder on; the ten paths are
`Tests/MurmurTypingTests/real-swipes.json`, and `RealSwipeReplayTests` replays them (the Mac
gives the phone's first reading on all ten). "swipe" came out "serious" and was not offered, and
"typing" came out "tripping" with "typing" fourth. An agent diagnosed both and changed nothing
in the decoder, because nothing it tried was clearly better without fitting ten samples.
What it found: "swipe" was never scored (the start lay nearer d than s, and `scanBudget` ran out
before the s-to-e words were read), would have been cut from the 36 re-scored words by short
frequent ones, and loses on the language model anyway (the stored pair "of serious" against a
backoff for "swipe"); the "typing" path really did run left to between e and r first, so
"tripping" is a fair reading. Against the simulated noise the real hand hits its keys (0.21
pitch from the middle keys, simulated 0.43), runs on past the last key (0.27 pitch, simulated
none), starts sideways of the first key (0.47 pitch across, 0.21 up and down) and overshoots its
turns, so a corner of the path is not evidence of a key. Measured and worth taking next: both
stages on bare pointers halved the debug 99th percentile with accuracy unchanged, which pays for
a larger `scanBudget`. A rare word like "swipe" will not come first after "of" from geometry;
that needs the owner's own words to carry weight (plan Milestone 7) and more samples.

**Next-word predictions never volunteer explicit words and do not loop.** The pair counts are
SymSpell's, taken from web pages, where adult and spam pages are loud: after "dog" the likeliest
next word was "sex", and tapping the centre cell from there wrote "video porno gratis" over and
over (the owner's screenshot, 2026-11-25). Two rules in `SuggestionEngine.predictNext`:
`neverVolunteered` (about forty explicit and spam words) are never offered as a next word,
though they still complete when typed, are left alone by autocorrect and are read from a swipe;
and within the last `repeatWindow` (12) words of the sentence a prediction that would repeat a
pair of neighbouring words is dropped, and a word already used keeps 5% of its score unless it
is one of thirty function words. Chains of centre taps are still not sentences ("the same time
to the first to be a few"): a pair model knows one word of context. That is what the plan's
language model (Milestone 9) is for.

**The strip's words come from a small transformer, with the pair model underneath.** The
owner called the pair model's predictions comically bad (2026-11-25: "my dog breeds of the same
time to the first to be a new window") and asked for a better model. It is
`distilbert/distilgpt2` (Apache-2.0, 82 M parameters, revision `2290a626`), converted to Core ML
with a 4-bit embedding and 6-bit layers (51.5 MB), a fixed window of the last 32 tokens, no
cache between calls, `.cpuOnly`. Measured on an M2 over 4,337 word positions of chat and note
style sentences (`training/typing-lm/`, 229 replay sentences and 290 from Tatoeba): the next word
is among the three offered 39.2% of the time against the pair model's 22.9%, first choice 23.5%
against 12.8%, keystrokes saved 54% against 39%; one pass takes 3.5 ms, the first load 0.55 s
and 25 MB of footprint. SmolLM2-135M was 3 points better and too large; pythia-70m was 3.5
points worse. How it works:

- **One pass per word boundary, nothing per keystroke.** `NextWordPredictor`
  (`Sources/MurmurTyping/Predict`, with our own byte-level BPE in `BPETokenizer`, checked against
  379 vectors from the reference tokenizer) returns a `WordPrediction`: a probability for each
  word of the keyboard's list that is a single token (20,182 words, 96% of the words in the
  evaluation). After a space its top three are the predictions; mid-word the same answer ranks
  the completions by typed prefix. A fresh pass mid-word was measured and is far worse (the
  letters typed so far are not how the tokenizer spells the word), and a second pass for
  two-token words gained 0.1 points, so neither exists.
- **`SuggestionEngine` still decides what is shown.** It takes the prediction only when it was
  made for the text's own word boundary, and applies every rule it had: `neverVolunteered`, no
  repeated pair, casing, the likeliest in the centre, a correction's place mid-word. The pair
  model fills any cell the prediction leaves empty and is the whole answer when there is none.
- **`SmartPredictions` (`ios/Keyboard`) owns the load, and the model loads before Bark.**
  `TypingController.keyboardAppeared` calls `prepare` at every appearance, and Bark's
  preparation waits in `SmartPredictions.waitForLoad` (at most
  `KeyboardDictation.predictionsFirstSeconds`, 8 s) before it loads. **Do not let Bark start
  first, and do not move the model's load back to the first key** (see the paragraph on the
  105 s load below). A load needs `Settings.smartPredictions` (Settings tab, default on), the
  model in the bundle and 60 MB left before the extension's limit
  (`os_proc_available_memory`). It ends with one prediction on the background queue, and only
  then is the state `ready`: Setup's Predictions row shows its check mark for a model that has
  answered in the keyboard's process, and the status file is written at every change of state.
  The `typing-lm-loading` marker is armed before the load and disarmed after that prediction,
  about a second. A marker found armed at launch means the last keyboard ended there; once is
  not proof of a memory death (an install leaves the same marker), so the first time only a
  second marker (`typing-lm-strike`) is armed and the load is tried again. With both armed
  nothing loads for `lockSeconds` (30 minutes) or until the app clears them (Setup's "Try
  again", or the switch turned on); the lock lifts by itself because a model that silently
  never returns is worse than one more try. One prediction runs at a time on a background
  queue and only the newest waiting request is kept. **It is one per process
  (`SmartPredictions.shared`), never the controller's:** iOS makes a new input view controller
  at many appearances (a screenshot does it), and a controller-owned model lost its load and
  left the marker armed, which locked every later keyboard out.
- **Why the CPU.** On the Neural Engine a first load of this file put 240 MB into the process,
  over the keyboard's 177 MB limit, for 2 ms saved per pass.
- **The model is not in git.** `uv run Tools/fetch_typing_lm.py --fetch` downloads the pinned
  weights (size and SHA-256 checked), converts them and writes the compiled model and the
  tokenizer's files into `ios/TypingLM`, a git-ignored folder the keyboard target copies whole.
  A checkout without it builds and runs on the pair model (`SmartPredictions` reports
  `missing`), and so would an Xcode Cloud build, which the owner does not use.

Known limits: it never offers a contraction as a next word ("I'm" is two tokens), it has GPT-2's
web taste ("please enable javascript to view the comments"), and everything on the phone is
unverified: whether Core ML keeps its 174 MiB compile cache in the extension's container. On the
owner's phone the load with its first prediction takes 0.80 s and adds 8.5 MB, and a prediction
takes 5 to 22 ms (2026-11-26). Setup has a Predictions row with a check mark when the model is
`ready`, and a note under it with the load time and the last prediction.
**A fine-tune exists and is not in git** (2026-11-26). `training/typing-lm/finetune.py` trained
the model for a quarter of an epoch on Tatoeba's sentences and SODA's dialogue turns, most of
them lowercased, on a Colab L4. On Murmur's own 229 sentences the next word is among the three
offered 54.5% of the time (stock 45.1%), and centre taps read like messages ("please don't worry
about it I know you will do great in your new job"). The weights are on the owner's Mac only
(`~/Library/Caches/MurmurBuild/typing-lm-ft/quarter`, SHA-256 `952ef2d8...`), built with
`Tools/fetch_typing_lm.py --weights <folder>`; `training/typing-lm/README.md` has the numbers.
The fallbacks beyond that are in `plans/001-keyboard-v2.md`, Milestone 9. **The pair model's words kept coming back on the phone: two causes** (2026-11-26). The owner
saw "my dog breeds of the same time to the first to be a new window" with the model installed,
on three builds in a row. First cause: the model belonged to `TypingController`, the controller
was replaced during the load, the load was thrown away and the marker it had armed made every
later keyboard report `stoppedLastTime`. Fixed by one model per process and two strikes before
the lock; the owner's next test still showed the pair model's words. Second cause, read off
`keyboard-status.json` after that test: the model was `ready`, but its load had taken 104.75 s
and Bark's 105.83 s in the same process, the first keyboard after an install. Alone on the same
phone the model loads in 0.64 s (a self-test in the app, since removed). The model's first load in a
container, which compiles it, started at the first key while Bark was compiling for the Neural
Engine, and waited for the whole of it; the owner's test fell inside those two minutes each
time, because each build was tried right after its install. That the load waits behind Bark's
compile is read off those times, not traced inside Core ML. The fix is the order: the model
loads at the keyboard's appearance and Bark waits for it. Verified from the Mac on the phone
the same day, with no typing: with the app launched right after an install so that a text
field took focus, the keyboard reported the model `ready` 3 s later, loaded and answered in 0.80 s, with Bark still
`loading` (it then compiled in 83.7 s); and a test in the app showed a model
that loaded first answering 160 times in a row through an 84.1 s Bark compile, median 5.8 ms
and slowest 12.1 ms. The owner then confirmed it on the phone ("it returns a real sentence
now"), and the keyboard's record of that session read: loaded and answered in 0.82 s, Bark in
0.55 s (already compiled), 16 answers, none stale, 20 of 22 strip passes with an answer, 142 MB
left, no marker armed.
**When debugging the keyboard, read `keyboard-status.json` off the phone before changing
code** (`xcrun devicectl device copy from --domain-type appGroupDataContainer
--domain-identifier group.ai.pivotstudio.murmur`): two rounds were spent on a theory the file
would have ruled out. It now carries the two states only, which is enough to see whether a
model loaded.

**The listening trace.** Added 2026-11-26, replacing the `Waveform` bars (phase-offset sines scaled
by a level), which moved whether or not anyone spoke. It was one red line first; the owner found
that jagged and asked for the reference video's braided dot matrix, then found the 11-row dot
grid low resolution and chose the smooth vector body below (all 2026-11-26). `VoiceTrace`
(`Sources/MurmurDesign`) is written from a public description of the idea and none of anyone's code.
The signal is `VoiceTraceModel`, a pure type with its own tests (`MurmurDesignTests`).
Audio is cut into 10 ms frames of RMS in dB (the phone's 2048-sample block, about 23 a second,
becomes 4 to 13 frames; the Mac passes one RMS per capture buffer, about 30 a second, repeated
for the frames since the last). A noise floor falls to a quieter frame with a 0.25 s time constant
and creeps up 1 dB a second; a speech peak jumps up and decays 6 dB a second; a frame maps between
them to 0...1 after a 4 dB gate over the floor, so a whisper and a shout both fill the height. The
range never counts as under 20 dB (a tenfold amplitude, as the anticipation rule demands), the
floor never goes below -70 dBFS and the peak never counts as under -55 dBFS, so a silent room, even
digital silence, is not amplified into motion. The envelope is a pair of first-order filters: 90% of
a step up in 35 ms and 90% of a step down in 95 ms (`riseSeconds`, `fallSeconds`, the reference's
numbers). A frame that climbs 0.3 out of a dip in the last 150 ms to at least 0.35 kicks a damped
spring (5 Hz, damping 0.32), so each word overshoots, dips under the steady level by about a third
of that and settles in about 0.3 s; the kick is sized so the first peak is `1 - bodyCeiling` (0.2)
of the height at most, and the steady level reaches 0.8. Each frame goes into a 1.8 s ring, read by
age with the frames interpolated: now in the middle, older values pushed out to both edges, so a
pause shows the last words leaving. Time since the newest frame also pushes values outward, and the
middle holds the newest frame for 0.1 s and then dies away, so a stalled feed holds no level.
The view draws one smooth vector body and no dots. `VoiceTrace.outline` samples the trace every
`DS.HUD.traceSampleSpacing` (1 pt) across the view's width and returns a top and a bottom edge.
The level is blurred along the trace with a gaussian (`traceSmoothLength`, 10 pt; the edges
`traceEdgeSmoothLength`, 3 pt; `VoiceTrace.smoothed`, mirrored at the middle), so a syllable is a
rounded bulge and never a spike. Three strands run along it as long, slow sine ribbons with
wavelengths of 146, 196 and 123 pt, speeds of 1, 0.7 and 1.25 times `traceCarrierSpeed` (0.2
cycles a second) and their own start phases, so they cross slowly and never repeat; a very slow
swell (308 pt, 0.08 cycles a second) changes their swing and thickness by 15% at most. At a
sample a strand's swing is the blurred level at that point's age (1 s each side) times
`traceReach` (0.9) of half the height, and its half thickness runs from `traceThinHalf` (0.75
pt) in silence to `traceLoudHalf` (7 pt) at full voice, so louder is fatter and the spring's
overshoot swells a syllable. An envelope plus a body band, which fades in as the level climbs
from `traceBodyFrom` (0.1) to `traceBodyTo` (0.5) and spans the strands by at least
`traceBodyReach` (0.2) of the swing, keeps the crossings from opening a hole. Everything thins
onto the middle line over the outer `traceEdgeTaper` (40%) of each side. The edges go into one
`Path` through quadratic curves between midpoints, so no facets show, and the `Canvas` fills it
once with the non-zero rule: overlaps never brighten and the edge is crisp. A copy
`traceRimWidth` (1.5 pt) wider is filled first at `traceRimOpacity` (0.3), which is the soft
rim; there is no blur and no gradient anywhere. Silence is a 1.5 pt hairline along the middle.
The owner found the 11-row dot grid low resolution on 2026-11-26 and chose a smooth vector body
over it. The pure helpers are `nonisolated`: they sit in a `View`, which is main-actor, and the
tests call them off it (a closure inside one trapped at run time before that). `outline` is a
pure function, so it is tested (`VoiceTraceBodyTests`); the view reads the model under a
`GeometryReader` and hands the `Canvas` plain arrays, so nothing mutates state in the draw (see
above). The timeline runs at 60 Hz while active and is paused otherwise. Before the phone's hold
has audio (`heardAudio` false) it is the hairline in `DS.Keyboard.waveformFlat`. Reduce Motion
stops the strands' travel and the swell (the body still follows the level) and redraws at 15 Hz.
The model lives in a `VoiceTraceSource`, fed from where the audio arrives
(`KeyboardDictation.received` and the pre-roll, `DictationController`'s capture callback). The
pre-roll goes in so the room is calibrated before the press. The Mac's `AudioCapture` reports
linear RMS and the controller maps it to the meter's old -50...0 dBFS window, so the meter is
unchanged. `MURMUR_TRACE_PREVIEW=<folder> swift test --filter VoiceTracePreview` writes
`voice-trace.png`: the Mac HUD and a 236 pt phone capsule at six moments of a synthetic
sentence. **Unverified on a device or in the HUD:** how the motion looks (the preview is stills;
whether it reads as liquid or as a plain waveform when it moves is the owner's call), whether
the spring and the 35 and 95 ms numbers feel right with a real microphone, the cost of the
Canvas at 60 Hz in the keyboard extension (a Release build on the phone has not run it) and the
phone capsule's real width (the preview assumes 236 pt). Reading the first real holds' dB values
off the phone is how to tune the model.

**The number and symbol pages follow the stock keys** (owner's screenshots, 2026-11-26).
Digits and symbols use `capitalLetterUIFont`, the stock capital height; at the lowercase size they
were about 10% taller. The quote keys are labelled with the typographic marks (” and ’) and still
type what the field's smart-quote setting says. The second symbol row ends `¥ £ €`, `#+=` is
`symbolsSwitchUIFont` (13.25 pt, smaller than `123`), and `•` is `bulletUIFont` (40 pt) so its dot
matches the stock one. Checked on the phone the same day.

**Number and decimal fields open on a number pad** (2026-11-26; unverified on a device). They
open on `Page.numberPad`, a stock 3x4 pad of digits with their letters. A decimal field puts `.`
at the bottom left; a number field with the globe shows the globe there, and otherwise that cell
is empty. It is the same height as the other pages, and has no pop-ups, accents, page switching,
autocorrect or swipe. A phone pad and a name phone pad get iOS's own keyboard, because iOS never
shows a custom keyboard there. A space typed after a character on the numbers or symbols page
returns to letters in the same effect batch (`typedOnSymbolPage` in `TypingEngine`); a space with
nothing typed on that page stays where it is.

The pad's geometry is Apple's decimal pad measured on the owner's iPhone 15 Pro (393 pt, dark
mode, 1.641 screenshot px per pt, 2026-11-26). Apple's: keys 48 pt tall on a 54 pt pitch (6.4 pt
gap), three equal columns about 123.7 pt wide with 6 pt between and about 5 pt side margins; digit
keys RGB 87 on a RGB 55 board (Murmur's letter keys are 68); the bottom-left slot (`.`, globe or
empty) and delete have no fill, only `0` does. Every digit's cap top is 11 pt below its key's top
(0.229 of the key height), the same for 1 and 0, so digits are not centred vertically; the digit
cap height is 15.8 pt (22 pt regular). Letters under 2 to 9 have a 6.7 pt cap height (9.5 pt
semibold), a cap top 35.3 pt down (0.735 of the key height in Apple's screenshot; Murmur uses 0.75 after a device comparison), and "ABC" spans 23 pt (Murmur uses 24 after the same comparison), centred. The
`.` sits on the digits' baseline and the delete glyph is about 25 pt wide. Murmur keeps the
keyboard's height, so the four rows share the same 205 pt as the letter rows (4 x 43 + 3 x 11):
keys 46.5 pt tall with 6.33 pt gaps (`KeyboardMetrics.numberPadKeycapHeight`, `numberPadRowGap`),
5 pt margins and 6 pt gaps, with text placed by the fractions above of the shortened key
(`DS.Keyboard.numberPadDigitCapTop`, `numberPadLettersCapTop`). The unfilled slots are drawn
with `touchBackingUIColor`, not clear. The light-mode digit fill (white) is inferred, not
measured. Unverified on a device.

**Text replacement and revert** (2026-11-26; unverified on a device). The system's Settings text
replacements arrive in `UILexicon` as (userInput, documentText) pairs through
`requestSupplementaryLexicon`. `TextReplacements` expands a matching trailing token on space in
prose fields (not secure, default or web search keyboards), before autocorrect looks at the
word; shortcuts are protected system words, so autocorrect never changes them, and phrases are
not. While the shortcut is typed the strip shows the phrase in the centre, with the pill. The
one-shot undo offer is gone: `CorrectionHistory` keeps the last 8 corrections and expansions with
24 characters of context each, and `refreshText` offers the original in the left cell whenever
the cursor sits at the end of a word that still reads as the replacement. It therefore comes
back after deleting through later words or moving the cursor, and is cleared only when the field
changes (`resetFieldState`). **The pill:** `autocorrectSlot` is published with `suggestions`, and
the centre cell holds whatever the space will type, even a fix that only extends the typed
letters, on a translucent continuous rounded rectangle (`DS.Keyboard.autocorrectPill*`) with a
spring keyed on its presence. The text it shows follows the same casing rule as the space
(`TypingController.casedReplacement`: with auto-capitalisation off a word typed in lowercase
keeps a lowercase start, "i'm"), without the smart apostrophe. It animates at 120 Hz through
`CADisableMinimumFrameDurationOnPhone`.

**Capitals on the keys are a narrowed SF Pro.** The stock keyboard sets its keys in SF Compact,
which an app cannot ask for and may not bundle. Fitted on 2026-11-25 to letter widths measured
from the owner's screenshots, SF Compact matches the stock capitals at about 23 pt and the stock
lowercase at about 24.5 pt, both to 0.2 pt. In SF Pro at 24.5 pt the capitals were 10% taller and
about 18% wider than stock (2.4 pt off on average). The semi-condensed named width at 23 pt
(`UIFont.Width(rawValue: -0.1)`, which iOS honoured as `wdth` 80) came out 0.7 pt too narrow on
the phone and a little tall, and the owner called it weird. Capitals are now
`DS.Keyboard.capitalLetterUIFont`: SF Pro at 22.25 pt (the stock capitals' 15.6 pt height) with
the variable font's `wdth` axis set to 90 through `kCTFontVariationAttribute`, because a named
width snaps to a step. On the Mac the straight letters are within 0.4 pt and the round ones (O,
Q, G, C) about 1 pt wide: SF Compact flattens their sides and no width of SF Pro does. Whether
iOS honours the axis set this way is unverified on a device; if it does not, the capitals are
standard width at the smaller size. Lowercase stays `letterUIFont`, already within 0.5 pt.

**A contact's name does not respell a plain word.** `UILexicon` supplies contacts' names, and many
are also words (Will, Mark, May, Rose). Both decoders used the lexicon's spelling for any word it
held, so swiped and corrected words came out capitalised at random (owner, 2026-11-25).
`UserLexicon.Entry.respellsKnownWords` is false for the system's entries: a word the model knows
types in lowercase, and for a swipe the name is the first alternative in the strip. The owner's
dictionary terms still set their own spelling, and a name the model lacks types as written.
Separately, `TypingController.recheckAutoShift` checks an automatic shift against the text at
each touch-down and takes it back if the text no longer starts a sentence: auto-shift is
otherwise worked out only after a text change or a host call, and a host call with an empty
context reads as a sentence start. That second cause is suspected, not observed.

**The swipe trail is a soft ribbon that relaxes behind the finger, and its width is a
setting.** Three versions, each from the owner's words (2026-11-25). An even 8 pt stroke of the
last 0.45 s of the path was static and rigid beside the stock keyboard's soft grey comet and
Gboard's thin fading line. A tapered outline at 35% of the label colour with a blurred shadow of
the same colour was still shiny and rigid: the shadow doubled the colour into a glow, and the
shape traced every touch sample. The trail is now `SwipeTrail` (`Sources/MurmurTyping/Input`), a
pure type that `KeyPlaneView` feeds and draws. A sample lives 0.6 s (`swipeTrailSeconds`) and the
width eases from `swipeTrailWidth` under the finger to nothing at the tail. At every frame each
sample but the newest moves a little towards the middle of its neighbours, more the older it is
(`swipeTrailRelaxRate`), so corners round off and the tail straightens as it ages: that is the
flow. The outline is one closed shape with a disc at each sharp turn (a swipe reverses at most
letters, and an outline alone folds into a hole there) and under the finger. It is drawn as four
filled copies (`SwipeTrail.layers`), each a little narrower and shorter than the last, at 5.5% of
the m's orange each (`swipeTrailUIColor`: `DS.Keyboard.wordmark` at `swipeTrailLayerOpacity`,
9% on dark keys and 16% on white ones): about 30% in the middle on dark keys with a soft edge,
and no shadow or blur anywhere. The first soft version was the label colour at 5.5% a layer; the
owner liked the shape and asked for the m's colour. The plane's display link redraws it at every frame while a finger is
down, and after the lift keeps running while the trail runs out and fades over
`swipeTrailFadeSeconds`. `Settings.swipeTrail` picks the width at the finger (thin, regular,
thick, bold: 6, 11, 15 and 19 pt), a `ChoiceKeys` card in the phone's Settings tab shown while
swipe typing is on. The look was checked on the Mac, not on the phone:
`MURMUR_TRAIL_PREVIEW=<folder> swift test --filter trailPreview` draws the trail over a dark
keyboard for three of the owner's real swipes. How it moves, and what four shape layers redrawn
at 120 Hz cost on a phone, are unverified.

**The diagnostics are gone** (2026-11-26). With typing, predictions and swiping working, the
owner asked for every test tool out of the app and the keyboard. Removed: the touch log and the
swipe recorder (`TypingDiagnostics`, `typing-diagnostics.jsonl`, `swipe-samples.jsonl`), the
two-key staged test, the window and touch probes, the stall monitor, the memory sampler, the
typing and prediction counters, the timing fields of `KeyboardStatus`, the typing lab and the
model self-test in the app, and `Tools/typing_live_log.py`. The keyboard's behaviour with them
switched off was kept line for line: the staged test's normal path is the only path now,
`relaxTouchDelays` still changes the same recognizers, and the plane's strip reach, empty
`draw(_:)` and touch backing are untouched. All of it is in git at `3b9ab87` if a problem needs
it again; the swipe recorder is the piece most likely to come back, for tuning the decoder on
real swipes. The status file is no longer rewritten every 10 s, only when a state changes, so
Setup allows a Bark load 300 s before it reads a silent `loading` as a death. A screenshot
hides any third-party keyboard until it is saved; Gboard does the same, so that is iOS and not
a bug.

**Auto-capitalisation is a setting, off by default.** The owner types in lowercase and asked for
it off (2026-11-25). `Settings.autoCapitalise` (key `autoCapitalise`, default false; Settings tab,
Auto-capitalisation). Off, `TypingController` reads every field as asking for no capitals, so
no automatic shift is set for typing, swiping or dictation; a lone "i" stays as typed, "im"
becomes "i'm", and the double-space period types no shift after it. Shift and caps lock work as
before. Do not flip the default without the owner.

**The strip is 44 pt and untrimmed; the space above it belongs to iOS and varies by app.**
iOS 26 puts a third-party keyboard inside its own rounded panel and, in some host apps, keeps a
margin above the keyboard's view that the extension can neither draw in nor remove (other
keyboards report the same; LimeIME's `docs/SAFARI_EXTRA_SPACE.md` traces it to the host's
`UIInputSetHostView` and finds that it depends on the focused field). Measured on 2026-11-25
from the owner's screenshots: in one app the m's top was 20 pt under the panel's edge (16 pt of
margin plus the strip's own 4 pt above the 36 pt m), in Notes it was about 4 pt (no margin). The
owner tuned a temporary "top trim" setting (0 to 4 pt, live on an open keyboard), settled on the
look with the stored value at 0, and saw that other apps did not follow, which is that margin.
The setting, its card and its signal are gone and `DS.Keyboard.stripHeight` stays 44: a trim
that suits a 16 pt margin would press the m against the panel's edge where there is none. What
stays from that work: `KeyboardView` places the strip directly above a clear space exactly as
tall as the plane, both from the keyboard's bottom edge, so a height iOS has not applied yet
shows as space above the strip and never between the strip and the keys. The strip is inside the
keyboard's own view, so it cannot cover the host app's content: the app is told the keyboard's
whole height, as for any keyboard.

**Typing felt heavy, and what was cut.** With the lost taps fixed the owner called typing
accurate but heavier than the stock keyboard (2026-11-25). Read off three diagnostics sessions:
a touch-down reached the keyboard a median 16 to 18 ms after it happened, and a lift's letter was
handed to `insertText` 20 to 24 ms after the lift, both about one 60 Hz frame; fingers stay down
a median 63 to 71 ms; the view was laid out 1.6 times per key. The stock keyboard runs inside
the host app, so some of the gap is the price of an extension. Changed, each unverified on a
device: (1) an ordinary letter or digit is sent straight to `insertText`; `typeInsert` used to
read `documentContextBeforeInput`, a round trip to the host on the main thread, before every
key, and now does so only for marks, the space, and when a suggestion's or a swipe's space is
waiting. (2) The plane's display link asks for 80 to 120 Hz (it asked for at most 60), and the
keyboard's `Info.plist` sets `CADisableMinimumFrameDurationOnPhone`. (3)
`viewDidLayoutSubviews` works the geometry out again only when the width, the orientation, the
globe key or the top trim changed. The owner then called typing perfect (2026-11-26); the
delays were not measured again. **The key tap is the light
impact at 0.7** (`DS.Keyboard.keyTapStrength`, in `KeyFeedback`): the owner tried light, soft and
rigid at strengths from 0.1 to 1 through two temporary settings and chose it by feel on
2026-11-25, because "heavy" was partly the tap at full strength. The settings are gone. Do not
change it without the owner.

**Checked against Apple's custom keyboard guides** (2026-11-25: "Creating a custom keyboard",
"Configuring a custom keyboard interface", and the Human Interface Guidelines page "Virtual
keyboards"). Done as they say: the four `NSExtensionAttributes`, the required height constraint,
the globe key only while `needsInputModeSwitchKey` and wired to `handleInputModeList` for all
touch events, the input click, `UILexicon`, the proxy's traits (autocorrection, spell checking,
capitals, smart quotes and dashes, the return key's job), the double-space period, caps lock, and
setup and settings in the app, not in the keyboard. Fixed on that day: `hasDictationKey` is true,
because the m is a dictation key and iOS otherwise shows its own microphone under the keyboard.
Set in `viewDidLoad` and then in `init` it changed nothing on the owner's phone (the microphone
still showed; the owner has the system's dictation switched on). The last try overrides the
property so it always reads true and sets it again at each appearance. The owner does not mind
the microphone: if it still shows, leave it and do not try further.
The letters page's bottom row
follows the field's keyboard type, as the stock keyboard's does (`KeyboardLayout.rows(for:showsGlobe:field:)`,
`TypingEngine.setField`): an email field has the space bar, `@` and `.`; a web address field has
`.`, `/` and `.com` and no space bar; a web search has the space bar and `.`; a number field opens
on the number page. `.com` keeps its case under shift, darkens when pressed and has no pop-up.
Unverified on a device. **Open gaps:** `enablesReturnKeyAutomatically` is not honoured (the
return key should dim in an empty field that asks for it; `hasText` is not reliable in every
host, and a wrong answer is a dead return key), and there is no `didReceiveMemoryWarning`
handling (the word model is memory-mapped and Bark is deliberately kept, so there is little to
release). The keyboard is iPhone only (`TARGETED_DEVICE_FAMILY = 1`),
so iPad's floating and regular widths do not apply.

**The talk key is Liquid Glass tinted brown.** The flat `DS.Color.hud` capsule blended into the
keyboard's backdrop, so the key is now `glassEffect(.regular.tint(DS.Keyboard.talkGlassTint), in:
.capsule)` in every state (idle, recording, finishing, failed). The tint is the HUD's brown, nearly
opaque near-black in light and a lighter brown (0x4A3A2E) in dark, where the HUD's own colour
would sink into the dark keyboard. It is not `.interactive()`: that adds its own touch tracking
beside the `DragGesture`, which must keep reporting touch-down at once. Do not wrap the key in a
`compositingGroup`, which flattens what the glass samples. The failed state's label is
`Color.clear`, not `EmptyView`: modifiers on an empty view render nothing, and the glass would
vanish from under the failure message. Idle and finishing, the capsule carries the wordmark, so
pressing it no longer jumps from a light key to a dark one. The m is set in EB Garamond Italic, the app icon's face
(`Tools/Fonts/EBGaramond-Italic[wght].ttf`, PostScript name `EBGaramond-Italic`), in
`DS.Keyboard.wordmark`, a soft orange (0xF2A57E) that is the same in both appearances because the
glass is dark in both. It is deliberately paler than `DS.Color.record`: red means recording and
nothing else. The keyboard target bundles the TTF and `OFL-EBGaramond.txt` from `Tools/Fonts` and
registers the font through its own `UIAppFonts` (the app target bundles only the licence text, for
Settings, Licences). `DS.Keyboard.mGlyphFont` checks that `UIFont(name:size:)` resolved and falls
back to SF italic (there is no `wordmarkFont`). The caption under the word is `wordmarkCaption` (the same orange at 90%), and the
failure message and its button use `onTalkKey`, `talkAction` and `onTalkAction`, because the old
`.primary` text is black in light mode and unreadable on the dark glass.

**Bark is prepared once per process, then warmed.** `ParakeetModels.manager()` already decodes a
second of silence on the shared manager inside every load, Mac and phone; for the batch
("On release") path that is the identical call, so the keyboard adds nothing there. For "While
speaking", whose engine goes through `OverlapWindowRecognizer`'s own `AsrManager` over the same
models, `barkPreparationTask` decodes one more second of silence through `makeBarkEngine` before
any controller sets `barkReady`; whether that pass helps is pending device numbers. Preparation
(arm the crash marker, load, warm-up) is one process-wide task that every controller awaits,
because `ParakeetModels.isLoaded` turns true when the load returns, before the warm-up ends, and a
second controller must not run a hold on the models meanwhile. A press during it uses Apple. The
marker stays armed through the warm-up. A warm-up error is logged and Bark is still used; one
that has not finished in `warmupTimeoutSeconds` (15 s) logs a fault, disarms the marker and
reports `failed`, and that result stays cached so a second warm-up never overlaps the first.
`barkLoadSeconds` includes `manager()`'s own pass.

**Bark's timings are in the log only.** The keyboard logs "Bark loaded in N s, warm-up N s" and
"release: N ms speech + N ms cleanup" (category `speech`); the status file and the Setup tab no
longer carry them. On the owner's phone Bark's first load after an install took 84 to 106 s
(the Neural Engine compile) and 0.55 s after that (2026-11-26).

**Building.** Output goes under `~/Library/Caches/MurmurBuild/ios`, never the repo.

```bash
make ios-project   # XcodeGen: ios/Murmur.xcodeproj and the two Info.plists
make ios-build     # unsigned, generic/platform=iOS, both targets, no simulator
make ios-install   # Release, signed with ios/Local.xcconfig, installed on the first physical iPhone
```

**Right after an install the keyboard can come up stock or empty.** Traced on 2026-11-26 with a temporary lifecycle log: while the keyboard that was on screen during `make ios-install` stays up, choosing Murmur (globe or list) launches nothing (no `viewDidLoad`, no crash or jetsam report), so iOS shows the stock keyboard or leaves the space empty. Dismissing the keyboard and raising it again starts Murmur, which laid out at 393 x 257 and appeared 0.18 s after `viewDidLoad`. No Murmur code runs in that window, so nothing in the keyboard can fix it; after an install, dismiss and raise the keyboard once.

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
5. **The rest of the iPhone keyboard's plan** (`plans/001-keyboard-v2.md`): learning from the
   owner's typing, edits to dictated text as training labels, and a transformer language model.

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
