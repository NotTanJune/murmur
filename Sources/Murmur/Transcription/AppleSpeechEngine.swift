import MurmurDictionary
import AVFoundation
import Foundation
import Speech

/// Streaming on-device transcription via macOS 26's `SpeechAnalyzer` / `SpeechTranscriber`.
///
/// No model ships with the app — the OS downloads and manages the assets, so the first
/// run for a given locale may block briefly while `AssetInstallationRequest` completes.
actor AppleSpeechEngine: TranscriptionEngine {
    private let locale: Locale

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// Text the engine has committed. Volatile results are appended on top for display
    /// but discarded as soon as a final result covering the same range arrives.
    private var finalizedText = ""
    private var firstAudioAt: Date?
    private var firstResultLogged = false

    init(locale: Locale = Locale.current) {
        self.locale = locale
    }

    func preferredInputFormat() async -> AVAudioFormat? {
        // The answer depends only on the module configuration, and the capture start waits
        // for it on every press, so ask the analyzer once per locale.
        let key = locale.identifier
        if let cached = Self.formatCache.format(for: key) { return cached }
        let module = transcriber ?? Self.makeTranscriber(locale: locale)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        if let format { Self.formatCache.store(format, for: key) }
        return format
    }

    private static let formatCache = FormatCache()

    private final class FormatCache: @unchecked Sendable {
        private let lock = NSLock()
        private var formats: [String: AVAudioFormat] = [:]

        func format(for key: String) -> AVAudioFormat? {
            lock.lock()
            defer { lock.unlock() }
            return formats[key]
        }

        func store(_ format: AVAudioFormat, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            formats[key] = format
        }
    }

    /// Installs the OS-managed speech asset ahead of the first recording. Analyzer startup
    /// still happens per utterance, but a first-use asset download no longer sits on the
    /// push-to-talk path.
    static func prewarm() async {
        guard SpeechTranscriber.isAvailable else { return }

        let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            ?? Locale(identifier: "en-US")
        let transcriber = Self.makeTranscriber(locale: resolvedLocale)

        do {
            try await Self.ensureModelInstalled(for: transcriber)
            // Format selection has its own first-use setup cost. Warm it with the same
            // module configuration used by each utterance so it does not sit between the
            // key press and `AudioCapture.start()` on the first recording.
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            if format == nil {
                Log.speech.error("Apple speech input format prewarm unavailable for \(resolvedLocale.identifier)")
            } else {
                Log.speech.info("Apple speech model and input format ready for \(resolvedLocale.identifier)")
            }
        } catch {
            Log.speech.error("Apple speech prewarm failed: \(error.localizedDescription)")
        }
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        let startedAt = Date()
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.localeUnsupported(locale)
        }

        let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
            ?? Locale(identifier: "en-US")

        let transcriber = Self.makeTranscriber(locale: resolvedLocale)
        self.transcriber = transcriber

        try await Self.ensureModelInstalled(for: transcriber)

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputContinuation

        // Bias the recognizer toward the dictionary's words before it hears anything. This
        // is a nudge, not a guarantee — `DictionaryCorrector` is the pass that actually
        // enforces spelling — but it's free and it catches things a post-hoc rewrite can't,
        // like a name the engine would otherwise split into two ordinary words.
        //
        // The list is capped at `DictionaryCorrector.biasLimit`. A long context list makes
        // these models drift: on quiet or ambiguous audio they start emitting the terms they
        // were primed with, which is a far worse failure than the misspelling it prevents.
        // Only the input-sequence initializers take a context up front, and this analyzer is
        // fed by `analyzer.start(inputSequence:)` later — so the context is applied here
        // instead. It must be set before any audio arrives to affect recognition.
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        if let context = await Self.context() {
            try? await analyzer.setContext(context)
        }

        finalizedText = ""
        firstAudioAt = nil
        firstResultLogged = false

        let (chunks, chunkContinuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()

        // Drain the transcriber's results into our simpler chunk stream.
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { break }
                    let snapshot = await self.absorb(result)
                    chunkContinuation.yield(TranscriptionChunk(text: snapshot, isFinal: false))
                }
                let final = await self?.finalizedText ?? ""
                chunkContinuation.yield(TranscriptionChunk(text: final, isFinal: true))
                chunkContinuation.finish()
            } catch {
                Log.speech.error("results stream failed: \(error.localizedDescription)")
                chunkContinuation.finish(throwing: error)
            }
        }

        try await analyzer.start(inputSequence: inputStream)
        Log.speech.info(
            "SpeechAnalyzer started for \(resolvedLocale.identifier) — setup \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 3))s"
        )

        return chunks
    }

    func feed(_ chunk: AudioChunk) async {
        if firstAudioAt == nil {
            firstAudioAt = Date()
        }
        inputContinuation?.yield(AnalyzerInput(buffer: chunk.buffer))
    }

    func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil

        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.speech.error("finalize failed: \(error.localizedDescription)")
            await analyzer?.cancelAndFinishNow()
        }

        analyzer = nil
        transcriber = nil
        resultsTask = nil
    }

    // MARK: - Result accumulation

    /// Folds one result into the running transcript and returns the full text to display.
    ///
    /// Final results are committed; a volatile result is shown appended to the committed
    /// text but never stored, so the next revision replaces it cleanly.
    private func absorb(_ result: SpeechTranscriber.Result) -> String {
        let text = String(result.text.characters)
        if !firstResultLogged, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            firstResultLogged = true
            if let firstAudioAt {
                Log.performance.info(
                    "Apple first transcription result \(Date().timeIntervalSince(firstAudioAt), format: .fixed(precision: 3))s after first audio"
                )
            } else {
                Log.performance.info("Apple transcription result arrived before audio")
            }
        }
        guard result.isFinal else {
            return (finalizedText + text).trimmingCharacters(in: .whitespaces)
        }
        finalizedText += text
        return finalizedText.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Setup helpers

    /// The dictionary's words, handed to the analyzer as contextual strings.
    ///
    /// Reads the store on the main actor because that's where it lives; the resulting array
    /// of strings is plain value data and crosses back safely.
    /// - Returns: nil when the dictionary is empty, so an empty context is never set for
    ///   nothing.
    ///
    /// Hops to the main actor rather than asserting it. The store is main-actor isolated and
    /// this runs on the engine's own executor — `MainActor.assumeIsolated` here doesn't check
    /// that claim, it asserts it, and takes the whole process down when it's false.
    private static func context() async -> AnalysisContext? {
        let phrases = await MainActor.run { DictionaryStore.shared.biasPhrases }
        guard !phrases.isEmpty else { return nil }

        let context = AnalysisContext()
        context.contextualStrings[.general] = phrases
        Log.speech.info("biasing with \(phrases.count, privacy: .public) dictionary phrase(s)")
        return context
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // `.volatileResults` is what makes live text appear while you're still talking.
            // `.fastResults` trades some recognition accuracy for earlier revisions, which
            // is the right trade for a push-to-talk HUD that must feel immediate.
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    private static func ensureModelInstalled(for transcriber: SpeechTranscriber) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let selected = transcriber.selectedLocales
        let alreadyThere = selected.allSatisfy { locale in
            installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        }
        guard !alreadyThere else { return }

        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                Log.speech.info("downloading speech model…")
                try await request.downloadAndInstall()
                Log.speech.info("speech model installed")
            }
        } catch {
            throw TranscriptionError.modelInstallFailed(error.localizedDescription)
        }
    }
}
