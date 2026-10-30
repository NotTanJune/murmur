import SwiftUI

/// The design system for Murmur.
///
/// Direction: **Liquid Glass over neo-brutalism.** Two layers, each with one job:
/// - **Glass is the control layer** — the transport dock, the listening HUD. It floats, it
///   refracts whatever scrolls beneath it, and it carries a hard ink outline so it still
///   reads as an object rather than a smudge.
/// - **Brutalism is the content layer** — transcripts, dictionary entries, settings panels.
///   Flat opaque cards, thick ink borders, hard offset shadows with no blur, heavy type.
///
/// The rules that keep this coherent:
/// - **Red means recording.** Nothing else in the app is red.
/// - **Yellow means selected.** The chosen key, the saved transcript, the winning engine.
///   A selected key is also *sunk* — shifted into its shadow — so selection reads without
///   color, and a check glyph makes it explicit.
/// - **No gradients, no soft shadows.** Depth is a hard ink slab offset down and right.
///   The only blur in the app is the system's own glass material.
/// - Every value a view needs lives here; components never declare their own.
enum DS {
    // MARK: - Color

    enum Color {
        /// The window background. Warm off-white on light, near-black on dark.
        static let paper = adaptive(light: 0xF3F0E8, dark: 0x111111)
        /// The dot grid printed on `paper`. Gives glass something to refract.
        static let paperDot = adaptive(light: 0xD3CEC2, dark: 0x2A2A2A)

        /// Brutalist cards and controls.
        static let card = adaptive(light: 0xFFFFFF, dark: 0x1D1D1D)
        /// A card under the pointer.
        static let cardHover = adaptive(light: 0xF7F5EF, dark: 0x262626)
        /// Text fields and other inputs set into a card.
        static let field = adaptive(light: 0xF3F0E8, dark: 0x141414)

        /// Borders, hard shadows and primary text. Light on dark, so the slab still shows.
        static let ink = adaptive(light: 0x111111, dark: 0xF1EDE4)
        /// Supporting text — timings, counts, notes.
        static let inkSecondary = adaptive(light: 0x55524C, dark: 0xA8A398)
        /// Placeholders, unlit meter segments, disabled glyphs.
        static let inkTertiary = adaptive(light: 0xB3AEA4, dark: 0x4A4844)

        /// Selection. Same in both appearances; always paired with `onAccent`.
        static let accent = swatch(0xFFD43B)
        /// Text and glyphs on `accent`.
        static let onAccent = swatch(0x111111)

        /// The record state — the only red in the app.
        static let record = swatch(0xE5322D)
        /// Glyphs on `record`.
        static let onRecord = swatch(0xFFFFFF)

        private static func swatch(_ hex: UInt32) -> SwiftUI.Color { SwiftUI.Color(hex: hex) }

        private static func adaptive(light: UInt32, dark: UInt32) -> SwiftUI.Color {
            SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            })
        }
    }

    // MARK: - Brutalism

    enum Brutal {
        /// Border on cards and controls.
        static let border: CGFloat = 2
        /// Border on small tags.
        static let borderThin: CGFloat = 1.5
        /// How far a card's hard shadow sits down and right.
        static let lift: CGFloat = 5
        /// The same for controls. A pressed or selected control sinks by exactly this much.
        static let liftSmall: CGFloat = 3
    }

    // MARK: - Glass

    enum Glass {
        /// The ink outline around glass. Thinner than a card's border: glass is the lighter layer.
        static let outline: CGFloat = 1.5
        /// Outline opacity, so the glass stays the dominant read.
        static let outlineOpacity: Double = 0.85
        /// Spacing that lets neighbouring glass shapes merge as they move.
        static let containerSpacing: CGFloat = 12
    }

    // MARK: - Type

    /// SF Pro at heavy weights. Brutalism is carried by weight and case, not by a novelty face.
    enum Font {
        static let display = SwiftUI.Font.system(size: 26, weight: .black)
        static let heading = SwiftUI.Font.system(size: 15, weight: .heavy)
        /// Uppercase labels. Pair with `eyebrowTracking`; `Eyebrow` does both.
        static let eyebrow = SwiftUI.Font.system(size: 10, weight: .bold)
        static let control = SwiftUI.Font.system(size: 12, weight: .bold)
        static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
        static let body = SwiftUI.Font.system(size: 13, weight: .regular)
        static let bodyEmphasis = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// Timings. Monospaced so digits don't shift.
        static let counter = SwiftUI.Font.system(size: 12, weight: .bold, design: .monospaced)
        /// The transport counter.
        static let counterLarge = SwiftUI.Font.system(size: 22, weight: .heavy, design: .monospaced)

        static let eyebrowTracking: CGFloat = 1.2
    }

    enum Icon {
        static let small: CGFloat = 9
        static let regular: CGFloat = 11
        static let large: CGFloat = 15
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

    // MARK: - Radius

    enum Radius {
        static let tag: CGFloat = 5
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let dock: CGFloat = 22
    }

    // MARK: - Sizes

    enum Control {
        static let height: CGFloat = 32
        static let heightSmall: CGFloat = 24
        static let recordSize: CGFloat = 44
        static let recordDot: CGFloat = 16
        static let recordStop: CGFloat = 13
        static let recordStopRadius: CGFloat = 2
        static let lampSize: CGFloat = 8
    }

    enum Meter {
        static let segments = 24
        static let segmentWidth: CGFloat = 4
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
        /// Gap between the hidden title bar's strip and the dock. The system still reserves
        /// the title bar's height as safe area, so this is the only clearance needed.
        static let dockTopInset: CGFloat = 8
        static let editorWidth: CGFloat = 460
        static let comparisonMinWidth: CGFloat = 600
        static let comparisonMinHeight: CGFloat = 440
        static let comparisonDefaultWidth: CGFloat = 680
        static let comparisonDefaultHeight: CGFloat = 580
    }

    enum Grid {
        /// Distance between dots on `paper`.
        static let pitch: CGFloat = 18
        static let dot: CGFloat = 1.6
    }

    // MARK: - HUD

    /// The listening capsule. Glass, outlined in ink, with red bars: it only shows while a
    /// hold is live, and red means recording.
    enum HUD {
        static let width: CGFloat = 148
        static let height: CGFloat = 40
        /// Room around the capsule inside the panel, so the outline isn't clipped.
        static let margin: CGFloat = 4
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
        /// A key sinking into its shadow. Snappy, no bounce: it's a physical stop.
        static let press = Animation.snappy(duration: 0.12)
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

private extension SwiftUI.Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
