import AVFoundation
import FluidAudio
import Testing
@testable import Murmur

struct IncrementalParakeetEngineTests {
    @Test("Windows stream as stable partials and release returns the cleaned final")
    func windowsThenFinal() async throws {
        let recognizer = ScriptedWindowRecognizer(windows: ["Hello there", "how <unk>are you."], final: "ignored")
        let engine = makeEngine(recognizer)
        let stream = try await engine.start()
        var iterator = stream.makeAsyncIterator()
        await engine.feed(try audioChunk())
        let first = try #require(try await iterator.next())
        #expect(first.text == "Hello there")
        #expect(first.stable == first.text)
        #expect(!first.isFinal)
        await engine.feed(try audioChunk())
        let second = try #require(try await iterator.next())
        #expect(second.text == "Hello there how are you.")
        #expect(second.stable == second.text)
        await engine.finish()
        let final = try #require(try await iterator.next())
        #expect(final.text == "Hello there how are you.")
        #expect(final.isFinal)
        #expect(try await iterator.next() == nil)
    }

    @Test("A window flushed at release is part of the final text, not a partial after it")
    func flushedWindow() async throws {
        let recognizer = ScriptedWindowRecognizer(windows: ["Hello there"], final: "", flushedAtFinish: ["and goodbye."])
        let engine = makeEngine(recognizer)
        let stream = try await engine.start()
        var iterator = stream.makeAsyncIterator()
        await engine.feed(try audioChunk())
        let partial = try #require(try await iterator.next())
        #expect(partial.text == "Hello there")
        await engine.finish()
        var rest: [TranscriptionChunk] = []
        while let chunk = try await iterator.next() { rest.append(chunk) }
        #expect(rest.map(\.text) == ["Hello there and goodbye."])
        #expect(rest.last?.isFinal == true)
    }

    @Test("Seams drop what the next window re-decoded", arguments: [
        ("my phone and my MacBook", DecodedWindow(text: "book", startsWord: false), "my phone and my MacBook"),
        ("my phone and my MacBook", DecodedWindow(text: "book and that's it.", startsWord: false), "my phone and my MacBook and that's it."),
        ("my phone and my MacBook", DecodedWindow(text: "Book is slow.", startsWord: true), "my phone and my MacBook is slow."),
        ("so they don't feel blind", DecodedWindow(text: "blindsided by it.", startsWord: true), "so they don't feel blindsided by it."),
        ("send it to Mac", DecodedWindow(text: "Book users.", startsWord: false), "send it to MacBook users."),
        ("I think.", DecodedWindow(text: "that's fair.", startsWord: true), "I think. that's fair."),
        ("over on the bill this quarter.", DecodedWindow(text: ", mostly because", startsWord: false), "over on the bill this quarter. mostly because"),
        ("send it to Mac", DecodedWindow(text: ", then", startsWord: false), "send it to Mac, then"),
        ("go to", DecodedWindow(text: "today's meeting", startsWord: true), "go to today's meeting"),
        ("", DecodedWindow(text: "First words", startsWord: true), "First words"),
    ])
    func seams(previous: String, window: DecodedWindow, expected: String) {
        #expect(IncrementalParakeetEngine.compose(previous, adding: window) == expected)
    }

    @Test("An empty recording yields one empty final chunk and never finishes the recognizer")
    func emptyRecording() async throws {
        let recognizer = ScriptedWindowRecognizer(windows: [], final: "hallucination")
        let engine = makeEngine(recognizer)
        let stream = try await engine.start()
        await engine.finish()
        var chunks: [TranscriptionChunk] = []
        for try await chunk in stream { chunks.append(chunk) }
        #expect(chunks.count == 1)
        #expect(chunks.first?.text == "")
        #expect(chunks.first?.isFinal == true)
        #expect(await recognizer.finishCalls == 0)
        #expect(await recognizer.cancelCalls == 1)
    }

    @Test("A failing finish surfaces as a stream error")
    func finishFailure() async throws {
        let recognizer = ScriptedWindowRecognizer(windows: [], final: "", failFinish: true)
        let engine = makeEngine(recognizer)
        let stream = try await engine.start()
        await engine.feed(try audioChunk())
        await engine.finish()
        var iterator = stream.makeAsyncIterator()
        await #expect(throws: WindowFailure.self) { try await iterator.next() }
    }

    @Test("Finish is safe before start and when repeated")
    func idempotentFinish() async {
        let engine = makeEngine(ScriptedWindowRecognizer(windows: [], final: ""))
        await engine.finish()
        await engine.finish()
    }

    @MainActor
    @Test("Transcribe timing persists and defaults to while speaking")
    func timingPersists() throws {
        let name = "murmur-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(Settings(defaults: defaults).transcribeTiming == .whileSpeaking)
        let settings = Settings(defaults: defaults)
        settings.transcribeTiming = .onRelease
        #expect(defaults.string(forKey: "transcribeTiming") == "onRelease")
        #expect(Settings(defaults: defaults).transcribeTiming == .onRelease)
        defaults.set("bogus", forKey: "transcribeTiming")
        #expect(Settings(defaults: defaults).transcribeTiming == .whileSpeaking)
    }

    private func makeEngine(_ recognizer: ScriptedWindowRecognizer) -> IncrementalParakeetEngine {
        IncrementalParakeetEngine(
            models: .shared,
            loadModels: { nil },
            makeRecognizer: { recognizer }
        )
    }

    private func audioChunk() throws -> AudioChunk {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 1_600)
        return AudioChunk(buffer: buffer)
    }
}

private struct WindowFailure: Error {}

private actor ScriptedWindowRecognizer: WindowedRecognizer {
    nonisolated let windows: AsyncStream<DecodedWindow>
    private let continuation: AsyncStream<DecodedWindow>.Continuation
    private var pending: [String]
    private let flushedAtFinish: [String]
    private let final: String
    private let failFinish: Bool
    private(set) var finishCalls = 0
    private(set) var cancelCalls = 0

    init(windows: [String], final: String, failFinish: Bool = false, flushedAtFinish: [String] = []) {
        (self.windows, continuation) = AsyncStream<DecodedWindow>.makeStream()
        pending = windows
        self.flushedAtFinish = flushedAtFinish
        self.final = final
        self.failFinish = failFinish
    }

    func load(_ models: AsrModels) async throws {}
    func start() async throws {}

    func stream(_ buffer: AVAudioPCMBuffer) async {
        if !pending.isEmpty { continuation.yield(DecodedWindow(text: pending.removeFirst())) }
    }

    func finish() async throws -> String {
        finishCalls += 1
        if failFinish { throw WindowFailure() }
        // Like the real recognizer: the flushed windows are reported, and the stream stays
        // open until `cancel()`.
        for text in flushedAtFinish { continuation.yield(DecodedWindow(text: text)) }
        return final
    }

    func cancel() async {
        cancelCalls += 1
        continuation.finish()
    }
}
