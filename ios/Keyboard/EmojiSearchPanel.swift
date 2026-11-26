import MurmurDesign
import MurmurKit
import SwiftUI
import UIKit

/// Emoji search, as iOS 26 does it: the search field on top with a Cancel beside it, one row of
/// results under it (Frequently Used while the query is empty), and the key plane below, which
/// `KeyboardView` keeps visible and `TypingController` routes into `EmojiSearchModel` instead of
/// the field. The field is not a text field: the keys are Murmur's own and the host's text proxy
/// is not the query, so it draws the query and a caret itself.
///
/// The panel lays out in the height it is given. The keyboard asks to be taller while searching
/// (`DS.Keyboard.emojiSearchRegionHeight` for this region); where less arrives (iOS did not
/// apply the new height), the field and the results share one row instead of stacking.
struct EmojiSearchPanel: View {
    let model: EmojiSearchModel
    let actions: KeyboardActions
    let close: () -> Void

    @State private var grid = EmojiGridController()
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var columns: Int { verticalSizeClass == .compact ? DS.Keyboard.emojiColumnsCompact : DS.Keyboard.emojiColumns }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.height < DS.Keyboard.emojiSearchRegionHeight - 1 {
                compact(width: geometry.size.width, height: geometry.size.height)
            } else {
                stacked
            }
        }
    }

    /// Field and Cancel over the row of results.
    private var stacked: some View {
        VStack(spacing: DS.Keyboard.emojiBarSpacing) {
            HStack(spacing: DS.Keyboard.emojiSearchFieldSpacing) {
                field
                Button("Cancel", action: close)
                    .buttonStyle(PlainKeyStyle())
                    .font(DS.Keyboard.barFont)
                    .foregroundStyle(.primary)
                    // Text has no keycap around it, so at the keys' edge it read as cut off.
                    .padding(.trailing, DS.Keyboard.emojiSearchFieldSpacing)
            }
            .frame(height: DS.Keyboard.emojiSearchFieldHeight)
            results
                .frame(height: DS.Keyboard.emojiSearchResultsHeight)
        }
        .padding(.horizontal, DS.Keyboard.padding)
        .padding(.top, DS.Keyboard.emojiSearchTopInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// A single row for a keyboard that did not grow: a field a little under half the width, the
    /// results beside it. The emoji key and return still go back to the grid.
    private func compact(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: DS.Keyboard.emojiSearchFieldSpacing) {
            field
                .frame(width: width * DS.Keyboard.emojiSearchCompactFieldFraction)
                .frame(height: DS.Keyboard.emojiSearchFieldHeight)
            results
        }
        .padding(.horizontal, DS.Keyboard.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Field

    private var field: some View {
        HStack(spacing: DS.Keyboard.emojiSearchFieldSpacing) {
            Image(systemName: "magnifyingglass")
                .font(DS.Keyboard.emojiSearchIconFont)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            queryText
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Describe an Emoji")
                .accessibilityValue(model.query.isEmpty ? "Empty" : model.query)
                .accessibilityAddTraits(.isSearchField)
            if !model.query.isEmpty {
                Button(action: model.clear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(DS.Keyboard.emojiSearchIconFont)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainKeyStyle())
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, DS.Keyboard.emojiSearchFieldInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(DS.Keyboard.key))
    }

    /// The query with the caret after it, or the placeholder with the caret before it.
    private var queryText: some View {
        HStack(spacing: 0) {
            if model.query.isEmpty {
                Caret()
                Text("Describe an Emoji")
                    .font(DS.Keyboard.emojiSearchFieldFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, DS.Keyboard.emojiSearchCaretWidth)
            } else {
                Text(model.query)
                    .font(DS.Keyboard.emojiSearchFieldFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Caret()
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Results

    private var results: some View {
        ZStack {
            EmojiGrid(
                categories: model.categories,
                rows: 1,
                columns: columns,
                controller: grid,
                onSection: { _ in },
                onSelect: { type($0) },
                // Skin tones are chosen in the picker's grid; a result shows the remembered one.
                onTones: { _, _, _ in },
                reloadToken: model.version)
            if !model.query.trimmingCharacters(in: .whitespaces).isEmpty, model.results.isEmpty {
                Text("No emoji found")
                    .font(DS.Keyboard.messageFont)
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.query.isEmpty ? "Frequently Used" : "Results")
    }

    /// The same path as the grid's tap: through the typing controller, remembered as a recent.
    /// Search stays open, as iOS keeps it.
    private func type(_ emoji: String) {
        KeyFeedback.press()
        actions.insert(emoji)
        EmojiRecents.record(emoji)
    }
}

/// The query's caret, blinking as the system's does.
private struct Caret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: DS.Keyboard.emojiSearchCaretBlink)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / DS.Keyboard.emojiSearchCaretBlink) % 2 == 0
            Rectangle()
                .fill(DS.Keyboard.wordmark)
                .frame(width: DS.Keyboard.emojiSearchCaretWidth, height: DS.Keyboard.emojiSearchCaretHeight)
                .opacity(on ? 1 : 0)
        }
        .accessibilityHidden(true)
    }
}
