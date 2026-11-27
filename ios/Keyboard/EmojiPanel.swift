import MurmurDesign
import MurmurKit
import SwiftUI
import UIKit

/// Murmur's own emoji picker. A keyboard extension has no way to show Apple's, so this follows
/// iOS 26's instead (measured against the owner's screenshot of Apple's on 2026-11-27): a "Search
/// Emoji" field at the top (a tap opens search mode, `EmojiSearchPanel`), a grid that scrolls
/// sideways, a category bar at the bottom, and a long press for skin tones. There is no section
/// title: the selected category in the bar names the section. It lays out in the height it is
/// given, never a taller one: the field and the bar keep their sizes and the grid takes the rest,
/// with fewer rows (never under `emojiMinRows`) where five would be under `emojiMinCellHeight`
/// each. The vertical rhythm is Apple's measured from the keyboard's bottom edge
/// (`emojiPanelTopInset` and the tokens after it). Each section starts on a fresh column, so
/// scrolling to a category lands on its first emoji. The grid is UIKit (`EmojiGrid`); this view holds the
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
    /// While the finger that opened the row slides over it: whether it has been on the row, and
    /// the tone under it now (nil off the row).
    @State private var toneEntered = false
    @State private var toneHover: String?
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
                VStack(spacing: 0) {
                    searchField
                        .padding(.horizontal, DS.Keyboard.emojiFieldSideInset)
                        .padding(.top, DS.Keyboard.emojiPanelTopInset)
                        .padding(.bottom, DS.Keyboard.emojiFieldGridGap)
                    EmojiGrid(
                        categories: categories,
                        rows: Self.rows(fitting: geometry.size.height, preferred: preferredRows),
                        columns: columns,
                        controller: grid,
                        onSection: { section = $0 },
                        onSelect: { type($0) },
                        onTones: { emoji, isRecent, anchor in showTones(for: emoji, isRecent: isRecent, anchor: anchor) },
                        onToneDrag: { toneDrag(to: $0, panel: geometry.size) },
                        onToneRelease: { toneRelease(at: $0, panel: geometry.size) },
                        compact: isCompact
                    )
                    categoryBar
                        .padding(.top, DS.Keyboard.emojiGridBarGap)
                        .padding(.bottom, DS.Keyboard.emojiPanelBottomInset)
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
    /// `emojiMinCellHeight` each, between `emojiMinRows` and `preferred`. The 305 pt portrait
    /// picker leaves 215 pt for the grid: four rows of 54 pt. A 257 pt keyboard (where iOS did not
    /// apply the extra height) leaves 167 pt, four rows of 42. Turned, 202 pt leaves 112 pt:
    /// three rows of 37 pt.
    private static func rows(fitting height: CGFloat, preferred: Int) -> Int {
        let grid = height - DS.Keyboard.emojiGridTop - DS.Keyboard.emojiGridBarGap - DS.Keyboard.emojiBarHeight
            - DS.Keyboard.emojiPanelBottomInset
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
            HStack(spacing: DS.Keyboard.emojiSearchIconSpacing) {
                Image(systemName: "magnifyingglass")
                    .font(DS.Keyboard.emojiSearchIconFont)
                Text("Search Emoji")
                    .font(DS.Keyboard.emojiSearchFieldFont)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Keyboard.emojiSearchFieldInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Capsule().fill(DS.Keyboard.emojiFieldFill))
            .contentShape(Capsule())
        }
        .buttonStyle(PlainKeyStyle())
        .frame(height: DS.Keyboard.emojiPanelFieldHeight)
        .accessibilityLabel("Search Emoji")
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
        // The grid shows the remembered toned form, so the base is looked up from it.
        let base = EmojiCatalog.base(ofToned: emoji) ?? emoji
        let forms = EmojiCatalog.tones(for: base)
        guard !forms.isEmpty else { return }
        let panelAnchor = anchor.offsetBy(dx: 0, dy: DS.Keyboard.emojiGridTop)
        KeyFeedback.press()
        toneEntered = false
        toneHover = nil
        tonePopup = TonePopup(base: base, forms: [base] + forms, anchor: panelAnchor)
    }

    /// Where the tone row sits and which tone is at a point; the drawing and the finger's hit test
    /// both read it, so they cannot disagree.
    private struct ToneRowLayout {
        let origin: CGPoint
        let size: CGSize
        let count: Int

        init(popup: TonePopup, panel: CGSize) {
            count = popup.forms.count
            let width = DS.Keyboard.emojiToneCellWidth * CGFloat(count) + DS.Keyboard.emojiToneInset * 2
            let height = DS.Keyboard.emojiToneCellHeight + DS.Keyboard.emojiToneInset * 2
            size = CGSize(width: width, height: height)
            // Centred over the pressed emoji, kept inside the panel. Where there is no room above it
            // inside the keyboard (the first row), the row goes below the pressed emoji instead.
            let x = min(max(popup.anchor.midX - width / 2, 0), max(panel.width - width, 0))
            let above = popup.anchor.minY - height
            let y = above >= 0 ? above : min(popup.anchor.maxY, max(panel.height - height, 0))
            origin = CGPoint(x: x, y: y)
        }

        /// The index of the tone cell under `point` (panel coordinates), or nil off the cells.
        func index(at point: CGPoint) -> Int? {
            guard point.y >= origin.y, point.y <= origin.y + size.height else { return nil }
            let local = point.x - origin.x - DS.Keyboard.emojiToneInset
            guard local >= 0 else { return nil }
            let index = Int(local / DS.Keyboard.emojiToneCellWidth)
            return index < count ? index : nil
        }
    }

    private func toneDrag(to point: CGPoint, panel: CGSize) {
        guard let popup = tonePopup else { return }
        let form = ToneRowLayout(popup: popup, panel: panel).index(at: point).map { popup.forms[$0] }
        // Until the finger reaches the row, the current tone stays lit and nothing changes.
        if !toneEntered, form == nil { return }
        let before = toneEntered ? toneHover : tones.preferred(for: popup.base)
        toneEntered = true
        toneHover = form
        if let form, form != before { KeyFeedback.press() }
    }

    private func toneRelease(at point: CGPoint, panel: CGSize) {
        guard let popup = tonePopup else { return }
        let layout = ToneRowLayout(popup: popup, panel: panel)
        if let index = layout.index(at: point) {
            choose(popup.forms[index], for: popup.base)
        } else if toneEntered {
            // The finger slid onto the row and away again: close it and type nothing.
            tonePopup = nil
        }
        // Never reached the row: it stays open for a tap.
    }

    private func toneRow(_ popup: TonePopup, panel: CGSize) -> some View {
        let layout = ToneRowLayout(popup: popup, panel: panel)
        let x = layout.origin.x
        let y = layout.origin.y
        let lit: String? = toneEntered ? toneHover : tones.preferred(for: popup.base)
        return HStack(spacing: 0) {
            ForEach(popup.forms, id: \.self) { form in
                Text(form)
                    .font(.system(size: DS.Keyboard.emojiToneGlyphSize))
                    .frame(width: DS.Keyboard.emojiToneCellWidth, height: DS.Keyboard.emojiToneCellHeight)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Keyboard.emojiToneRadius)
                            .fill(form == lit ? DS.Keyboard.functionKey : .clear)
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

    /// Apple's bar: ABC near the leading edge, the categories in equal cells with the selected
    /// one on a circle, every icon in the label colour, and the delete glyph alone at the end.
    private var categoryBar: some View {
        HStack(spacing: 0) {
            Button(action: close) {
                Text("ABC")
                    .font(DS.Keyboard.emojiBarABCFont)
                    .opacity(DS.Keyboard.emojiBarABCOpacity)
                    .padding(.leading, DS.Keyboard.emojiBarABCInset)
                    .frame(width: DS.Keyboard.emojiBarSideWidth, alignment: .leading)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                let selected = index == section
                Button {
                    section = index
                    grid.scroll(toSection: index)
                } label: {
                    Self.icon(for: category)
                        .frame(maxWidth: DS.Keyboard.emojiBarSelectionDiameter, maxHeight: DS.Keyboard.emojiBarSelectionDiameter)
                        .background(Circle().fill(selected ? DS.Keyboard.emojiSelectionFill : .clear))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(category.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            DeleteKey(height: DS.Keyboard.emojiBarHeight, bare: true, action: actions.delete)
        }
        .buttonStyle(PlainKeyStyle())
        .foregroundStyle(.primary)
        .frame(height: DS.Keyboard.emojiBarHeight)
    }

    /// Three of Apple's category icons are not SF Symbols, so Murmur draws its own.
    @ViewBuilder
    private static func icon(for category: EmojiCatalog.Category) -> some View {
        switch category.id {
        case "nature": DogFaceIcon()
        case "food": AppleFruitIcon()
        case "travel": CompactCarIcon()
        default: Image(systemName: category.symbol).font(DS.Keyboard.barIconFont)
        }
    }
}
