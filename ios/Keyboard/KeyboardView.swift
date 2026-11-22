import MurmurDesign
import SwiftUI
import UIKit

/// What the keyboard's keys do to the host field. The controller supplies these, because only
/// it holds `textDocumentProxy` and the globe key's event handling.
struct KeyboardActions {
    let insert: (String) -> Void
    let delete: () -> Void
    let newline: () -> Void
    let dismiss: () -> Void
    /// Resizes the keyboard; the emoji panel is taller than the key page.
    let setHeight: (CGFloat) -> Void
    let globe: (UIView, UIEvent) -> Void
    let openMurmur: () -> Void
    let showsGlobe: () -> Bool
    let returnTitle: () -> String
    let returnIsProminent: () -> Bool
}

/// The keyboard: Murmur's talk key with history, a row of punctuation, digits or symbols, then
/// emoji, hide, space and return, after Granola's voice-only keyboard.
struct KeyboardView: View {
    let dictation: KeyboardDictation
    let actions: KeyboardActions

    private enum Panel { case keys, emoji, history }
    private enum Page {
        case punctuation, digits, symbols

        var keys: [String] {
            switch self {
            case .punctuation: ["@", ".", ",", "?", "!", "'"]
            case .digits: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
            case .symbols: ["-", "/", ":", ";", "(", ")", "$", "&", "\"", "#"]
            }
        }

        /// The mode key names the page it leads to.
        var nextTitle: String {
            switch self {
            case .punctuation: "123"
            case .digits: "#+="
            case .symbols: "ABC"
            }
        }

        var next: Page {
            switch self {
            case .punctuation: .digits
            case .digits: .symbols
            case .symbols: .punctuation
            }
        }
    }

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var panel: Panel = .keys
    @State private var page: Page = .punctuation

    var body: some View {
        Group {
            switch panel {
            case .keys: keys
            case .emoji: EmojiPanel(actions: actions, close: { show(.keys) })
            case .history: HistoryPanel(actions: actions, close: { show(.keys) })
            }
        }
        .padding(DS.Keyboard.padding)
        // The height the keyboard actually has, never the one asked for: a taller fixed frame in
        // a shorter keyboard is centred and clipped at both ends, which on 2026-11-22 cut the
        // emoji panel's title and half a row off the top and its category bar off the bottom.
        // The panel fits what arrives (`EmojiPanel` drops rows to make room).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Landscape can change the size class while the emoji panel is up.
        .onChange(of: verticalSizeClass) { actions.setHeight(panelHeight) }
    }

    private func height(for panel: Panel) -> CGFloat {
        // History gets the emoji panel's height too: a list of dictations needs the room more
        // than the key page's 168 pt, which fitted only two and a half rows.
        guard panel == .emoji || panel == .history else { return DS.Keyboard.height }
        return verticalSizeClass == .compact ? DS.Keyboard.emojiPanelHeightCompact : DS.Keyboard.emojiPanelHeight
    }

    private var panelHeight: CGFloat { height(for: panel) }

    /// The keyboard's height is asked for first, then the panel changes. The content always
    /// fills the height the keyboard has at that moment, so neither order can clip it.
    private func show(_ next: Panel) {
        actions.setHeight(height(for: next))
        panel = next
    }

    private var keys: some View {
        VStack(spacing: DS.Keyboard.rowSpacing) {
            HStack(spacing: DS.Keyboard.keySpacing) {
                IconKey(symbol: "clock.arrow.circlepath", fill: .clear, width: DS.Keyboard.historyWidth, label: "Recent dictations") {
                    show(.history)
                }
                TalkKey(dictation: dictation, actions: actions)
            }
            HStack(spacing: DS.Keyboard.keySpacing) {
                if page == .punctuation {
                    IconKey(symbol: dictation.shiftNext ? "shift.fill" : "shift", fill: DS.Keyboard.functionKey, label: "Shift", isSelected: dictation.shiftNext) {
                        dictation.shiftNext.toggle()
                    }
                }
                ForEach(page.keys, id: \.self) { character in
                    CharacterKey(title: character) { actions.insert(character) }
                }
                DeleteKey(action: actions.delete)
            }
            HStack(spacing: DS.Keyboard.keySpacing) {
                if actions.showsGlobe() {
                    GlobeKey(action: actions.globe)
                        .frame(width: DS.Keyboard.functionKeyWidth, height: DS.Keyboard.keyHeight)
                }
                TextKey(title: page.nextTitle, fill: DS.Keyboard.functionKey, width: DS.Keyboard.functionKeyWidth) {
                    page = page.next
                }
                IconKey(symbol: "face.smiling", fill: DS.Keyboard.functionKey, label: "Emoji") { show(.emoji) }
                IconKey(symbol: "keyboard.chevron.compact.down", fill: DS.Keyboard.functionKey, label: "Hide keyboard", action: actions.dismiss)
                TextKey(title: "", fill: DS.Keyboard.letterKey, width: nil, label: "Space") { actions.insert(" ") }
                ReturnKey(actions: actions)
            }
        }
    }
}

// MARK: Talk key

