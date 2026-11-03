# Flow-style UI rework (macOS)

Date: 2026-11-02. Approved by the user in conversation.

Replace the "Liquid Glass over neo-brutalism" direction with an aesthetic modelled on Wispr
Flow's desktop hub: classical serif display type over a rounded geometric sans, a cream and
lavender light theme, a warm near-black dark theme, white cards with hairline borders, a
sidebar with an inset content pane. We take the aesthetic, not the brand: no Flow logo,
waveform mark, name or copy.

## Sources

- wisprflow.ai stylesheet tokens (`--base-color--*`, `--_text-collection---font--*`).
- Mobbin, Wispr Flow iOS: onboarding, home, dictionary, style screens.
- wisprflow.ai/whats-new, "Dark Mode for Desktop Is Here" (2026-10-19), screenshot sampled
  for the dark theme and the desktop layout.

## 1. Fonts

- `Resources/Fonts/` holds `EBGaramond[wght].ttf`, `EBGaramond-Italic[wght].ttf`,
  `Figtree[wght].ttf` (variable, from google/fonts, SIL OFL 1.1) and both `OFL-*.txt`.
- Shipped by the `Makefile` `app` target into `Contents/Resources/Fonts/` and activated by
  `ATSApplicationFontsPath = Fonts` in `Resources/Info.plist`. No code registration, no
  `Bundle.module`.
- Names: EB Garamond family "EB Garamond" (PostScript `EBGaramond-Regular`, `-Medium`, ...);
  Figtree PostScript `Figtree-Regular`, `-Medium`, `-SemiBold`, `-Bold` (its nameID 1 reads
  "Figtree Light", so resolve by PostScript name or typographic family, and verify).
- `DS.Font` builds each role through a helper that checks `NSFont(name:size:)` and falls back
  to the SF equivalent, so `swift build`/tests and a broken bundle still render.
- Roles: `display` (Garamond 34), `stat` (Garamond 40, used for the big word count),
  `title` (Figtree Medium 26, page titles like "Welcome back"), `heading` (Figtree SemiBold 15),
  `body` (Figtree 14), `bodyEmphasis` (Figtree Medium 14), `control` (Figtree Medium 13),
  `caption` (Figtree 12), `eyebrow` (Figtree SemiBold 11, uppercase, tracking 1.0),
  `counter` / `counterLarge` stay SF monospaced (digits must not shift).

## 2. Color tokens (adaptive light / dark)

| Token | Light | Dark | Use |
|---|---|---|---|
| `chrome` | `#F2F1F6` | `#1F1F1F` | sidebar and title-bar area |
| `pane` | `#FBFAF7` | `#1A1A1A` | inset content pane |
| `paneEdge` | `#1A1A1A` @ 10% | `#2B2B2B` | pane outline |
| `card` | `#FFFFFF` | `#1A1A1A` | list cards, settings cards |
| `cardHover` | `#F7F6F2` | `#222222` | row under pointer |
| `field` | `#F2F1F6` | `#141414` | inputs |
| `hairline` | `#1A1A1A` @ 12% | `#2A2A2A` | card borders |
| `divider` | `#1A1A1A` @ 8% | `#262626` | row dividers |
| `navSelected` | `#F0D7FF` | `#303030` | selected sidebar item |
| `navSelectedInk` | `#4B2A63` | `#EDEDE8` | glyph/text on selected nav |
| `ink` | `#1A1A1A` | `#EDEDE8` | primary text, selected-card border |
| `inkSecondary` | `#666666` | `#8A8A85` | times, notes |
| `inkTertiary` | `#AAAAAA` | `#4F4F4E` | placeholders, disabled |
| `selected` | `#FFFFEB` | `#2E2C22` | "this one is on" fill |
| `onSelected` | `#1A1A1A` | `#EDEDE8` | text on `selected` |
| `primary` | `#1A1A1A` | `#EDEDE8` | primary button fill |
| `onPrimary` | `#FFFFFF` | `#1A1A1A` | primary button text |
| `stat` | `#034F46` | `#5FB3A3` | big serif numbers |
| `highlight` | `#FFA946` | `#FFA946` | single accent word in a display line |
| `record` | `#FF6C4C` | `#FF6C4C` | recording only |
| `onRecord` | `#FFFFFF` | `#FFFFFF` | glyphs on `record` |
| `hud` | `#1A1A1A` | `#2A2A2A` | listening capsule |
| `toast` | `#1A1A1A` | `#EDEDE8` | toasts ("Copied") |

