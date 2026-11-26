# 002: Keyboard polish batch (text replacement, emoji, trace, number pad, revert, pill)

Written 2026-11-26 against commit `711913c` on branch `keyboard-v2`. One plan, four work units
(A to D) with disjoint file ownership so four executors can run at once, plus a docs unit (E)
after them. Each unit is self-contained: read only your unit, the "Shared rules" and the
"Repo facts".

If `git log --oneline -1` is not `711913c` and the files in your unit changed since (check with
`git diff 711913c -- <your files>`), read the changes before editing; STOP and report if they
conflict with your steps.

## Shared rules (every unit)

- Work directly in `/Users/nottanjune/Code-Projects/murmur`. No worktrees, no branches, no
  commits, no pushes, no `make ios-install`, no simulator, no iPhone Control.
- Edit only the files your unit lists. Other executors are editing other files at the same
  time. If a build fails in a file you do not own, wait 60 s and retry (up to 5 times); never
  edit it. If it still fails, report the error and stop.
- `Sources/MurmurDesign/DesignSystem.swift` is shared: add or change tokens only inside the
  enum your unit names (`DS.HUD` for B, `DS.Keyboard` for A, C, D), in a block with a comment
  naming your unit. Views contain no literal numbers or colours: every value is a token.
- Do not edit `AGENTS.md`. Put what it should say in your report under "Docs notes".
- Builds are CPU heavy on the owner's Mac: batch edits, then build. Use exactly these commands:
  - Package tests: `nice -n 19 swift test --scratch-path ~/Library/Caches/MurmurBuild/scratch -j 2 --filter <Filter>`
    (SwiftPM locks the scratch folder, so a concurrent run waits; that is expected).
  - iOS compile: `nice -n 19 make ios-build 2>&1 | tail -40` (expect `** BUILD SUCCEEDED **`).
    If it reports a locked build database, wait 60 s and retry.
- Tests: one small test file or a few cases per item, no more. Follow Swift Testing
  (`import Testing`, `@Test`, `#expect`) as the existing files in `Tests/MurmurTypingTests` do.
- Comments explain why, in plain sentences, like the surrounding code. No em dashes.
- Report: files changed, commands run with their final lines, anything unverified, Docs notes.

## Repo facts

- Swift 6, SwiftPM package with libraries `MurmurTyping` (pure keyboard logic, tested on the
  Mac), `MurmurKit`, `MurmurDesign`, `MurmurDictionary`; iOS keyboard extension code in
  `ios/Keyboard/` (compiled only by `make ios-build`).
- `TypingEngine` (`Sources/MurmurTyping/Input/TypingEngine.swift`) is pure: touches in,
  `[TypingEffect]` out. `TypingController` (`ios/Keyboard/TypingController.swift`) applies the
  effects to the host through `textDocumentProxy`, runs autocorrect at word ends
  (`finishWord`, line ~749) and builds the strip off the main thread (`scheduleStrip`, ~1117).
- `SuggestionStrip` (`ios/Keyboard/SuggestionStrip.swift`) draws three cells; slot 0 shows the
  undo chip when `typing.undoChip` is set; slot 1 is the centre.

---

## Unit A: Text replacement, robust revert, autocorrect pill

**Owns:** `ios/Keyboard/KeyboardViewController.swift`, `ios/Keyboard/TypingController.swift`
(except the two lines Unit C names), `ios/Keyboard/SuggestionStrip.swift`, new
`Sources/MurmurTyping/Correct/TextReplacements.swift`, new
`Sources/MurmurTyping/Correct/CorrectionHistory.swift`, `Sources/MurmurTyping/Correct/WordCorrection.swift`
(only if you need to touch `UndoOffer`), `DS.Keyboard` tokens, new tests
`Tests/MurmurTypingTests/TextReplacementTests.swift` and `CorrectionHistoryTests.swift`.

### A1. Text replacement shortcuts (the owner's "addr" fills in an address)

Why: the owner's Settings > General > Keyboard > Text Replacement entries must work in Murmur.
iOS already hands them to the keyboard: `UILexicon` from `requestSupplementaryLexicon` holds
contact names (where `userInput == documentText`) and the text replacements (`userInput` is
the shortcut, `documentText` the phrase). Today the code throws the shortcut away:

```swift
// ios/Keyboard/KeyboardViewController.swift:184
requestSupplementaryLexicon { @Sendable [weak self] lexicon in
    nonisolated(unsafe) let lexicon = lexicon
    Task { @MainActor in
        self?.typing.setSystemLexicon(lexicon.entries.map(\.documentText))
    }
}
```

