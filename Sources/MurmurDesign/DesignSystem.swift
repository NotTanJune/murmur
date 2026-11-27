import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import CoreText
import UIKit
#endif

/// The design system for Murmur.
///
/// Direction: ink on paper. A warm paper ground, charcoal ink, an ochre accent, moss for
/// statistics, Fraunces for big moments over Figtree for everything else, white cards with
/// hairline borders, and a sidebar beside an inset content pane.
///
/// The rules that keep this coherent:
/// - **Red means recording.** `record` and nothing else; the record button, lamp, level
///   meter and HUD bars.
/// - **Cream means selected.** Every "this one is on" state is a `selected` fill, an ink
///   stroke and a check glyph (`KeyButtonStyle(isSelected:)`, `ChoiceKeys`, `OptionCard`),
///   so selection reads without colour. Don't invent a second selection treatment.
/// - **No gradients.** Shadows exist only on floating surfaces (HUD, toasts); cards sit flat
///   behind a hairline.
/// - **Serif is for big moments** (stats, empty states). Figtree everywhere else.
/// - **Every value a view needs lives here**; views and components never declare their own.
/// - Fonts ship through `ATSApplicationFontsPath` (see Makefile and Info.plist). Each role
///   checks that its face resolved and falls back to SF, so a broken bundle still renders.
public enum DS {
    // MARK: - Color

    public enum Color {
        /// Sidebar and title-bar area.
        public static let chrome = adaptive(light: 0xEDE7DB, dark: 0x1A1715)
        /// The inset content pane.
        public static let pane = adaptive(light: 0xF7F3EA, dark: 0x211D1A)
        /// The pane's outline.
        public static let paneEdge = adaptive(light: 0x1C1917, dark: 0x332D27, lightAlpha: 0.10)

        /// List cards and settings cards.
        public static let card = adaptive(light: 0xFFFDF8, dark: 0x211D1A)
        /// A row under the pointer.
        public static let cardHover = adaptive(light: 0xF1EBDF, dark: 0x2A2521)
        /// Inputs.
        public static let field = adaptive(light: 0xEDE7DB, dark: 0x171412)
        /// Card borders.
        public static let hairline = adaptive(light: 0x1C1917, dark: 0x2E2925, lightAlpha: 0.12)
        /// Row dividers inside a card.
        public static let divider = adaptive(light: 0x1C1917, dark: 0x2A2622, lightAlpha: 0.08)

        /// The selected sidebar item, and the glyph and text on it.
        public static let navSelected = adaptive(light: 0xEADFC9, dark: 0x332D27)
        public static let navSelectedInk = adaptive(light: 0x5C3D14, dark: 0xF0E8DA)

        /// Primary text and the selected-card border.
        public static let ink = adaptive(light: 0x1C1917, dark: 0xF0E8DA)
        /// Supporting text: times, notes.
        public static let inkSecondary = adaptive(light: 0x6B625A, dark: 0x9A9087)
        /// Placeholders, unlit meter segments, disabled glyphs.
        public static let inkTertiary = adaptive(light: 0xA89F94, dark: 0x574F48)

        /// "This one is on", and the text on it.
        public static let selected = adaptive(light: 0xFBF1DD, dark: 0x332B1E)
        public static let onSelected = adaptive(light: 0x1C1917, dark: 0xF0E8DA)

        /// The primary button, and the text on it.
        public static let primary = adaptive(light: 0x1C1917, dark: 0xF0E8DA)
        public static let onPrimary = adaptive(light: 0xFFFDF8, dark: 0x1C1917)

        /// Big serif numbers.
        public static let stat = adaptive(light: 0x3F5D3A, dark: 0x9FBF93)
        /// The single accent word in a display line.
        public static let highlight = swatch(0xD08A2B)

        /// The record state, the only red in the app.
        public static let record = swatch(0xFF6C4C)
        /// Glyphs on `record`.
        public static let onRecord = swatch(0xFFFFFF)

        /// The listening capsule.
        public static let hud = adaptive(light: 0x1C1917, dark: 0x2A2521)
        /// Toasts, and the text on them.
        public static let toast = adaptive(light: 0x1C1917, dark: 0xF0E8DA)
        public static let onToast = adaptive(light: 0xFFFDF8, dark: 0x1C1917)
        /// The check in a toast.
        public static let success = swatch(0x4A9B6E)

        /// Shadow colour for floating surfaces.
        public static let shadow = adaptive(light: 0x000000, dark: 0x000000, lightAlpha: 0.08, darkAlpha: 0.40)

        private static func swatch(_ hex: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(hex: hex)
        }

