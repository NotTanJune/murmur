import MurmurDesign
import MurmurDictionary
import MurmurKit
import SwiftUI

/// The third tab: terms to favour and corrections to apply, the same list and corrector the
/// Mac uses. One list, with a tag for the kind; tapping a row edits it.
struct DictionaryView: View {
    @State private var store = DictionaryStore.shared
    @State private var query = ""
    @State private var editing: DictionaryEntry?
    @State private var isAdding = false

    private var entries: [DictionaryEntry] { store.filtered(by: query) }

    var body: some View {
        PhonePage(title: "Dictionary") {
            HStack(spacing: DS.Space.base) {
                Eyebrow(text: "\(store.entries.count) entries")
                Spacer()
                Button { isAdding = true } label: {
                    Label("Add", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(KeyButtonStyle(kind: .primary, compact: true))
            }
            if !store.entries.isEmpty {
                SearchField(text: $query, placeholder: "Search dictionary")
            }

            if entries.isEmpty {
                EmptyPanel(
                    label: store.entries.isEmpty ? "Teach it your words." : "No matches",
                    highlight: store.entries.isEmpty ? "words" : nil,
                    detail: store.entries.isEmpty
                        ? "Add the words the recognizer keeps getting wrong."
                        : "Try a different search."
                )
            } else {
                VStack(alignment: .leading, spacing: DS.Space.snug) {
                    ForEach(entries) { entry in
                        DictionaryRow(
                            entry: entry,
                            onEdit: { editing = entry },
                            onToggle: {
                                var flipped = entry
                                flipped.isEnabled.toggle()
                                store.update(flipped)
                            }
                        )
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isAdding) {
            DictionaryEditor(entry: nil, onSave: { store.add($0) }, onDelete: nil)
        }
        .sheet(item: $editing) { entry in
            DictionaryEditor(entry: entry, onSave: { store.update($0) }, onDelete: { store.delete(entry) })
        }
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onEdit: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.base) {
            Button(action: onEdit) {
                HStack(spacing: DS.Space.base) {
                    Tag(text: entry.kind == .correction ? "Fix" : "Term")
                    // An off entry is dimmed through its colours, not a row-wide opacity.
                    if entry.kind == .correction {
                        Text(entry.hear)
                            .font(DS.Font.body)
                            .foregroundStyle(entry.isEnabled ? DS.Color.inkSecondary : DS.Color.inkTertiary)
                            .strikethrough(true, color: DS.Color.inkTertiary)
                        Image(systemName: "arrow.right")
                            .font(.system(size: DS.Icon.small, weight: .semibold))
                            .foregroundStyle(entry.isEnabled ? DS.Color.inkSecondary : DS.Color.inkTertiary)
                    }
                    Text(entry.write)
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(entry.isEnabled ? DS.Color.ink : DS.Color.inkSecondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit this entry")

            // On is cream, ink-stroked and checked, like every other "on" state.
            Button(entry.isEnabled ? "On" : "Off", action: onToggle)
                .buttonStyle(KeyButtonStyle(kind: .secondary, isSelected: entry.isEnabled, compact: true))
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// Adds or edits one entry. Warnings are hints only and never block saving. Deleting asks first.
private struct DictionaryEditor: View {
    let entry: DictionaryEntry?
    let onSave: (DictionaryEntry) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var kind: DictionaryEntry.Kind
    @State private var hear: String
    @State private var write: String
    @State private var isConfirmingDelete = false

    init(entry: DictionaryEntry?, onSave: @escaping (DictionaryEntry) -> Void, onDelete: (() -> Void)?) {
        self.entry = entry
        self.onSave = onSave
        self.onDelete = onDelete
        _kind = State(initialValue: entry?.kind ?? .term)
        _hear = State(initialValue: entry?.hear ?? "")
        _write = State(initialValue: entry?.write ?? "")
    }

    /// The hear field keeps its text while the kind is Term, so switching back loses nothing;
    /// only the saved entry ignores it.
    private var draft: DictionaryEntry {
        DictionaryEntry(
            id: entry?.id ?? UUID(),
            kind: kind,
            write: write.trimmingCharacters(in: .whitespacesAndNewlines),
            hear: kind == .correction ? hear.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            isEnabled: entry?.isEnabled ?? true
        )
    }

    private var isValid: Bool {
        let hasWrite = !write.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasHear = !hear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasWrite && (kind == .term || hasHear)
    }

    var body: some View {
        PhonePage(title: entry == nil ? "New entry" : "Edit entry") {
            ChoiceKeys(
                options: [DictionaryEntry.Kind.term, .correction],
                selection: Binding(
                    get: { kind },
                    set: { candidate in withAnimation(DS.Motion.panel) { kind = candidate } }
                ),
                title: { $0 == .term ? "Term" : "Correction" }
            )

            VStack(alignment: .leading, spacing: DS.Space.base) {
                if kind == .correction {
                    PaperTextField(label: "What it hears", text: $hear, prompt: "tail wind")
                    PaperTextField(label: "Write", text: $write, prompt: "Tailwind")
                } else {
                    PaperTextField(label: "Word or phrase", text: $write, prompt: "Tailwind")
                }
            }

            ForEach(DictionaryWarning.check(draft)) { warning in
                HStack(alignment: .top, spacing: DS.Space.snug) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: DS.Icon.regular, weight: .semibold))
                        .foregroundStyle(DS.Color.onSelected)
                    Text(warning.message)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.onSelected)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(DS.Color.selected, radius: DS.Radius.control)
            }

            HStack(spacing: DS.Space.snug) {
                if onDelete != nil {
                    Button("Delete") { isConfirmingDelete = true }
                        .buttonStyle(KeyButtonStyle(kind: .secondary))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(KeyButtonStyle(kind: .secondary))
                Button("Save") {
                    guard isValid else { return }
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(KeyButtonStyle(kind: .primary))
                .disabled(!isValid)
            }
        }
        .confirmationDialog("Delete this entry?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete entry", role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
