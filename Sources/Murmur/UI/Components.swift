import SwiftUI

// The app's vocabulary: paper, cards, keys, tags, the glass dock, the meter.
// Every value here comes from `DS`. If a component needs a number that isn't a token, the
// token is missing — add it there rather than inlining it.

// MARK: - Surfaces

/// The window background: flat paper with a printed dot grid. The grid is what makes the
/// glass dock visibly refract as content scrolls under it; on a flat fill glass reads as tint.
struct PaperBackground: View {
    var body: some View {
        Canvas { context, size in
            let dot = DS.Grid.dot
            var y = DS.Grid.pitch / 2
            while y < size.height {
                var x = DS.Grid.pitch / 2
                while x < size.width {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)),
                        with: .color(DS.Color.paperDot)
                    )
                    x += DS.Grid.pitch
                }
                y += DS.Grid.pitch
            }
        }
        .background(DS.Color.paper)
        .allowsHitTesting(false)
    }
}

extension View {
    /// A brutalist surface: flat fill, ink border, and a hard ink slab offset down and right.
    /// The slab is drawn outside the view's bounds, so containers must leave `lift` of room.
    func brutalSurface(
        _ fill: Color = DS.Color.card,
        radius: CGFloat = DS.Radius.card,
        lift: CGFloat = DS.Brutal.lift,
        border: CGFloat = DS.Brutal.border
    ) -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                shape.fill(DS.Color.ink).offset(x: lift, y: lift)
                shape.fill(fill)
                shape.strokeBorder(DS.Color.ink, lineWidth: border)
            }
        }
    }

    /// Liquid Glass with an ink outline: the control layer. The outline is what ties glass to
    /// the brutalist content beneath it.
    func outlinedGlass(radius: CGFloat = DS.Radius.dock) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return glassEffect(.regular, in: shape)
            .overlay {
                shape.strokeBorder(DS.Color.ink.opacity(DS.Glass.outlineOpacity), lineWidth: DS.Glass.outline)
            }
    }
}

/// A content card with a title. Settings and notices are built from these.
struct BrutalCard<Content: View>: View {
    var title: String?
    var fill: Color = DS.Color.card
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            if let title {
                Text(title)
                    .font(DS.Font.heading)
                    .foregroundStyle(DS.Color.ink)
            }
            content
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brutalSurface(fill)
    }
}

// MARK: - Labels

/// A small uppercase label. The casing happens here so a label can never be half-styled.
struct Eyebrow: View {
    let text: String
    var color: Color = DS.Color.inkSecondary

    var body: some View {
        Text(text.uppercased())
            .font(DS.Font.eyebrow)
            .tracking(DS.Font.eyebrowTracking)
            .foregroundStyle(color)
    }
}

/// An outlined tag: engine name, cleanup profile, entry kind.
struct Tag: View {
    let text: String
    var isHighlighted = false

    var body: some View {
        Eyebrow(text: text, color: isHighlighted ? DS.Color.onAccent : DS.Color.ink)
            .padding(.horizontal, DS.Space.snug)
            .padding(.vertical, DS.Space.hair)
            .background(
                isHighlighted ? DS.Color.accent : DS.Color.card,
                in: .rect(cornerRadius: DS.Radius.tag, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.tag, style: .continuous)
                    .strokeBorder(DS.Color.ink, lineWidth: DS.Brutal.borderThin)
            )
    }
}

/// Supporting copy under a control.
struct Note: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Controls

/// A brutalist key. At rest it stands proud of its shadow; pressed or selected it sinks
/// into it. Selected keys are also yellow, so selection reads at a glance and without color.
struct BrutalButtonStyle: ButtonStyle {
    var isSelected = false
    var fill: Color = DS.Color.card
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        KeyBody(
            label: configuration.label,
            isSunk: isSelected || configuration.isPressed,
            isSelected: isSelected,
            fill: fill,
            compact: compact
        )
    }

    private struct KeyBody<Label: View>: View {
        let label: Label
        let isSunk: Bool
        let isSelected: Bool
        let fill: Color
        let compact: Bool

        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let lift = DS.Brutal.liftSmall
            let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            label
                .font(DS.Font.control)
                .foregroundStyle(isSelected ? DS.Color.onAccent : DS.Color.ink)
                .padding(.horizontal, compact ? DS.Space.snug : DS.Space.base)
                .frame(minHeight: compact ? DS.Control.heightSmall : DS.Control.height)
                .background {
                    ZStack {
                        shape.fill(isSelected ? DS.Color.accent : fill)
                        shape.strokeBorder(DS.Color.ink, lineWidth: DS.Brutal.border)
                    }
                }
                .background {
                    // Behind the key and offset by `lift` at rest. When the key sinks by the
                    // same amount the slab ends up exactly under it, i.e. it disappears.
                    shape.fill(DS.Color.ink)
                        .offset(x: isSunk ? 0 : lift, y: isSunk ? 0 : lift)
                }
                .offset(x: isSunk ? lift : 0, y: isSunk ? lift : 0)
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(DS.Motion.press, value: isSunk)
        }
    }
}

