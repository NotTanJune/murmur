import AVFoundation
import CoreML
import FluidAudio
import Foundation

actor FluidStreamingEngine: TranscriptionEngine {
    private let manager: any StreamingAsrManager
    private var tail: Task<Void, Never>?
    private var loaded = false
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?
    private var receivedAudio = false

    init(manager: any StreamingAsrManager) {
        self.manager = manager
    }

    func preferredInputFormat() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func prepare() async throws {
        try await serialized { [self] in try await loadModels() }
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        try await serialized { [self] in try await openSession() }
    }

    func feed(_ chunk: AudioChunk) async {
        do {
            try await serialized { [self] in await accept(chunk) }
        } catch {
            Log.speech.error("Streaming input failed: \(error.localizedDescription)")
        }
    }

    func finish() async {
        do {
            try await serialized { [self] in await closeSession() }
        } catch {
            Log.speech.error("Streaming finish failed: \(error.localizedDescription)")
        }
    }

    private func serialized<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let previous = tail
        let task = Task {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }

    private func loadModels() async throws {
        guard !loaded else { return }
        do {
            try await manager.loadModels()
            loaded = true
        } catch {
            await manager.cleanup()
            throw error
        }
    }

    private func openSession() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        guard loaded else { throw StreamingEngineError.modelNotLoaded }
        guard continuation == nil else { throw StreamingEngineError.alreadyRunning }
        try await manager.reset()
        receivedAudio = false
        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation
        await manager.setPartialTranscriptCallback { text in
            continuation.yield(TranscriptionChunk(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines), isFinal: false
            ))
        }
        return stream
    }

    private func accept(_ chunk: AudioChunk) async {
        guard let continuation, chunk.buffer.frameLength > 0 else { return }
        receivedAudio = true
        do {
            try await manager.append(chunk)
            try await manager.processBufferedAudio()
        } catch {
            continuation.finish(throwing: error)
            self.continuation = nil
            await manager.setPartialTranscriptCallback { _ in }
        }
    }

    private func closeSession() async {
        guard let continuation else { return }
        self.continuation = nil
        do {
            await manager.setPartialTranscriptCallback { _ in }
            let text = receivedAudio ? try await manager.finish() : ""
            continuation.yield(TranscriptionChunk(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines), isFinal: true
            ))
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}

private extension StreamingAsrManager {
    func append(_ chunk: AudioChunk) throws {
        try appendAudio(chunk.buffer)
    }
}

enum StreamingEngines {
    static let parakeetEOU = make(.parakeetEou160ms)
    static let nemotron = make(.nemotron560ms)

    private static func make(_ variant: StreamingModelVariant) -> FluidStreamingEngine {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return FluidStreamingEngine(manager: variant.createManager(configuration: configuration))
    }
}

private enum StreamingEngineError: LocalizedError {
    case modelNotLoaded
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "Load the selected streaming model in Settings before recording."
        case .alreadyRunning: "The streaming engine is still finishing its previous recording."
        }
    }
}
