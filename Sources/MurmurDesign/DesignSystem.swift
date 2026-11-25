import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
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

    /// The listening capsule: a dark pill with a soft shadow and red bars. It only shows
    /// while a hold is live, and red means recording.
    public enum HUD {
        public static let width: CGFloat = 148
        public static let height: CGFloat = 40
        /// Room around the capsule inside the panel, so its shadow isn't clipped.
        public static let margin: CGFloat = 16
        /// Distance above the Dock.
        public static let dockOffset: CGFloat = 96

        public static let waveformWidth: CGFloat = 112
        public static let waveformHeight: CGFloat = 24
        public static let waveformBarCount = 16
        public static let waveformBarWidth: CGFloat = 3
        public static let waveformBarSpacing: CGFloat = 3
        public static let waveformBarRadius: CGFloat = 1.5
        public static let waveformFloorHeight: CGFloat = 2
        public static let waveformAmplitude: CGFloat = 22
        public static let waveformMinimumLevel: Float = 0.04
        public static let waveformInterval: TimeInterval = 1.0 / 30.0
        public static let waveformFrequency: Double = 6.0
        public static let waveformEnvelopeFloor: Double = 0.35
        public static let waveformEnvelopeRange: Double = 0.65
        public static let waveformLevelFloor: Double = 0.55
        public static let waveformLevelRange: Double = 0.45
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

        /// The suggestion strip above the keys: 30 pt upright, the stock 44 pt turned.
        public static let stripHeight: CGFloat = 30
        public static let stripHeightLandscape: CGFloat = 44
        /// Between the strip and the first row: 8 pt upright, 6 pt turned.
        public static let stripGap: CGFloat = 8
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
        /// The clock the key plane runs while a finger is down: 40 per second is one tick every
        /// 25 ms, and the range lets a 60 Hz screen answer at 30 or 60.
        public static let tickRate: Float = 40
        public static let tickRateMinimum: Float = 30
        public static let tickRateMaximum: Float = 60
        /// The emoji picker. Apple's shows five rows in portrait. The panel is exactly as tall as
        /// the key page (iOS ignores a keyboard that grows after it first appears), and the grid
        /// divides what is left after the section title and the category bar.
        public static let emojiRows = 5
        /// Where less height arrives than the panel asked for, rows are dropped so none is under
        /// `emojiMinCellHeight`, down to `emojiMinRows`; the title and the category bar keep
        /// their sizes.
        public static let emojiMinCellHeight: CGFloat = 34
        public static let emojiMinRows = 3
        /// Columns in view at once, so a cell is the panel's width over this.
        public static let emojiColumns = 8
        public static let emojiGlyphSize: CGFloat = 30
        /// Landscape (compact vertical size class): the key page is 202 pt, which leaves about
        /// 126 pt for the grid, so three rows of about 42 pt keep the glyph at its size where
        /// five would shrink it. The columns widen to match the wider screen.
        public static let emojiRowsCompact = 3
        public static let emojiColumnsCompact = 14
        public static let emojiBarHeight: CGFloat = 36
        public static let emojiBarSpacing: CGFloat = 4
        /// The small caps label naming the section in view.
        public static let emojiTitleHeight: CGFloat = 20
        public static let emojiTitleInset: CGFloat = 6
        public static let emojiTitleFont = SwiftUI.Font.system(size: 12, weight: .semibold)
        /// The skin-tone row that floats above an emoji after a long press.
        public static let emojiToneCellWidth: CGFloat = 40
        public static let emojiToneCellHeight: CGFloat = 44
        public static let emojiToneGlyphSize: CGFloat = 26
        public static let emojiToneRadius: CGFloat = 10
        public static let emojiToneInset: CGFloat = 4
        public static let emojiLongPress: TimeInterval = 0.4
        /// A drag this long while the tone row is up closes it, so a scroll attempt does.
        public static let emojiDismissDrag: CGFloat = 10
        /// The emoji panel's delete key repeats as the key plane's does (`TypingEngine`).
        public static let deleteRepeatDelay: Duration = .milliseconds(360)
        public static let deleteRepeatInterval: Duration = .milliseconds(75)
        /// RMS to meter level: microphone RMS sits low, so callers scale it by this before
        /// handing it to `Waveform`, which itself applies no gain.
        public static let levelGain: Float = 8

        /// Type. The keyboard uses the system face so it sits beside Apple's own keyboards.
        public static let iconFont = SwiftUI.Font.system(size: 19)
        public static let barFont = SwiftUI.Font.system(size: 15, weight: .medium)
        public static let barIconFont = SwiftUI.Font.system(size: 15)
        public static let messageFont = SwiftUI.Font.system(size: 11)
        public static let messageActionFont = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// The readiness line in the strip that says what is not ready yet.
        public static let captionFont = SwiftUI.Font.system(size: 11)
        /// The strip's suggestion cells. The centre one is emphasised, as on the stock keyboard.
        public static let suggestionFont = SwiftUI.Font.system(size: 17)
        public static let suggestionEmphasisFont = SwiftUI.Font.system(size: 17, weight: .semibold)

        /// The m, and the readiness caption. The record control is glass tinted dark brown in
        /// both appearances (`talkGlassTint`), so these colours do not adapt. `wordmark` is a soft orange, paler
        /// than `Color.record` on purpose: red means recording and nothing else.
        public static let wordmark = SwiftUI.Color(hex: 0xF2A57E)
        /// Text on the capsule that is not the word (the failure message).
        public static let onTalkKey = SwiftUI.Color(hex: 0xF0E8DA)
        /// The flat bars on the capsule before the hold has heard audio: soft and clearly visible
        /// on the dark ground, where `inkTertiary` (about 1.9:1 in dark) nearly vanishes. Keyboard only.
        public static let waveformFlat = onTalkKey.opacity(0.5)
        /// The failure's "Open Murmur" button: the wordmark orange with ink on it.
        public static let talkAction = wordmark
        public static let onTalkAction = SwiftUI.Color(hex: 0x1C1917)

        /// PostScript name of the app icon's face, `Tools/Fonts/EBGaramond-Italic[wght].ttf`.
        public static let wordmarkFace = "EBGaramond-Italic"
        /// The m of the dictation button: the wordmark's face at a size that fits the 30 pt
        /// circle (`mCircleDiameter`). EB Garamond Italic is smaller on the body than SF at the
        /// same point size.
        public static let mGlyphSize: CGFloat = 22
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
        public static let mCircleDiameter: CGFloat = 30
        /// The recording capsule's height: the circle's, because the capsule is the circle grown
        /// leftward. It grows to end `padding` after the history cell (`functionKeyWidth`).
        public static let recordingCapsuleHeight: CGFloat = 30
        /// A suggestion's text sits this far below the cell's centre. The stock strip's text is
        /// centred in the 30 pt strip, so none.
        public static let suggestionTextOffset: CGFloat = 0
        public static let suggestionInset: CGFloat = 4
        public static let suggestionMinimumScale: CGFloat = 0.7
        public static let suggestionDividerHeight: CGFloat = 20
        /// The undo chip in the left suggestion cell after an autocorrection: an arrow and the
        /// original word. The gap between the two.
        public static let undoChipSpacing: CGFloat = 4
        public static let undoChipIconFont = SwiftUI.Font.system(size: 13, weight: .semibold)

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
        public static let labelUIFont = UIFont.systemFont(ofSize: 16)
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
        public static let messageActionInsetY: CGFloat = 4
        public static let messageLines = 2

        #if canImport(UIKit)
        /// Every key's fill, as on the iOS 26 keyboard, where letters, shift, delete, 123 and
        /// return share one colour. Dark is the stock key measured (RGB 68).
        public static let keyUIColor = UIColor {
            $0.userInterfaceStyle == .dark ? UIColor(white: 0.267, alpha: 1) : .white
        }
        public static let key = SwiftUI.Color(uiColor: keyUIColor)
        /// The hairline between two filled suggestion cells.
        public static let suggestionDivider = SwiftUI.Color(uiColor: .separator)
        /// The key plane's glyphs.
        public static let keyLabelUIColor = UIColor.label
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
        /// The emoji bar's selected category and the chosen skin tone.
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
