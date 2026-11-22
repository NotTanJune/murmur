import MurmurDesign
import MurmurKit
import SwiftUI
import UIKit

/// The newest dictations, newest first, from the same run log the Mac and the app use. Tapping
/// one types it again. The log is stored oldest first, so `RunStore.singles` does the reversing.
///
/// A flat list with hairline dividers rather than a stack of key-coloured cards: the rows are
/// text to read and pick, not keys. The list itself is UIKit (`HistoryList`), for touch
/// handling that matches a system list.
struct HistoryPanel: View {
    let actions: KeyboardActions
    let close: () -> Void

    private var entries: [HistoryEntry] {
        RunStore.shared.singles
            .prefix(DS.Keyboard.historyLimit)
            .map { HistoryEntry(id: $0.id, date: $0.date, text: TrainingLabel.displayText($0)) }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
                HistoryList(entries: entries) { text in
                    actions.insert(text)
                    close()
                }
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
}