        private static func adaptive(
            light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1
        ) -> SwiftUI.Color {
            #if canImport(AppKit)
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
            })
            #else
            SwiftUI.Color(uiColor: UIColor { traits in
                let isDark = traits.userInterfaceStyle == .dark
                return UIColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
            })
            #endif
        }
    }

    // MARK: - Type

    /// Fraunces for big moments, Figtree for everything else, SF if either is missing.
    public enum Font {
        /// PostScript names. The font check script in the rework spec resolves every one.
        public enum Face {
            public static let fraunces = "Fraunces-Regular"
            public static let frauncesItalic = "Fraunces-Italic"
            public static let figtree = "Figtree-Regular"
            public static let figtreeMedium = "Figtree-Medium"
            public static let figtreeSemiBold = "Figtree-SemiBold"
        }

        public static let display = custom(Face.fraunces, size: 34, fallback: .system(size: 34, weight: .regular, design: .serif))
        /// The accent word inside a display line.
        public static let displayItalic = custom(Face.frauncesItalic, size: 34, fallback: .system(size: 34, weight: .regular, design: .serif).italic())
        /// The big word count.
        public static let stat = custom(Face.fraunces, size: 40, fallback: .system(size: 40, weight: .regular, design: .serif))
        /// Page titles.
        public static let title = custom(Face.figtreeMedium, size: 26, fallback: .system(size: 26, weight: .medium))
        public static let heading = custom(Face.figtreeSemiBold, size: 15, fallback: .system(size: 15, weight: .semibold))
        public static let body = custom(Face.figtree, size: 14, fallback: .system(size: 14, weight: .regular))
        public static let bodyEmphasis = custom(Face.figtreeMedium, size: 14, fallback: .system(size: 14, weight: .medium))
        public static let control = custom(Face.figtreeMedium, size: 13, fallback: .system(size: 13, weight: .medium))
        public static let caption = custom(Face.figtree, size: 12, fallback: .system(size: 12, weight: .regular))
        /// Uppercase labels. Pair with `eyebrowTracking`; `Eyebrow` does both.
        public static let eyebrow = custom(Face.figtreeSemiBold, size: 11, fallback: .system(size: 11, weight: .semibold))
        /// The app name in the sidebar.
        public static let brand = custom(Face.figtreeSemiBold, size: 18, fallback: .system(size: 18, weight: .semibold))
        /// Timings. Monospaced so digits don't shift.
        public static let counter = SwiftUI.Font.system(size: 12, weight: .semibold, design: .monospaced)
        /// The transport counter.
        public static let counterLarge = SwiftUI.Font.system(size: 22, weight: .bold, design: .monospaced)

        public static let eyebrowTracking: CGFloat = 1.0

        /// Every PostScript name above, for the check script.
        public static let allFaces = [Face.fraunces, Face.frauncesItalic, Face.figtree, Face.figtreeMedium, Face.figtreeSemiBold]

        private static func custom(_ name: String, size: CGFloat, fallback: SwiftUI.Font) -> SwiftUI.Font {
            #if canImport(AppKit)
            guard let font = NSFont(name: name, size: size) else { return fallback }
            return SwiftUI.Font(font)
            #else
            // The iOS app ships the TTFs through `UIAppFonts`; until a face resolves, SF stands in.
            guard UIFont(name: name, size: size) != nil else { return fallback }
            return SwiftUI.Font.custom(name, fixedSize: size)
            #endif
        }
    }

    public enum Icon {
        public static let small: CGFloat = 9
        public static let regular: CGFloat = 12
        public static let large: CGFloat = 15
        public static let nav: CGFloat = 14
    }

    // MARK: - Spacing

    /// A 4pt grid.
    public enum Space {
        public static let hair: CGFloat = 2
        public static let tight: CGFloat = 4
        public static let snug: CGFloat = 8
        public static let base: CGFloat = 12
        public static let roomy: CGFloat = 16
        public static let wide: CGFloat = 24
        public static let panel: CGFloat = 32
    }

    // MARK: - Shape

    public enum Radius {
        public static let tag: CGFloat = 6
        public static let control: CGFloat = 8
        public static let nav: CGFloat = 8
        public static let card: CGFloat = 12
        public static let option: CGFloat = 16
        public static let pane: CGFloat = 20
    }

    public enum Stroke {
        public static let hairline: CGFloat = 1
        public static let selected: CGFloat = 1.5
    }

    public enum Shadow {
        /// Floating surfaces only: HUD, toasts, popovers. Colour is `Color.shadow`.
        public static let floatRadius: CGFloat = 6
        public static let floatY: CGFloat = 2
    }

    // MARK: - Sizes

    public enum Control {
        public static let height: CGFloat = 32
        public static let heightSmall: CGFloat = 26
        public static let recordSize: CGFloat = 44
        public static let recordDot: CGFloat = 14
        public static let recordStop: CGFloat = 13
        public static let recordStopRadius: CGFloat = 3
        public static let lampSize: CGFloat = 8
        public static let iconButton: CGFloat = 28
        public static let navHeight: CGFloat = 34
        public static let searchWidth: CGFloat = 260
    }

    public enum Meter {
        public static let segments = 24
        public static let segmentWidth: CGFloat = 3
        public static let segmentSpacing: CGFloat = 2
        public static let height: CGFloat = 22
        public static let segmentRadius: CGFloat = 1
        /// Bars grow toward the middle of the meter, so even silence draws a shape.
        public static let minimumFill: CGFloat = 0.18
    }

    public enum Window {
        public static let mainMinWidth: CGFloat = 900
        public static let mainMinHeight: CGFloat = 540
        public static let mainDefaultWidth: CGFloat = 940
        public static let mainDefaultHeight: CGFloat = 660
        public static let sidebarWidth: CGFloat = 220
        /// Space above the sidebar's first item so it clears the traffic lights.
        public static let trafficLightClearance: CGFloat = 44
        /// Height of the strip above the pane, where the appearance toggle sits. The pane
        /// starts below it so its rounded corner shows.
        public static let titleBarHeight: CGFloat = 40
        /// Widest the pane's content grows; keeps lines readable on a big window.
        public static let contentMaxWidth: CGFloat = 760
        /// Fixed width of the time column in a transcript row.
        public static let timeColumnWidth: CGFloat = 64
        public static let editorWidth: CGFloat = 460
        public static let comparisonMinWidth: CGFloat = 600
        public static let comparisonMinHeight: CGFloat = 440
        public static let comparisonDefaultWidth: CGFloat = 680
        public static let comparisonDefaultHeight: CGFloat = 580
    }

    // MARK: - HUD

    /// The listening capsule: a dark pill with a soft shadow and a red trace. It only shows
    /// while a hold is live, and red means recording.
    public enum HUD {
        public static let width: CGFloat = 148
        public static let height: CGFloat = 40
        /// Room around the capsule inside the panel, so its shadow isn't clipped.
        public static let margin: CGFloat = 16
        /// Distance above the Dock.
        public static let dockOffset: CGFloat = 96

        /// The trace's area in the capsule.
        public static let waveformWidth: CGFloat = 124
        public static let waveformHeight: CGFloat = 31
        public static let waveformInterval: TimeInterval = 1.0 / 60.0
        /// With Reduce Motion on the trace redraws less often and its braid stops travelling.
        public static let waveformReducedInterval: TimeInterval = 1.0 / 15.0

        // The voice trace (`VoiceTrace`): a silk line with four fanned echoes (trace lab style
        // A7, 2026-11-27). The keyboard's capsule shares all of it.
        /// Distance between a line's samples across the width.
        public static let traceSampleSpacing: CGFloat = 1
        /// How much history the model is asked for: the loudest level of this last stretch, read
        /// at this many evenly spaced ages, drives the line.
        public static let traceLevelWindow: TimeInterval = 0.12
        public static let traceLevelSamples = 6
        /// Waves across the width, and how fast they travel (radians a second).
        public static let traceCycles: Double = 1.6
        public static let traceSpeed: Double = 2.6
        /// The main line's peak height at full voice, as a share of the view's height.
        public static let traceReach: Double = 0.42
        /// The fan, faintest first and the main line last: each line's lag (0 is the main line),
        /// opacity and stroke width in points.
        public static let traceEchoLags: [Double] = [0.48, 0.36, 0.24, 0.12, 0]
        public static let traceEchoOpacities: [Double] = [0.08, 0.14, 0.24, 0.42, 1]
        public static let traceEchoWidths: [CGFloat] = [1, 1, 1.1, 1.3, 1.75]
        /// An echo trails the main line by `lag` times this phase (radians) and is lower by `lag`
        /// times this share.
        public static let traceEchoPhase: Double = 6
        public static let traceEchoFalloff: Double = 0.8
        /// Share of each side, from the edge in, over which every line closes onto the middle.
        public static let traceTaper: Double = 0.22
        /// The idle hairline's width before the hold has heard audio.
        public static let traceIdleWidth: CGFloat = 1.75
        public static let fadeDuration: TimeInterval = 0.16
    }

    // MARK: - Keyboard

    /// The iOS keyboard extension. Keys follow the system keyboard's look so Murmur sits
    /// beside Apple's own keyboards (iOS 26: one flat fill for every key, no drop shadow, rounder
    /// corners, measured from a screenshot of the stock keyboard on 2026-11-25); red stays reserved for recording (`Color.record`), and the
    /// m and the recording capsule are Liquid Glass tinted toward `Color.hud` (`talkGlassTint`).
    public enum Keyboard {
        /// The inset of the emoji and history panels. The key plane draws its own `sideInset`.
        public static let padding: CGFloat = 6
        public static let keySpacing: CGFloat = 6
        public static let keyRadius: CGFloat = 10
        public static let functionKeyWidth: CGFloat = 44
        /// The failure message's inset inside the glass capsule it sits in.
        public static let labelInset: CGFloat = 22

        // MARK: Key plane geometry
        // The stock iOS 26/27 keyboard on a 393 pt iPhone, measured from the owner's screenshots
        // on 2026-11-25: 43 pt keycaps, a 54 pt row pitch (11 pt between rows), 6 pt between
        // keys. iOS puts about 16 pt of its own margin above a third-party keyboard view, so
        // the strip and its gap are 34 pt (30 + 4) and not the stock 52: the first row then
        // lands 51 pt below the panel's top edge, where the stock keyboard's does.
        // `KeyboardMetrics` (MurmurTyping, which cannot import this module) is built from these
        // through `TypingController`'s constants.

        /// The suggestion strip above the keys, 44 pt: the 36 pt m with 4 pt above and below. The
        /// owner tried trimming its top through a temporary setting and kept it untrimmed
        /// (2026-11-25).
        public static let stripHeight: CGFloat = 44
        public static let stripHeightLandscape: CGFloat = 44
        /// A key press's haptic tap: the light impact at this strength, the owner's choice by
        /// feel on 2026-11-25 (full strength read as heavy).
        public static let keyTapStrength: CGFloat = 0.7
        /// Between the strip and the first row: 8 pt upright, 6 pt turned.
        public static let stripGap: CGFloat = 8
        /// While a burst of typing is under way, a touch this far up into the suggestion strip
        /// counts as a tap on the top row, as on Apple's keyboard, where a fast thumb aimed at
        /// the top row lands high. On 2026-11-25 an `e` landed 0.3 pt above the key plane and was
        /// not typed. The strip keeps its upper part, where the suggestions' text sits.
        public static let typingStripReach: CGFloat = 12
        /// How long after a key goes down the reach above applies. Fast typing puts the next
        /// key within about 150 ms; choosing a suggestion takes longer than this.
        public static let typingStripReachSeconds: Double = 0.35
        public static let stripGapLandscape: CGFloat = 6
        public static let keycapHeight: CGFloat = 43
        public static let keycapHeightLandscape: CGFloat = 32
        /// Between two rows of keys: 11 pt upright, 8 pt turned.
        public static let rowGap: CGFloat = 11
        public static let rowGapLandscape: CGFloat = 8
        /// Between the view's side edge and the outermost keycap.
        public static let sideInset: CGFloat = 6
        public static let bottomInset: CGFloat = 0
        /// The width the fixed key widths below were measured at; shift and delete scale from it.
        public static let referenceWidth: CGFloat = 393
        /// The `123` or `ABC` key, the emoji key and the globe key in the bottom row.
        public static let pageKeyWidth: CGFloat = 42
        public static let returnKeyWidth: CGFloat = 91
        /// How far the space bar's touch area reaches up into the row above it.
        public static let spaceHitReach: CGFloat = 2.5
        /// How far the keycaps fade toward the backdrop while the space bar is a trackpad, as a
        /// fraction: the keys are hidden at 1.
        public static let trackpadKeyBlank: Double = 0.6
        /// The clock the key plane runs while a finger is down. It asks for the screen's full
        /// 120 per second on purpose: on 2026-11-25 a touch-down reached the keyboard a median
        /// 17 ms after it happened and a lift's letter was sent 20 to 24 ms after the lift, both
        /// about one 60 Hz frame, and the owner felt typing as heavier than the stock keyboard.
        /// A display link that asks for at most 60 votes for the slower rate. The engine's tick
        /// itself is a few comparisons.
        public static let tickRate: Float = 120
        /// How long the keys must be quiet before the suggestion strip is worked out and drawn
        /// again, so a burst of taps is not followed by a redraw per key. Raising it to 300 ms on
        /// 2026-11-25 did not change how many taps a fast sentence lost, so the redraw is not what
        /// loses them; 120 ms keeps the strip feeling live.
        public static let suggestionQuietSeconds: Double = 0.12
        public static let tickRateMinimum: Float = 80
        public static let tickRateMaximum: Float = 120
        /// Swipe typing: while a finger swipes, the strip's centre cell shows the best reading at
        /// most this often. A decode costs well under a millisecond on a Mac, but the finger
        /// moves 60 to 120 times a second and a reading that changes every frame only flickers.
        public static let swipeLiveDecodeSeconds: Double = 0.07
        /// How long a point of the swipe's path stays in the trail. The trail is the last stretch
        /// of the path, so it follows the finger and thins out behind it.
        public static let swipeTrailSeconds: Double = 0.6
        /// The trail's width at the finger. It tapers to nothing at its tail, as the stock
        /// keyboard's and Gboard's do (the owner's screen recordings, 2026-11-25): the first
        /// version was one even 8 pt line cut off at its end, which read as rigid.
        public static let swipeTrailWidth: CGFloat = 11
        /// The trail's other widths at the finger (Settings, Swipe trail): thin, thick and bold
        /// beside the regular `swipeTrailWidth`.
        public static let swipeTrailWidthThin: CGFloat = 6
        public static let swipeTrailWidthThick: CGFloat = 15
        public static let swipeTrailWidthBold: CGFloat = 19
        /// How fast the trail relaxes behind the finger (`SwipeTrail.Configuration.relaxRate`):
        /// higher rounds corners off sooner.
        public static let swipeTrailRelaxRate: Double = 16
        /// How long the trail takes to fade once the finger lifts.
        public static let swipeTrailFadeSeconds: Double = 0.3
        /// Points of the path closer together than this are merged before the trail is drawn.
        public static let swipeTrailMinimumStep: CGFloat = 1.5
        /// The strength of one of the trail's layers. The layers (`SwipeTrail.layers`, four) lie
        /// over each other, so on dark keys the middle of the trail is about 0.3 and its edge
        /// 0.09; white keys take about twice that. The second version was 0.35 of the label
        /// colour with a glow of the same colour around it, which the owner called shiny
        /// (2026-11-25).
        public static let swipeTrailLayerOpacity: CGFloat = 0.09
        public static let swipeTrailLayerOpacityLight: CGFloat = 0.16
        /// The emoji picker. Apple's shows four rows in portrait (row pitch about 54 pt, measured
        /// 2026-11-26 on an iPhone 15 Pro). In portrait the panel is `emojiExtraHeight` taller than
        /// the key page, as the stock emoji keyboard is, and the grid divides what is left after
        /// the search field and the category bar: 215 pt, four rows of about 54 pt.
        public static let emojiRows = 4
        /// How much taller the keyboard is while the emoji grid shows in portrait (the stock emoji
        /// keyboard is about 40 pt taller than its letters keyboard; 48 pt here gives the grid four
        /// rows of about 54 pt). Search has its own extra height and does not add this one.
        public static let emojiExtraHeight: CGFloat = 48
        /// Where less height arrives than the panel asked for, rows are dropped so none is under
        /// `emojiMinCellHeight`, down to `emojiMinRows`; the title and the category bar keep
        /// their sizes.
        /// 40 so a 40 pt glyph is not clipped by its cell; a 257 pt keyboard (where iOS did not
        /// apply the extra height) still fits four rows (167 pt for the grid, 167 / 40 = 4).
        public static let emojiMinCellHeight: CGFloat = 40
        public static let emojiMinRows = 3
        /// Columns in view at once, so a cell is the panel's width over this. The stock keyboard
        /// shows 7 (column pitch about 56 pt on 393 pt).
        public static let emojiColumns = 7
        /// The stock faces are 35 pt wide on screen (105 px at 3x, measured 2026-11-27 against
        /// the owner's screenshot of Apple's picker); a 40 pt font drew them 37 pt, so 38.
        public static let emojiGlyphSize: CGFloat = 38
        /// Landscape rows are about 37 pt, so the glyph is smaller there.
        public static let emojiGlyphSizeCompact: CGFloat = 30
        /// Landscape (compact vertical size class): the key page is 202 pt, which leaves about
        /// 126 pt for the grid, so three rows of about 42 pt keep the glyph at its size where
        /// five would shrink it. The columns widen to match the wider screen.
        public static let emojiRowsCompact = 3
        public static let emojiColumnsCompact = 14
        /// The category bar: as tall as its selection circle, as Apple's is.
        public static let emojiBarHeight: CGFloat = 30
        /// The gap between the field and the results in search mode.
        public static let emojiBarSpacing: CGFloat = 4
        /// The picker's vertical rhythm, from Apple's picker on an iPhone 15 Pro (2026-11-27,
        /// measured from the keyboard's bottom edge, where the host's top margin cannot reach): the
        /// bar's centre 20 pt up, the last row's centre 65 pt up, rows on a 54 pt pitch, the field
        /// 40 pt tall and 8 pt over the grid. The top inset takes what the keyboard's height leaves.
        public static let emojiPanelTopInset: CGFloat = 4
        public static let emojiPanelFieldHeight: CGFloat = 40
        public static let emojiFieldGridGap: CGFloat = 8
        public static let emojiGridBarGap: CGFloat = 3
        public static let emojiPanelBottomInset: CGFloat = 5
        /// Where the grid starts inside the picker, for converting the grid's points to the panel's.
        public static let emojiGridTop: CGFloat = emojiPanelTopInset + emojiPanelFieldHeight + emojiFieldGridGap
        /// The field sits 9 pt from the keyboard's edges, 3 pt inside the panel's own padding.
        public static let emojiFieldSideInset: CGFloat = 3
        /// The bar's three parts: ABC 13 pt from the keyboard's edge in a 47 pt cell, the
        /// categories sharing what is between (32 pt each on a 393 pt phone), the delete glyph's
        /// ink about 8 pt from the trailing edge (the symbol's own bearing adds 3) in a 47 pt cell.
        public static let emojiBarSideWidth: CGFloat = 47
        public static let emojiBarABCInset: CGFloat = 7
        public static let emojiBarDeleteInset: CGFloat = 5
        /// The selected category's circle.
        public static let emojiBarSelectionDiameter: CGFloat = 30
        /// The two category icons Murmur draws itself (`DogFaceIcon`, `AppleFruitIcon`): their
        /// square and their stroke, matched to the medium-weight symbols beside them.
        public static let emojiBarDrawnIconSize: CGFloat = 20
        public static let emojiBarIconStroke: CGFloat = 1.6
        /// Apple's delete glyph in the bar is a little dimmer than the category icons.
        public static let emojiBarDeleteOpacity: Double = 0.8
        public static let emojiBarDeleteFont = SwiftUI.Font.system(size: 20)
        /// ABC is lighter than the icons: 28 pt of ink and a peak of RGB 224 in Apple's bar.
        public static let emojiBarABCFont = SwiftUI.Font.system(size: 14.5)
        public static let emojiBarABCOpacity: Double = 0.88
        /// The small caps label of the history panel's header (the emoji panel's section is shown by
        /// its category bar, and its header is the search field below).
        public static let emojiTitleFont = SwiftUI.Font.system(size: 12, weight: .semibold)
        /// Search mode's field, as tall as before the picker's own field grew to
        /// `emojiPanelFieldHeight` (search's height is unmeasured against Apple's).
        public static let emojiSearchFieldHeight: CGFloat = 36
        /// Inside either field: the magnifying glass 12 pt from the capsule's edge and 8 pt before
        /// the text (Apple's text starts 37 pt in), a 16 pt glyph, 17 pt text.
        public static let emojiSearchFieldInset: CGFloat = 12
        public static let emojiSearchIconSpacing: CGFloat = 8
        /// Between search mode's field and its Cancel button.
        public static let emojiSearchFieldSpacing: CGFloat = 6
        public static let emojiSearchFieldFont = SwiftUI.Font.system(size: 17)
        public static let emojiSearchIconFont = SwiftUI.Font.system(size: 17)
        /// Search mode: the field, then one row of results, above the key plane. The keyboard is
        /// taller by `emojiSearchRegionHeight` less the strip's height while it shows, and the
        /// region is laid out in whatever height arrives: below `emojiSearchRegionHeight` the
        /// field and the results share one row (`emojiSearchCompactFieldFraction` of its width
        /// for the field).
        public static let emojiSearchTopInset: CGFloat = 4
        public static let emojiSearchResultsHeight: CGFloat = 40
        public static let emojiSearchRegionHeight: CGFloat =
            emojiSearchTopInset + emojiSearchFieldHeight + emojiBarSpacing + emojiSearchResultsHeight
        public static let emojiSearchCompactFieldFraction: CGFloat = 0.45
        /// The query's caret. It blinks as the system's does.
        public static let emojiSearchCaretWidth: CGFloat = 2
        public static let emojiSearchCaretHeight: CGFloat = 20
        public static let emojiSearchCaretBlink: TimeInterval = 0.53
        /// The skin-tone row that floats above an emoji after a long press.
        public static let emojiToneCellWidth: CGFloat = 40
        public static let emojiToneCellHeight: CGFloat = 44
        public static let emojiToneGlyphSize: CGFloat = 35 // 26 scaled by 40 / 30, rounded
        public static let emojiToneRadius: CGFloat = 10
        public static let emojiToneInset: CGFloat = 4
        public static let emojiLongPress: TimeInterval = 0.4
        /// A drag this long while the tone row is up closes it, so a scroll attempt does.
        public static let emojiDismissDrag: CGFloat = 10
        /// The emoji panel's delete key repeats as the key plane's does (`TypingEngine`).
        public static let deleteRepeatDelay: Duration = .milliseconds(360)
        public static let deleteRepeatInterval: Duration = .milliseconds(75)

        /// Type. The keyboard uses the system face so it sits beside Apple's own keyboards.
        public static let iconFont = SwiftUI.Font.system(size: 19)
        public static let barFont = SwiftUI.Font.system(size: 15, weight: .medium)
        /// The emoji bar's category symbols: Apple's are about 7% larger than 15 pt and heavier.
        public static let barIconFont = SwiftUI.Font.system(size: 16, weight: .medium)
        public static let messageFont = SwiftUI.Font.system(size: 12)
        public static let messageActionFont = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// The readiness line in the strip that says what is not ready yet.
        public static let captionFont = SwiftUI.Font.system(size: 11)
        /// The strip's suggestion cells. The centre one is emphasised, as on the stock keyboard.
        public static let suggestionFont = SwiftUI.Font.system(size: 17)
        public static let suggestionEmphasisFont = SwiftUI.Font.system(size: 17, weight: .semibold)

        /// The m, and the readiness caption. The record control is glass tinted dark brown in
        /// both appearances (`talkGlassTint`), so these colours do not adapt. `wordmark` is a soft orange, paler
        /// than `Color.record` on purpose: red means recording and nothing else.
        public static let wordmark = SwiftUI.Color(hex: wordmarkHex)
        static let wordmarkHex: UInt32 = 0xF2A57E
        /// Text on the capsule that is not the word (the failure message).
        public static let onTalkKey = SwiftUI.Color(hex: 0xF0E8DA)
        /// The flat bars on the capsule before the hold has heard audio: soft and clearly visible
        /// on the dark ground, where `inkTertiary` (about 1.9:1 in dark) nearly vanishes. Keyboard only.
        public static let waveformFlat = onTalkKey.opacity(0.5)
        /// The listening trace in the recording capsule: the room it leaves at each end of the
        /// capsule's flat run (the trailing end meets the m).
        public static let traceInset: CGFloat = 14
        /// The failure's "Open Murmur" button: the wordmark orange with ink on it.
        public static let talkAction = wordmark
        public static let onTalkAction = SwiftUI.Color(hex: 0x1C1917)

        /// PostScript name of the app icon's face, `Tools/Fonts/EBGaramond-Italic[wght].ttf`.
        public static let wordmarkFace = "EBGaramond-Italic"
        /// The m of the dictation button: the wordmark's face at a size that fits the 30 pt
        /// circle (`mCircleDiameter`). EB Garamond Italic is smaller on the body than SF at the
        /// same point size.
        public static let mGlyphSize: CGFloat = 26
        #if canImport(UIKit)
        /// EB Garamond Italic, registered by the keyboard's `UIAppFonts`. Falls back to SF
        /// italic when the face does not resolve (a build without the file, or `swift test`).
        public static let mGlyphFont: SwiftUI.Font = {
            guard UIFont(name: wordmarkFace, size: mGlyphSize) != nil else {
                return SwiftUI.Font.system(size: mGlyphSize, weight: .medium).italic()
            }
            return SwiftUI.Font.custom(wordmarkFace, fixedSize: mGlyphSize)
        }()

        /// How far the m rises so its x-height is centred in the circle. SwiftUI centres the
        /// font's line box, and EB Garamond has far more room under the baseline than above
        /// the x-height, so an m set at the centre sits low. The x-height's centre is
        /// `ascender - xHeight / 2` below the line's top and the box's centre is
        /// `(ascender + |descender|) / 2`, which differ by `(ascender - |descender| - xHeight) / 2`:
        /// 3.4 pt at 22 pt. Zero when the face did not resolve, as then the system face is
        /// used, which this does not describe.
        ///
        /// No horizontal offset: the m's ink centre is 0.18 pt right of its advance centre at
        /// 22 pt (0.008 em; the italic angle is 17.2 degrees), under a physical pixel at 3x.
        public static let mGlyphLift: CGFloat = {
            guard let font = UIFont(name: wordmarkFace, size: mGlyphSize) else { return 0 }
            return (font.ascender - abs(font.descender) - font.xHeight) / 2
        }()
        #endif

        // MARK: Suggestion strip
        /// The cell the m sits in at the strip's trailing end. The glass circle is centred in it,
        /// and the whole cell takes the touch, so the button is bigger than it looks.
        public static let mButtonCellWidth: CGFloat = 59
        /// The m's glass circle, as tall as the strip so it fits in it.
        public static let mCircleDiameter: CGFloat = 36
        /// The recording capsule's height: the circle's, because the capsule is the circle grown
        /// leftward. It grows to end `padding` after the history cell (`functionKeyWidth`).
        public static let recordingCapsuleHeight: CGFloat = 36
        /// A suggestion's text sits this far below the cell's centre. The stock strip's text is
        /// centred in the 30 pt strip, so none.
        public static let suggestionTextOffset: CGFloat = 0
        public static let suggestionInset: CGFloat = 4
        public static let suggestionMinimumScale: CGFloat = 0.7
        public static let suggestionDividerHeight: CGFloat = 24
        /// The undo chip in the left suggestion cell after an autocorrection: an arrow and the
        /// original word. The gap between the two.
        public static let undoChipSpacing: CGFloat = 4
        public static let undoChipIconFont = SwiftUI.Font.system(size: 13, weight: .semibold)

        // Unit A (polish plan 002): the soft pill behind the centre suggestion that the space
        // bar will apply, as on the stock keyboard.
        public static let autocorrectPillRadius: CGFloat = 8
        public static let autocorrectPillInset: CGFloat = 4
        public static let autocorrectPillStartScale: CGFloat = 0.92
        public static let autocorrectPillSpring = SwiftUI.Animation.spring(response: 0.28, dampingFraction: 0.86)

        // MARK: Pop-ups
        /// The key pop-up is the keycap widened by this factor, drawn above it.
        public static let popupWidthScale: CGFloat = 1.5
        public static let popupHeight: CGFloat = 54
        /// How the head of the pop-up narrows to the key: the radius of the two curves.
        public static let popupNeckRadius: CGFloat = 10
        /// The accent row's selected cell is inset from the row by this much.
        public static let popupCellInset: CGFloat = 3
        #if canImport(UIKit)
        public static let popupUIFont = UIFont.systemFont(ofSize: 30)
        public static let accentUIFont = UIFont.systemFont(ofSize: 24)
        /// The key plane's faces: letters at 24.5 pt (the stock x-height is 12.3 pt, 1.1 times
        /// the old 22.5 pt face's), labels (`123`, `return`) at 16 pt.
        public static let letterUIFont = UIFont.systemFont(ofSize: 24.5)
        /// Capital letters on the keys. The stock keyboard sets its keys in SF Compact, which
        /// apps cannot ask for and may not bundle: capitals at about 23 pt, lowercase at about
        /// 24.5 pt (fitted on 2026-11-25 to letter widths measured from screenshots; SF Compact
        /// matched to 0.2 pt). In SF Pro at `letterUIFont`'s size the capitals came out 10% taller
        /// and about 18% wider than stock. The semi-condensed width (`wdth` 80) at 23 pt was then
        /// 0.7 pt too narrow on the straight letters and a little tall, and the owner called it
        /// weird. This is SF Pro at the stock capitals' height with `wdth` 90: straight letters
        /// within 0.4 pt on the Mac, round ones (O, Q, G, C) about 1 pt wide, because SF Compact
        /// flattens their sides and SF Pro does not. Lowercase stays standard width, where SF
        /// Pro already sits within 0.5 pt.
        public static let capitalLetterUIFont: UIFont = {
            let base = UIFont.systemFont(ofSize: capitalLetterSize)
            let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
            let descriptor = base.fontDescriptor.addingAttributes([
                variation: [capitalLetterWidthAxis: capitalLetterWidth]
            ])
            return UIFont(descriptor: descriptor, size: capitalLetterSize)
        }()
        /// The capitals' size: the stock capitals' height (15.6 pt) in SF Pro.
        public static let capitalLetterSize: CGFloat = 22.25
        /// The variable font's width axis (`wdth`) and the value the capitals use, where 100 is
        /// standard. A named width snaps to a step (semi-condensed is 80), so the axis is set
        /// directly.
        public static let capitalLetterWidthAxis = 0x7764_7468
        public static let capitalLetterWidth: CGFloat = 90
        public static let labelUIFont = UIFont.systemFont(ofSize: 16)
        /// `#+=` is set smaller than `123` on the stock keyboard: about 83% of its width,
        /// measured from the owner's screenshots on 2026-11-26.
        public static let symbolsSwitchUIFont = UIFont.systemFont(ofSize: 13.25)
        /// The `•` key. SF Pro's bullet at the capitals' size is a 3.7 pt dot and the stock
        /// key's is about 6.7 pt (owner's screenshots, 2026-11-26); at this size its centre
        /// still lands on the key's centre.
        public static let bulletUIFont = UIFont.systemFont(ofSize: 40)
        // Unit C (plans/002): the number pad's digits, and the letters under 2 to 9.
        /// Measured from Apple's decimal pad on a 393 pt iPhone (2026-11-26): digits 15.8 pt cap
        /// height (22 pt regular), letters 6.7 pt cap height (9.5 pt semibold).
        public static let numberPadDigitUIFont = UIFont.systemFont(ofSize: 22, weight: .regular)
        public static let numberPadLettersUIFont = UIFont.systemFont(ofSize: 9.5, weight: .semibold)
        /// How far apart the first and last letter of "ABC" are, left edge to right edge.
        public static let numberPadLettersSpan: CGFloat = 24
        /// Where a digit's cap top and its letters' cap top sit, as fractions of the pad key's
        /// height. The same for every digit, so 1 and 0 line up with 2 to 9.
        public static let numberPadDigitCapTop: CGFloat = 0.229
        public static let numberPadLettersCapTop: CGFloat = 0.75
        /// The delete glyph's width on the pad, about the stock one.
        public static let numberPadDeleteIconWidth: CGFloat = 25
        public static let iconPointSize: CGFloat = 19
        #endif

        public static let historyTitleFont = SwiftUI.Font.system(size: 13, weight: .semibold)
        public static let historyRowFont = SwiftUI.Font.system(size: 15)
        public static let historyActionFont = SwiftUI.Font.system(size: 15, weight: .medium)
        #if canImport(UIKit)
        /// The history list is a UIKit table (`HistoryList`), so its rows take UIKit faces at the
        /// sizes of `historyRowFont` and `captionFont`.
        public static let historyRowUIFont = UIFont.systemFont(ofSize: 15)
        public static let historyTimeUIFont = UIFont.systemFont(ofSize: 11)
        #endif

        /// A key under the finger.
        public static let pressedOpacity: Double = 0.6
        /// History panel: gap between rows, row insets, header inset, how many runs it lists.
        public static let historySpacing: CGFloat = 6
        public static let historyRowInsetX: CGFloat = 10
        public static let historyRowInsetY: CGFloat = 10
        public static let historyHeaderInset: CGFloat = 6
        /// The history header's row, which the list scrolls under.
        public static let historyHeaderHeight: CGFloat = 32
        public static let historyRowLines = 2
        public static let historyLimit = 30
        /// The failure message's inset around its action, and the action's own insets.
        public static let messageGap: CGFloat = 8
        public static let messageActionInsetX: CGFloat = 12
        public static let messageActionInsetY: CGFloat = 6
        public static let messageLines = 2

        #if canImport(UIKit)
        /// Every key's fill, as on the iOS 26 keyboard, where letters, shift, delete, 123 and
        /// return share one colour. Dark is the stock key measured (RGB 68).
        public static let keyUIColor = UIColor {
            $0.userInterfaceStyle == .dark ? UIColor(white: 0.267, alpha: 1) : .white
        }
        public static let key = SwiftUI.Color(uiColor: keyUIColor)
        /// The number pad's digit keys: RGB 87 on dark (Apple's pad, 2026-11-26), lighter than
        /// the letter keys. White on light is inferred, not measured.
        public static let numberPadKeyUIColor = UIColor {
            $0.userInterfaceStyle == .dark ? UIColor(white: 87.0 / 255.0, alpha: 1) : .white
        }
        /// What the keyboard's root view and key plane are filled with, in place of clear. iOS
        /// routes a touch to a keyboard extension only where the keyboard has drawn something:
        /// a touch on a fully clear point goes to the host app instead and is never typed
        /// (measured 2026-11-25, eight lost taps of eight in the gaps between keycaps). The alpha
        /// is too low to see over the system's backdrop.
        public static let touchBackingUIColor = UIColor(white: 0.5, alpha: 0.001)
        /// The hairline between two filled suggestion cells.
        public static let suggestionDivider = SwiftUI.Color(uiColor: .separator)
        /// Unit A: the pill behind the centre suggestion that the space will apply. White at 16%
        /// on dark, black at 7% on light.
        public static let autocorrectPill = SwiftUI.Color(
            uiColor: UIColor {
                $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.16) : UIColor(white: 0, alpha: 0.07)
            })
        /// The key plane's glyphs.
        public static let keyLabelUIColor = UIColor.label
        /// One layer of the swipe trail: the m's orange (`wordmark`), as the owner asked on
        /// 2026-11-25, at `swipeTrailLayerOpacity` on dark keys and `swipeTrailLayerOpacityLight`
        /// on white ones, where the pale orange needs more to show.
        public static let swipeTrailUIColor = UIColor {
            UIColor(
                hex: wordmarkHex,
                alpha: $0.userInterfaceStyle == .dark ? swipeTrailLayerOpacity : swipeTrailLayerOpacityLight)
        }
        /// The pop-up over a pressed key: the key's own colour in light, a little lighter than a
        /// key in dark so it reads as lifted. The accent row's chosen cell is the system blue.
        public static let popupUIFill = UIColor {
            $0.userInterfaceStyle == .dark ? UIColor(white: 0.36, alpha: 1) : .white
        }
        public static let popupSelectedUIFill = UIColor.systemBlue
        public static let popupSelectedUILabel = UIColor.white
        /// The shadow under a pop-up. A pop-up floats over the keys, which is the one place a
        /// shadow is allowed; its radius and offset are `DS.Shadow`.
        public static let popupShadowUIColor = UIColor(DS.Color.shadow)
        /// The skin-tone row's ground, lighter than a key so it floats above the grid.
        public static let letterKey = SwiftUI.Color(uiColor: UIColor {
            $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white
        })
        /// The emoji picker's field and its selected category's circle: RGB 64 on dark (Apple's
        /// picker, 2026-11-27). The light values are the earlier ones, not measured.
        public static let emojiFieldFill = SwiftUI.Color(uiColor: UIColor {
            $0.userInterfaceStyle == .dark ? UIColor(white: 64.0 / 255.0, alpha: 1) : .white
        })
        public static let emojiSelectionFill = SwiftUI.Color(uiColor: UIColor {
            $0.userInterfaceStyle == .dark
                ? UIColor(white: 64.0 / 255.0, alpha: 1)
                : UIColor(red: 0.67, green: 0.69, blue: 0.74, alpha: 1)
        })
        /// The chosen skin tone.
        public static let functionKey = SwiftUI.Color(uiColor: UIColor {
            $0.userInterfaceStyle == .dark ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.67, green: 0.69, blue: 0.74, alpha: 1)
        })
        /// Return when the field gives it a job other than a new line, as on Apple's keyboard.
        public static let prominentUIKey = UIColor.systemBlue
        /// Text and glyphs on `prominentUIKey`.
        public static let onProminentUIKey = UIColor.white
        /// The Liquid Glass tint of the m and the recording capsule: the HUD's brown, nearly opaque in light, and a
        /// lighter brown in dark where `hud` would sink into the keyboard's own dark backdrop.
        /// Under the wordmark's orange and the red bars it keeps contrast in both.
        public static let talkGlassTint = SwiftUI.Color(uiColor: UIColor {
            $0.userInterfaceStyle == .dark
                ? UIColor(red: 0x4A / 255, green: 0x3A / 255, blue: 0x2E / 255, alpha: 0.9)
                : UIColor(red: 0x1C / 255, green: 0x19 / 255, blue: 0x17 / 255, alpha: 0.88)
        })
        #endif
    }

    // MARK: - Phone app

    /// The iPhone app's own sizes. The shared tokens above carry everything else; these are
    /// the few values a single column of cards needs that a window on the Mac does not.
    public enum Phone {
        /// The download bar and its track.
        public static let progressHeight: CGFloat = 6
        /// The leading status glyph of a setup row, so labels line up whatever the glyph.
        public static let statusGlyphWidth: CGFloat = 22
        /// The correction editor's text box, tall enough to show a few lines before it scrolls.
        public static let editorMinHeight: CGFloat = 120
        /// How many lines a run's text shows in the list; the editor shows all of it.
        public static let rowTextLines = 8
        /// A text input's height, a little taller than the Mac's for a fingertip.
        public static let fieldHeight: CGFloat = 40
        /// Gap between a page's bottom edge and a toast.
        public static let toastInset: CGFloat = 16
    }

    // MARK: - Motion

    public enum Motion {
        /// A control being pressed: a slight scale and fade.
        public static let press = Animation.snappy(duration: 0.12)
        public static let pressScale: CGFloat = 0.98
        public static let pressOpacity: Double = 0.85
        public static let disabledOpacity: Double = 0.4
        /// Panel and section changes.
        public static let panel = Animation.smooth(duration: 0.22)
        /// The record state coming on.
        public static let lamp = Animation.easeOut(duration: 0.08)
        /// Meter segments following the input level.
        public static let meter = Animation.linear(duration: 0.08)
        /// How often the Setup tab rereads what the keyboard reports while it is on screen.
        public static let statusPoll: Duration = .seconds(1.5)
        /// How long "Copied" stays up.
        public static let copiedHold: Duration = .seconds(1.4)
    }
}

// MARK: - Floating surfaces

public extension View {
    /// The soft shadow of a surface that floats above the window: HUD, toasts, popovers and the
    /// keyboard's skin-tone row. The one place a shadow is allowed.
    func floatingShadow() -> some View {
        shadow(color: DS.Color.shadow, radius: DS.Shadow.floatRadius, y: DS.Shadow.floatY)
    }
}

// MARK: - Hex helpers

/// 0xRRGGBB in sRGB, so tokens match the palette on wide-gamut displays.
private extension SwiftUI.Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

#if canImport(AppKit)
private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
#else
private extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
#endif
