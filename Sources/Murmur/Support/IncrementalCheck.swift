import AVFoundation
import Foundation
import Synchronization

/// `Murmur --incremental-check <audio-file> [--fast] [--no-anticipation]`: plays a recording through the
/// incremental Bark engine the way a hold would (16 kHz mono, 100 ms buffers), printing each
/// window as it lands, then the release tail, and the batch engine's text on the same audio
/// for comparison. Exercises the real windowed recognizer and the real model without a
/// microphone; what it cannot check is the hotkey or capture path. `--fast` feeds without
/// pacing: the text is the same, because a window's words depend only on its samples, but
/// every window then decodes at release and the tail time means nothing. `--no-anticipation`
/// turns off the decode at a pause, to compare its text with the ordinary release decode.
@MainActor
enum IncrementalCheck {
    static func run(path: String, paced: Bool = true, anticipating: Bool = true) async -> Bool {
        let started = Date()
        await StreamingModelPreparation.shared.load(.barkClean)?.value
        guard StreamingModelPreparation.shared.state(for: .barkClean) == .ready else {
            print("FAIL load: \(StreamingModelPreparation.shared.state(for: .barkClean).message)")
            return false
        }
        print(String(format: "Bark 3.0 Clean ready in %.2fs", Date().timeIntervalSince(started)))

        let chunks: [AudioChunk]
        do {
            chunks = try load(path)
        } catch {
            print("FAIL audio: \(error.localizedDescription)")
            return false
        }
        let seconds = Double(chunks.reduce(0) { $0 + Int($1.buffer.frameLength) }) / 16_000
        print(String(format: "%.1fs of audio in %d buffers", seconds, chunks.count))

        // Incremental: feed, watching partials, then finish.
        let made = Mutex<OverlapWindowRecognizer?>(nil)
        let incremental = IncrementalParakeetEngine(models: .barkClean, makeRecognizer: {
            let recognizer = OverlapWindowRecognizer(anticipatesRelease: anticipating)
            made.withLock { $0 = recognizer }
            return recognizer
        })
        let stream: AsyncThrowingStream<TranscriptionChunk, Error>
        do {
            stream = try await incremental.start()
        } catch {
            print("FAIL start: \(error.localizedDescription)")
            return false
        }
        let feedStart = Date()
        let printer = Task { @MainActor in
            var final: String?
            do {
                for try await chunk in stream {
                    if chunk.isFinal {
                        final = chunk.text
                    } else {
                        print(String(format: "  +%.1fs window: %@", Date().timeIntervalSince(feedStart), chunk.text.suffix(80).description))
                    }
                }
            } catch {
                print("FAIL stream: \(error.localizedDescription)")
            }
            return final
        }
        // Paced at twice real time: windows must have a chance to decode while audio is
        // still arriving, as they do during a hold. Feeding everything at once would push
        // every window into the release tail and measure nothing.
        for chunk in chunks {
            await incremental.feed(chunk)
            if paced { try? await Task.sleep(for: .milliseconds(50)) }
        }
        let fedIn = Date().timeIntervalSince(feedStart)
        let release = Date()
        await incremental.finish()
        let final = await printer.value
        let tail = Date().timeIntervalSince(release)
        let reused = await made.withLock { $0 }?.reusedAtRelease ?? false
        print(String(format: "incremental: fed over %.1fs (%@), release tail %.2fs, %@", fedIn, paced ? "2× real time" : "unpaced", tail,
                     reused ? "reused the decode made at the last pause" : "decoded at release"))
        print("  " + (final ?? "(none)"))

        // Batch, on identical audio.
        let batch = ParakeetEngine(models: .barkClean)
        var batchText = ""
        do {
            let batchStream = try await batch.start()
            for chunk in chunks { await batch.feed(chunk) }
            let batchRelease = Date()
            await batch.finish()
            for try await chunk in batchStream where chunk.isFinal { batchText = chunk.text }
            print(String(format: "batch: release to text %.2fs", Date().timeIntervalSince(batchRelease)))
            print("  " + batchText)
        } catch {
            print("batch failed: \(error.localizedDescription)")
        }

        let finalWords = (final ?? "").split(whereSeparator: \.isWhitespace).count
        let batchWords = batchText.split(whereSeparator: \.isWhitespace).count
        print("words: incremental \(finalWords), batch \(batchWords)")
        let passed = final.map { !$0.isEmpty } ?? false
        print(passed ? "PASS" : "FAIL")
        return passed
    }

    /// The file as 16 kHz mono float32 in 100 ms buffers, the shape capture delivers.
    static func load(_ path: String) throws -> [AudioChunk] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw TranscriptionError.noAudioFormat
        }
        let sourceFrames = AVAudioFrameCount(file.length)
        guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: sourceFrames) else {
            throw TranscriptionError.noAudioFormat
        }
        try file.read(into: source)
        let ratio = 16_000 / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(sourceFrames) * ratio) + 1_024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw TranscriptionError.noAudioFormat
        }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let conversionError { throw conversionError }

        var chunks: [AudioChunk] = []
        let step = 1_600
        var offset = 0
        let total = Int(converted.frameLength)
        guard let samples = converted.floatChannelData?[0] else { return [] }
        while offset < total {
            let count = min(step, total - offset)
            guard let piece = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(count)) else { break }
            piece.frameLength = AVAudioFrameCount(count)
            piece.floatChannelData?[0].update(from: samples + offset, count: count)
            chunks.append(AudioChunk(buffer: piece))
            offset += count
        }
        return chunks
    }
}