## 3. Shape, depth, motion

- `DS.Radius`: `tag` 6, `control` 8, `nav` 8, `card` 12, `option` 16, `pane` 20; primary
  buttons are `Capsule`.
- `DS.Stroke`: `hairline` 1, `selected` 1.5.
- `DS.Shadow.float`: black 8% (dark: 40%), radius 6, y 2. Only for floating surfaces: HUD,
  toasts, popovers. Cards have no shadow.
- `DS.Motion`: keep `panel`, `lamp`, `meter`, `copiedHold`; `press` becomes a 0.98 scale +
  opacity change, no positional sink.
- Delete `DS.Brutal`, `DS.Glass`, `DS.Grid`, `PaperBackground`, `brutalSurface()`,
  `outlinedGlass()`. Afterwards `grep -rn "Brutal\|Glass\|glassEffect\|PaperBackground\|paperDot"
  Sources/Murmur` must find nothing (except unrelated words in comments, which should go too).

## 4. Components (`Components.swift`)

- `cardSurface()` modifier: `card` fill, `hairline` stroke, `Radius.card`. `Card` view (was
  `BrutalCard`): optional eyebrow title above a `cardSurface()` body.
- `Eyebrow`, `Tag`, `Note`: restyled with the new tokens. `Tag(isHighlighted:)` uses
  `selected` fill + `ink` hairline.
- `FlowButtonStyle(kind:isSelected:compact:dense:)` (replaces `BrutalButtonStyle`):
  `.primary` capsule `primary` fill; `.secondary` `card` fill + `hairline` stroke, radius
  `control`; selected = `selected` fill + `ink` 1.5 pt stroke + leading `checkmark` glyph.
  Pressed = `Motion.press` scale. Disabled = 40% opacity.
- `ChoiceKeys`: a row of option chips using `FlowButtonStyle(.secondary, isSelected:)`.
  Selected still reads without color (stroke weight + check glyph).
- `RecordButton`: `record` circle, white dot idle / white rounded square while recording;
  no ink outline, no slab.
- `SearchField`, text fields: `field` fill, `hairline` stroke, radius `control`, Figtree.
- `LevelMeter`: keep geometry; lit segments `record`, unlit `inkTertiary`.
- `Toast`: dark capsule, small green `checkmark.circle.fill`, `Shadow.float`. Use it for the
  existing "Copied" feedback if that is currently inline text.
