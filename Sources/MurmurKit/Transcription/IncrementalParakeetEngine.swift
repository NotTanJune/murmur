import AVFoundation
import FluidAudio
import Foundation

/// A recognizer that decodes windows of audio while it is still being fed.
///
/// The seam exists so the engine can be tested with a scripted fake; the production
/// conformer is `OverlapWindowRecognizer`.
public protocol WindowedRecognizer: Actor {
    func load(_ models: AsrModels) async throws
    func start() async throws
    func stream(_ buffer: AVAudioPCMBuffer) async
    /// The words each window settled, in order. Ends after `cancel()`.
    var windows: AsyncStream<DecodedWindow> { get }
    /// Decodes the audio not yet decoded; its words arrive on `windows` first. The returned
    /// text is the recognizer's own join of everything, used only when no window was reported.
    func finish() async throws -> String
    func cancel() async
}

/// The words one window added to the transcript: whole words that no later window revises.
public struct DecodedWindow: Sendable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// Parakeet / Bark decoded in windows during the hold, so release only decodes the audio
/// since the last one. Uses the same already-loaded `AsrModels` as `ParakeetEngine`.
public actor IncrementalParakeetEngine: TranscriptionEngine {
    private let models: ParakeetModels
    private let loadModels: @Sendable () async throws -> AsrModels?
    private let makeRecognizer: @Sendable () -> any WindowedRecognizer

    private var recognizer: (any WindowedRecognizer)?
    private var consumer: Task<Void, Never>?
    /// The active session's output. Non-nil means a session is open.
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?
    private var windowCount = 0
    /// The transcript composed from the windows so far.
    private var composed = ""
    /// Set once release begins: windows flushed then go into the final text, not into partials.
    private var finishing = false
    private var sampleCount = 0

    public init(
        models: ParakeetModels = .shared,
        loadModels: (@Sendable () async throws -> AsrModels?)? = nil,
        makeRecognizer: @escaping @Sendable () -> any WindowedRecognizer = { OverlapWindowRecognizer() }
    ) {
        self.models = models
        self.loadModels = loadModels ?? { try await models.loadedModels() }
        self.makeRecognizer = makeRecognizer
    }

    public func preferredInputFormat() async -> AVAudioFormat? {
        // Same as the batch engine: the windowed manager expects 16 kHz mono Float32.
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    public func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        windowCount = 0
        composed = ""
        finishing = false
        sampleCount = 0

        // Forces the (possibly slow) first load here, before the user speaks.
        let loaded = try await loadModels()
        let recognizer = makeRecognizer()
        if let loaded { try await recognizer.load(loaded) }
        try await recognizer.start()
        self.recognizer = recognizer

        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation

        let windows = await recognizer.windows
        consumer = Task { [weak self] in
            for await window in windows {
                if Task.isCancelled { return }
                await self?.append(window: window)
            }
        }
        return stream
    }

    public func feed(_ chunk: AudioChunk) async {
        let buffer = chunk.buffer
        guard buffer.frameLength > 0, let recognizer else { return }
        // Sound for the reason `AudioChunk` is: the buffer is fresh and never touched again.
        nonisolated(unsafe) let handoff = buffer
        await recognizer.stream(handoff)
        sampleCount += Int(buffer.frameLength)
    }

    public func finish() async {
        guard let continuation else { return }
        let recognizer = self.recognizer
        self.continuation = nil
        self.recognizer = nil
        let label = models.source.label

        guard sampleCount >= 1_600, let recognizer else {
            Log.speech.info("\(label, privacy: .public): skipped — only \(self.sampleCount) samples captured")
            consumer?.cancel()
            await consumer?.value
            consumer = nil
            await recognizer?.cancel()
            continuation.yield(TranscriptionChunk(text: "", isFinal: true))
            continuation.finish()
            return
        }

        do {
            let started = Date()
            let heldWindows = windowCount
            finishing = true
            let raw = try await recognizer.finish()
            // The flushed windows were reported before `finish` returned; ending the stream
            // lets the consumer drain them, so the final text is composed from every window
            // and nothing can land after it.
            await recognizer.cancel()
            await consumer?.value
            consumer = nil
            let elapsed = Date().timeIntervalSince(started)

            let audioSeconds = Double(sampleCount) / 16_000
            Log.speech.info("""
                \(label, privacy: .public): \(audioSeconds, format: .fixed(precision: 1))s audio, \
                \(heldWindows) window(s) decoded while held, \(self.windowCount - heldWindows) at release, tail \
                \(elapsed, format: .fixed(precision: 2))s
                """)
            let final = composed.isEmpty ? ParakeetEngine.cleanTranscript(raw) : composed
            continuation.yield(TranscriptionChunk(text: final, isFinal: true))
            continuation.finish()
        } catch {
            consumer?.cancel()
            await consumer?.value
            consumer = nil
            await recognizer.cancel()
            Log.speech.error("\(label, privacy: .public) failed: \(error.localizedDescription)")
            continuation.finish(throwing: error)
        }
    }

    private func append(window: DecodedWindow) {
        // Windows flushed at release arrive after the stream's continuation has been taken
        // for the final chunk; they still belong in the text.
        guard continuation != nil || finishing else { return }
        let cleaned = ParakeetEngine.cleanTranscript(window.text)
        guard !cleaned.isEmpty else { return }
        windowCount += 1
        composed = composed.isEmpty ? cleaned : composed + " " + cleaned
        guard !finishing else { return }
        continuation?.yield(TranscriptionChunk(text: composed, isFinal: false, stable: composed))
    }
}