Steps:
1. New pure `TextReplacements` (Sendable value type) in `MurmurTyping/Correct`: built from
   `[(shortcut: String, phrase: String)]`, keeping only pairs whose folded forms differ
   (`UserLexicon.fold`). `func expansion(forTextBefore text: String) -> (shortcut: String, phrase: String)?`
   takes the trailing run of non-whitespace characters before the cursor and matches it
   case-insensitively (fold) against the shortcuts, so "addr", "Addr" and "omw" match and a
   shortcut with digits or symbols works. Returns the shortcut as typed in the field.
2. `KeyboardViewController`: pass the pairs (`userInput`, `documentText`). `TypingController.setSystemLexicon`
   takes pairs: names (pairs whose folds are equal) stay system words as today; replacement
   phrases are not system words any more (a whole address is not a word); replacement
   shortcuts become system words, so autocorrect never changes "addr" to "add".
3. Expansion on space: in the space path (`typeSpace(before:proxy:finishesWord:)`, reached from
   `typeInsert` at ~661), before autocorrect runs, when `textRulesApply` and the field is not
   secure, if `expansion(forTextBefore:)` matches: delete the shortcut's characters, insert the
   phrase, then the space, and record the pair in `CorrectionHistory` (A2) with original =
   shortcut, replacement = phrase. Autocorrect does not run on that word.
4. Strip: while the trailing token is a shortcut, the centre cell shows the phrase as a
   `.correction` suggestion and A3 marks it pending; tapping it expands with a space as any
   suggestion does. Long phrases already shrink through `minimumScaleFactor`; also add
   `.truncationMode(.middle)` for this cell only if it overflows.
5. Test (`TextReplacementTests`, 3 cases): "addr" matches case-insensitively and returns the
   phrase; a name pair ("Will"/"Will") is not a replacement; "xaddr" does not match "addr".

### A2. Revert the autocorrect wherever the cursor returns to the word

Why: today the offer (`UndoOffer`, `WordCorrection.swift:207`) lives only from the correction
to the very next edit: `afterDelete` keeps it for exactly one single delete, a held delete's
repeat ends it, and `typeInsert` (~631), cursor moves and every field change set `undo = nil`.
So deleting back through a later word, moving the cursor, or the keyboard reappearing never
offers the original again. The stock keyboard offers the original whenever the cursor sits at
the end of a word it corrected and that word still reads as the correction.

Steps:
1. New pure `CorrectionHistory` (Sendable): the last 8 corrections, newest first, each
   `{original, replacement, before}` where `before` is up to 24 characters of the text that
   preceded the replacement when it was typed. `mutating func record(original:replacement:textBeforeWord:)`;
   `func offer(textBefore: String, nextCharacter: Character?) -> Entry?` returns the newest
   entry whose replacement is the suffix of `textBefore`, where the character before that
   suffix is not a letter or digit (a whole word), `nextCharacter` is nil or not a letter or
   digit, and the text before the replacement ends with the entry's `before` (compare the
   shorter of the two lengths, so a field that only shows a short context still matches).
   `mutating func remove(_:)`, `mutating func clear()`.
