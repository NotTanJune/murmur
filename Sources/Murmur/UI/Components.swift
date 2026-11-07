import SwiftUI

// The app's vocabulary: cards, buttons, tags, the record button, the meter, toasts.
// Every value in this file comes from `DS`. If a
// token is missing: add it there rather than inlining it.

// MARK: - Surfaces

extension View {
    /// A card: flat fill and a hairline border. No shadow; depth is for floating things.
    func cardSurface(
        _ fill: Color = DS.Color.card,
        radius: CGFloat = DS.Radius.card
    ) -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                shape.fill(fill)
                shape.strokeBorder(DS.Color.hairline, lineWidth: DS.Stroke.hairline)
            }
        }
    }

    /// One row's slice of a card, so a long card can live in a `LazyVStack` row by row
    /// instead of building every row at once. The first slice carries the top corners, the
    /// last the bottom ones, and every slice but the first draws the divider above it.
    func cardSegment(isFirst: Bool, isLast: Bool, radius: CGFloat = DS.Radius.card) -> some View {
        let fill = UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? radius : 0,
            bottomLeadingRadius: isLast ? radius : 0,
            bottomTrailingRadius: isLast ? radius : 0,
            topTrailingRadius: isFirst ? radius : 0
        )
        return background(DS.Color.card)
            .clipShape(fill)
            .overlay {
                CardSegmentOutline(radius: radius, isFirst: isFirst, isLast: isLast)
                    .stroke(DS.Color.hairline, lineWidth: DS.Stroke.hairline)
            }
            .overlay(alignment: .top) {
                if !isFirst {
                    Rectangle().fill(DS.Color.divider).frame(height: DS.Stroke.hairline)
                }
            }
    }

    /// The soft shadow of a surface that floats above the window: HUD, toasts, popovers.
    func floatingShadow() -> some View {
        shadow(color: DS.Color.shadow, radius: DS.Shadow.floatRadius, y: DS.Shadow.floatY)
    }
}

/// A content card, optionally under an eyebrow title. Settings groups are built from these.
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            if let title {
                Eyebrow(text: title)
            }
            VStack(alignment: .leading, spacing: DS.Space.base) {
                content
            }
            .padding(DS.Space.roomy)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }
}

/// A selectable card for a choice between described options.
struct OptionCard<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .padding(DS.Space.roomy)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    let shape = RoundedRectangle(cornerRadius: DS.Radius.option, style: .continuous)
                    ZStack {
                        shape.fill(isSelected ? DS.Color.selected : DS.Color.card)
                        shape.strokeBorder(
                            isSelected ? DS.Color.ink : DS.Color.hairline,
                            lineWidth: isSelected ? DS.Stroke.selected : DS.Stroke.hairline
                        )
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.option, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The outline of a `cardSegment`: both sides always, the top edge and corners only on the
/// first slice, the bottom ones only on the last, so stacked slices read as one border.
private struct CardSegmentOutline: Shape {
    let radius: CGFloat
    let isFirst: Bool
    let isLast: Bool

    func path(in rect: CGRect) -> Path {
        let inset = DS.Stroke.hairline / 2
        let minX = rect.minX + inset, maxX = rect.maxX - inset
        let minY = rect.minY + (isFirst ? inset : 0)
        let maxY = rect.maxY - (isLast ? inset : 0)
        let r = radius - inset

        var path = Path()
        if isLast {
            path.move(to: CGPoint(x: minX + r, y: maxY))
            path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY - r), radius: r)
        } else {
            path.move(to: CGPoint(x: minX, y: maxY))
        }
        if isFirst {
            path.addLine(to: CGPoint(x: minX, y: minY + r))
            path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + r, y: minY), radius: r)
            path.addLine(to: CGPoint(x: maxX - r, y: minY))
            path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + r), radius: r)
        } else {
            path.addLine(to: CGPoint(x: minX, y: minY))
            path.move(to: CGPoint(x: maxX, y: minY))
        }
        if isLast {
            path.addLine(to: CGPoint(x: maxX, y: maxY - r))
            path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX - r, y: maxY), radius: r)
            path.addLine(to: CGPoint(x: minX + r, y: maxY))
        } else {
            path.addLine(to: CGPoint(x: maxX, y: maxY))
        }
        return path
    }
}

