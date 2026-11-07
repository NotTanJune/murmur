import AVFoundation
import Foundation

struct ComparisonResult: Sendable {
    let engine: String
    let text: String
    let seconds: Double
}

/// Replays one recording through each engine in batch, so outputs and timings are
/// comparable even though Apple's engine streams in normal use.
///
/// The timings are not like for like. Apple, Parakeet and Bark are local compute times for
/// the same buffers fed back to back, with the clock started after model load. The replay is
/// not paced to real time, so the figures say how fast an engine finishes a recording that is
/// already complete, not how long a user waits after release. Wispr Flow's number is its own
/// end-to-end latency (network and cloud cleanup included) and belongs in no shared ranking.
///
/// Nothing here types, touches the pasteboard or runs the formatter: several transcripts
/// would fight over one text field.
enum EngineComparison {
    static func run(
        chunks: [AudioChunk],
        onResult: @MainActor (ComparisonResult) -> Void = { _ in }
    ) async -> [ComparisonResult] {
        var engines: [(name: String, engine: any TranscriptionEngine)] = [
            ("Apple", AppleSpeechEngine()),
            ("Parakeet", ParakeetEngine()),
        ]

        // Bark joins only when already loaded. Starting it here would put a download of about
        // 450 MB, or a Neural Engine compile of a minute or more, inside the run.
        if await ParakeetModels.barkClean.isLoaded {
            let decoder = await MainActor.run { Settings.shared.barkDecoder }
            if case .custom = decoder {
                engines.append(("Bark Clean (fine-tuned)", ParakeetEngine(models: .barkClean)))
                engines.append(("Bark Clean (stock)", ParakeetEngine(models: .stockBarkClean)))
            } else {
                engines.append(("Bark Clean", ParakeetEngine(models: .barkClean)))
            }
        }

        // One at a time: two engines sharing the Neural Engine and CPU would distort each
        // other's timings.
        var results: [ComparisonResult] = []
        for (name, engine) in engines {
            let result = await measure(name: name, engine: engine, chunks: chunks)
            results.append(result)
            await onResult(result)
        }
        return results
    }

    private static func failureText(_ error: Error) -> String {
        "\u{26A0}\u{FE0F} \(error.localizedDescription)"
    }

    private static func measure(
        name: String,
        engine: any TranscriptionEngine,
        chunks: [AudioChunk]
    ) async -> ComparisonResult {
        let stream: AsyncThrowingStream<TranscriptionChunk, Error>
        do {
            stream = try await engine.start()
        } catch {
            Log.speech.error("\(name, privacy: .public) failed to start: \(error.localizedDescription)")
            await engine.finish()
            return ComparisonResult(engine: name, text: failureText(error), seconds: 0)
        }

        // Start timing only now: `start()` loads models, and timing from before it would turn
        // whichever engine the menu had warmed into an apparent speed difference.
        let started = Date()

        // Reading begins before any audio is fed, since some engines emit their final chunk
        // inside `finish()`. Only a final chunk counts; a stream that ends without one is
        // empty text, never the last partial.
        let collector = Task { () -> String in
            var final = ""
            for try await chunk in stream where chunk.isFinal {
                final = chunk.text
            }
            return final
        }

        for chunk in chunks {
            await engine.feed(chunk)
        }
        await engine.finish()

        do {
            let text = try await collector.value
            return ComparisonResult(
                engine: name,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                seconds: Date().timeIntervalSince(started)
            )
        } catch {
            // A failed stream and a silent recording must not look alike.
            Log.speech.error("\(name, privacy: .public) failed: \(error.localizedDescription)")
            return ComparisonResult(
                engine: name,
                text: failureText(error),
                seconds: Date().timeIntervalSince(started)
            )
        }
    }
}
