import MurmurDesign
import MurmurKit
import SwiftUI
import UIKit

/// The Bark download, shared by the Setup tab and the Model screen so both show one state.
///
/// The transfer and the checksum pass run off the main actor inside
/// `BarkModelStore.ensureDownloaded`; progress comes back here through a callback that hops
/// to the main actor. The screen stays awake while it runs, because a suspended app stops
/// the transfer and an interrupted install starts over.
@MainActor @Observable
final class BarkDownload {
    static let shared = BarkDownload()

    enum State: Equatable {
        case idle
        case downloading(fraction: Double)
        case failed(String)
    }

    private(set) var state = State.idle
    private(set) var isInstalled = BarkModelStore.isDownloaded

    @ObservationIgnored private var task: Task<Void, Never>?

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    func refresh() {
        isInstalled = BarkModelStore.isDownloaded
    }

    func start() {
        guard !isDownloading, !BarkModelStore.isDownloaded else { return }
        state = .downloading(fraction: 0)
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task { [weak self] in
            let outcome: Result<Void, any Error>
            do {
                _ = try await BarkModelStore.ensureDownloaded { fraction in
                    Task { @MainActor in self?.report(fraction) }
                }
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            self?.finish(outcome)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func delete() {
        do {
            try BarkModelStore.delete()
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
        refresh()
    }

    private func report(_ fraction: Double) {
        // A late callback after the task ended must not bring the bar back.
        guard isDownloading else { return }
        state = .downloading(fraction: fraction)
    }

    private func finish(_ outcome: Result<Void, any Error>) {
        UIApplication.shared.isIdleTimerDisabled = false
        task = nil
        switch outcome {
        case .success:
            state = .idle
        case .failure(let error) where error is CancellationError || (error as? URLError)?.code == .cancelled:
            state = .idle
        case .failure(let error):
            state = .failed(error.localizedDescription)
        }
        refresh()
    }
}

/// Settings → Model: the Bark download, which engine hears you, and when it transcribes.
struct ModelView: View {
    @State private var settings = Settings.shared

    var body: some View {
        PhonePage(title: "Model") {
            Card(title: "Bark Clean") {
                BarkModelRow()
                Note(text: SpeechEngineChoice.barkClean.detail)
            }

            Card(title: "Engine") {
                ChoiceKeys(
                    options: [SpeechEngineChoice.barkClean, .apple],
                    selection: Binding(
                        get: { settings.engine == .barkClean ? .barkClean : .apple },
                        set: { settings.engine = $0 }
                    ),
                    title: { $0 == .barkClean ? "Bark Clean" : "Apple" }
                )
                Note(text: settings.engine == .barkClean
                    ? "The keyboard uses Apple's transcriber until Bark has loaded, and whenever Bark is not on this iPhone."
                    : "Apple's on-device transcriber. It needs no download.")
            }

            if settings.engine == .barkClean {
                Card(title: "Transcribe") {
                    ChoiceKeys(
                        options: TranscribeTiming.allCases,
                        selection: $settings.transcribeTiming,
                        title: \.displayName
                    )
                    Note(text: settings.transcribeTiming.detail)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { BarkDownload.shared.refresh() }
    }
}

/// Bark's status and its one action: download, cancel or delete. Shared by Setup and Model.
struct BarkModelRow: View {
    @State private var download = BarkDownload.shared
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(spacing: DS.Space.base) {
                VStack(alignment: .leading, spacing: DS.Space.hair) {
                    Text("Bark 3.0 Clean")
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                    Text(sizeLine)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                Spacer(minLength: DS.Space.snug)
                action
            }
            if case .downloading(let fraction) = download.state {
                ProgressBar(fraction: fraction)
            }
            if case .failed(let message) = download.state {
                Note(text: message, color: DS.Color.inkSecondary)
            }
        }
        .confirmationDialog(
            "Delete Bark Clean?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete model", role: .destructive) { download.delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The keyboard falls back to Apple's transcriber. You can download Bark again.")
        }
    }

    private var sizeLine: String {
        let total = Self.megabytes(BarkModelStore.totalBytes)
        switch download.state {
        case .downloading(let fraction):
            return "\(Int((fraction * 100).rounded())) percent of \(total). Keep Murmur open."
        case .idle, .failed:
            return download.isInstalled ? "\(total) on this iPhone" : "\(total) download. Use Wi-Fi."
        }
    }

    @ViewBuilder private var action: some View {
        if download.isDownloading {
            Button("Cancel") { download.cancel() }
                .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
        } else if download.isInstalled {
            Button("Delete") { isConfirmingDelete = true }
                .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
        } else {
            Button("Download") { download.start() }
                .buttonStyle(KeyButtonStyle(kind: .primary, compact: true))
        }
    }

    private static func megabytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
