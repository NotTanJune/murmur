import MurmurDesign
import SwiftUI

// The phone's copy of the Mac's cards, labels and page frame (`Sources/Murmur/UI/Components.swift`).
// The Mac's views stay in the Mac target; these are small re-creations over the same `DS` tokens.

extension View {
    /// A card: flat fill and a hairline border. No shadow; depth is for floating things.
    func cardSurface(_ fill: Color = DS.Color.card, radius: CGFloat = DS.Radius.card) -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack {
                shape.fill(fill)
                shape.strokeBorder(DS.Color.hairline, lineWidth: DS.Stroke.hairline)
            }
        }
    }
}

/// A page: a title, then a lazy column of content on the paper ground.
struct PhonePage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Space.wide) {
                Text(title)
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                    .accessibilityAddTraits(.isHeader)
                content
            }
            .padding(.horizontal, DS.Space.roomy)
            .padding(.vertical, DS.Space.roomy)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Color.pane.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
    }
}

/// A content card, optionally under an eyebrow title.
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

/// A small uppercase label. The casing happens here so a label can never be half-styled.
struct Eyebrow: View {
    let text: String
    var color: Color = DS.Color.inkSecondary

    var body: some View {
        Text(text.uppercased())
            .font(DS.Font.eyebrow)
            .tracking(DS.Font.eyebrowTracking)
            .foregroundStyle(color)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A small tag: entry kind, "Labelled".
struct Tag: View {
    let text: String
    var isHighlighted = false

    var body: some View {
        Text(text.uppercased())
            .font(DS.Font.eyebrow)
            .tracking(DS.Font.eyebrowTracking)
            .foregroundStyle(isHighlighted ? DS.Color.onSelected : DS.Color.inkSecondary)
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
    var color: Color = DS.Color.inkSecondary

    var body: some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A short confirmation that floats over the page: "Copied".
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
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, DS.Space.wide)
        .padding(.vertical, DS.Space.panel)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
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

/// A determinate bar for the download. Ink on the field, not a gradient.
struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Color.field)
                Capsule()
                    .fill(DS.Color.ink)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: DS.Phone.progressHeight)
        .accessibilityElement()
        .accessibilityLabel("Download progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}
