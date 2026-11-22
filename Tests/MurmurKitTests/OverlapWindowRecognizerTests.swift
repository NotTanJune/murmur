import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import MurmurKit

struct OverlapWindowRecognizerTests {
    @Test("Token timings become words on the recording's timeline, without Bark's <unk>")
    func wordsFromTimings() {
        let timings = [
            TokenTiming(token: " He", tokenId: 1, startTime: 0.08, endTime: 0.16, confidence: 1),
            TokenTiming(token: "llo", tokenId: 2, startTime: 0.16, endTime: 0.32, confidence: 1),
            TokenTiming(token: ",", tokenId: 3, startTime: 0.32, endTime: 0.4, confidence: 1),
            TokenTiming(token: " <unk>", tokenId: 0, startTime: 0.4, endTime: 0.48, confidence: 1),
            TokenTiming(token: " there", tokenId: 4, startTime: 0.56, endTime: 0.8, confidence: 1),
        ]
        let words = OverlapWindowRecognizer.words(from: timings, offset: 9)
        #expect(words.map(\.text) == ["Hello,", "there"])
        #expect(abs((words.first?.start ?? 0) - 9.08) < 1e-9)
        #expect(abs((words.last?.end ?? 0) - 9.8) < 1e-9)
    }

    /// A recording of one word every half second, and a decoder that behaves as Bark does at
    /// a window's edges: the first word capitalised, and a period on the last word when the
    /// audio stops before the recording does.
    private actor ScriptedSpeech {
        let seconds: Int
        private(set) var requests: [Range<Int>] = []

        init(seconds: Int) { self.seconds = seconds }

        var transcript: String { (0..<seconds * 2).map { "w\($0)" }.joined(separator: " ") }

        func decode(_ window: [Float], _ startSample: Int) -> [TimedWord] {
            requests.append(startSample..<startSample + window.count)
            let from = Double(startSample) / 16_000
            let to = from + Double(window.count) / 16_000
            var words = (0..<seconds * 2).compactMap { index -> TimedWord? in
                let start = Double(index) * 0.5 + 0.1
                guard start >= from, start + 0.3 <= to else { return nil }
                return TimedWord(text: "w\(index)", start: start, end: start + 0.3)
            }
            if let first = words.first {
                words[0] = TimedWord(text: first.text.uppercased(), start: first.start, end: first.end)
            }
            if to < Double(seconds), let last = words.last {
                words[words.count - 1] = TimedWord(text: last.text + ".", start: last.start, end: last.end)
            }
            return words
        }
    }

    private func transcribe(_ speech: ScriptedSpeech) async throws -> (text: String, windows: Int) {
        let recognizer = OverlapWindowRecognizer { try await speech.decode($0, $1) }
        try await recognizer.start()
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        for _ in 0..<(await speech.seconds) {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            await recognizer.stream(buffer)
        }
        let whole = try await recognizer.finish()
        await recognizer.cancel()
        var pieces: [String] = []
        for await window in recognizer.windows { pieces.append(window.text) }
        #expect(pieces.joined(separator: " ") == whole)
        return (whole, pieces.count)
    }

    @Test("A long hold is decoded in overlapping windows and no edge of any window is kept")
    func overlappingWindows() async throws {
        let speech = ScriptedSpeech(seconds: 30)
        let result = try await transcribe(speech)
        // Only the recording's own first word keeps the capital the decoder gives a first word.
        #expect(result.text == "W0 " + (await speech.transcript).dropFirst(3))
        let second = 16_000
        #expect(await speech.requests == [0..<13 * second, 9 * second..<24 * second, 20 * second..<30 * second])
        #expect(result.windows == 3)
    }

    @Test("A hold shorter than one window is decoded once, whole, at release")
    func shortHold() async throws {
        let speech = ScriptedSpeech(seconds: 5)
        let result = try await transcribe(speech)
        #expect(result.text == "W0 " + (await speech.transcript).dropFirst(3))
        #expect(await speech.requests == [0..<5 * 16_000])
    }

    /// Records the windows asked for and answers each with one word naming its end, in
    /// tenths of a second.
    private actor WindowLog {
        private(set) var requests: [Range<Int>] = []

        func decode(_ window: [Float], _ startSample: Int) -> [TimedWord] {
            let range = startSample..<startSample + window.count
            requests.append(range)
            let end = Double(range.upperBound) / 16_000
            return [TimedWord(text: "to\(Int((end * 10).rounded()))", start: end - 0.5, end: end - 0.2)]
        }
    }

    /// Feeds tenths of a second: "S" is speech, "." is the room, "s" is speech no louder
    /// than three times the room.
    private func hold(_ pattern: String, into recognizer: OverlapWindowRecognizer) async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        for character in pattern {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
            buffer.frameLength = 1_600
            let level: Float = character == "S" ? 0.1 : (character == "s" ? 0.0003 : 0.0001)
            for index in 0..<1_600 { buffer.floatChannelData?[0][index] = level }
            // Sound for the reason `AudioChunk` is: the buffer is fresh and never touched again.
            nonisolated(unsafe) let handoff = buffer
            await recognizer.stream(handoff)
        }
    }

    @Test("A pause is decoded early, and a release in the silence after it decodes nothing more")
    func releaseAfterAPause() async throws {
        let log = WindowLog()
        let recognizer = OverlapWindowRecognizer { await log.decode($0, $1) }
        try await recognizer.start()
        // Two seconds of speech, then half a second of quiet before the key comes up.
        try await hold(String(repeating: "S", count: 20) + ".....", into: recognizer)
        let text = try await recognizer.finish()
        // Decoded once, 0.3 s into the quiet (thirteen 20 ms levels), not again at release.
        #expect(await log.requests == [0..<Int(2.3 * 16_000)])
        #expect(text == "to23")
        #expect(await recognizer.reusedAtRelease)
    }

    @Test("Speech after a pause discards the early decode, and release decodes everything")
    func speechAfterAPause() async throws {
        let log = WindowLog()
        let recognizer = OverlapWindowRecognizer { await log.decode($0, $1) }
        try await recognizer.start()
        try await hold(String(repeating: "S", count: 20) + "....." + "SSSSS", into: recognizer)
        let text = try await recognizer.finish()
        #expect(await log.requests == [0..<Int(2.3 * 16_000), 0..<Int(3.0 * 16_000)])
        #expect(text == "to30")
        #expect(await recognizer.reusedAtRelease == false)
    }

    @Test("With the early decode off, a pause costs nothing and release decodes once")
    func anticipationOff() async throws {
        let log = WindowLog()
        let recognizer = OverlapWindowRecognizer(anticipatesRelease: false) { await log.decode($0, $1) }
        try await recognizer.start()
        try await hold(String(repeating: "S", count: 20) + ".....", into: recognizer)
        let text = try await recognizer.finish()
        #expect(await log.requests == [0..<Int(2.5 * 16_000)])
        #expect(text == "to25")
    }

    @Test("A hold whose speech does not stand out from the room is never decoded early")
    func noRangeNoEarlyDecode() async throws {
        let log = WindowLog()
        let recognizer = OverlapWindowRecognizer { await log.decode($0, $1) }
        try await recognizer.start()
        // Quiet speech, a quiet gap, more quiet speech: 2026-11-13, "Okay." typed as "Yeah.".
        try await hold("...sssss.....sssss.....", into: recognizer)
        let text = try await recognizer.finish()
        #expect(await log.requests == [0..<Int(2.3 * 16_000)])
        #expect(text == "to23")
        #expect(await recognizer.reusedAtRelease == false)
    }
}