/// A pane page: a title, then content in a centred column of readable width. Lazy, so a
/// long list only builds the rows on screen.
struct PageScroll<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    @State private var isScrolling = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.wide) {
                Text(title)
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                content
            }
            .padding(.horizontal, DS.Space.panel)
            .padding(.top, DS.Space.roomy)
            .padding(.bottom, DS.Space.panel)
            .frame(maxWidth: DS.Window.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onScrollPhaseChange { _, phase in isScrolling = phase != .idle }
        .environment(\.isScrolling, isScrolling)
    }
}

extension EnvironmentValues {
    /// True while the enclosing `PageScroll` is moving, so rows can ignore hover.
    @Entry var isScrolling = false
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

/// A small tag: engine name, cleanup profile, entry kind.
struct Tag: View {
    let text: String
    var isHighlighted = false

    var body: some View {
        Eyebrow(text: text, color: isHighlighted ? DS.Color.onSelected : DS.Color.inkSecondary)
            .padding(.horizontal, DS.Space.snug)
            .padding(.vertical, DS.Space.hair)
            .background(
                isHighlighted ? DS.Color.selected : DS.Color.field,
                in: .rect(cornerRadius: DS.Radius.tag, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.tag, style: .continuous)
                    .strokeBorder(
                        isHighlighted ? DS.Color.ink : DS.Color.hairline,
                        lineWidth: DS.Stroke.hairline
                    )
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

/// A short confirmation that floats over the content: "Copied".
struct Toast: View {
    let text: String

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: DS.Icon.large))
                .foregroundStyle(DS.Color.success)
            Text(text)
                .font(DS.Font.control)
                .foregroundStyle(DS.Color.onToast)
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.toast, in: .capsule)
        .floatingShadow()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Controls

/// The app's button. `.primary` is a filled capsule; `.secondary` a hairline-bordered chip;
/// `.plain` a bare glyph for quiet actions. Selected is a cream fill, an ink stroke and a
/// leading check, so it reads without colour.
struct KeyButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }

    var kind: Kind = .secondary
    var isSelected = false
    /// Shorter, for row actions.
    var compact = false
    /// Tighter sides, for rows of choices that share a crowded line.
    var dense = false
    /// Whether a selected button prepends a check. Off where the label already has a glyph
    /// that changes with the state (bookmark, pencil).
    var showsCheck = true

    func makeBody(configuration: Configuration) -> some View {
        PaperBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            style: self
        )
    }

    private struct PaperBody<Label: View>: View {
        let label: Label
        let isPressed: Bool
        let style: KeyButtonStyle

        @Environment(\.isEnabled) private var isEnabled

        private var isSelected: Bool { style.isSelected && style.kind == .secondary }

        var body: some View {
            HStack(spacing: DS.Space.tight) {
                if isSelected && style.showsCheck {
                    Image(systemName: "checkmark")
                        .font(.system(size: DS.Icon.small, weight: .bold))
                }
                label
            }
            .font(DS.Font.control)
            .foregroundStyle(foreground)
            // A label never wraps: a squeezed row would otherwise break one word across
            // two lines inside its chip.
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: style.compact ? DS.Control.heightSmall : DS.Control.height)
            .background { surface }
            .contentShape(shape)
            .scaleEffect(isPressed ? DS.Motion.pressScale : 1)
            .opacity(isEnabled ? (isPressed ? DS.Motion.pressOpacity : 1) : DS.Motion.disabledOpacity)
            .animation(DS.Motion.press, value: isPressed)
        }

        private var horizontalPadding: CGFloat {
            if style.kind == .plain { return DS.Space.snug }
            if style.kind == .primary { return DS.Space.roomy }
            return style.compact || style.dense ? DS.Space.snug : DS.Space.base
        }

        private var foreground: Color {
            switch style.kind {
            case .primary: DS.Color.onPrimary
            case .plain: DS.Color.inkSecondary
            case .secondary: isSelected ? DS.Color.onSelected : DS.Color.ink
            }
        }

        private var shape: AnyShape {
            style.kind == .primary
                ? AnyShape(Capsule())
                : AnyShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }

        @ViewBuilder private var surface: some View {
            switch style.kind {
            case .primary:
                Capsule().fill(DS.Color.primary)
            case .plain:
                Color.clear
            case .secondary:
                ZStack {
                    shape.fill(isSelected ? DS.Color.selected : DS.Color.card)
                    shape.stroke(
                        isSelected ? DS.Color.ink : DS.Color.hairline,
                        lineWidth: isSelected ? DS.Stroke.selected : DS.Stroke.hairline
                    )
                }
            }
        }
    }
}

