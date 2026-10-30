import MurmurDictionary
import AppKit
import SwiftUI

/// The dictionary: add, edit, delete, search.
///
/// Both entry kinds live in one list rather than separate tabs — they're two shapes of the
/// same idea and you want to see everything you've taught it at once. The kind is carried by
/// a silkscreen tag on each row.
struct DictionaryPanel: View {
    @State private var store = DictionaryStore.shared
    @State private var query = ""
    @State private var editing: DictionaryEntry?
    @State private var isAdding = false

    private var entries: [DictionaryEntry] { store.filtered(by: query) }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: DS.Space.base) {
                header

                if entries.isEmpty {
                    EmptyPanel(
                        label: store.entries.isEmpty ? "Dictionary empty" : "No matches",
                        detail: store.entries.isEmpty
                            ? "Add words it keeps getting wrong."
                            : "Try a different search."
                    )
                    .padding(.top, DS.Space.wide)
                } else {
                    ForEach(entries) { entry in
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
                    }
                }
            }
            .padding(.horizontal, DS.Space.roomy)
            .padding(.top, DS.Space.snug)
            .padding(.bottom, DS.Space.wide)
            .padding(.trailing, DS.Brutal.lift)
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
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
            SearchField(text: $query, placeholder: "Search dictionary")
            Eyebrow(text: "\(store.entries.count) entries")
                .fixedSize()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: DS.Icon.regular, weight: .bold))
            }
            .buttonStyle(BrutalButtonStyle())
            .help("Reveal \(DictionaryStore.fileURL.path)")
            .accessibilityLabel("Reveal dictionary file")
            Button { isAdding = true } label: {
                Label("Add", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(BrutalButtonStyle(fill: DS.Color.card))
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.bottom, DS.Space.snug)
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
                    .font(.system(size: DS.Icon.small, weight: .bold))
                    .foregroundStyle(DS.Color.inkSecondary)
            }

            Text(entry.write)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)

            Spacer()

            if isHovering {
                Button("Edit", action: onEdit)
                    .buttonStyle(BrutalButtonStyle(compact: true))
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: DS.Icon.regular, weight: .bold))
                }
                .buttonStyle(BrutalButtonStyle(compact: true))
                .accessibilityLabel("Delete")
            }
            // On is yellow and sunk, like every other "on" state in the app.
            Button(entry.isEnabled ? "On" : "Off", action: onToggle)
                .buttonStyle(BrutalButtonStyle(isSelected: entry.isEnabled, compact: true))
                .help(entry.isEnabled ? "Turn this entry off" : "Turn this entry on")
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.base)
        .brutalSurface(isHovering ? DS.Color.cardHover : DS.Color.card, radius: DS.Radius.control, lift: DS.Brutal.liftSmall)
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
                .font(DS.Font.display)
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
                        .font(.system(size: DS.Icon.regular, weight: .bold))
                        .foregroundStyle(DS.Color.onAccent)
                    Text(warning.message)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.onAccent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.base)
                .frame(maxWidth: .infinity, alignment: .leading)
                .brutalSurface(DS.Color.accent, radius: DS.Radius.control, lift: DS.Brutal.liftSmall)
            }

            HStack(spacing: DS.Space.snug) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(BrutalButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard isValid else { return }
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(BrutalButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(.trailing, DS.Brutal.liftSmall)
            .padding(.bottom, DS.Brutal.liftSmall)
        }
        .padding(DS.Space.panel)
        .frame(width: DS.Window.editorWidth)
        .background(PaperBackground())
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
        BrutalTextField(label: label, text: text, prompt: prompt)
    }
}