2. Controller: record in `finishWord` (where `undo = UndoOffer(...)` is set today, ~767) and in
   A1's expansion. Keep `undoChip: String?` as the strip's input, but derive it in `refreshText`
   (~991, which runs after every edit and host change) from
   `history.offer(textBefore: before, nextCharacter: after?.first)`, instead of from `UndoOffer`.
   `chooseUndo` (~778): delete `replacement.count` characters, insert the original with no
   space, `autocorrector?.recordUndo` as today (build the `UndoOffer` it needs, or add an
   overload taking original and replacement), remove the entry. Clear the history where the
   field changes (where `undo = nil` sits with the "Taps and an undo offer belong to the text of
   the last field" comment, ~442), not on every key. Remove the now-dead `undo` paths.
3. The chip must not show in the middle of typing a new word: it shows only when the cursor is
   right after the corrected word (rule above guarantees it: a typed letter makes the suffix
   longer than the replacement and the char before it a letter).
4. Test (`CorrectionHistoryTests`, 4 cases): offered right after the space is deleted ("the"
   with text "I saw the"); offered after deleting back through a later word ("I saw the cat "
   then delete "cat " leaves "I saw the"); not offered when a letter follows the cursor; not
   offered once the word was edited ("thex").

### A3. Translucent pill on the centre suggestion that the space will apply

Why: on the stock keyboard the word the space bar will autocorrect to sits in a soft pill in the
centre cell, so the owner knows a correction is coming. `scheduleStrip` already calls the same
`evaluate` that `finishWord` uses, but puts the result in the centre only through
`stripCorrection` (`WordCorrection.swift:137`), which hides a replacement that merely extends
the typed letters, although the space still applies it.

Steps:
1. In `scheduleStrip`, keep the evaluation and take `replacement?.text` (what the space will
   type, the same value `finishWord` types) as the pending word. If it is not already the
   centre suggestion, merge it into the centre with `SuggestionEngine.merging(correction:into:)`
   (check it removes a duplicate elsewhere in the strip; if not, drop the duplicate). A1's
   shortcut phrase is also pending. Publish `autocorrectSlot: Int?` (1 or nil) in the same
   main-actor `Task` that publishes `suggestions`, so the two never disagree.
2. `SuggestionStrip.cell(at:)`: behind slot 1's label when `typing.autocorrectSlot == 1`, a
   `RoundedRectangle(cornerRadius: DS.Keyboard.autocorrectPillRadius, style: .continuous)` filled
   with `DS.Keyboard.autocorrectPill` (white at about 0.16 opacity in dark, black at about 0.07
   in light; define it as a dynamic colour the way the other `DS.Keyboard` colours are), inset by
   `DS.Keyboard.autocorrectPillInset`. It appears and leaves with `.transition(.opacity.combined(with: .scale(scale: DS.Keyboard.autocorrectPillStartScale)))`
   under a spring (`DS.Keyboard.autocorrectPillSpring`, response about 0.28, damping 0.86),
   animated on `autocorrectSlot != nil` only, so it does not re-animate on every keystroke while
   the same correction stays pending. The label text changes without animation.
3. ProMotion: SwiftUI animations run at up to 120 Hz when the bundle's `Info.plist` has
   `CADisableMinimumFrameDurationOnPhone` = true. Confirm it is in `ios/Keyboard/Info.plist`
   (it is generated from `ios/project.yml`; if missing, STOP and report, do not edit either).
4. No new tests for the pill.

**Done when:** `--filter "TextReplacementTests|CorrectionHistoryTests|TypingEngine|Suggestion"` passes,
`make ios-build` succeeds, and `grep -n "undo = UndoOffer\|afterDelete" ios/Keyboard/TypingController.swift`
shows no remaining use of the old one-shot path.

---

## Unit B: Crisp, smooth voice trace (Mac HUD and iPhone capsule)

**Owns:** `Sources/MurmurDesign/VoiceTrace.swift`, `DS.HUD` trace tokens and
`DS.Keyboard.traceDotPitch`, `Sources/Murmur/UI/HUDView.swift`, the `VoiceTrace(` call in
`ios/Keyboard/SuggestionStrip.swift` (that one call only; Unit A owns the rest of the file, so
change just its arguments), `Tests/MurmurDesignTests/VoiceTraceDotsTests.swift` (rename allowed).
Do not change `VoiceTraceModel.swift`: the signal is right.

Why: the owner calls the trace low resolution on the Mac. Root cause: it is vector drawing, but
the body is sampled on a dot grid of `DS.HUD.traceDotPitch` 2.8 pt (3 pt on the phone), so the
whole shape has 11 rows and about 43 columns of resolution, and brightness is quantised to 10
levels (`VoiceTrace.draw`, `VoiceTrace.brightness`). The owner chose (2026-11-26) a smooth vector
body: one continuous filled shape, no dots.

Steps:
1. Replace the grid and dots with an outline sampled every `DS.HUD.traceSampleSpacing` (1 pt)
   across the view's width. Keep the current motion ideas, expressed in points instead of
   columns and as fractions of the half height instead of rows: newest in the middle, history
   to both edges over `traceSeconds`; three strands with their wavelengths
   (`traceStrandColumns` x 2.8 pt), speeds and phases; the slow writhe; the gaussian smoothing
   of levels across x; the taper onto the middle line over the outer `traceEdgeTaper`.
2. Geometry per sample x: each strand has a centre `h_i(x)` (as now) and a half thickness
   `t_i(x) = traceThinHalf + (traceLoudHalf - traceThinHalf) * voice`, in points. The body
   (fades in with `smoothstep(traceBodyFrom, traceBodyTo, voice)`) spans the strands as now.
   Build one `Path` that is the union of the three ribbons (top edge left to right, bottom edge
   back, closed) and the body band, and fill it once with the tint at full opacity, non-zero
   rule, so overlaps do not brighten: one cohesive liquid silhouette with crisp anti-aliased
   edges. Silence is a hairline (`traceThinHalf` about 0.75 pt) along the middle. Use
   quadratic curves through midpoints (or a polyline at 1 pt spacing) so no facets show.
3. A soft rim without blur or gradients (the design system forbids both): fill the same shape a
   second time first, offset outward by `traceRimWidth` (about 1.5 pt, built from thickness +
   rim), at `traceRimOpacity` (about 0.3). The edge fade by age becomes the taper only.
4. Inactive (`isActive` false, the phone before audio arrives): the hairline in `idleTint`,
   clock paused, as now. Reduce Motion: as now (no carrier travel, 15 Hz).
5. Keep the draw closure free of state: compute the paths (or the plain edge arrays) outside
   `Canvas`, under the `GeometryReader`, and expose a pure static function the test can call,
   for example `VoiceTrace.outline(levels:width:height:time:reduceMotion:) -> (top: [CGFloat], bottom: [CGFloat])`.
6. Remove `Grid`, `brightness`, the dot and halo tokens (`traceDotPitch` in both enums,
   `traceBaseRadius`, `traceLitRadius`, `traceHaloRadius`, `traceLevels`, `traceLitThreshold`,
   and so on) and their uses. `VoiceTrace.init` loses `pitch`; update both call sites.
7. Test (one file, 3 cases): silence gives `top - bottom` about `2 * traceThinHalf` everywhere;
   a loud steady level gives a middle thickness well above that and stays inside the height;
   edges taper to the hairline. Update the `MURMUR_TRACE_PREVIEW` preview test (in the same
   file today) to render the new look and run it:
   `MURMUR_TRACE_PREVIEW=$HOME/Library/Caches/MurmurBuild/trace-preview nice -n 19 swift test --scratch-path ~/Library/Caches/MurmurBuild/scratch -j 2 --filter VoiceTrace`
   Report the PNG path; the reviewer will look at it.

**Done when:** `--filter "VoiceTrace|MurmurDesignTests"` passes, `nice -n 19 make build CONFIG=debug 2>&1 | tail -5`
succeeds (the Mac app compiles), and `grep -rn "traceDotPitch\|Grid(size" Sources ios` is empty.

---

## Unit C: Number pad for number fields, and space returns to letters

**Owns:** `Sources/MurmurTyping/Layout/KeyKind.swift`, `KeyboardLayout.swift`,
`KeyboardMetrics.swift`, `Sources/MurmurTyping/Input/TypingEngine.swift`,
`Sources/MurmurTyping/Input/Types.swift`, `ios/Keyboard/KeyPlaneView.swift`, `DS.Keyboard` tokens,
and in `ios/Keyboard/TypingController.swift` only `kind(of:)` (~481) and the
`engine.setPage(traits.keyboardKind == .number ? .numbers : .letters)` line (~330), plus any
`switch` that stops compiling because of the new enum cases. Tests:
`Tests/MurmurTypingTests/TypingEngineTests.swift` (add cases) or a new `NumberPadTests.swift`.

### C1. A real number pad

Why: a number field opens Murmur on the 123 page today (`TypingController` ~330). iOS does show
a custom keyboard for `.numberPad`, `.decimalPad` and `.asciiCapableNumberPad`, so Murmur can
draw the stock 3 x 4 pad. (For `.phonePad` and `.namePhonePad` iOS always shows its own keyboard,
so there is nothing to do there.)

Steps:
1. `FieldKeyboardKind` (`Types.swift`): add `.decimal` beside `.number`; `kind(of:)` maps
   `.decimalPad` to `.decimal`. Grep every `switch` on the kind and every `== .number`
   (`grep -rn "\.number\b" Sources ios`) and treat `.decimal` like `.number` (no autocorrect,
   no swipe, and so on).
2. `Page`: add `.numberPad`. `KeyboardLayout.rows(for: .numberPad, ...)`: rows `1 2 3`,
   `4 5 6`, `7 8 9`, then bottom: left slot `.` for `.decimal`, else `.globe` when `showsGlobe`,
   else empty; `0`; `.delete`. `rows` needs the field kind for this, which it already receives.
3. `KeyboardMetrics.frames`: for the number pad, three equal keycaps per row across the full
   width with the existing key gap and row geometry (same 4 rows, same height, so the keyboard
   does not change height). Keep the empty bottom-left slot as no key; the controller's touch
   backing already makes the area touchable.
4. `KeyPlaneView`: digits in a larger font (`DS.Keyboard.numberPadDigitUIFont`, about 28 pt
   regular) with the stock letters under 2 to 9 (`ABC`, `DEF`, `GHI`, `JKL`, `MNO`, `PQRS`,
   `TUV`, `WXYZ`) in `DS.Keyboard.numberPadLettersUIFont` (about 10 pt, semibold, wide tracking).
   No pop-ups on the pad. Delete keeps its repeat.
5. `TypingController` ~330: `.number`, `.decimal` open on `.numberPad`. No page switching exists
   on the pad. The strip and the m stay.
6. Test (2 cases): rows for `.numberPad` with `.decimal` hold "." and "0" in the bottom row and
   12 keys at most; a tap on the "5" frame in an engine on `.numberPad` emits `.insert("5", ...)`.

### C2. Space after a number or symbol goes back to letters

Why: the owner types `5`, space, and expects to keep typing letters with no extra tap, as on the
stock keyboard. Today space on the numbers or symbols page stays there
(`TypingEngine.ended`, `case .space:` calls `typeSpace`).

Steps:
1. `TypingEngine`: a flag set when a character is typed while `page` is `.numbers` or `.symbols`
   (in `typeCased`), cleared whenever the page changes (`setPage`, a page key, the return
   below). In `ended`, `.space`, not trackpad: after `typeSpace`, if the flag is set and the page
   is `.numbers` or `.symbols` and the field is not `.number`/`.decimal`, set `page = .letters`,
   `recomputeFrames()`, append `.setPage(.letters)`, in the same effect batch so it is
   instant. Space with nothing typed on the page stays on the page. Several digits then space
   also return.
2. Check `TypingController.apply` handles `.setPage` from a space the same way it does from a
   page key (plane redraw, shift recheck). Fix only inside your owned lines if it does not.
3. Test (2 cases): letters, tap 123, tap "1", tap space: effects contain `.setPage(.letters)`
   and `engine.page == .letters`; letters, tap 123, tap space: page stays `.numbers`.

**Done when:** `--filter "TypingEngine|NumberPad|KeyboardLayout|KeyboardMetrics"` passes and
`make ios-build` succeeds.

---

## Unit D: Emoji in Apple's order, current Unicode, Apple's size

**Owns:** `Tools/gen_emoji.py`, new `Tools/apple_emoji_order.swift`, new
`Tools/apple-emoji-order.txt` (generated), `Sources/MurmurKit/Emoji/EmojiData.swift` and
`EmojiNames.swift` (generated), the `Makefile` (one new target), `THIRD_PARTY.md` (CLDR version
line), `ios/Keyboard/EmojiGrid.swift` (cell glyph only), `DS.Keyboard.emoji*` tokens.

Why: the picker is ordered by Unicode's `emoji-test.txt` 16.0, and Apple's order differs
(Activity before Travel, clothing in Smileys & People, hearts in Symbols, gendered families
hidden, its own order within sections). The owner's iPhone and Mac (macOS 27.2.1) are already
on Unicode 17 emoji. Apple's exact lists are on this Mac: the private framework
`/System/Library/PrivateFrameworks/EmojiFoundation.framework` has class `EMFEmojiCategory` with
class methods `PeopleEmoji`, `NatureEmoji`, `FoodAndDrinkEmoji`, `ActivityEmoji`,
`TravelAndPlacesEmoji`, `ObjectsEmoji`, `SymbolsEmoji` (each an `[String]`, in display order)
and `computeEmojiFlagsSortedByLanguage` (all flags, Apple's order, 260 on this Mac). This was
probed on 2026-11-26: People 482, Nature 218, Food 130, Activity 123, Travel 131, Objects 227,
Symbols 302, and Unicode 17 emoji present. Only the generated order (a list of public Unicode
sequences) is committed; no Apple code or file is copied, and nothing private ships in the app.

Steps:
1. `Tools/apple_emoji_order.swift`, run as `swift Tools/apple_emoji_order.swift <out.txt>`:
   `dlopen` the framework path above (`.../Versions/A/EmojiFoundation`), get the class with
   `NSClassFromString("EMFEmojiCategory")`, call each selector with `perform`, and write one line
   per section: `smileys`, `nature`, `food`, `activity`, `travel`, `objects`, `symbols`,
   `flags`, a tab, then the emoji separated by single spaces. Exit non-zero if any list is
   empty. Write the result to `Tools/apple-emoji-order.txt`.
2. Fetch Unicode 17.0 `emoji-test.txt` and CLDR 48 annotations into
   `~/Library/Caches/MurmurBuild/emoji/` with curl:
   `https://www.unicode.org/Public/emoji/17.0/emoji-test.txt`,
   `https://raw.githubusercontent.com/unicode-org/cldr/release-48/common/annotations/en.xml`,
   `https://raw.githubusercontent.com/unicode-org/cldr/release-48/common/annotationsDerived/en.xml`.
   If a URL 404s, try the next CLDR release tag (`release-48-1`); STOP and report if none work.
3. `gen_emoji.py`: add the order file as a new first argument. Section membership and order come
   from it. Match each Apple string to its fully qualified `emoji-test` sequence ignoring U+FE0F
   on both sides, and emit the `emoji-test` form. An Apple entry missing from `emoji-test` is a
   hard error naming it ("Apple has newer emoji than emoji-test.txt; pass a newer Unicode
   version"). `emoji-test` bases Apple does not list are left out; print their count. Keep the
   skin tone table and the names logic as they are, keyed by the emitted form. Update the
   docstring and the generated header (versions, inputs). Keep the section ids, titles and SF
   Symbols the app already uses.
4. `Makefile`: target `emoji` with `UNICODE ?= 17.0` and `CLDR ?= 48` that fetches the three
   files into `~/Library/Caches/MurmurBuild/emoji/`, runs step 1, then the generator with
   `python3 -I`. This is the update process: after Apple ships new emoji (usually an x.4 release
   of iOS and macOS together) and the Mac is updated, run `make emoji UNICODE=<new> CLDR=<new>`;
   the generator fails loudly if Unicode is behind Apple.
5. Size: `DS.Keyboard.emojiGlyphSize` 30 to 36 pt (the reviewer calibrates it against a stock
   screenshot later, so keep it one token). Make sure a 36 pt glyph is not clipped at the
   panel's smallest cell (`emojiMinCellHeight`, 34): raise `emojiMinCellHeight` to 40 and check
   `EmojiPanel`'s row computation still gives 4 rows in portrait at the 257 pt keyboard (read
   the code and write the arithmetic in your report). Scale `emojiToneGlyphSize` by the same
   ratio.
6. Tests: run the existing emoji tests; fix only test expectations that hard-code Unicode
   order, and list each change in your report.

**Done when:** `make emoji` runs end to end, `git diff --stat Sources/MurmurKit/Emoji` shows the
regenerated files, `head -3 Sources/MurmurKit/Emoji/EmojiData.swift` names Unicode 17.0 and
Apple's order, the first emoji of Smileys is 😀 then 😃 😄 😁 😆 🥹, `--filter "Emoji"` passes,
and `make ios-build` succeeds.

---

## Unit E: Docs (after A to D are reviewed)

One executor updates `AGENTS.md` from the four reports' Docs notes: the emoji paragraph (Apple
order source, Unicode 17, `make emoji` as the update process), the listening trace paragraph
(smooth vector body, why the dots went), the key plane notes (number pad, space returns to
letters, phone pad is iOS's own), text replacement through `UILexicon`, the correction history
and the pill. Replace superseded sentences; keep the file's style (plain past-tense facts with
dates, no em dashes).

## Final review and device check (advisor)

1. Re-run every unit's done criteria and a full `nice -n 19 swift test --scratch-path ~/Library/Caches/MurmurBuild/scratch -j 2`.
2. Read every diff for scope and the design-system rules; view the trace preview PNG.
3. `make ios-install`, then one short iPhone Control pass: stock emoji panel beside Murmur's (set
   the glyph size from the measured ratio), type "addr " in Notes, a number field, "5 " then
   letters, an autocorrect with its pill, delete back to the corrected word for the revert chip.
4. Commit and push.

## Maintenance notes

- Apple's lists come from a private framework; if `EMFEmojiCategory` disappears in a future
  macOS, `make emoji` fails at step 1 and the committed `Tools/apple-emoji-order.txt` still
  regenerates the current data.
- `CorrectionHistory` matching depends on `documentContextBeforeInput`, which some hosts
  truncate; that is why `before` compares only the overlap.
