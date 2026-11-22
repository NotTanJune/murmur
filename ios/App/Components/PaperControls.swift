import MurmurDesign
import SwiftUI

// Buttons and inputs, the phone's copy of the Mac's `KeyButtonStyle`, `ChoiceKeys` and
// `PaperTextField`. Cream means selected: a `selected` fill, an ink stroke and a check.

/// `.primary` is a filled capsule; `.secondary` a hairline-bordered chip; `.plain` a bare
/// label for quiet actions. Selected is cream, ink-stroked and checked, so it reads without colour.
struct KeyButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }

    var kind: Kind = .secondary
    var isSelected = false
    /// Shorter, for row actions.
    var compact = false
    /// Whether a selected button prepends a check. Off where the label already has a glyph
    /// that changes with the state (bookmark).
    var showsCheck = true

    func makeBody(configuration: Configuration) -> some View {
        PaperBody(label: configuration.label, isPressed: configuration.isPressed, style: self)
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
            switch style.kind {
            case .plain: DS.Space.snug
            case .primary: DS.Space.roomy
            case .secondary: style.compact ? DS.Space.snug : DS.Space.base
            }
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

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                }
                .buttonStyle(KeyButtonStyle(kind: .secondary, isSelected: isSelected))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// A labelled one-line text input.
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
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, DS.Space.snug)
                .frame(height: DS.Phone.fieldHeight)
                .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Color.hairline, lineWidth: DS.Stroke.hairline)
                )
        }
    }
}

/// A switch row with an optional note under it, tinted moss like the Mac's switches.
struct ToggleRow: View {
    let title: String
    var note: String?
    @Binding var isOn: Bool
    var isDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            Toggle(isOn: $isOn) {
                Text(title)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
            }
            .tint(DS.Color.stat)
            .disabled(isDisabled)
            if let note {
                Note(text: note)
            }
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
                .autocorrectionDisabled()
                .submitLabel(.search)
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
