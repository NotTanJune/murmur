import Foundation
import Observation

@MainActor
@Observable
final class StreamingModelPreparation {
    static let shared = StreamingModelPreparation()

    enum State: Equatable {
        case unloaded
        /// On disk but not in memory. Loads at the next press, alongside recording.
        case sleeping
        case loading
        case ready
        case failed(String)

        var message: String {
            switch self {
            case .unloaded: "Model not loaded. The first load requires an internet download."
            case .sleeping: "Installed, not in memory. Loads when you press the key."
            case .loading: "Downloading or loading model. Leave the app open; audio is not uploaded."
            case .ready: "Model ready. Hold the key to record."
            case .failed(let message): "Model load failed: \(message)"
            }
        }
    }

    private var states: [SpeechEngineChoice: State] = [:]
    private let prepare: @Sendable (SpeechEngineChoice) async throws -> Void
    private let isInstalled: (SpeechEngineChoice) -> Bool

    init(
        isInstalled: @escaping (SpeechEngineChoice) -> Bool = { $0.isInstalledLocally },
        prepare: @escaping @Sendable (SpeechEngineChoice) async throws -> Void = { choice in
        switch choice {
        case .parakeet:
            _ = try await ParakeetModels.shared.manager()
            return
        case .barkClean:
            _ = try await ParakeetModels.barkClean.manager()
            return
        case .apple, .parakeetEOU, .nemotron:
            break
        }
        guard let engine = choice.streamingEngine else { return }
        try await engine.prepare()
    }) {
        self.isInstalled = isInstalled
        self.prepare = prepare
    }

    func state(for choice: SpeechEngineChoice) -> State {
        if let state = states[choice] { return state }
        return choice.requiresPreparedModel && isInstalled(choice) ? .sleeping : .unloaded
    }

    /// Only a model that would have to be *downloaded* blocks recording. One already on disk
    /// loads at the press while audio buffers, so the first word is never lost to it.
    func recordingBlocker(for choice: SpeechEngineChoice) -> String? {
        guard choice.requiresPreparedModel else { return nil }
        switch state(for: choice) {
        case .ready, .sleeping: return nil
        case .loading where isInstalled(choice): return nil
        case .unloaded, .loading, .failed:
            return "\(choice.displayName): \(state(for: choice).message) Open Settings → Model to load it or check progress."
        }
    }

    /// At the press: start loading an installed model that was released to save memory.
    func wake(_ choice: SpeechEngineChoice) {
        guard state(for: choice) == .sleeping else { return }
        load(choice)
    }

    /// After idle: release the Bark and Parakeet models. The streaming engines keep theirs;
    /// they aren't installed through this app and would need a download to come back.
    func release() async {
        for choice in [SpeechEngineChoice.parakeet, .barkClean] where states[choice] == .ready {
            let models: ParakeetModels = choice == .barkClean ? .barkClean : .shared
            await models.unload()
            states[choice] = isInstalled(choice) ? .sleeping : .unloaded
        }
    }

    /// Starts loading when the model is already on disk. Used at launch and when the engine
    /// is picked, so an installed model is ready without a separate click and nothing is
    /// downloaded without one.
    @discardableResult
    func loadIfInstalled(_ choice: SpeechEngineChoice) -> Task<Void, Never>? {
        guard choice.isInstalledLocally else { return nil }
        return load(choice)
    }

    @discardableResult
    func load(_ choice: SpeechEngineChoice) -> Task<Void, Never>? {
        guard choice.requiresPreparedModel, state(for: choice) != .loading,
              state(for: choice) != .ready else { return nil }
        states[choice] = .loading
        return Task {
            do {
                try await prepare(choice)
                states[choice] = .ready
                ModelResidency.shared.loaded()
            } catch {
                states[choice] = .failed(error.localizedDescription)
                Log.speech.error("Model load failed: \(error.localizedDescription)")
            }
        }
    }
}
