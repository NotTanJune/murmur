import MurmurDesign
import SwiftUI
import UIKit

/// What the emoji and history panels and the strip need from the host. The key plane has its
/// own path (`TypingController`); these are the few things SwiftUI asks for.
struct KeyboardActions {
    /// Types text as the emoji and history panels do, through the typing controller so the
    /// shift key and the suggestions follow it.
    let insert: (String) -> Void
    let delete: () -> Void
    let openMurmur: () -> Void
}

/// The keyboard: the suggestion strip above the key plane, or the emoji or history panel in the
/// same height. The strip holds the history button, the suggestions and the m, Murmur's
/// dictation button (`SuggestionStrip`); the plane is UIKit (`KeyPlaneView`).
struct KeyboardView: View {
    let dictation: KeyboardDictation
    let typing: TypingController
    let actions: KeyboardActions

    private enum Panel { case keys, emoji, history }

    @State private var panel: Panel = .keys

    var body: some View {
        Group {
            switch panel {
            case .keys:
                keys
            case .emoji:
                EmojiPanel(actions: actions, close: {
                    // The stock emoji keyboard's ABC returns to letters, whatever page it left.
                    typing.showLetters()
                    show(.keys)
                })
                .padding(DS.Keyboard.padding)
            case .history:
                HistoryPanel(actions: actions, close: { show(.keys) })
                    .padding(DS.Keyboard.padding)
            }
        }
        // The height the keyboard actually has, never one asked for: the panels fit what
        // arrives (`EmojiPanel` drops rows to make room). They are exactly as tall as the key
        // page, because iOS ignores a keyboard that grows after it first appears.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { typing.onShowEmoji = { show(.emoji) } }
    }

    private func show(_ next: Panel) {
        panel = next
    }

    /// The strip over the plane. The plane draws its own side inset, so there is no padding
    /// here: the 6 pt padding belongs to the emoji and history panels only.
    private var keys: some View {
        VStack(spacing: 0) {
            SuggestionStrip(
                dictation: dictation, typing: typing, actions: actions,
                showHistory: { show(.history) })
            KeyPlane(typing: typing)
        }
        // The key plane's rows are placed from the keyboard's top in `KeyboardMetrics`, and a
        // touch outside a view's bounds never reaches it, so no inset may shorten the plane.
        .ignoresSafeArea()
    }
}

/// The key plane in SwiftUI. It is made again when the emoji or history panel gives way to the
/// keys, so it hands itself to the controller, which gives it the current state.
private struct KeyPlane: UIViewRepresentable {
    let typing: TypingController

    func makeUIView(context: Context) -> KeyPlaneView {
        let plane = KeyPlaneView()
        typing.attach(plane)
        return plane
    }

    func updateUIView(_ plane: KeyPlaneView, context: Context) {}

    static func dismantleUIView(_ plane: KeyPlaneView, coordinator: ()) {
        plane.cancelAllTouches()
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
    let action: () -> Void
    @State private var repeater: Task<Void, Never>?
    /// Resets itself when the gesture is cancelled, which `onEnded` does not report; the change
    /// below then stops the repeater, so a cancelled touch cannot keep deleting.
    @GestureState private var touching = false

    var body: some View {
        KeyFace(fill: DS.Keyboard.key) {
            Image(systemName: repeater == nil ? "delete.left" : "delete.left.fill").font(DS.Keyboard.iconFont)
        }
        .frame(width: DS.Keyboard.functionKeyWidth, height: height)
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
