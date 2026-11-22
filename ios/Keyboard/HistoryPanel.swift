import MurmurDesign
import MurmurKit
import SwiftUI
import UIKit

/// The newest dictations, newest first, from the same run log the Mac and the app use. Tapping
/// one types it again. The log is stored oldest first, so `RunStore.singles` does the reversing.
struct HistoryPanel: View {
    let actions: KeyboardActions
    let close: () -> Void

    private var entries: [Entry] {
        RunStore.shared.singles
            .prefix(DS.Keyboard.historyLimit)
            .map { Entry(id: $0.id, text: TrainingLabel.displayText($0)) }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private struct Entry: Identifiable {
        let id: UUID
        let text: String
    }

    var body: some View {
        let entries = entries
        VStack(spacing: DS.Keyboard.historySpacing) {
            HStack {
                Text("Recent dictations")
                    .font(DS.Keyboard.historyTitleFont)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close)
                    .font(DS.Keyboard.historyActionFont)
            }
            .padding(.horizontal, DS.Keyboard.historyHeaderInset)
            if entries.isEmpty {
                Text("Nothing dictated yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Keyboard.historySpacing) {
                        ForEach(entries) { entry in
                            Button {
                                UIDevice.current.playInputClick()
                                actions.insert(entry.text)
                                close()
                            } label: {
                                KeyFace(fill: DS.Keyboard.letterKey) {
                                    Text(entry.text)
                                        .font(DS.Keyboard.historyRowFont)
                                        .lineLimit(DS.Keyboard.historyRowLines)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, DS.Keyboard.historyRowInsetX)
                                        .padding(.vertical, DS.Keyboard.historyRowInsetY)
                                }
                            }
                            .buttonStyle(KeyPressStyle())
                        }
                    }
                }
            }
        }
        // The app may have written runs since this process last read the file.
        .task { RunStore.shared.reload() }
    }
}
