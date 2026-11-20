import AVFoundation
import FluidAudio
import Foundation

/// Production recognizer: decodes overlapping windows of the hold with Bark or Parakeet and
/// joins them on a word both windows agree on (`WindowSeam`).
///
/// Each window is two seconds of earlier audio, an eleven-second centre and two seconds of
/// later audio, fifteen seconds in all, which is the model's input size. It is decoded on its
/// own, exactly as the batch engine decodes a clip of that length, so a window's text depends
/// only on the samples in it and the result is the same however fast the audio arrived. At
/// release the audio left over, always between two and thirteen seconds once a window has
/// been decoded, goes into one last window with its two seconds of earlier audio.
///
/// This replaces FluidAudio's `SlidingWindowAsrManager`, which decodes each window to its
/// last sample, keeps that text, and removes the next window's copy of it as a duplicate.
/// The kept copy is the one cut off mid-word, so a word spanning the cut was typed as its
/// first half, a period and its second half: "inference.ringement", "act.tions",
/// "return.urning" (26 of them in 27 labelled runs, 2026-11-08 to 11-13). At release it
/// also cut a window at every eleven seconds of leftover audio with no later audio at all,
/// which put one of those in the last seconds of nearly every long hold.
actor OverlapWindowRecognizer: WindowedRecognizer {
    static let sampleRate = 16_000
    static let centreSamples = 11 * sampleRate
    static let contextSamples = 2 * sampleRate

    private var manager: AsrManager?
    private let converter = AudioConverter()

    private let input: AsyncStream<[Float]>
    private let inputContinuation: AsyncStream<[Float]>.Continuation
    nonisolated let windows: AsyncStream<DecodedWindow>
    private let output: AsyncStream<DecodedWindow>.Continuation
    private var worker: Task<Void, Never>?

    /// Every sample of the hold. A minute is under 4 MB, and the last window needs audio
    /// from before its centre.
    private var samples: [Float] = []
    /// Where the next window's centre starts.
    private var centre = 0
    /// Words of the last decoded window that the next one may still replace.
    private var pending: [TimedWord] = []
    /// Where the last settled word ended.
    private var settledEnd: TimeInterval = 0
    private var settledText: [String] = []
    /// A window that failed during the hold is decoded again at release rather than skipped.
    private var stalled = false

    /// Whether the last window is decoded early, at a pause (see `anticipate`).
    private let anticipatesRelease: Bool
    /// The loudness (RMS) of every 20 ms of the hold so far.
    private var levels: [Float] = []
    /// The loudest level of the quietest 0.2 s of the hold so far: what the room sounds like.
    private var quietestStretch = Float.infinity
    /// The last window as it stood at the latest pause: decoded as if the key had come up
    /// there, and used at release if nothing but silence followed.
    private var anticipated: (centre: Int, end: Int, words: [TimedWord])?
    /// Whether release reused a decode made at a pause. For the check tool and tests.
    private(set) var reusedAtRelease = false

    /// Decodes one window (its samples and where they start in the recording) into words on
    /// the recording's timeline. Tests script it; nil means the loaded model.
    typealias Decoder = @Sendable (_ window: [Float], _ startSample: Int) async throws -> [TimedWord]
    private let scriptedDecoder: Decoder?

    init(anticipatesRelease: Bool = true, decoder: Decoder? = nil) {
        self.anticipatesRelease = anticipatesRelease
        scriptedDecoder = decoder
        (input, inputContinuation) = AsyncStream<[Float]>.makeStream()
        (windows, output) = AsyncStream<DecodedWindow>.makeStream()
    }

    func load(_ models: AsrModels) async throws {
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    func start() async throws {
        guard manager != nil || scriptedDecoder != nil else { throw TranscriptionError.notRunning }
        worker = Task { [weak self, input] in
            for await buffer in input {
                await self?.append(buffer)
            }
        }
    }

    func stream(_ buffer: AVAudioPCMBuffer) async {
        // The engine asks capture for 16 kHz mono already; the converter passes that through
        // and covers any other format.
        do {
            inputContinuation.yield(try converter.resampleBuffer(buffer))
        } catch {
            Log.speech.error("windowed recognizer: audio conversion failed — \(error.localizedDescription)")
        }
    }

    func finish() async throws -> String {
        inputContinuation.finish()
        await worker?.value
        worker = nil
        try await decodeAvailable(final: true)
        return settledText.joined(separator: " ")
    }

    func cancel() async {
        inputContinuation.finish()
        worker?.cancel()
        output.finish()
    }

    private func append(_ buffer: [Float]) async {
        samples.append(contentsOf: buffer)
        guard !stalled else { return }
        do {
            try await decodeAvailable(final: false)
            try await anticipate()
        } catch {
            stalled = true
            Log.speech.error("windowed recognizer: window failed, retrying at release — \(error.localizedDescription)")
        }
    }

    /// Decodes every window the audio so far allows. While the key is held a window needs
    /// its two seconds of later audio; at release whatever is left becomes the last window.
    private func decodeAvailable(final: Bool) async throws {
        let full = Self.centreSamples + Self.contextSamples
        while true {
            let ahead = samples.count - centre
            let isLast = final && ahead <= full
            guard ahead > 0, isLast || ahead >= full else {
                // Nothing left to decode at release: whatever was held back is final.
                if final {
                    settle(pending)
                    pending = []
                }
                return
            }

            if isLast, let early = anticipated, early.centre == centre, isSilent(from: early.end) {
                // The key came up in the silence after the last pause: that decode is the text.
                reusedAtRelease = true
                anticipated = nil
                let silence = Double(samples.count - early.end) / Double(Self.sampleRate)
                Log.speech.info("windowed recognizer: release reused the decode made at the last pause (\(silence, format: .fixed(precision: 2))s of silence since)")
                centre += Self.centreSamples
                settle(early.words)
                pending = []
                return
            }

            let start = max(0, centre - Self.contextSamples)
            let end = isLast ? samples.count : centre + full
            let decoded = try await decode(start..<end)
            let boundary = TimeInterval(centre) / TimeInterval(Self.sampleRate)
            let joined = centre == 0 ? decoded
                : WindowSeam.join(pending, decoded, boundary: boundary, settledEnd: settledEnd)

            centre += Self.centreSamples
            if isLast {
                settle(joined)
                pending = []
                return
            }
            // Words that start within reach of the next boundary wait for the next window.
            let hold = TimeInterval(centre) / TimeInterval(Self.sampleRate) - WindowSeam.reach
            let firstHeld = joined.firstIndex { $0.start >= hold } ?? joined.endIndex
            settle(Array(joined[..<firstHeld]))
            pending = Array(joined[firstHeld...])
        }
    }

    // MARK: Decoding ahead of the release

    static let levelSamples = sampleRate / 50
    /// A pause this long starts the early decode: 0.26 s, thirteen levels.
    static let pauseLevels = 13
    static let stretchLevels = 10

    /// Decodes the last window at a pause, before the key comes up.
    ///
    /// A hold shorter than one window, and the tail of every longer one, used to be decoded
    /// only at release: 0.13 to 0.35 s of waiting that began when the key came up. But the
    /// key comes up after the talking stops, a median 0.50 s after across 81 recordings
    /// (three quarters of them 0.34 s or more). So when the audio has been quiet for a
    /// quarter of a second, the audio so far is decoded exactly as release would decode it.
    /// If the key then comes up with nothing but silence in between, that text is the
    /// result and release has no decode left to wait for. If speech resumes, the early
    /// decode is thrown away and the next pause makes another.
    private func anticipate() async throws {
        guard anticipatesRelease, samples.count > centre else { return }
        measureLevels()
        guard levels.count > Self.pauseLevels, let threshold = silenceThreshold() else { return }
        guard levels.suffix(Self.pauseLevels).allSatisfy({ $0 < threshold }) else { return }
        // Only when there is speech this window has not been decoded with yet.
        let windowStart = max(0, centre - Self.contextSamples)
        let covered = anticipated.flatMap { $0.centre == centre ? $0.end : nil } ?? windowStart
        guard levels[min(covered / Self.levelSamples, levels.count)...].contains(where: { $0 >= threshold }) else { return }

        let end = samples.count
        let decoded = try await decode(windowStart..<end)
        let boundary = TimeInterval(centre) / TimeInterval(Self.sampleRate)
        let joined = centre == 0 ? decoded
            : WindowSeam.join(pending, decoded, boundary: boundary, settledEnd: settledEnd)
        anticipated = (centre, end, joined)
    }

    private func measureLevels() {
        while (levels.count + 1) * Self.levelSamples <= samples.count {
            let start = levels.count * Self.levelSamples
            var sum: Float = 0
            for sample in samples[start..<start + Self.levelSamples] { sum += sample * sample }
            levels.append((sum / Float(Self.levelSamples)).squareRoot())
            if levels.count >= Self.stretchLevels, let peak = levels.suffix(Self.stretchLevels).max() {
                quietestStretch = min(quietestStretch, peak)
            }
        }
    }

    /// The level below which a 20 ms stretch is the room and not speech, or nil when this
    /// hold does not show the difference.
    ///
    /// The room is the quietest fifth of a second so far, taken at its loudest level. Speech
    /// is the hold's 95th percentile. Unless speech is ten times the room there is nothing to
    /// go on, and the early decode stays off: a 0.8 s recording whose speech was no louder
    /// than its noise once had its first 0.4 s decoded as the whole of it, and typed "Yeah."
    /// for "Okay." (2026-11-13). With that range the threshold is three times the room,
    /// never more than a tenth of the speech level. On 82 recordings 6 had no such range and
    /// 53 ended in a pause this rule could see.
    private func silenceThreshold() -> Float? {
        guard quietestStretch.isFinite, quietestStretch > 0 else { return nil }
        let loud = levels.sorted()[levels.count * 95 / 100]
        guard loud >= 10 * quietestStretch else { return nil }
        return min(3 * quietestStretch, 0.1 * loud)
    }

    /// Whether everything captured from `sample` on is silence.
    private func isSilent(from sample: Int) -> Bool {
        measureLevels()
        guard let threshold = silenceThreshold() else { return false }
        return levels[min(sample / Self.levelSamples, levels.count)...].allSatisfy { $0 < threshold }
    }

    private func settle(_ words: [TimedWord]) {
        guard !words.isEmpty else { return }
        settledEnd = words.last?.end ?? settledEnd
        let text = words.map(\.text).joined(separator: " ")
        settledText.append(text)
        output.yield(DecodedWindow(text: text))
    }

    /// One window decoded from a fresh decoder state, as words on the recording's timeline.
    private func decode(_ range: Range<Int>) async throws -> [TimedWord] {
        var window = Array(samples[range])
        if let scriptedDecoder { return try await scriptedDecoder(window, range.lowerBound) }
        guard let manager else { throw TranscriptionError.notRunning }
        // The model refuses less than 0.3 s; a tap that short is padded with silence.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: Self.sampleRate)
        if window.count < minimum {
            window.append(contentsOf: [Float](repeating: 0, count: minimum - window.count))
        }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(window, decoderState: &state)
        let offset = TimeInterval(range.lowerBound) / TimeInterval(Self.sampleRate)
        return Self.words(from: result.tokenTimings ?? [], offset: offset)
    }

    /// Token timings grouped into words. Bark's `<unk>` (its stand-in for a quotation mark)
    /// is dropped here so it never becomes a word of its own.
    nonisolated static func words(from timings: [TokenTiming], offset: TimeInterval) -> [TimedWord] {
        buildWordTimings(from: timings.filter { !$0.token.contains("<unk>") }).compactMap { word in
            let text = word.word.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return TimedWord(text: text, start: word.startTime + offset, end: word.endTime + offset)
        }
    }
}
