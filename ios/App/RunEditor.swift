import MurmurDesign
import MurmurKit
import SwiftUI

/// The correction editor for one history run: what was said, fixed by hand, which becomes the
/// training label (`TrainingLabel`). A model-cleaned run is corrected against what Bark
/// heard, not against the text it typed, so the "Heard" eyebrow says which one this is.
struct RunEditor: View {
    let run: DictationRun

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(run: DictationRun) {
        self.run = run
        _draft = State(initialValue: run.label ?? TrainingLabel.editBase(run))
    }

    private var base: String { TrainingLabel.editBase(run) }

    var body: some View {
        NavigationStack {
            PhonePage(title: "Correct") {
                VStack(alignment: .leading, spacing: DS.Space.snug) {
                    if run.cleanup != nil { Eyebrow(text: "Heard") }
                    TextEditor(text: $draft)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                        .scrollContentBackground(.hidden)
                        .focused($isFocused)
                        .padding(DS.Space.snug)
                        .frame(minHeight: DS.Phone.editorMinHeight)
                        .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .strokeBorder(DS.Color.hairline, lineWidth: DS.Stroke.hairline)
                        )
                    Note(text: "Write what you said. Corrections train the model on the next export.")
                }
                if draft != base {
                    Button("Reset to what was heard") { draft = base }
                        .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) { bar }
        }
        .onAppear { isFocused = true }
    }

    private var bar: some View {
        HStack(spacing: DS.Space.snug) {
            Spacer()
            Button("Cancel") { dismiss() }
                .buttonStyle(KeyButtonStyle(kind: .secondary))
            Button("Save") {
                commit()
                dismiss()
            }
            .buttonStyle(KeyButtonStyle(kind: .primary))
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.base)
        .background(DS.Color.pane)
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unchanged or emptied text is not a correction; it clears any earlier label.
        RunLog.setLabel(trimmed.isEmpty || trimmed == base ? nil : trimmed, for: run)
    }
}