/// A row of chips for one choice. The selected chip is cream, ink-stroked and checked.
struct ChoiceKeys<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var help: ((Option) -> String)?
    var dense = false
    /// Stack the chips top to bottom, for narrow columns.
    var isVertical = false

    var body: some View {
        let layout = isVertical
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.snug))
            : AnyLayout(HStackLayout(spacing: DS.Space.snug))
        layout {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                }
                .buttonStyle(KeyButtonStyle(kind: .secondary, isSelected: isSelected, dense: dense))
                .help(help?(option) ?? "")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// Record and stop. Round, the one control that isn't a chip: it's the thing you press most.
struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(DS.Color.record)
                if isRecording {
                    RoundedRectangle(cornerRadius: DS.Control.recordStopRadius, style: .continuous)
                        .fill(DS.Color.onRecord)
                        .frame(width: DS.Control.recordStop, height: DS.Control.recordStop)
                } else {
                    Circle()
                        .fill(DS.Color.onRecord)
                        .frame(width: DS.Control.recordDot, height: DS.Control.recordDot)
                }
            }
            .frame(width: DS.Control.recordSize, height: DS.Control.recordSize)
        }
        .buttonStyle(RecordStyle())
        .help(isRecording ? "Stop recording" : "Record")
        .accessibilityLabel(isRecording ? "Stop" : "Record")
    }

    private struct RecordStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? DS.Motion.pressScale : 1)
                .opacity(configuration.isPressed ? DS.Motion.pressOpacity : 1)
                .animation(DS.Motion.press, value: configuration.isPressed)
        }
    }
}

/// A small search field.
struct SearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: DS.Icon.regular, weight: .semibold))
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
        .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Color.hairline, lineWidth: DS.Stroke.hairline)
        )
    }
}

/// A magnifier that expands into a `SearchField`; closing it clears the query.
struct SearchToggle: View {
    @Binding var text: String
    let placeholder: String
    @State private var isOpen = false

    var body: some View {
        if isOpen || !text.isEmpty {
            HStack(spacing: DS.Space.snug) {
                SearchField(text: $text, placeholder: placeholder)
                    .frame(width: DS.Control.searchWidth)
                Button {
                    text = ""
                    withAnimation(DS.Motion.panel) { isOpen = false }
                } label: {
                    Text("Done")
                }
                .buttonStyle(KeyButtonStyle(kind: .plain))
            }
        } else {
            Button {
                withAnimation(DS.Motion.panel) { isOpen = true }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DS.Icon.regular, weight: .semibold))
            }
            .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
            .help(placeholder)
            .accessibilityLabel(placeholder)
        }
    }
}

/// A labelled text input, for the dictionary editor.
struct PaperTextField: View {
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
                        .strokeBorder(DS.Color.hairline, lineWidth: DS.Stroke.hairline)
                )
        }
    }
}

/// Nothing to show yet. The headline is a display serif; `highlight`, a substring of
/// `label`, is set in italic and the accent colour.
struct EmptyPanel: View {
    let label: String
    var highlight: String?
    let detail: String

    var body: some View {
        VStack(spacing: DS.Space.snug) {
            Text(headline)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
        }
        .padding(.horizontal, DS.Space.wide)
        .padding(.vertical, DS.Space.roomy)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headline: AttributedString {
        var text = AttributedString(label)
        text.font = DS.Font.display
        text.foregroundColor = DS.Color.ink
        if let highlight, let range = text.range(of: highlight) {
            text[range].font = DS.Font.displayItalic
            text[range].foregroundColor = DS.Color.highlight
        }
        return text
    }
}

// MARK: - Instrumentation

/// A segmented level meter. Lit segments are red while recording (red means recording);
/// unlit ones stay faint.
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
            .frame(width: DS.Control.lampSize, height: DS.Control.lampSize)
            .animation(DS.Motion.lamp, value: isLit)
    }
}
