import MurmurDictionary
import AppKit
import SwiftUI

/// The dictionary: add, edit, delete, search.
///
/// Both entry kinds live in one list rather than separate tabs — they're two shapes of the
/// same idea and you want to see everything you've taught it at once. The kind is carried by
/// a tag on each row.
struct DictionaryPanel: View {
    @State private var store = DictionaryStore.shared
    @State private var query = ""
    @State private var editing: DictionaryEntry?
    @State private var isAdding = false

    private var entries: [DictionaryEntry] { store.filtered(by: query) }

    var body: some View {
        PageScroll(title: "Dictionary") {
            header

            if entries.isEmpty {
                EmptyPanel(
                    label: store.entries.isEmpty ? "Teach it your words." : "No matches",
                    highlight: store.entries.isEmpty ? "words" : nil,
                    detail: store.entries.isEmpty
                        ? "Add words it keeps getting wrong."
                        : "Try a different search."
                )
                .padding(.top, DS.Space.wide)
            } else {
                // Lazy row by row; see `cardSegment`.
                let rows = entries
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { position, entry in
                        DictionaryRow(
                            entry: entry,
                            onEdit: { editing = entry },
                            onToggle: {
                                var updated = entry
                                updated.isEnabled.toggle()
                                store.update(updated)
                            },
                            onDelete: { store.delete(entry) }
                        )
                        .cardSegment(isFirst: position == 0, isLast: position == rows.count - 1)
                    }
                }
            }
        }
        .sheet(isPresented: $isAdding) {
            DictionaryEditor(entry: nil) { store.add($0) }
        }
        .sheet(item: $editing) { entry in
            DictionaryEditor(entry: entry) { store.update($0) }
        }
    }

    /// The file path is reachable because the spec asks for the dictionary to be editable
    /// outside the UI — which is only true if you can find it.
    private var header: some View {
        HStack(spacing: DS.Space.base) {
            Eyebrow(text: "\(store.entries.count) entries")
                .fixedSize()
            Spacer()
            SearchToggle(text: $query, placeholder: "Search dictionary")
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: DS.Icon.regular, weight: .semibold))
            }
            .buttonStyle(FlowButtonStyle(kind: .secondary, compact: true))
            .help("Reveal \(DictionaryStore.fileURL.path)")
            .accessibilityLabel("Reveal dictionary file")
            Button { isAdding = true } label: {
                Label("Add", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(FlowButtonStyle(kind: .primary, compact: true))
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}

// MARK: - Row

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.Space.base) {
            Tag(text: entry.kind == .correction ? "Fix" : "Term")

            if entry.kind == .correction {
                Text(entry.hear)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .strikethrough(true, color: DS.Color.inkTertiary)
                Image(systemName: "arrow.right")
                    .font(.system(size: DS.Icon.small, weight: .semibold))
                    .foregroundStyle(DS.Color.inkSecondary)
            }

            Text(entry.write)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)

            Spacer()

            if isHovering {
                Button("Edit", action: onEdit)
                    .buttonStyle(FlowButtonStyle(kind: .secondary, compact: true))
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: DS.Icon.regular, weight: .semibold))
                }
                .buttonStyle(FlowButtonStyle(kind: .secondary, compact: true))
                .accessibilityLabel("Delete")
            }
            // On is cream, ink-stroked and checked, like every other "on" state in the app.
            Button(entry.isEnabled ? "On" : "Off", action: onToggle)
                .buttonStyle(FlowButtonStyle(kind: .secondary, isSelected: entry.isEnabled, compact: true))
                .help(entry.isEnabled ? "Turn this entry off" : "Turn this entry on")
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.base)
        .background(isHovering ? DS.Color.cardHover : Color.clear)
        .opacity(entry.isEnabled ? 1 : 0.6)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Editor

/// Add or edit one entry, with the false-positive warning shown live as you type.
private struct DictionaryEditor: View {
    let entry: DictionaryEntry?
    let onSave: (DictionaryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: DictionaryEntry.Kind
    @State private var hear: String
    @State private var write: String

    init(entry: DictionaryEntry?, onSave: @escaping (DictionaryEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _kind = State(initialValue: entry?.kind ?? .term)
        _hear = State(initialValue: entry?.hear ?? "")
        _write = State(initialValue: entry?.write ?? "")
    }

    private var draft: DictionaryEntry {
        DictionaryEntry(
            id: entry?.id ?? UUID(),
            kind: kind,
            write: write.trimmingCharacters(in: .whitespacesAndNewlines),
            hear: kind == .correction ? hear.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            isEnabled: entry?.isEnabled ?? true
        )
    }

    private var warnings: [DictionaryWarning] { DictionaryWarning.check(draft) }

    private var isValid: Bool {
        !draft.write.isEmpty && (kind == .term || !draft.hear.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            Text(entry == nil ? "New entry" : "Edit entry")
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)

            kindPicker

            VStack(alignment: .leading, spacing: DS.Space.base) {
                if kind == .correction {
                    field("When you hear", text: $hear, prompt: "cloud code")
                }
                field(
                    kind == .correction ? "Write" : "Word or phrase",
                    text: $write,
                    prompt: kind == .correction ? "Claude Code" : "Anthropic"
                )
            }

            ForEach(warnings) { warning in
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
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(FlowButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard isValid else { return }
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(FlowButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(DS.Space.panel)
        .frame(width: DS.Window.editorWidth)
        .background(DS.Color.pane)
    }

    private var kindPicker: some View {
        ChoiceKeys(
            options: [DictionaryEntry.Kind.term, .correction],
            selection: Binding(
                get: { kind },
                set: { candidate in withAnimation(DS.Motion.panel) { kind = candidate } }
            ),
            title: { $0 == .term ? "Term" : "Correction" }
        )
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        FlowTextField(label: label, text: text, prompt: prompt)
    }
}
