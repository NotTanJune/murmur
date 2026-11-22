import MurmurDesign
import MurmurKit
import SwiftUI
import UIKit

/// The newest dictations, newest first, from the same run log the Mac and the app use. Tapping
/// one types it again. The log is stored oldest first, so `RunStore.singles` does the reversing.
///
/// A flat list with hairline dividers rather than a stack of key-coloured cards: the rows are
/// text to read and pick, not keys. The scroll view's soft top edge (iOS 26) is turned off,
/// because under the header it blurred the first row into an unreadable smear.
struct HistoryPanel: View {
    let actions: KeyboardActions
    let close: () -> Void

    private var entries: [Entry] {
        RunStore.shared.singles
            .prefix(DS.Keyboard.historyLimit)
            .map { Entry(id: $0.id, date: $0.date, text: TrainingLabel.displayText($0)) }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private struct Entry: Identifiable {
        let id: UUID
        let date: Date
        let text: String
    }

    var body: some View {
        let entries = entries
        VStack(spacing: 0) {
            header
            if entries.isEmpty {
                Text("Nothing dictated yet.")
                    .font(DS.Keyboard.historyRowFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 {
                                Divider().padding(.leading, DS.Keyboard.historyRowInsetX)
                            }
                            row(entry)
                        }
                    }
                }
                .scrollEdgeEffectHidden(true, for: .all)
                .scrollIndicators(.hidden)
            }
        }
        // The app may have written runs since this process last read the file.
        .task { RunStore.shared.reload() }
    }

    private var header: some View {
        HStack {
            Text("Recent")
                .textCase(.uppercase)
                .font(DS.Keyboard.emojiTitleFont)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button("Done", action: close)
                .font(DS.Keyboard.historyActionFont)
        }
        .padding(.horizontal, DS.Keyboard.historyHeaderInset)
        .frame(height: DS.Keyboard.historyHeaderHeight)
    }

    private func row(_ entry: Entry) -> some View {
        Button {
            UIDevice.current.playInputClick()
            actions.insert(entry.text)
            close()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: DS.Keyboard.historyRowInsetX) {
                Text(entry.text)
                    .font(DS.Keyboard.historyRowFont)
                    .foregroundStyle(.primary)
                    .lineLimit(DS.Keyboard.historyRowLines)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.date, format: .relative(presentation: .named, unitsStyle: .narrow))
                    .font(DS.Keyboard.captionFont)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DS.Keyboard.historyRowInsetX)
            .padding(.vertical, DS.Keyboard.historyRowInsetY)
            .contentShape(Rectangle())
        }
        .buttonStyle(KeyPressStyle())
        .accessibilityHint("Types it again")
    }
}
