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
    /// beside Apple's own keyboards; red stays reserved for recording (`Color.record`), and the
    /// talk key is Liquid Glass tinted toward `Color.hud` (`talkGlassTint`).
    public enum Keyboard {
        public static let padding: CGFloat = 6
        public static let rowSpacing: CGFloat = 10
        public static let keySpacing: CGFloat = 6
        public static let talkHeight: CGFloat = 48
        public static let keyHeight: CGFloat = 44
        public static let keyRadius: CGFloat = 8
        public static let functionKeyWidth: CGFloat = 44
        public static let returnWidth: CGFloat = 92
        public static let historyWidth: CGFloat = 40
        public static let labelInset: CGFloat = 22
        /// The emoji picker. Apple's shows five rows in portrait; the panel is taller than the
        /// key page so they fit, and the grid divides what is left after the section title and
        /// the category bar.
        public static let emojiRows = 5
        /// Where less height arrives than the panel asked for, rows are dropped so none is under
        /// `emojiMinCellHeight`, down to `emojiMinRows`; the title and the category bar keep
        /// their sizes.
        public static let emojiMinCellHeight: CGFloat = 34
        public static let emojiMinRows = 3
        /// Columns in view at once, so a cell is the panel's width over this.
        public static let emojiColumns = 8
        public static let emojiGlyphSize: CGFloat = 30
        public static let emojiPanelHeight: CGFloat = 260
        /// Landscape (compact vertical size class): 200 pt leaves 124 pt for the grid, so three
        /// rows of about 41 pt keep the glyph at its size where five would shrink it to 25 pt.
        /// The columns widen to match the wider screen.
        public static let emojiPanelHeightCompact: CGFloat = 200
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
        public static let deleteRepeatDelay: Duration = .milliseconds(400)
        public static let deleteRepeatInterval: Duration = .milliseconds(80)
        /// RMS to meter level: microphone RMS sits low, so callers scale it by this before
        /// handing it to `Waveform`, which itself applies no gain.
        public static let levelGain: Float = 8

        /// Type. The keyboard uses the system face so it sits beside Apple's own keyboards.
        public static let characterFont = SwiftUI.Font.system(size: 22)
        public static let labelFont = SwiftUI.Font.system(size: 16)
        public static let iconFont = SwiftUI.Font.system(size: 19)
        public static let barFont = SwiftUI.Font.system(size: 15, weight: .medium)
        public static let barIconFont = SwiftUI.Font.system(size: 15)
        public static let messageFont = SwiftUI.Font.system(size: 12)
        public static let messageActionFont = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// The line under "Murmur" that says what is not ready yet.
        public static let captionFont = SwiftUI.Font.system(size: 11)

        /// The talk key's idle word. The capsule is glass tinted dark brown in both appearances
        /// (`talkGlassTint`), so these colours do not adapt. `wordmark` is a soft orange, paler
        /// than `Color.record` on purpose: red means recording and nothing else.
        public static let wordmark = SwiftUI.Color(hex: 0xF2A57E)
        /// The readiness caption under the word: the same orange, quieter.
        public static let wordmarkCaption = wordmark.opacity(0.9)
        /// Text on the capsule that is not the word (the failure message).
        public static let onTalkKey = SwiftUI.Color(hex: 0xF0E8DA)
        /// The flat bars on the capsule before the hold has heard audio: soft and clearly visible
        /// on the dark ground, where `inkTertiary` (about 1.9:1 in dark) nearly vanishes. Keyboard only.
        public static let waveformFlat = onTalkKey.opacity(0.5)
        /// The failure's "Open Murmur" button: the wordmark orange with ink on it.
        public static let talkAction = wordmark
        public static let onTalkAction = SwiftUI.Color(hex: 0x1C1917)

        /// The word's size; EB Garamond Italic is smaller on the body than SF at the same point
        /// size, so it runs larger than the 19 pt SF the key used before.
        public static let wordmarkSize: CGFloat = 23
        /// PostScript name of the app icon's face, `Tools/Fonts/EBGaramond-Italic[wght].ttf`.
        public static let wordmarkFace = "EBGaramond-Italic"
        #if canImport(UIKit)
        /// EB Garamond Italic, registered by the keyboard's `UIAppFonts`. Falls back to SF
        /// italic when the face does not resolve (a build without the file, or `swift test`).
        public static let wordmarkFont: SwiftUI.Font = {
            guard UIFont(name: wordmarkFace, size: wordmarkSize) != nil else {
                return SwiftUI.Font.system(size: wordmarkSize, weight: .medium).italic()
            }
            return SwiftUI.Font.custom(wordmarkFace, fixedSize: wordmarkSize)
        }()
        #endif
        public static let historyTitleFont = SwiftUI.Font.system(size: 13, weight: .semibold)
        public static let historyRowFont = SwiftUI.Font.system(size: 15)
        public static let historyActionFont = SwiftUI.Font.system(size: 15, weight: .medium)

        /// The one-pixel drop under each key.
        public static let keyShadowOffset: CGFloat = 1
        /// A key under the finger.
        public static let pressedOpacity: Double = 0.6
        /// History panel: gap between rows, row insets, header inset, how many runs it lists.
        public static let historySpacing: CGFloat = 6
        public static let historyRowInsetX: CGFloat = 10
        public static let historyRowInsetY: CGFloat = 8
        public static let historyHeaderInset: CGFloat = 6
        public static let historyRowLines = 2
        public static let historyLimit = 30
        /// The failure message's inset around its action, and the action's own insets.
        public static let messageGap: CGFloat = 8
        public static let messageActionInsetX: CGFloat = 12
        public static let messageActionInsetY: CGFloat = 6
        public static let messageLines = 2
        /// Gap between the talk key's label and its caption.
        public static let captionGap: CGFloat = 1

        /// Padding, the talk row, two key rows and the gaps between rows.
        public static var height: CGFloat {
            padding * 2 + talkHeight + keyHeight * 2 + rowSpacing * 2
        }

        #if canImport(UIKit)
        public static let letterKey = SwiftUI.Color(uiColor: UIColor {
            $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white
        })
        public static let functionKey = SwiftUI.Color(uiColor: UIColor {
            $0.userInterfaceStyle == .dark ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.67, green: 0.69, blue: 0.74, alpha: 1)
        })
        public static let keyShadow = SwiftUI.Color(uiColor: UIColor {
            $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.35) : UIColor(red: 0.53, green: 0.54, blue: 0.56, alpha: 1)
        })
        /// Return when the field gives it a job other than a new line, as on Apple's keyboard.
        public static let prominentKey = SwiftUI.Color(uiColor: .systemBlue)
        public static let onProminentKey = SwiftUI.Color.white
        /// The Liquid Glass tint of the talk key: the HUD's brown, nearly opaque in light, and a
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