/// Murmur's key. Touch down starts recording; a quick tap locks it on and a second tap ends
/// it; a hold ends on release. The capsule is Liquid Glass tinted brown (`talkGlassTint`). While
/// recording it becomes the Mac's HUD: bars that follow the input level, and no text; the bars
/// are flat and grey until the hold has heard audio, then red. Otherwise it reads "Murmur" in the
/// app icon's italic and a soft orange (`DS.Keyboard.wordmark`), with a caption under it while the
/// microphone or Bark is not ready, dimmed while the last hold is still finishing, because a
/// press then is ignored.
private struct TalkKey: View {
    let dictation: KeyboardDictation
    let actions: KeyboardActions
    /// The finger is on the key. A `GestureState` resets itself when the gesture is cancelled
    /// (the keyboard went away mid-touch), so the change below always sees the touch end, and
    /// the dictation never keeps a press that nothing will release.
    @GestureState private var touching = false
    /// A press that has started and not yet ended, so the down and the up each reach the
    /// dictation once, whether the gesture ends or is cancelled.
    @State private var isDown = false

    var body: some View {
        ZStack {
            // Liquid Glass tinted toward the HUD's brown, so the key lifts off the keyboard's
            // backdrop in both appearances while the wordmark and the red bars keep their
            // contrast. Not `.interactive()`: it would add its own touch tracking beside the
            // DragGesture below, and the key already answers touch-down at once by changing state.
            keyLabel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glassEffect(.regular.tint(DS.Keyboard.talkGlassTint), in: .capsule)
            // The key itself is one button. The failure state's own button stays reachable.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isRecording ? "Stop dictation" : "Dictate")
            .accessibilityValue(isRecording ? (dictation.heardAudio ? "Listening" : "Starting") : (dictation.readinessCaption ?? ""))
            .accessibilityAddTraits(.isButton)
            // VoiceOver's double-tap is not a touch on the key, so it gets the tap-to-lock
            // meaning directly: the first one starts dictation and locks it, the next one ends it.
            .accessibilityAction { dictation.toggleDictation() }
            .accessibilityHidden(isFailed)
            if isFailed { failure }
        }
        .frame(height: DS.Keyboard.talkHeight)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { _ in
                    guard !isDown else { return }
                    isDown = true
                    UIDevice.current.playInputClick()
                    dictation.touchDown()
                }
                .onEnded { _ in
                    guard isDown else { return }
                    isDown = false
                    dictation.touchUp()
                },
            isEnabled: !dictation.isBusy
        )
        // A cancelled gesture (the keyboard went away mid-touch, or the key was disabled) resets
        // `touching` without `onEnded`; release the press then.
        .onChange(of: touching) { _, down in
            guard !down, isDown else { return }
            isDown = false
            dictation.touchUp()
        }
    }

    private var isFailed: Bool {
        if case .failed = dictation.state { return true }
        return false
    }

    private var isRecording: Bool {
        if case .recording = dictation.state { return true }
        return false
    }

    @ViewBuilder private var keyLabel: some View {
        switch dictation.state {
        case .recording(let level):
            // Flat and neutral until the hold has audio, then red and following the level, so
            // the bars never claim a microphone that is not yet hearing.
            if dictation.heardAudio {
                Waveform(level: level * DS.Keyboard.levelGain, isActive: true)
            } else {
                Waveform(level: 0, isActive: false, tint: DS.Keyboard.waveformFlat)
            }
        case .failed:
            // A real view, not `EmptyView`: modifiers on an empty view render nothing, and the
            // glass behind the failure message would vanish with them.
            Color.clear
        case .idle, .finishing:
            VStack(spacing: DS.Keyboard.captionGap) {
                Text("Murmur")
                    .font(DS.Keyboard.wordmarkFont)
                    .foregroundStyle(DS.Keyboard.wordmark)
                if let caption = dictation.readinessCaption {
                    Text(caption)
                        .font(DS.Keyboard.captionFont)
                        .foregroundStyle(DS.Keyboard.wordmarkCaption)
                        .lineLimit(1)
                }
            }
            .opacity(dictation.isBusy ? DS.Motion.disabledOpacity : 1)
        }
    }

    /// The microphone message keeps its permissions hint; any other failure says only that
    /// dictation failed. The cause is in the log, never on the key.
    private var failureMessage: String {
        if case .failed(.dictation) = dictation.state { return "Dictation failed. Try again." }
        return "Microphone unavailable. Open Murmur to check permissions."
    }

    private var failure: some View {
        HStack(spacing: DS.Keyboard.messageGap) {
            Text(failureMessage)
                .font(DS.Keyboard.messageFont)
                .foregroundStyle(DS.Keyboard.onTalkKey)
                .lineLimit(DS.Keyboard.messageLines)
                .multilineTextAlignment(.leading)
            Button(action: actions.openMurmur) {
                Text("Open Murmur")
                    .font(DS.Keyboard.messageActionFont)
                    .foregroundStyle(DS.Keyboard.onTalkAction)
                    .fixedSize()
                    .padding(.horizontal, DS.Keyboard.messageActionInsetX)
                    .padding(.vertical, DS.Keyboard.messageActionInsetY)
                    .background(Capsule().fill(DS.Keyboard.talkAction))
            }
            .buttonStyle(KeyPressStyle())
        }
        .padding(.horizontal, DS.Keyboard.labelInset)
    }
}