/// A row of keys for one choice. The selected key is sunk, yellow and checked.
struct ChoiceKeys<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var help: ((Option) -> String)?

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    selection = option
                } label: {
                    HStack(spacing: DS.Space.tight + DS.Space.hair) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: DS.Icon.regular, weight: .bold))
                        Text(title(option))
                    }
                }
                .buttonStyle(BrutalButtonStyle(isSelected: isSelected))
                .help(help?(option) ?? "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        // Room for the shadow slab, which sits outside each key's bounds.
        .padding(.trailing, DS.Brutal.liftSmall)
        .padding(.bottom, DS.Brutal.liftSmall)
    }
}

/// Record and stop. Round, the one control that isn't a key: it's the thing you press most.
struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    RoundedRectangle(cornerRadius: DS.Control.recordStopRadius)
                        .fill(DS.Color.onRecord)
                        .frame(width: DS.Control.recordStop, height: DS.Control.recordStop)
                } else {
                    Circle()
                        .fill(DS.Color.record)
                        .overlay(Circle().strokeBorder(DS.Color.ink, lineWidth: DS.Brutal.borderThin))
                        .frame(width: DS.Control.recordDot, height: DS.Control.recordDot)
                }
            }
            .frame(width: DS.Control.recordSize, height: DS.Control.recordSize)
        }
        .buttonStyle(RecordStyle(isRecording: isRecording))
        .help(isRecording ? "Stop recording" : "Record")
        .accessibilityLabel(isRecording ? "Stop" : "Record")
    }

    private struct RecordStyle: ButtonStyle {
        let isRecording: Bool

        func makeBody(configuration: Configuration) -> some View {
            let isSunk = isRecording || configuration.isPressed
            let lift = DS.Brutal.liftSmall
            configuration.label
                .background {
                    ZStack {
                        Circle().fill(isRecording ? DS.Color.record : DS.Color.card)
                        Circle().strokeBorder(DS.Color.ink, lineWidth: DS.Brutal.border)
                    }
                }
                .background {
                    Circle().fill(DS.Color.ink).offset(x: isSunk ? 0 : lift, y: isSunk ? 0 : lift)
                }
                .offset(x: isSunk ? lift : 0, y: isSunk ? lift : 0)
                .animation(DS.Motion.press, value: isSunk)
        }
    }
}

/// A small search field set into the paper.
struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DS.Icon.regular, weight: .bold))
                .foregroundStyle(DS.Color.inkSecondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DS.Space.base)
        .frame(height: DS.Control.height)
        .brutalSurface(DS.Color.card, radius: DS.Radius.control, lift: DS.Brutal.liftSmall)
    }
}

/// A labelled text input, for the dictionary editor.
struct BrutalTextField: View {
    let label: String
    @Binding var text: String
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            Eyebrow(text: label)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .padding(.horizontal, DS.Space.snug)
                .frame(height: DS.Control.height)
                .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Color.ink, lineWidth: DS.Brutal.border)
                )
        }
    }
}

/// Nothing to show yet.
struct EmptyPanel: View {
    let label: String
    let detail: String

    var body: some View {
        VStack(spacing: DS.Space.snug) {
            Text(label)
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.ink)
            Text(detail)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
        }
        .padding(.horizontal, DS.Space.wide)
        .padding(.vertical, DS.Space.roomy)
        .brutalSurface()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Instrumentation

/// A segmented level meter. Lit segments are red while recording (red means recording) and
/// ink otherwise; unlit ones stay faintly printed.
struct LevelMeter: View {
    /// Input level, 0...1.
    let level: Float
    let isActive: Bool

    var body: some View {
        let lit = isActive ? Int((CGFloat(min(max(level, 0), 1)) * CGFloat(DS.Meter.segments)).rounded(.up)) : 0
        HStack(alignment: .center, spacing: DS.Meter.segmentSpacing) {
            ForEach(0..<DS.Meter.segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: DS.Meter.segmentRadius)
                    .fill(index < lit ? DS.Color.record : DS.Color.inkTertiary)
                    .frame(width: DS.Meter.segmentWidth, height: segmentHeight(index))
            }
        }
        .frame(height: DS.Meter.height)
        .animation(DS.Motion.meter, value: lit)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(isActive ? "\(Int(level * 100)) percent" : "Idle")
    }

    /// A shallow rise across the meter, so it reads as a scale rather than a bar chart.
    private func segmentHeight(_ index: Int) -> CGFloat {
        let progress = CGFloat(index + 1) / CGFloat(DS.Meter.segments)
        return DS.Meter.height * (DS.Meter.minimumFill + (1 - DS.Meter.minimumFill) * progress)
    }
}

/// A small round indicator: lit red while recording.
struct Lamp: View {
    let isLit: Bool

    var body: some View {
        Circle()
            .fill(isLit ? DS.Color.record : DS.Color.inkTertiary)
            .overlay(Circle().strokeBorder(DS.Color.ink, lineWidth: DS.Brutal.borderThin))
            .frame(width: DS.Control.lampSize, height: DS.Control.lampSize)
            .animation(DS.Motion.lamp, value: isLit)
    }
}
