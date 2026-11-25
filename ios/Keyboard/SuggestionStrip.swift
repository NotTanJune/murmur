import MurmurDesign
import MurmurTyping
import SwiftUI
import UIKit

/// The strip above the keys, 30 pt tall upright (`TypingController.stripHeight`). From the
/// leading end: the history button (shown while no
/// word is being typed), three suggestion cells, and the **m**, which is Murmur's dictation
/// button and grows into the recording capsule over the strip's trailing end.
///
/// Taps here are infrequent next to the keys, so the strip is SwiftUI.
struct SuggestionStrip: View {
    let dictation: KeyboardDictation
    let typing: TypingController
    let actions: KeyboardActions
    /// Opens the history panel.
    let showHistory: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    if isFailed {
                        // The message takes the strip up to the m; the m stays, and pressing it
                        // tries again.
                        failure
                            .padding(.leading, DS.Keyboard.sideInset)
                    } else {
                        history
                        suggestionCells
                    }
                    // The m's own cell, so the cells above never run under it.
                    Color.clear.frame(width: DS.Keyboard.mButtonCellWidth)
                }
                RecordControl(dictation: dictation, stripWidth: geometry.size.width)
            }
        }
        .frame(height: typing.stripHeight)
    }

    private var isFailed: Bool {
        if case .failed = dictation.state { return true }
        return false
    }

    /// The capsule is over the cells: they hide while it records or finishes.
    private var capsuleShowing: Bool {
        switch dictation.state {
        case .recording, .finishing: true
        case .idle, .failed: false
        }
    }

    // MARK: History

    /// The history button, in the strip's leading cell at all times: while a word is typed, while
    /// the capsule records or finishes (the capsule ends just after this cell), and while an
    /// undo chip shows (that one lives in the left suggestion cell).
    @ViewBuilder private var history: some View {
        Button(action: showHistory) {
            Image(systemName: "clock.arrow.circlepath")
                .font(DS.Keyboard.iconFont)
                .frame(width: DS.Keyboard.functionKeyWidth)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyPressStyle())
        .accessibilityLabel("Recent dictations")
        .frame(width: DS.Keyboard.functionKeyWidth)
        .frame(maxHeight: .infinity)
    }

    // MARK: Suggestions

    @ViewBuilder private var suggestionCells: some View {
        if capsuleShowing {
            Color.clear.frame(maxWidth: .infinity)
        } else if !typing.suggestions.isEmpty || typing.undoChip != nil {
            HStack(spacing: 0) {
                ForEach(0..<Self.slotCount, id: \.self) { slot in
                    cell(at: slot)
                    if slot < Self.slotCount - 1 {
                        divider(after: slot)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        } else if let caption = dictation.readinessCaption {
            Text(caption)
                .font(DS.Keyboard.captionFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        } else {
            Color.clear.frame(maxWidth: .infinity)
        }
    }

    /// Always three cells, so the middle one stays in the middle with fewer suggestions.
    private static let slotCount = 3

    @ViewBuilder private func cell(at slot: Int) -> some View {
        if slot == 0, let original = typing.undoChip {
            undoChip(original)
        } else if slot < typing.suggestions.count {
            let suggestion = typing.suggestions[slot]
            Button { typing.choose(suggestion) } label: {
                Text(Self.title(for: suggestion))
                    .font(slot == 1 ? DS.Keyboard.suggestionEmphasisFont : DS.Keyboard.suggestionFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(DS.Keyboard.suggestionMinimumScale)
                    .padding(.horizontal, DS.Keyboard.suggestionInset)
                    .offset(y: DS.Keyboard.suggestionTextOffset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(maxWidth: .infinity)
        }
    }

    /// The word the keyboard just replaced, in the left cell as on the stock keyboard, with an
    /// arrow: tapping it puts the word back with no space. It takes the place of the typed word's
    /// own cell for as long as the offer lives.
    private func undoChip(_ original: String) -> some View {
        Button(action: typing.chooseUndo) {
            HStack(spacing: DS.Keyboard.undoChipSpacing) {
                Image(systemName: "arrow.uturn.backward")
                    .font(DS.Keyboard.undoChipIconFont)
                Text(original)
                    .font(DS.Keyboard.suggestionFont)
                    .lineLimit(1)
                    .minimumScaleFactor(DS.Keyboard.suggestionMinimumScale)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, DS.Keyboard.suggestionInset)
            .offset(y: DS.Keyboard.suggestionTextOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Undo autocorrect")
        .accessibilityValue(original)
    }

    /// The word you are typing is shown in quotes, as on the stock keyboard.
    private static func title(for suggestion: Suggestion) -> String {
        suggestion.kind == .typed ? "\u{201C}\(suggestion.text)\u{201D}" : suggestion.text
    }

    /// A hairline between two filled cells.
    @ViewBuilder private func divider(after slot: Int) -> some View {
        let filled = typing.suggestions.count > slot + 1
        Rectangle()
            .fill(filled ? DS.Keyboard.suggestionDivider : .clear)
            .frame(width: DS.Stroke.hairline, height: DS.Keyboard.suggestionDividerHeight)
    }

    // MARK: Failure

    /// The microphone message keeps its permissions hint; any other failure says only that
    /// dictation failed. The cause is in the log, never on the key.
    private var failureMessage: String {
        if case .failed(.dictation) = dictation.state { return "Dictation failed. Try again." }
        return "Microphone unavailable. Open Murmur to check permissions."
    }

    /// The capsule behind the message is the same glass as the m, so a failure reads as the
    /// m's own.
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
        .frame(maxWidth: .infinity)
        .frame(height: DS.Keyboard.recordingCapsuleHeight)
        .glassEffect(.regular.tint(DS.Keyboard.talkGlassTint), in: .capsule)
    }
}

// MARK: - Record control

/// The m, and the capsule it grows into. One view that stays in the hierarchy in every state
/// and only changes its width and content, so a held touch keeps tracking, and the second tap
/// of a locked recording lands on the same gesture that started it.
///
/// Touch down starts recording; a quick tap locks it on and a second tap ends it; a hold ends
/// on release. While recording it is Liquid Glass tinted toward the HUD's brown
/// (`talkGlassTint`), 30 pt tall, growing leftward from the m across the strip to one
/// `padding` past the history cell, with bars that follow the input level: flat and grey until
/// the hold has heard audio, then red. The m stays visible at its trailing end. While
/// finishing it shows a spinner.
///
/// The glass is not `.interactive()`: that would add its own touch tracking beside the
/// `DragGesture` below, which must keep reporting touch-down at once. Nothing wraps it in a
/// `compositingGroup`, which would flatten what the glass samples.
private struct RecordControl: View {
    let dictation: KeyboardDictation
    let stripWidth: CGFloat
    /// The finger is on the control. A `GestureState` resets itself when the gesture is
    /// cancelled (the keyboard went away mid-touch), so the change below always sees the touch
    /// end, and the dictation never keeps a press that nothing will release.
    @GestureState private var touching = false
    /// A press that has started and not yet ended, so the down and the up each reach the
    /// dictation once, whether the gesture ends or is cancelled.
    @State private var isDown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var height: CGFloat { DS.Keyboard.recordingCapsuleHeight }
    private var circle: CGFloat { DS.Keyboard.mCircleDiameter }
    /// The m's cell is wider than its circle; the circle sits in the middle of it.
    private var cellPadding: CGFloat { (DS.Keyboard.mButtonCellWidth - circle) / 2 }

    private var isRecording: Bool {
        if case .recording = dictation.state { return true }
        return false
    }

    private var isExpanded: Bool {
        switch dictation.state {
        case .recording, .finishing: true
        case .idle, .failed: false
        }
    }

    /// The circle, or while recording the capsule: its trailing end stays where the circle's is
    /// and its leading end reaches one `padding` past the history cell.
    private var capsuleWidth: CGFloat {
        guard isExpanded else { return circle }
        let leading = DS.Keyboard.functionKeyWidth + DS.Keyboard.padding
        return max(stripWidth - cellPadding - leading, circle)
    }

    var body: some View {
        HStack(spacing: 0) {
            if isExpanded {
                capsuleContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
            Text("m")
                .font(DS.Keyboard.mGlyphFont)
                .foregroundStyle(DS.Keyboard.wordmark)
                // The x-height, not the line box, is centred in the circle.
                .offset(y: -DS.Keyboard.mGlyphLift)
                .frame(width: circle, height: circle)
                .opacity(dictation.isBusy ? DS.Motion.disabledOpacity : 1)
        }
        .frame(width: capsuleWidth, height: height)
        .glassEffect(.regular.tint(DS.Keyboard.talkGlassTint), in: .capsule)
        .animation(reduceMotion ? nil : DS.Motion.panel, value: isExpanded)
        // The m's cell is wider than its circle, so a thumb that misses the circle still lands.
        // The capsule has no extra touch area on its leading side, which would lie over the
        // history cell: it ends where it is drawn.
        .padding(.leading, isExpanded ? 0 : cellPadding)
        .padding(.trailing, cellPadding)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isRecording ? "Stop dictation" : "Dictate")
        .accessibilityValue(isRecording ? (dictation.heardAudio ? "Listening" : "Starting") : "")
        .accessibilityAddTraits(.isButton)
        // VoiceOver's double-tap is not a touch on the control, so it gets the tap-to-lock
        // meaning directly: the first one starts dictation and locks it, the next one ends it.
        .accessibilityAction { dictation.toggleDictation() }
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { _ in
                    guard !isDown else { return }
                    isDown = true
                    // The click only: the start pattern (`KeyboardHaptics`) follows within
                    // moments, and a third tap would blur it.
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
        // A cancelled gesture (the keyboard went away mid-touch, or the control was disabled)
        // resets `touching` without `onEnded`; release the press then.
        .onChange(of: touching) { _, down in
            guard !down, isDown else { return }
            isDown = false
            dictation.touchUp()
        }
    }

    @ViewBuilder private var capsuleContent: some View {
        switch dictation.state {
        case .recording(let level):
            // Flat and neutral until the hold has audio, then red and following the level, so
            // the bars never claim a microphone that is not yet hearing.
            if dictation.heardAudio {
                Waveform(level: level * DS.Keyboard.levelGain, isActive: true)
            } else {
                Waveform(level: 0, isActive: false, tint: DS.Keyboard.waveformFlat)
            }
        case .finishing:
            ProgressView().tint(DS.Keyboard.wordmark)
        case .idle, .failed:
            EmptyView()
        }
    }
}
