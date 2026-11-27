import MurmurDesign
import SwiftUI
import UIKit

/// What the emoji and history panels and the strip need from the host. The key plane has its
/// own path (`TypingController`, outside SwiftUI); these are the few things SwiftUI asks for.
struct KeyboardActions {
    /// Types text as the emoji and history panels do, through the typing controller so the
    /// shift key and the suggestions follow it.
    let insert: (String) -> Void
    let delete: () -> Void
    let openMurmur: () -> Void
}

/// The keyboard's SwiftUI layer: the suggestion strip, or the emoji or history panel in the
/// full height. The strip holds the history button, the suggestions and the m, Murmur's
/// dictation button (`SuggestionStrip`). The key plane is not here: `KeyPlaneView` is a UIKit
/// subview of the keyboard's root view that the view controller places over the clear space
/// under the strip, so SwiftUI's gesture handling never sits between a finger and a key.
struct KeyboardView: View {
    let dictation: KeyboardDictation
    let typing: TypingController
    let actions: KeyboardActions

    private enum Panel { case keys, emoji, search, history }

    @State private var panel: Panel = .keys
    /// The query and results of emoji search; the panel is `.search` while it is open.
    @State private var search = EmojiSearchModel()

    var body: some View {
        Group {
            switch panel {
            case .keys:
                keys
            case .emoji:
                EmojiPanel(
                    actions: actions,
                    close: {
                        // The stock emoji keyboard's ABC returns to letters, whatever page it left.
                        typing.showLetters()
                        show(.keys)
                    },
                    openSearch: { show(.search) }
                )
                // The picker sets its own top and bottom insets (`emojiPanelTopInset`).
                .padding(.horizontal, DS.Keyboard.padding)
            case .search:
                searching
            case .history:
                HistoryPanel(actions: actions, close: { show(.keys) })
                    .padding(DS.Keyboard.padding)
            }
        }
        // The height the keyboard actually has, never one asked for: the panels fit what
        // arrives (`EmojiPanel` drops rows to make room). The key page and history are as tall as
        // the key page; the emoji grid (portrait) and search ask for more
        // (`TypingController.setEmojiPanelShown`, `beginSearch`), and a taller keyboard after it
        // first appeared was observed to apply (2026-11-26). Both lay out in whatever arrives.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            typing.onShowEmoji = { show(.emoji) }
            // Return in the search, or the keyboard going away mid-search, goes back to the grid.
            search.onSubmit = { show(.emoji) }
            typing.onSearchAbandoned = { show(.emoji) }
        }
    }

    /// The plane is shown for the keys and for search (which types on it) and hidden under the
    /// other panels, so it takes no touches there. Opening search routes the keys into the query
    /// and makes the keyboard taller; leaving it undoes both.
    private func show(_ next: Panel) {
        if panel == .search, next != .search {
            typing.endSearch()
        }
        if next == .search, panel != .search {
            search.open()
            typing.beginSearch { search.handle($0) }
        }
        panel = next
        typing.setPlaneVisible(next == .keys || next == .search)
        typing.setEmojiPanelShown(next == .emoji)
    }

    /// Search mode: the field and one row of results fill what the keyboard has above the plane
    /// (the strip's place, and the extra height search asks for), over clear space exactly as
    /// tall as the plane, as `keys` does.
    private var searching: some View {
        VStack(spacing: 0) {
            EmojiSearchPanel(model: search, actions: actions, close: { show(.emoji) })
            Color.clear.frame(height: typing.planeSpace)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
    }

    /// The strip directly above clear space exactly as tall as the plane, which the view
    /// controller lays the plane over. Both are placed from the keyboard's bottom edge, as the
    /// plane is, so the strip always sits against the keys: whatever height iOS gives the
    /// keyboard (it can lag behind a change, or round it), a difference shows only as space above
    /// the strip and never as a gap or an overlap between the strip and the first row. The plane
    /// draws its own side inset, so there is no padding here: the 6 pt padding belongs to the
    /// emoji and history panels only.
    private var keys: some View {
        VStack(spacing: 0) {
            SuggestionStrip(
                dictation: dictation, typing: typing, actions: actions,
                showHistory: { show(.history) })
            Color.clear.frame(height: typing.planeSpace)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
    }
}

// MARK: Keys

struct KeyFace<Content: View>: View {
    let fill: Color
    @ViewBuilder let content: Content

    var body: some View {
        // Flat, with no drop shadow, as the iOS 26 keyboard draws its keys.
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: DS.Keyboard.keyRadius, style: .continuous).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: DS.Keyboard.keyRadius, style: .continuous))
    }
}

/// Deletes once on touch, then repeats while held.
struct DeleteKey: View {
    let height: CGFloat
    /// The emoji bar's form: the glyph alone, with no keycap, near the trailing edge of the space
    /// it is given, as Apple's picker draws it.
    var bare = false
    let action: () -> Void
    @State private var repeater: Task<Void, Never>?
    /// Resets itself when the gesture is cancelled, which `onEnded` does not report; the change
    /// below then stops the repeater, so a cancelled touch cannot keep deleting.
    @GestureState private var touching = false

    var body: some View {
        KeyFace(fill: bare ? Color.clear : DS.Keyboard.key) {
            if bare {
                Image(systemName: repeater == nil ? "delete.left" : "delete.left.fill")
                    .font(DS.Keyboard.emojiBarDeleteFont)
                    .opacity(DS.Keyboard.emojiBarDeleteOpacity)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, DS.Keyboard.emojiBarDeleteInset)
            } else {
                Image(systemName: repeater == nil ? "delete.left" : "delete.left.fill").font(DS.Keyboard.iconFont)
            }
        }
        .frame(width: bare ? DS.Keyboard.emojiBarSideWidth : DS.Keyboard.functionKeyWidth, height: height)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { _ in
                    guard repeater == nil else { return }
                    KeyFeedback.press()
                    action()
                    repeater = Task { @MainActor in
                        try? await Task.sleep(for: DS.Keyboard.deleteRepeatDelay)
                        while !Task.isCancelled {
                            // Each repeated deletion clicks and taps, as the stock keyboard's does.
                            KeyFeedback.press()
                            action()
                            try? await Task.sleep(for: DS.Keyboard.deleteRepeatInterval)
                        }
                    }
                }
                .onEnded { _ in stopRepeating() }
        )
        .onChange(of: touching) { _, down in
            if !down { stopRepeating() }
        }
        .onDisappear { stopRepeating() }
        .accessibilityLabel("Delete")
        .accessibilityAddTraits(.isButton)
    }

    private func stopRepeating() {
        repeater?.cancel()
        repeater = nil
    }
}

/// A key's press: dimmed while held, with the click and the haptic tap (`KeyFeedback`) at
/// touch-down, as the stock keyboard gives them, not when the action fires on release.
struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .opacity(configuration.isPressed ? DS.Keyboard.pressedOpacity : 1)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { KeyFeedback.press() }
            }
    }
}

/// `KeyPressStyle` without its colour, for labels that set their own (the emoji category bar).
struct PlainKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? DS.Keyboard.pressedOpacity : 1)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { KeyFeedback.press() }
            }
    }
}
