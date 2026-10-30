import Foundation
import Observation

@MainActor
@Observable
final class StreamingModelPreparation {
    static let shared = StreamingModelPreparation()

    enum State: Equatable {
        case unloaded
        case loading
        case ready
        case failed(String)

        var message: String {
            switch self {
            case .unloaded: "Model not loaded. The first load requires an internet download."
            case .loading: "Downloading or loading model. Leave the app open; audio is not uploaded."
            case .ready: "Model ready. Hold the key to record."
            case .failed(let message): "Model load failed: \(message)"
            }
        }
    }

    private var states: [SpeechEngineChoice: State] = [:]
    private let prepare: @Sendable (SpeechEngineChoice) async throws -> Void

    init(prepare: @escaping @Sendable (SpeechEngineChoice) async throws -> Void = { choice in
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
        self.prepare = prepare
    }

    func state(for choice: SpeechEngineChoice) -> State {
        states[choice] ?? .unloaded
    }

    func recordingBlocker(for choice: SpeechEngineChoice) -> String? {
        guard choice.requiresPreparedModel, state(for: choice) != .ready else { return nil }
        return "\(choice.displayName): \(state(for: choice).message) Open Settings → Model to load it or check progress."
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
            } catch {
                states[choice] = .failed(error.localizedDescription)
                Log.speech.error("Model load failed: \(error.localizedDescription)")
            }
        }
    }
}
