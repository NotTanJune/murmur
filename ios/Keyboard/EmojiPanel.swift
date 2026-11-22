import MurmurDesign
import SwiftUI
import UIKit

/// Murmur's own emoji picker: a keyboard extension cannot open Apple's. Three rows scroll
/// sideways, sized from the height the keyboard leaves above the category bar.
struct EmojiPanel: View {
    let actions: KeyboardActions
    let close: () -> Void
    @State private var recents = EmojiRecents.load()

    private var categories: [EmojiData.Category] {
        let recent = EmojiData.Category(id: "recents", title: "Frequently Used", symbol: "clock", emoji: recents)
        return (recents.isEmpty ? [] : [recent]) + EmojiData.categories
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: DS.Keyboard.emojiBarSpacing) {
                GeometryReader { geometry in
                    // Rows fill the height the keyboard actually leaves, so none spills past
                    // the top edge.
                    let cell = geometry.size.height / CGFloat(DS.Keyboard.emojiRows)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(
                            rows: Array(repeating: GridItem(.fixed(cell), spacing: 0), count: DS.Keyboard.emojiRows),
                            spacing: 0
                        ) {
                            ForEach(categories) { category in
                                ForEach(Array(category.emoji.enumerated()), id: \.offset) { index, emoji in
                                    Button {
                                        UIDevice.current.playInputClick()
                                        actions.insert(emoji)
                                        EmojiRecents.record(emoji)
                                    } label: {
                                        Text(emoji)
                                            .font(.system(size: cell * DS.Keyboard.emojiScale))
                                            .frame(width: cell, height: cell)
                                    }
                                    .buttonStyle(.plain)
                                    .id("\(category.id)-\(index)")
                                }
                            }
                        }
                    }
                    .scrollEdgeEffectHidden(true, for: .all)
                }
                HStack(spacing: 0) {
                    Button("ABC") {
                        recents = EmojiRecents.load()
                        close()
                    }
                    .font(DS.Keyboard.barFont)
                    .frame(width: DS.Keyboard.functionKeyWidth)
                    ForEach(categories) { category in
                        Button {
                            proxy.scrollTo("\(category.id)-0", anchor: .leading)
                        } label: {
                            Image(systemName: category.symbol)
                                .font(DS.Keyboard.barIconFont)
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityLabel(category.title)
                    }
                    DeleteKey(height: DS.Keyboard.emojiBarHeight, action: actions.delete)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(height: DS.Keyboard.emojiBarHeight)
            }
        }
    }
}
