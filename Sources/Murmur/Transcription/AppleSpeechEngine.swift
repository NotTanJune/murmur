import MurmurDictionary
import AVFoundation
import Foundation
import Speech

/// Streams on-device transcription through macOS 26's `SpeechAnalyzer` and
/// `SpeechTranscriber`. Murmur bundles no model: the OS owns the speech assets, so the
/// first run for a locale may wait on an asset installation request.
actor AppleSpeechEngine: TranscriptionEngine {
    private let locale: Locale
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    /// What the engine has committed so far. A pending volatile result is shown on top of
    /// it for display only, and a final result covering the same range replaces that
    /// volatile text.
    private var committedText = ""
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
        // Same module configuration either way, so the format is the same. A throwaway
        // transcriber here installs and starts nothing.
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

        // May download. The controller buffers audio while this runs.
        try await Self.ensureModelInstalled(for: transcriber)

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputContinuation
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Biasing only raises the odds of the right spelling; `DictionaryCorrector` stays the
        // authority, but a bias still catches terms the recognizer would otherwise split into
        // common words. The list is capped at `DictionaryCorrector.biasLimit` (applied inside
        // `DictionaryStore.biasPhrases`) because a long list makes these models drift and emit
        // the primed terms on quiet or ambiguous audio, which is worse than the misspelling it
        // prevents. The context goes on after construction because `start(inputSequence:)`
        // takes none.
        if let context = await Self.dictionaryContext() {
            try? await analyzer.setContext(context)
        }
        committedText = ""
        firstAudioAt = nil
        firstResultLogged = false

        let (chunks, output) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { break }
                    let snapshot = await self.accumulate(result)
                    output.yield(TranscriptionChunk(text: snapshot, isFinal: false))
                }
                // Committed text only; a pending volatile tail is never promoted.
                let finalText = await self?.committedText ?? ""
                output.yield(TranscriptionChunk(text: finalText, isFinal: true))
                output.finish()
            } catch {
                Log.speech.error("Apple speech results failed: \(error.localizedDescription)")
                output.finish(throwing: error)
            }
        }

        do {
            try await analyzer.start(inputSequence: inputStream)
        } catch {
            resultsTask?.cancel()
            resultsTask = nil
            inputContinuation.finish()
            self.inputContinuation = nil
            self.analyzer = nil
            self.transcriber = nil
            throw error
        }
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
            Log.speech.error("Apple speech finalize failed: \(error.localizedDescription)")
            await analyzer?.cancelAndFinishNow()
        }
        analyzer = nil
        transcriber = nil
        // The results task is left alone: it ends with the results sequence, after yielding
        // the final chunk.
        resultsTask = nil
    }

    /// Final results extend the stored transcript. A volatile result changes only the
    /// returned text, so a later revision supersedes it.
    private func accumulate(_ result: SpeechTranscriber.Result) -> String {
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
        if !result.isFinal {
            return (committedText + text).trimmingCharacters(in: .whitespaces)
        }
        // Apple's final text carries its own spacing, so nothing is inserted between pieces.
        committedText += text
        return committedText.trimmingCharacters(in: .whitespaces)
    }

    private static func dictionaryContext() async -> AnalysisContext? {
        // Runs on the engine's executor, so the main-actor hop must be a real one.
        let phrases = await MainActor.run { DictionaryStore.shared.biasPhrases }
        guard !phrases.isEmpty else { return nil }
        let context = AnalysisContext()
        context.contextualStrings[.general] = phrases
        Log.speech.info("Apple speech biased with \(phrases.count, privacy: .public) dictionary phrases")
        return context
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // `.volatileResults` is what produces live text during the hold.
            // `.fastResults` trades some recognition accuracy for earlier revisions, which
            // is the right trade for a push-to-talk HUD that must feel immediate.
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    private static func ensureModelInstalled(for transcriber: SpeechTranscriber) async throws {
        let installed = await SpeechTranscriber.installedLocales
        let installedIDs = Set(installed.map { $0.identifier(.bcp47) })
        if transcriber.selectedLocales.allSatisfy({ installedIDs.contains($0.identifier(.bcp47)) }) {
            return
        }
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
            Log.speech.info("Downloading Apple speech model")
            try await request.downloadAndInstall()
            Log.speech.info("Apple speech model installed")
        } catch {
            throw TranscriptionError.modelInstallFailed(error.localizedDescription)
        }
    }
}
