import MurmurDesign
import MurmurKit
import SwiftUI
import UIKit

/// Murmur's own emoji picker. A keyboard extension has no way to show Apple's, so this follows
/// iOS 26's instead: a "Describe an Emoji" search field at the top (a tap opens search mode,
/// `EmojiSearchPanel`), a grid that scrolls sideways, a category bar at the bottom, and a long
/// press for skin tones. There is no section title: the selected category in the bar names the
/// section. It lays out in the height it is given, never a taller one: the field and the bar keep
/// their sizes and the grid takes the rest, with fewer rows (never under `emojiMinRows`) where
/// five would be under `emojiMinCellHeight` each (the field costs the fifth row of a 253 pt
/// panel, as it does in iOS 26). Each section starts on a fresh column, so scrolling to a
/// category lands on its first emoji. The grid is UIKit (`EmojiGrid`); this view holds the
/// field, the category bar and the tone row, and hears from the grid only when the section in view
/// changes.
struct EmojiPanel: View {
    let actions: KeyboardActions
    let close: () -> Void
    let openSearch: () -> Void

    /// Frequently Used is read once, when the panel opens: typing an emoji must not reshuffle
    /// the grid under the finger, and closing the panel discards this view and its state.
    @State private var categories = Self.categories(recents: EmojiRecents.load())
    @State private var tones = EmojiTonePreference(defaults: MurmurEnvironment.defaults)
    @State private var section = 0
    @State private var tonePopup: TonePopup?
    @State private var grid = EmojiGridController()
    /// VoiceOver focus for the tone row, which opens over the grid and would otherwise leave the
    /// reader on the emoji underneath it.
    @AccessibilityFocusState private var toneRowFocused: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isCompact: Bool { verticalSizeClass == .compact }
    private var preferredRows: Int { isCompact ? DS.Keyboard.emojiRowsCompact : DS.Keyboard.emojiRows }
    private var columns: Int { isCompact ? DS.Keyboard.emojiColumnsCompact : DS.Keyboard.emojiColumns }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                VStack(spacing: DS.Keyboard.emojiBarSpacing) {
                    searchField
                    EmojiGrid(
                        categories: categories,
                        rows: Self.rows(fitting: geometry.size.height, preferred: preferredRows),
                        columns: columns,
                        controller: grid,
                        onSection: { section = $0 },
                        onSelect: { type($0) },
                        onTones: { emoji, isRecent, anchor in showTones(for: emoji, isRecent: isRecent, anchor: anchor) }
                    )
                    categoryBar
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                if let tonePopup {
                    // SwiftUI cannot pass a touch through and also catch it, so a tap outside or
                    // the start of a scroll closes the row and the next touch scrolls.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { self.tonePopup = nil }
                        .gesture(DragGesture(minimumDistance: DS.Keyboard.emojiDismissDrag).onChanged { _ in self.tonePopup = nil })
                    toneRow(tonePopup, panel: geometry.size)
                }
            }
        }
        .onChange(of: tonePopup != nil) { _, isOpen in
            if !isOpen { grid.returnFocusToPressedCell() }
        }
    }

    /// The rows that fit the grid's share of a panel `height` tall, at least
    /// `emojiMinCellHeight` each, between `emojiMinRows` and `preferred`. A 257 pt keyboard
    /// (245 pt inside its padding) leaves 165 pt for the grid under the 36 pt field: four rows of
    /// 41 pt. Turned, 202 pt (190 inside) leaves 110 pt: three rows of 37 pt.
    private static func rows(fitting height: CGFloat, preferred: Int) -> Int {
        let grid = height - DS.Keyboard.emojiSearchFieldHeight - DS.Keyboard.emojiBarHeight - DS.Keyboard.emojiBarSpacing * 2
        let fitting = Int((max(grid, 0) / DS.Keyboard.emojiMinCellHeight).rounded(.down))
        return max(DS.Keyboard.emojiMinRows, min(preferred, fitting))
    }

    // MARK: Data

    private static func categories(recents: [String]) -> [EmojiCatalog.Category] {
        let recent = EmojiCatalog.Category(id: "recents", title: "Frequently Used", symbol: "clock", emoji: recents)
        return (recents.isEmpty ? [] : [recent]) + EmojiCatalog.categories
    }

    private func type(_ emoji: String) {
        KeyFeedback.press()
        actions.insert(emoji)
        EmojiRecents.record(emoji)
    }

    // MARK: Search field

    /// Looks like iOS 26's field and opens search mode when tapped. It is a button: typing into
    /// it is done by the key plane in search mode, not here.
    private var searchField: some View {
        Button(action: openSearch) {
            HStack(spacing: DS.Keyboard.emojiSearchFieldSpacing) {
                Image(systemName: "magnifyingglass")
                    .font(DS.Keyboard.emojiSearchIconFont)
                Text("Describe an Emoji")
                    .font(DS.Keyboard.emojiSearchFieldFont)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Keyboard.emojiSearchFieldInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(DS.Keyboard.key))
            .contentShape(Capsule())
        }
        .buttonStyle(PlainKeyStyle())
        .frame(height: DS.Keyboard.emojiSearchFieldHeight)
        .accessibilityLabel("Describe an Emoji")
        .accessibilityHint("Search emoji by description")
        .accessibilityAddTraits(.isSearchField)
    }

    // MARK: Skin tones

    private struct TonePopup {
        let base: String
        let forms: [String]
        /// The pressed cell in the panel's coordinates.
        let anchor: CGRect
    }

    /// `anchor` is the pressed cell in the grid's coordinates; the grid starts below the search field.
    private func showTones(for emoji: String, isRecent: Bool, anchor: CGRect) {
        let base = isRecent ? (EmojiCatalog.base(ofToned: emoji) ?? emoji) : emoji
        let forms = EmojiCatalog.tones(for: base)
        guard !forms.isEmpty else { return }
        let panelAnchor = anchor.offsetBy(dx: 0, dy: DS.Keyboard.emojiSearchFieldHeight + DS.Keyboard.emojiBarSpacing)
        KeyFeedback.press()
        tonePopup = TonePopup(base: base, forms: [base] + forms, anchor: panelAnchor)
    }

    private func toneRow(_ popup: TonePopup, panel: CGSize) -> some View {
        let width = DS.Keyboard.emojiToneCellWidth * CGFloat(popup.forms.count) + DS.Keyboard.emojiToneInset * 2
        let height = DS.Keyboard.emojiToneCellHeight + DS.Keyboard.emojiToneInset * 2
        // Centred over the pressed emoji, kept inside the panel. Where there is no room above it
        // inside the keyboard (the first row), the row goes below the pressed emoji instead.
        let x = min(max(popup.anchor.midX - width / 2, 0), max(panel.width - width, 0))
        let above = popup.anchor.minY - height
        let y = above >= 0 ? above : min(popup.anchor.maxY, max(panel.height - height, 0))
        let current = tones.preferred(for: popup.base)
        return HStack(spacing: 0) {
            ForEach(popup.forms, id: \.self) { form in
                Text(form)
                    .font(.system(size: DS.Keyboard.emojiToneGlyphSize))
                    .frame(width: DS.Keyboard.emojiToneCellWidth, height: DS.Keyboard.emojiToneCellHeight)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Keyboard.emojiToneRadius)
                            .fill(form == current ? DS.Keyboard.functionKey : .clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { choose(form, for: popup.base) }
                    .accessibilityAddTraits(.isButton)
            }
        }
        .padding(DS.Keyboard.emojiToneInset)
        .background(RoundedRectangle(cornerRadius: DS.Keyboard.emojiToneRadius).fill(DS.Keyboard.letterKey))
        .floatingShadow()
        .offset(x: x, y: y)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Skin tones")
        .accessibilityFocused($toneRowFocused)
        .accessibilityAction(.escape) { tonePopup = nil }
        .onAppear { toneRowFocused = true }
    }

    private func choose(_ form: String, for base: String) {
        tones.set(form, for: base)
        // `EmojiTonePreference` is not observable, so the cells in view are told to redraw.
        tonePopup = nil
        grid.refreshVisible()
        type(form)
    }

    // MARK: Category bar

    private var categoryBar: some View {
        HStack(spacing: 0) {
            Button("ABC", action: close)
                .font(DS.Keyboard.barFont)
                .frame(width: DS.Keyboard.functionKeyWidth)
            ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                let selected = index == section
                Button {
                    section = index
                    grid.scroll(toSection: index)
                } label: {
                    Image(systemName: category.symbol)
                        .font(DS.Keyboard.barIconFont)
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Keyboard.keyRadius)
                                .fill(selected ? DS.Keyboard.functionKey : .clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: DS.Keyboard.keyRadius))
                }
                .accessibilityLabel(category.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            // The gap every other row keeps between keys: without it the selected category's
            // fill met the delete key's edge when the last category (Flags) was selected.
            DeleteKey(height: DS.Keyboard.emojiBarHeight, action: actions.delete)
                .padding(.leading, DS.Keyboard.keySpacing)
        }
        .buttonStyle(PlainKeyStyle())
        .foregroundStyle(.secondary)
        .frame(height: DS.Keyboard.emojiBarHeight)
    }
}
