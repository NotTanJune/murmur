import AVFoundation
import FluidAudio
import Testing
@testable import Murmur

struct FluidStreamingEngineTests {
    @Test("Streaming emits snapshots before release and preserves the flushed ending")
    func partialsAndFinalWords() async throws {
        let engine = FluidStreamingEngine(manager: ScriptedRecognizer())
        try await engine.prepare()
        let stream = try await engine.start()
        var iterator = stream.makeAsyncIterator()
        await engine.feed(try audioChunk())
        let partial = try #require(try await iterator.next())
        #expect(partial.text == "First words")
        #expect(!partial.isFinal)
        await engine.feed(try audioChunk())
        let revised = try #require(try await iterator.next())
        #expect(revised.text == "First words with")
        await engine.finish()
        let final = try #require(try await iterator.next())
        #expect(final.text == "First words with the ending.")
        #expect(final.isFinal)
        #expect(try await iterator.next() == nil)
    }

    @Test("Repeated sessions reset decoder state and reuse loaded models")
    func repeatedSessions() async throws {
        let manager = ScriptedRecognizer()
        let engine = FluidStreamingEngine(manager: manager)
        for _ in 0..<2 {
            try await engine.prepare()
            let stream = try await engine.start()
            await engine.feed(try audioChunk())
            await engine.finish()
            var chunks: [TranscriptionChunk] = []
            for try await chunk in stream { chunks.append(chunk) }
            #expect(chunks.map(\.text) == ["First words", "First words with the ending."])
        }
        #expect(await manager.loads == 1)
    }

    @Test("A processing failure closes the stream instead of injecting a partial success")
    func processingFailure() async throws {
        let engine = FluidStreamingEngine(manager: ScriptedRecognizer(failProcessing: true))
        try await engine.prepare()
        let stream = try await engine.start()
        await engine.feed(try audioChunk())
        await engine.finish()
        var iterator = stream.makeAsyncIterator()
        await #expect(throws: RecognitionFailure.self) { try await iterator.next() }
    }

    @Test("Empty recordings do not finalize a model into hallucinated text")
    func emptyRecording() async throws {
        let engine = FluidStreamingEngine(manager: ScriptedRecognizer())
        try await engine.prepare()
        let stream = try await engine.start()
        await engine.finish()
        var iterator = stream.makeAsyncIterator()
        let final = try #require(try await iterator.next())
        #expect(final.text.isEmpty)
        #expect(final.isFinal)
        #expect(try await iterator.next() == nil)
    }

    @Test("Recording never triggers an unrequested model download")
    func explicitPreparation() async throws {
        let manager = ScriptedRecognizer()
        let engine = FluidStreamingEngine(manager: manager)
        await #expect(throws: (any Error).self) { try await engine.start() }
        #expect(await manager.loads == 0)
    }

    @Test("Finalization errors propagate rather than returning the live snapshot")
    func finalizationFailure() async throws {
        let engine = FluidStreamingEngine(manager: ScriptedRecognizer(failFinish: true))
        try await engine.prepare()
        let stream = try await engine.start()
        await engine.feed(try audioChunk())
        await engine.finish()
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next()?.text == "First words")
        await #expect(throws: RecognitionFailure.self) { try await iterator.next() }
    }

    @Test("Release waits for in-flight processing before flushing")
    func orderedFinalization() async throws {
        let gate = ProcessingGate()
        let engine = FluidStreamingEngine(manager: ScriptedRecognizer(gate: gate))
        try await engine.prepare()
        let stream = try await engine.start()
        let chunk = try audioChunk()
        let feed = Task { await engine.feed(chunk) }
        await gate.waitUntilEntered()
        let finish = Task { await engine.finish() }
        await gate.release()
        await feed.value
        await finish.value
        var chunks: [TranscriptionChunk] = []
        for try await chunk in stream { chunks.append(chunk) }
        #expect(chunks.map(\.text) == ["First words", "First words with the ending."])
        #expect(chunks.last?.isFinal == true)
    }

    private func audioChunk() throws -> AudioChunk {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 160)
        return AudioChunk(buffer: buffer)
    }
}

private struct RecognitionFailure: Error {}

private actor ScriptedRecognizer: StreamingAsrManager {
    let displayName = "Scripted recognizer"
    var loads = 0
    private var buffers = 0
    private var pending = false
    private var callback: (@Sendable (String) -> Void)?
    private let failProcessing: Bool
    private let failFinish: Bool
    private let gate: ProcessingGate?

    init(failProcessing: Bool = false, failFinish: Bool = false, gate: ProcessingGate? = nil) {
        self.failProcessing = failProcessing
        self.failFinish = failFinish
        self.gate = gate
    }

    func loadModels() { loads += 1 }
    func appendAudio(_ buffer: AVAudioPCMBuffer) {
        if buffer.frameLength > 0 { buffers += 1; pending = true }
    }
    func processBufferedAudio() async throws {
        if let gate { await gate.enter() }
        if failProcessing { throw RecognitionFailure() }
        pending = false
        callback?(getPartialTranscript())
    }
    func finish() throws -> String {
        if failFinish || pending { throw RecognitionFailure() }
        return "First words with the ending."
    }
    func reset() { buffers = 0; pending = false }
    func cleanup() { reset() }
    func setPartialTranscriptCallback(_ callback: @escaping @Sendable (String) -> Void) {
        self.callback = callback
    }
    func getPartialTranscript() -> String {
        buffers == 1 ? "First words" : "First words with"
    }
}

private actor ProcessingGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
