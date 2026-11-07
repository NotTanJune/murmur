import AppKit
import SwiftUI

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
enum DS {
    // MARK: - Color

    enum Color {
        /// Sidebar and title-bar area.
        static let chrome = adaptive(light: 0xEDE7DB, dark: 0x1A1715)
        /// The inset content pane.
        static let pane = adaptive(light: 0xF7F3EA, dark: 0x211D1A)
        /// The pane's outline.
        static let paneEdge = adaptive(light: 0x1C1917, dark: 0x332D27, lightAlpha: 0.10)

        /// List cards and settings cards.
        static let card = adaptive(light: 0xFFFDF8, dark: 0x211D1A)
        /// A row under the pointer.
        static let cardHover = adaptive(light: 0xF1EBDF, dark: 0x2A2521)
        /// Inputs.
        static let field = adaptive(light: 0xEDE7DB, dark: 0x171412)
        /// Card borders.
        static let hairline = adaptive(light: 0x1C1917, dark: 0x2E2925, lightAlpha: 0.12)
        /// Row dividers inside a card.
        static let divider = adaptive(light: 0x1C1917, dark: 0x2A2622, lightAlpha: 0.08)

        /// The selected sidebar item, and the glyph and text on it.
        static let navSelected = adaptive(light: 0xEADFC9, dark: 0x332D27)
        static let navSelectedInk = adaptive(light: 0x5C3D14, dark: 0xF0E8DA)

        /// Primary text and the selected-card border.
        static let ink = adaptive(light: 0x1C1917, dark: 0xF0E8DA)
        /// Supporting text: times, notes.
        static let inkSecondary = adaptive(light: 0x6B625A, dark: 0x9A9087)
        /// Placeholders, unlit meter segments, disabled glyphs.
        static let inkTertiary = adaptive(light: 0xA89F94, dark: 0x574F48)

        /// "This one is on", and the text on it.
        static let selected = adaptive(light: 0xFBF1DD, dark: 0x332B1E)
        static let onSelected = adaptive(light: 0x1C1917, dark: 0xF0E8DA)

        /// The primary button, and the text on it.
        static let primary = adaptive(light: 0x1C1917, dark: 0xF0E8DA)
        static let onPrimary = adaptive(light: 0xFFFDF8, dark: 0x1C1917)

        /// Big serif numbers.
        static let stat = adaptive(light: 0x3F5D3A, dark: 0x9FBF93)
        /// The single accent word in a display line.
        static let highlight = swatch(0xD08A2B)

        /// The record state, the only red in the app.
        static let record = swatch(0xFF6C4C)
        /// Glyphs on `record`.
        static let onRecord = swatch(0xFFFFFF)

        /// The listening capsule.
        static let hud = adaptive(light: 0x1C1917, dark: 0x2A2521)
        /// Toasts, and the text on them.
        static let toast = adaptive(light: 0x1C1917, dark: 0xF0E8DA)
        static let onToast = adaptive(light: 0xFFFDF8, dark: 0x1C1917)
        /// The check in a toast.
        static let success = swatch(0x4A9B6E)

        /// Shadow colour for floating surfaces.
        static let shadow = adaptive(light: 0x000000, dark: 0x000000, lightAlpha: 0.08, darkAlpha: 0.40)

        private static func swatch(_ hex: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(hex: hex)
        }

