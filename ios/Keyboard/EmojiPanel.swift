import MurmurDesign
import MurmurKit
import SwiftUI
import UIKit

/// Murmur's own emoji picker. A keyboard extension has no way to show Apple's, so this follows
/// it instead: a section title at the top, a grid of five rows that scrolls sideways, a
/// category bar at the bottom, and a long press for skin tones. It lays out in the height it is
/// given, never a taller one: the title and the bar keep their sizes and the grid takes the
/// rest, with fewer rows (never under `emojiMinRows`) where five would be under
/// `emojiMinCellHeight` each. Each section starts on a fresh
/// column, so scrolling to a category lands on its first emoji and the title can be read from
/// the scroll offset alone. The grid is UIKit (`EmojiGrid`); this view holds the title, the
/// category bar and the tone row, and hears from the grid only when the section in view changes.
struct EmojiPanel: View {
    let actions: KeyboardActions
    let close: () -> Void

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
                    title
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
    /// `emojiMinCellHeight` each, between `emojiMinRows` and `preferred`. A 260 pt keyboard
    /// (248 pt inside its padding) leaves 184 pt for the grid: five rows of 36.8 pt.
    private static func rows(fitting height: CGFloat, preferred: Int) -> Int {
        let grid = height - DS.Keyboard.emojiTitleHeight - DS.Keyboard.emojiBarHeight - DS.Keyboard.emojiBarSpacing * 2
        let fitting = Int((max(grid, 0) / DS.Keyboard.emojiMinCellHeight).rounded(.down))
        return max(DS.Keyboard.emojiMinRows, min(preferred, fitting))
    }

    // MARK: Data

    private static func categories(recents: [String]) -> [EmojiCatalog.Category] {
        let recent = EmojiCatalog.Category(id: "recents", title: "Frequently Used", symbol: "clock", emoji: recents)
        return (recents.isEmpty ? [] : [recent]) + EmojiCatalog.categories
    }

    private func type(_ emoji: String) {
        UIDevice.current.playInputClick()
        actions.insert(emoji)
        EmojiRecents.record(emoji)
    }

    // MARK: Title

    private var title: some View {
        HStack {
            Text(categories[min(section, categories.count - 1)].title)
                .textCase(.uppercase)
                .font(DS.Keyboard.emojiTitleFont)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Keyboard.emojiTitleInset)
        .frame(height: DS.Keyboard.emojiTitleHeight)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Skin tones

    private struct TonePopup {
        let base: String
        let forms: [String]
        /// The pressed cell in the panel's coordinates.
        let anchor: CGRect
    }

    /// `anchor` is the pressed cell in the grid's coordinates; the grid starts below the title.
    private func showTones(for emoji: String, isRecent: Bool, anchor: CGRect) {
        let base = isRecent ? (EmojiCatalog.base(ofToned: emoji) ?? emoji) : emoji
        let forms = EmojiCatalog.tones(for: base)
        guard !forms.isEmpty else { return }
        let panelAnchor = anchor.offsetBy(dx: 0, dy: DS.Keyboard.emojiTitleHeight + DS.Keyboard.emojiBarSpacing)
        UIDevice.current.playInputClick()
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
            DeleteKey(height: DS.Keyboard.emojiBarHeight, action: actions.delete)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(height: DS.Keyboard.emojiBarHeight)
    }
}
