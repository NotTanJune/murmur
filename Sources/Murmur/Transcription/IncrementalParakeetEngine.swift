import AVFoundation
import FluidAudio
import Foundation

/// A recognizer that decodes fixed windows of audio while it is still being fed.
///
/// The seam exists so the engine can be tested with a scripted fake; the production
/// conformer wraps FluidAudio's `SlidingWindowAsrManager`.
protocol WindowedRecognizer: Actor {
    func load(_ models: AsrModels) async throws
    func start() async throws
    func stream(_ buffer: AVAudioPCMBuffer) async
    /// Each decoded window as it lands, in order. Ends after `cancel()`.
    var windows: AsyncStream<DecodedWindow> { get }
    /// Flushes the audio not yet decoded; its windows arrive on `windows` first. The
    /// returned text is the recognizer's own join of every token, used only when no window
    /// was reported.
    func finish() async throws -> String
    func cancel() async
}

/// One decoded window of audio.
struct DecodedWindow: Sendable, Equatable {
    let text: String
    /// False when the window's first token continues the word the previous window ended on
    /// (no SentencePiece word boundary), so the texts glue rather than join with a space.
    let startsWord: Bool

    init(text: String, startsWord: Bool = true) {
        self.text = text
        self.startsWord = startsWord
    }
}

/// Parakeet / Bark decoded in 11 s windows during the hold, so release only processes the
/// trailing partial window. Uses the same already-loaded `AsrModels` as `ParakeetEngine`.
actor IncrementalParakeetEngine: TranscriptionEngine {
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

    init(
        models: ParakeetModels = .shared,
        loadModels: (@Sendable () async throws -> AsrModels?)? = nil,
        makeRecognizer: @escaping @Sendable () -> any WindowedRecognizer = { SlidingWindowRecognizer() }
    ) {
        self.models = models
        self.loadModels = loadModels ?? { try await models.loadedModels() }
        self.makeRecognizer = makeRecognizer
    }

    func preferredInputFormat() async -> AVAudioFormat? {
        // Same as the batch engine: the windowed manager expects 16 kHz mono Float32.
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
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

    func feed(_ chunk: AudioChunk) async {
        let buffer = chunk.buffer
        guard buffer.frameLength > 0, let recognizer else { return }
        // Sound for the reason `AudioChunk` is: the buffer is fresh and never touched again.
        nonisolated(unsafe) let handoff = buffer
        await recognizer.stream(handoff)
        sampleCount += Int(buffer.frameLength)
    }

    func finish() async {
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
        composed = Self.compose(composed, adding: DecodedWindow(text: cleaned, startsWord: window.startsWord))
        guard !finishing else { return }
        continuation?.yield(TranscriptionChunk(text: composed, isFinal: false, stable: composed))
    }

    /// Joins the next window onto the transcript, removing what the seam re-decoded.
    ///
    /// Each window is decoded with two seconds of the previous one as context, and the
    /// recognizer drops tokens it has already emitted by their timestamps. Near a boundary the
    /// timing is loose enough that the last word sometimes comes back: "MacBook" + "book",
    /// glued because the token had no word boundary, typed "MacBookbook"; "blind" +
    /// "blindsided" when the first window ended mid-word. Three narrow rules at the seam only:
    ///
    /// 1. A glued fragment that equals the end of the previous word is the previous word's
    ///    ending again: dropped.
    /// 2. A first word equal to the last word, or to its ending ("MacBook" then "Book"),
    ///    ignoring case and punctuation: dropped.
    /// 3. A last word of four or more letters that is a prefix of the first word is a cut-off
    ///    start of that word: the cut-off is dropped.
    nonisolated static func compose(_ text: String, adding window: DecodedWindow) -> String {
        let addition = window.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return text }
        guard !text.isEmpty else { return addition }

        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var incoming = addition.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let last = words.last, let first = incoming.first else { return text }
        let lastCore = core(last)
        let firstCore = core(first)

        if !window.startsWord {
            // Rule 1: the fragment repeats the ending of the word it would extend, or is
            // punctuation landing on a word that already has some ("quarter." + ",").
            let repeatsEnding = !firstCore.isEmpty && lastCore.lowercased().hasSuffix(firstCore.lowercased())
            let doublesPunctuation = firstCore.isEmpty && last != lastCore
            if repeatsEnding || doublesPunctuation {
                incoming.removeFirst()
                return incoming.isEmpty ? text : text + " " + incoming.joined(separator: " ")
            }
            return text + addition
        }

        if !lastCore.isEmpty, firstCore.count >= 3 || firstCore.lowercased() == lastCore.lowercased(),
           lastCore.lowercased().hasSuffix(firstCore.lowercased()) {
            // Rule 2. Keep the earlier copy: it carries any punctuation the sentence needs.
            incoming.removeFirst()
        } else if lastCore.count >= 4, firstCore.count > lastCore.count,
                  firstCore.lowercased().hasPrefix(lastCore.lowercased()),
                  last == lastCore {
            // Rule 3, only when the cut-off word carries no punctuation of its own.
            words.removeLast()
        }
        return (words + incoming).joined(separator: " ")
    }

    /// The word without surrounding punctuation.
    private nonisolated static func core(_ word: String) -> String {
        word.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }
}

/// Production recognizer: one single-use `SlidingWindowAsrManager` per recording.
/// Always loaded with caller-supplied models; the no-argument `loadModels()` would download
/// NVIDIA's weights over Bark's.
actor SlidingWindowRecognizer: WindowedRecognizer {
    private let manager = SlidingWindowAsrManager(config: .default)
    private var updates: AsyncStream<DecodedWindow>?
    private var vocabulary: [Int: String] = [:]

    func load(_ models: AsrModels) async throws {
        vocabulary = models.vocabulary
        try await manager.loadModels(models)
    }

    func start() async throws {
        // Subscribing registers the update continuation, so do it before audio flows.
        let source = await manager.transcriptionUpdates
        let vocabulary = self.vocabulary
        updates = AsyncStream<DecodedWindow> { continuation in
            let task = Task {
                for await update in source {
                    // A token that starts a word carries the boundary marker: SentencePiece's
                    // "▁", or a leading space in the vocabulary Bark and Parakeet v3 ship.
                    // FluidAudio accepts both; so does this. A first token without one
                    // continues the previous window's last word.
                    let firstToken = update.tokenIds.first.flatMap { vocabulary[$0] }
                    let startsWord = firstToken.map {
                        $0.hasPrefix(ASRConstants.sentencePieceWordBoundary) || $0.hasPrefix(" ")
                    } ?? true
                    continuation.yield(DecodedWindow(text: update.text, startsWord: startsWord))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        try await manager.startStreaming(source: .microphone)
    }

    func stream(_ buffer: AVAudioPCMBuffer) async {
        // Awaited so buffers reach the manager in the order they were captured.
        nonisolated(unsafe) let buffer = buffer
        await manager.streamAudio(buffer)
    }

    var windows: AsyncStream<DecodedWindow> { updates ?? AsyncStream { $0.finish() } }

    func finish() async throws -> String { try await manager.finish() }
    func cancel() async { await manager.cancel() }
}
