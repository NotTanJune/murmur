import MurmurDictionary
import AppKit
import SwiftUI

/// Where entries are added, edited, deleted and searched.
///
/// Terms and corrections share one list rather than two tabs: they are two forms of the same
/// idea, and the point of the screen is to see everything the app has been taught at once.
/// The kind is shown by
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
                        ? "Add the words the recognizer keeps getting wrong."
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
                                var flipped = entry
                                flipped.isEnabled.toggle()
                                store.update(flipped)
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
            .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
            .help("Reveal \(DictionaryStore.fileURL.path)")
            .accessibilityLabel("Reveal dictionary file")
            Button { isAdding = true } label: {
                Label("Add", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(KeyButtonStyle(kind: .primary, compact: true))
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
    @Environment(\.isScrolling) private var isScrolling

    var body: some View {
        HStack(spacing: DS.Space.base) {
            Tag(text: entry.kind == .correction ? "Fix" : "Term")

            // An off entry is dimmed through its colours, not a row-wide `opacity`, which
            // would render every row to an offscreen layer while scrolling.
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

            Spacer()

            if isHovering {
                Button("Edit", action: onEdit)
                    .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: DS.Icon.regular, weight: .semibold))
                }
                .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
                .accessibilityLabel("Delete")
            }
            // On is cream, ink-stroked and checked, like every other "on" state in the app.
            Button(entry.isEnabled ? "On" : "Off", action: onToggle)
                .buttonStyle(KeyButtonStyle(kind: .secondary, isSelected: entry.isEnabled, compact: true))
                .help(entry.isEnabled ? "Turn this entry off" : "Turn this entry on")
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.base)
        .background(isHovering ? DS.Color.cardHover : Color.clear)
        // Hover is ignored while the list is moving, so rows passing under a still pointer
        // don't re-render on every frame (same as the transcripts list).
        .onHover { if !isScrolling { isHovering = $0 } }
        .onChange(of: isScrolling) { _, scrolling in
            if scrolling { isHovering = false }
        }
    }
}

// MARK: - Editor

/// Adds or edits one entry. Warnings are hints only and never block saving.
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

    private var warnings: [DictionaryWarning] { DictionaryWarning.check(draft) }

    private var isValid: Bool {
        let hasWrite = !write.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasHear = !hear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasWrite && (kind == .term || hasHear)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            Text(entry == nil ? "New entry" : "Edit entry")
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)

            kindPicker

            VStack(alignment: .leading, spacing: DS.Space.base) {
                if kind == .correction {
                    field("What it hears", text: $hear, prompt: "tail wind")
                    field("Write", text: $write, prompt: "Tailwind")
                } else {
                    field("Word or phrase", text: $write, prompt: "Tailwind")
                }
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
                    .buttonStyle(KeyButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard isValid else { return }
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(KeyButtonStyle(kind: .primary))
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
        PaperTextField(label: label, text: text, prompt: prompt)
    }
}