- `OptionCard` (new, Flow's selectable card): `Radius.option`, `hairline` stroke, selected =
  `selected` fill + `ink` 1.5 pt stroke. Use where settings choose between described options
  if any exist; don't force it elsewhere.

## 5. Main window (`MainWindow.swift`)

```
┌──────────────┬───────────────────────────┐
│ ● ● ●        │                       ☀   │
│              ╭───────────────────────────┤
│ Murmur       │  Welcome back             │
│ ▣ History    │  1,204 words (serif)      │
│   Dictionary │  TODAY                ⌕   │
│   Settings   │  ╭───────────────────────╮│
│              │  │11:42  Can we push...  ││
│ ┌──────────┐ │  ╰───────────────────────╯│
│ │ ● Record │ │                           │
│ │ Bark ✓   │ │                           │
│ └──────────┘ │                           │
└──────────────┴───────────────────────────┘
```

- Custom sidebar + inset pane (not `NavigationSplitView`): `HStack(spacing: 0)` on `chrome`.
  Sidebar width token `DS.Window.sidebarWidth` (220). Title bar stays hidden; the traffic
  lights sit over the sidebar, so the sidebar's top padding clears them
  (`DS.Window.trafficLightClearance`). Remove the paper strip and its `onGeometryChange`
  sizing; it existed only for the glass dock.
- Sidebar: app name "Murmur" (Figtree SemiBold 18, no logo glyph), nav items for each
  `MainWindow.Section` with SF Symbols (`waveform` History/Transcriptions, `book.closed`
  Dictionary, `gearshape` Settings), selected item = `navSelected` fill, radius `nav`.
  Footer: everything the `TransportDock` showed (record button, elapsed/counter, engine
  status, stand-in "preparing" highlighted tag, recording notice entry point), laid out
  vertically in a `cardSurface()` box. Keep every existing behaviour and binding of
  `TransportDock`; only its placement and styling change. Rename to `SidebarTransport` or
  keep the name, executor's choice.
- Pane: `pane` fill, `UnevenRoundedRectangle` with only the top-leading corner at
  `Radius.pane`, `paneEdge` stroke, inset from the window top by the title-bar height so the
  corner shows. Top-right of the pane: `AppearanceToggle` restyled as a plain `sun.max` /
  `moon` icon button.
- `MainNavigation.shared` and `Section` keep their API: ⌘,, menu bar, notice and the old gear
  path still call `MainNavigation.shared.show(.settings)`.

### Transcriptions

- Page title "Welcome back" (`title`), then a stat line: total words across runs in the
  store in `stat` font and color ("1,204 words"), with a `caption` "dictated with Murmur"
  under it. Compute from data already in `RunStore`; if no cheap word source exists, count
  words of the delivered text. Hide when there are no runs.
- Runs grouped by day with `Eyebrow` headers ("TODAY", "YESTERDAY", then a date). Each group
  is one `cardSurface()` with `divider` lines between rows. Search icon at the right of the
  first header row expands the existing `SearchField`.
- Row: time column (`caption`, `inkSecondary`, fixed width token) + transcript text (`body`).
  Every existing row feature stays: copy, edit, save chip, delete, timing, engine label,
  stand-in label, delivery timing. Secondary actions appear on hover in the trailing edge;
  metadata (engine, timing) on a second `caption` line.
- Clear-history confirmation and empty state keep their behaviour; empty state uses a
  `display` serif line (e.g. "Hold the key and *speak*." with "speak" in `highlight`).

### Dictionary and Settings

- Same pane chrome. Page title in `title`. Groups as `Card`s with `Eyebrow` headers, rows
  separated by `divider`. Inline `ChoiceKeys` keep working. Long lists (engine picker) stay
  system pickers. No literal values.

## 6. HUD (`HUDView.swift`, `HUDPanel.swift`)

- Drop `.glassEffect` and the ink outline. Capsule filled with `hud`, `Shadow.float`, `record`
  bars. Same size tokens; `HUD.margin` grows enough that the shadow isn't clipped by the
  panel.

## 7. Comparison window

- Restyle through the new components and tokens only; layout unchanged. `DashboardHTML`
  stays as is.

## 8. App-wide

- `Settings.appearance` (system/light/dark) unchanged; still applied via `NSApp.appearance`.
- Window minimum sizes stay; adjust only if the sidebar makes content cramped.

## 9. Documentation

- Rewrite the header comment of `DesignSystem.swift` and the "Design system" section of
  `AGENTS.md` to describe this direction. Rules to state: red means recording (`record`
  only); yellow/cream means selected (`selected` fill + ink stroke + check glyph); no
  literal values in views; no gradients; shadows only on floating surfaces; display serif
  only for big moments (stats, empty states), Figtree everywhere else; fonts ship through
  `ATSApplicationFontsPath` and fall back to SF.

## 10. Verification

- `nice -n 19 swift build -c debug -j 2 --scratch-path ~/Library/Caches/MurmurBuild/scratch`
  must pass with no new warnings in touched files.
- `nice -n 19 swift test -j 2 --scratch-path ~/Library/Caches/MurmurBuild/scratch` must pass.
- `nice -n 19 make app CONFIG=debug` must succeed, and the bundle must contain
  `Contents/Resources/Fonts/*.ttf` and `ATSApplicationFontsPath` in its Info.plist.
- Font names resolve: a small `swift` script that registers the three files with
  `CTFontManagerRegisterFontsForURL` and prints `NSFont(name:size:)` for every name `DS.Font`
  uses.
- The grep in section 3 returns nothing.
- Visual check in the running app is the user's (no `make install`/`run` without asking).
