import MurmurDesign
import MurmurDictionary
import MurmurKit
import SwiftUI
import UIKit

/// Builds a training export and hands it to the share sheet.
///
/// The folder (`TrainingExport.writeFolder`, the same layout the Mac writes) and its zip are
/// made off the main actor. iOS has no `ditto`, so the zip comes from `NSFileCoordinator`
/// reading the folder with `.forUploading`, which hands back a temporary archive that is
/// deleted when the accessor returns; it is copied to a stable URL inside the accessor.
@MainActor @Observable
final class TrainingExporter {
    enum State: Equatable {
        case idle
        case preparing
        case failed(String)
        case exported(String)
    }

    /// A finished archive waiting for the share sheet.
    struct Prepared: Identifiable, Sendable {
        let id = UUID()
        let zip: URL
        let exportedIDs: Set<UUID>
        let labelled: Int
        let replay: Int
    }

    private(set) var state = State.idle
    /// Set once the archive is ready; the view presents the share sheet for it.
    var prepared: Prepared?

    func prepare() {
        guard state != .preparing else { return }
        state = .preparing
        let runs = RunStore.shared.runs
        let corrector = DictionaryStore.shared.corrector
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.build(runs: runs, corrector: corrector, date: Date())
                }.value
                prepared = result
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Runs already stamped as exported, so the completion handler and the dismissal, which
    /// can both report one sheet, mark it once.
    @ObservationIgnored private var markedIDs: Set<UUID> = []

    /// The share sheet reported its result. `done` is the archive the sheet was opened with,
    /// captured by the view: SwiftUI clears `prepared` when the sheet dismisses itself, which
    /// can come before this handler runs, so the property is never read here. Runs count as
    /// exported only when the user actually sent the archive somewhere (AirDrop, Files, Mail).
    func finishSharing(_ done: Prepared, completed: Bool) {
        guard completed, markedIDs.insert(done.id).inserted else { return }
        RunLog.markExported(ids: done.exportedIDs)
        state = .exported("Exported \(done.labelled) labelled and \(done.replay) replay clips.")
    }

    /// The sheet is gone, by a finished share, a cancel or a swipe. Every path ends here, so
    /// the scratch copy of the audio never outlives it.
    func sheetDismissed() {
        prepared = nil
        if case .exported = state {} else { state = .idle }
        Task.detached { Self.removeScratch() }
    }

    private nonisolated static var scratch: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MurmurExport", isDirectory: true)
    }

    private nonisolated static func removeScratch() {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Writes `export-<date>/` and `export-<date>.zip` under a fresh scratch folder.
    private nonisolated static func build(runs: [DictationRun], corrector: DictionaryCorrector, date: Date) throws -> Prepared {
        let files = FileManager.default
        removeScratch()
        try files.createDirectory(at: scratch, withIntermediateDirectories: true)

        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        let folder = scratch.appendingPathComponent("export-\(day.string(from: date))", isDirectory: true)
        let summary = try TrainingExport.writeFolderSummary(runs: runs, corrector: corrector, to: folder, date: date)
        guard summary.labelled > 0 else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Nothing is labelled yet."])
        }

        let zip = scratch.appendingPathComponent(folder.lastPathComponent + ".zip")
        var coordinationError: NSError?
        var copyError: (any Error)?
        var copied = false
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { archive in
            do {
                try? files.removeItem(at: zip)
                try files.copyItem(at: archive, to: zip)
                copied = true
            } catch {
                copyError = error
            }
        }
        guard copied else {
            if let copyError { throw copyError }
            if let coordinationError { throw coordinationError }
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The archive could not be made."])
        }
        // The folder is inside the zip now; keep only the archive.
        try? files.removeItem(at: folder)
        return Prepared(zip: zip, exportedIDs: summary.exportedIDs, labelled: summary.labelled, replay: summary.replay)
    }
}

/// Settings → Training: keep recordings, and export the corrected ones to the Mac.
struct TrainingView: View {
    @State private var settings = Settings.shared
    @State private var store = RunStore.shared
    @State private var exporter = TrainingExporter()
    @State private var recordingsBytes = 0
    @State private var isConfirmingDeleteAudio = false

    var body: some View {
        let pending = TrainingExport.pending(store.runs, corrector: DictionaryStore.shared.corrector)
        PhonePage(title: "Training") {
            Card(title: "Recordings") {
                ToggleRow(
                    title: "Keep recordings for training",
                    note: settings.keepRecordings
                        ? "Each dictation's audio stays on this iPhone for 30 days (\(size)), longer while it has a correction waiting to be exported. Nothing leaves it unless you export."
                        : "No audio is kept. Corrections can't train the model without it.",
                    isOn: Binding(
                        get: { settings.keepRecordings },
                        set: { on in
                            if on {
                                settings.keepRecordings = true
                            } else {
                                isConfirmingDeleteAudio = true
                            }
                        }
                    )
                )
            }

            Card(title: "Export") {
                Text(pending.count == 1 ? "1 labelled recording" : "\(pending.count) labelled recordings")
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                Note(text: pending.count == 0
                    ? "Fix a transcript in History, or add a dictionary entry that fires, and its recording shows up here."
                    : String(format: "%.1f minutes of corrected speech since the last export.", pending.seconds / 60))
                Button(exporter.state == .preparing ? "Preparing" : "Export labelled recordings") { exporter.prepare() }
                    .buttonStyle(KeyButtonStyle(kind: .primary))
                    .disabled(pending.count == 0 || exporter.state == .preparing)
                switch exporter.state {
                case .failed(let message): Note(text: "Export failed: \(message)")
                case .exported(let message): Note(text: message)
                case .idle, .preparing: EmptyView()
                }
                Note(text: "AirDrop the zip to your Mac, then choose Import from iPhone in Murmur's Training settings there.")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { recordingsBytes = RecordingStore.shared.totalBytes() }
        .onChange(of: store.runs.count) { _, _ in recordingsBytes = RecordingStore.shared.totalBytes() }
        .sheet(item: $exporter.prepared, onDismiss: { exporter.sheetDismissed() }) { prepared in
            ShareSheet(items: [prepared.zip]) { completed in
                exporter.finishSharing(prepared, completed: completed)
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(
            "Delete all recordings?",
            isPresented: $isConfirmingDeleteAudio,
            titleVisibility: .visible
        ) {
            Button("Delete recordings", role: .destructive) {
                settings.keepRecordings = false
                RunLog.deleteAllRecordings()
                recordingsBytes = 0
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every saved recording on this iPhone is deleted, and new dictations keep no audio. This can't be undone.")
        }
    }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: Int64(recordingsBytes), countStyle: .file)
    }
}

/// The system share sheet, reporting whether the user sent the item anywhere.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            onFinish(completed)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