// MARK: Keys

struct KeyFace<Content: View>: View {
    let fill: Color
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.Keyboard.keyRadius)
                    .fill(fill)
                    .shadow(
                        color: fill == .clear ? .clear : DS.Keyboard.keyShadow,
                        radius: 0, x: 0, y: DS.Keyboard.keyShadowOffset)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Keyboard.keyRadius))
    }
}

private struct CharacterKey: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button {
            UIDevice.current.playInputClick()
            action()
        } label: {
            KeyFace(fill: DS.Keyboard.letterKey) {
                Text(title).font(DS.Keyboard.characterFont)
            }
        }
        .buttonStyle(KeyPressStyle())
        .frame(height: DS.Keyboard.keyHeight)
    }
}

private struct TextKey: View {
    let title: String
    let fill: Color
    let width: CGFloat?
    /// What VoiceOver says; the visible title is empty on the space bar.
    var label: String?
    let action: () -> Void

    var body: some View {
        Button {
            UIDevice.current.playInputClick()
            action()
        } label: {
            KeyFace(fill: fill) {
                Text(title).font(DS.Keyboard.labelFont)
            }
        }
        .buttonStyle(KeyPressStyle())
        .accessibilityLabel(label ?? title)
        .frame(width: width, height: DS.Keyboard.keyHeight)
        .frame(maxWidth: width == nil ? .infinity : nil)
    }
}

private struct IconKey: View {
    let symbol: String
    let fill: Color
    var width: CGFloat? = nil
    let label: String
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button {
            UIDevice.current.playInputClick()
            action()
        } label: {
            KeyFace(fill: fill) {
                Image(systemName: symbol).font(DS.Keyboard.iconFont)
            }
        }
        .buttonStyle(KeyPressStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .frame(width: width ?? DS.Keyboard.functionKeyWidth, height: DS.Keyboard.keyHeight)
    }
}

private struct ReturnKey: View {
    let actions: KeyboardActions

    var body: some View {
        let prominent = actions.returnIsProminent()
        Button {
            UIDevice.current.playInputClick()
            actions.newline()
        } label: {
            KeyFace(fill: prominent ? DS.Keyboard.prominentKey : DS.Keyboard.functionKey) {
                Text(actions.returnTitle())
                    .font(DS.Keyboard.labelFont)
                    .foregroundStyle(prominent ? DS.Keyboard.onProminentKey : .primary)
            }
        }
        .buttonStyle(KeyPressStyle())
        .frame(width: DS.Keyboard.returnWidth, height: DS.Keyboard.keyHeight)
    }
}

/// Deletes once on touch, then repeats while held.
struct DeleteKey: View {
    var height: CGFloat = DS.Keyboard.keyHeight
    let action: () -> Void
    @State private var repeater: Task<Void, Never>?
    /// Resets itself when the gesture is cancelled, which `onEnded` does not report; the change
    /// below then stops the repeater, so a cancelled touch cannot keep deleting.
    @GestureState private var touching = false

    var body: some View {
        KeyFace(fill: DS.Keyboard.functionKey) {
            Image(systemName: repeater == nil ? "delete.left" : "delete.left.fill").font(DS.Keyboard.iconFont)
        }
        .frame(width: DS.Keyboard.functionKeyWidth, height: height)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { _ in
                    guard repeater == nil else { return }
                    UIDevice.current.playInputClick()
                    action()
                    repeater = Task { @MainActor in
                        try? await Task.sleep(for: DS.Keyboard.deleteRepeatDelay)
                        while !Task.isCancelled {
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

struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .opacity(configuration.isPressed ? DS.Keyboard.pressedOpacity : 1)
    }
}

// MARK: Globe

/// The globe key needs the real `UIEvent` so a long press shows the keyboard list, which a
/// SwiftUI button does not provide. The fill is the SwiftUI face behind it.
private struct GlobeKey: View {
    let action: (UIView, UIEvent) -> Void

    var body: some View {
        KeyFace(fill: DS.Keyboard.functionKey) {
            GlobeButton(action: action)
        }
    }

    private struct GlobeButton: UIViewRepresentable {
        let action: (UIView, UIEvent) -> Void

        func makeUIView(context: Context) -> UIButton {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: "globe"), for: .normal)
            button.tintColor = .label
            button.accessibilityLabel = "Next keyboard"
            button.addTarget(context.coordinator, action: #selector(Coordinator.tapped(_:event:)), for: .allTouchEvents)
            return button
        }

        func updateUIView(_ button: UIButton, context: Context) {
            context.coordinator.action = action
        }

        func makeCoordinator() -> Coordinator { Coordinator(action: action) }

        @MainActor
        final class Coordinator: NSObject {
            var action: (UIView, UIEvent) -> Void
            init(action: @escaping (UIView, UIEvent) -> Void) { self.action = action }
            @objc func tapped(_ sender: UIButton, event: UIEvent) { action(sender, event) }
        }
    }
}