        private static func adaptive(
            light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1
        ) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
            })
        }
    }

    // MARK: - Type

    /// Fraunces for big moments, Figtree for everything else, SF if either is missing.
    enum Font {
        /// PostScript names. The font check script in the rework spec resolves every one.
        enum Face {
            static let fraunces = "Fraunces-Regular"
            static let frauncesItalic = "Fraunces-Italic"
            static let figtree = "Figtree-Regular"
            static let figtreeMedium = "Figtree-Medium"
            static let figtreeSemiBold = "Figtree-SemiBold"
        }

        static let display = custom(Face.fraunces, size: 34, fallback: .system(size: 34, weight: .regular, design: .serif))
        /// The accent word inside a display line.
        static let displayItalic = custom(Face.frauncesItalic, size: 34, fallback: .system(size: 34, weight: .regular, design: .serif).italic())
        /// The big word count.
        static let stat = custom(Face.fraunces, size: 40, fallback: .system(size: 40, weight: .regular, design: .serif))
        /// Page titles.
        static let title = custom(Face.figtreeMedium, size: 26, fallback: .system(size: 26, weight: .medium))
        static let heading = custom(Face.figtreeSemiBold, size: 15, fallback: .system(size: 15, weight: .semibold))
        static let body = custom(Face.figtree, size: 14, fallback: .system(size: 14, weight: .regular))
        static let bodyEmphasis = custom(Face.figtreeMedium, size: 14, fallback: .system(size: 14, weight: .medium))
        static let control = custom(Face.figtreeMedium, size: 13, fallback: .system(size: 13, weight: .medium))
        static let caption = custom(Face.figtree, size: 12, fallback: .system(size: 12, weight: .regular))
        /// Uppercase labels. Pair with `eyebrowTracking`; `Eyebrow` does both.
        static let eyebrow = custom(Face.figtreeSemiBold, size: 11, fallback: .system(size: 11, weight: .semibold))
        /// The app name in the sidebar.
        static let brand = custom(Face.figtreeSemiBold, size: 18, fallback: .system(size: 18, weight: .semibold))
        /// Timings. Monospaced so digits don't shift.
        static let counter = SwiftUI.Font.system(size: 12, weight: .semibold, design: .monospaced)
        /// The transport counter.
        static let counterLarge = SwiftUI.Font.system(size: 22, weight: .bold, design: .monospaced)

        static let eyebrowTracking: CGFloat = 1.0

        /// Every PostScript name above, for the check script.
        static let allFaces = [Face.fraunces, Face.frauncesItalic, Face.figtree, Face.figtreeMedium, Face.figtreeSemiBold]

        private static func custom(_ name: String, size: CGFloat, fallback: SwiftUI.Font) -> SwiftUI.Font {
            guard let font = NSFont(name: name, size: size) else { return fallback }
            return SwiftUI.Font(font)
        }
    }

    enum Icon {
        static let small: CGFloat = 9
        static let regular: CGFloat = 12
        static let large: CGFloat = 15
        static let nav: CGFloat = 14
    }

    // MARK: - Spacing

    /// A 4pt grid.
    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 4
        static let snug: CGFloat = 8
        static let base: CGFloat = 12
        static let roomy: CGFloat = 16
        static let wide: CGFloat = 24
        static let panel: CGFloat = 32
    }

    // MARK: - Shape

    enum Radius {
        static let tag: CGFloat = 6
        static let control: CGFloat = 8
        static let nav: CGFloat = 8
        static let card: CGFloat = 12
        static let option: CGFloat = 16
        static let pane: CGFloat = 20
    }

    enum Stroke {
        static let hairline: CGFloat = 1
        static let selected: CGFloat = 1.5
    }

    enum Shadow {
        /// Floating surfaces only: HUD, toasts, popovers. Colour is `Color.shadow`.
        static let floatRadius: CGFloat = 6
        static let floatY: CGFloat = 2
    }

    // MARK: - Sizes

    enum Control {
        static let height: CGFloat = 32
        static let heightSmall: CGFloat = 26
        static let recordSize: CGFloat = 44
        static let recordDot: CGFloat = 14
        static let recordStop: CGFloat = 13
        static let recordStopRadius: CGFloat = 3
        static let lampSize: CGFloat = 8
        static let iconButton: CGFloat = 28
        static let navHeight: CGFloat = 34
        static let searchWidth: CGFloat = 260
    }

    enum Meter {
        static let segments = 24
        static let segmentWidth: CGFloat = 3
        static let segmentSpacing: CGFloat = 2
        static let height: CGFloat = 22
        static let segmentRadius: CGFloat = 1
        /// Bars grow toward the middle of the meter, so even silence draws a shape.
        static let minimumFill: CGFloat = 0.18
    }

    enum Window {
        static let mainMinWidth: CGFloat = 900
        static let mainMinHeight: CGFloat = 540
        static let mainDefaultWidth: CGFloat = 940
        static let mainDefaultHeight: CGFloat = 660
        static let sidebarWidth: CGFloat = 220
        /// Space above the sidebar's first item so it clears the traffic lights.
        static let trafficLightClearance: CGFloat = 44
        /// Height of the strip above the pane, where the appearance toggle sits. The pane
        /// starts below it so its rounded corner shows.
        static let titleBarHeight: CGFloat = 40
        /// Widest the pane's content grows; keeps lines readable on a big window.
        static let contentMaxWidth: CGFloat = 760
        /// Fixed width of the time column in a transcript row.
        static let timeColumnWidth: CGFloat = 64
        static let editorWidth: CGFloat = 460
        static let comparisonMinWidth: CGFloat = 600
        static let comparisonMinHeight: CGFloat = 440
        static let comparisonDefaultWidth: CGFloat = 680
        static let comparisonDefaultHeight: CGFloat = 580
    }

    // MARK: - HUD

    /// The listening capsule: a dark pill with a soft shadow and red bars. It only shows
    /// while a hold is live, and red means recording.
    enum HUD {
        static let width: CGFloat = 148
        static let height: CGFloat = 40
        /// Room around the capsule inside the panel, so its shadow isn't clipped.
        static let margin: CGFloat = 16
        /// Distance above the Dock.
        static let dockOffset: CGFloat = 96

        static let waveformWidth: CGFloat = 112
        static let waveformHeight: CGFloat = 24
        static let waveformBarCount = 16
        static let waveformBarWidth: CGFloat = 3
        static let waveformBarSpacing: CGFloat = 3
        static let waveformBarRadius: CGFloat = 1.5
        static let waveformFloorHeight: CGFloat = 2
        static let waveformAmplitude: CGFloat = 22
        static let waveformMinimumLevel: Float = 0.04
        static let waveformInterval: TimeInterval = 1.0 / 30.0
        static let waveformFrequency: Double = 6.0
        static let waveformEnvelopeFloor: Double = 0.35
        static let waveformEnvelopeRange: Double = 0.65
        static let waveformLevelFloor: Double = 0.55
        static let waveformLevelRange: Double = 0.45
        static let fadeDuration: TimeInterval = 0.16
    }

    // MARK: - Motion

    enum Motion {
        /// A control being pressed: a slight scale and fade.
        static let press = Animation.snappy(duration: 0.12)
        static let pressScale: CGFloat = 0.98
        static let pressOpacity: Double = 0.85
        static let disabledOpacity: Double = 0.4
        /// Panel and section changes.
        static let panel = Animation.smooth(duration: 0.22)
        /// The record state coming on.
        static let lamp = Animation.easeOut(duration: 0.08)
        /// Meter segments following the input level.
        static let meter = Animation.linear(duration: 0.08)
        /// How long "Copied" stays up.
        static let copiedHold: Duration = .seconds(1.4)
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
