import Foundation
import Observation

/// Load state for S1-mini, shown in Settings and the menu.
///
/// Cleanup never blocks recording: until S1-mini is ready, holds use the rule pass. So unlike
/// the speech models there is no recording gate here, only status.
@MainActor
@Observable
final class S1MiniPreparation {
    static let shared = S1MiniPreparation()

    enum State: Equatable {
        case unloaded
        /// Installed but not in memory. Loads at the next press, alongside recording.
        case sleeping
        case downloading
        case converting
        case loading
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .converting, .loading: true
            case .unloaded, .sleeping, .ready, .failed: false
            }
        }

        var message: String {
            switch self {
            case .unloaded: "Not loaded. Until it is, cleanup uses the basic rules."
            case .sleeping: "Installed, not in memory. Loads when you press the key."
            case .downloading: "Downloading 1.5 GB and checking it. Leave the app open."
            case .converting: "Converting to 4-bit on this Mac."
            case .loading: "Loading onto the GPU."
            case .ready: "Ready."
            case .failed(let message): "Load failed: \(message)"
            }
        }
    }

    private(set) var state: State
    private let load: @Sendable (@escaping @Sendable (S1MiniModelStore.Phase?) -> Void) async throws -> Void

    init(
        isInstalled: Bool = S1MiniModelStore.isInstalled,
        load: @escaping @Sendable (@escaping @Sendable (S1MiniModelStore.Phase?) -> Void) async throws -> Void = { phase in
            try await S1MiniEngine.shared.load(phase: phase)
        }
    ) {
        state = isInstalled ? .sleeping : .unloaded
        self.load = load
    }

    /// At the press: start loading if the model was released to save memory.
    func wake() {
        guard state == .sleeping else { return }
        start()
    }

    /// After idle: free the model's GPU memory.
    func release() async {
        guard state == .ready else { return }
        await S1MiniEngine.shared.unload()
        state = .sleeping
    }

    /// Loads only when the converted model is already on disk, so nothing downloads without
    /// a click. Used at launch and when S1-mini is picked.
    @discardableResult
    func loadIfInstalled(isInstalled: Bool = S1MiniModelStore.isInstalled) -> Task<Void, Never>? {
        guard isInstalled else { return nil }
        return start()
    }

    @discardableResult
    func start() -> Task<Void, Never>? {
        guard !state.isBusy, state != .ready else { return nil }
        state = .loading
        return Task {
            do {
                try await load { phase in
                    Task { @MainActor in
                        // A late hop must not move a finished load back to busy.
                        guard self.state.isBusy else { return }
                        switch phase {
                        case .downloading: self.state = .downloading
                        case .converting: self.state = .converting
                        case nil: self.state = .loading
                        }
                    }
                }
                state = .ready
                ModelResidency.shared.loaded()
            } catch {
                state = .failed(error.localizedDescription)
                Log.speech.error("S1-mini load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
