import Foundation
import Testing
@testable import MurmurDesign

/// Synthetic levels at the model's own frame rate, so every time below is exact.
private struct Feeder {
    var model = VoiceTraceModel()
    var time: TimeInterval = 1_000
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

    /// Deterministic jitter in -1...1.
    private mutating func jitter() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 33) / Double(1 << 30) - 1
    }

    /// `seconds` of frames at `dB` (plus up to `wobble` dB either way), one level per frame.
    mutating func hold(_ dB: Double, seconds: Double, wobble: Double = 0) {
        let frames = Int((seconds / model.parameters.frameSeconds).rounded())
        for _ in 0..<frames {
            time += model.parameters.frameSeconds
            let level = dB + wobble * jitter()
            model.ingest(rms: Float(pow(10, level / 20)), at: time)
        }
    }

    /// Speech as words: `on` seconds loud, `off` seconds of room, repeated.
    mutating func words(loud: Double, room: Double, count: Int, on: Double = 0.35, off: Double = 0.2) {
        for _ in 0..<count {
            hold(loud, seconds: on, wobble: 3)
            hold(room, seconds: off, wobble: 1.5)
        }
    }

    /// The largest value the trace has shown at its centre over the next `seconds` of `dB`.
    mutating func peak(of dB: Double, seconds: Double) -> Float {
        var highest: Float = 0
        let frames = Int((seconds / model.parameters.frameSeconds).rounded())
        for _ in 0..<frames {
            hold(dB, seconds: model.parameters.frameSeconds)
            highest = max(highest, model.current)
        }
        return highest
    }
}

struct VoiceTraceModelTests {
    @Test("A whisper and a shout reach about the same height")
    func whisperAndShoutAgree() {
        var whisper = Feeder()
        whisper.hold(-75, seconds: 0.6, wobble: 1.5)
        whisper.words(loud: -50, room: -75, count: 4)
        let whisperPeak = whisper.peak(of: -50, seconds: 0.3)

        var shout = Feeder()
        shout.hold(-75, seconds: 0.6, wobble: 1.5)
        shout.words(loud: -12, room: -75, count: 4)
        let shoutPeak = shout.peak(of: -12, seconds: 0.3)

        #expect(whisperPeak > 0.75)
        #expect(shoutPeak > 0.75)
        #expect(abs(whisperPeak - shoutPeak) < 0.1)
    }

    @Test("A quiet speaker in a noisy room still fills the height")
    func noisyRoomIsLearned() {
        var feeder = Feeder()
        feeder.hold(-45, seconds: 0.8, wobble: 1.5)
        feeder.words(loud: -20, room: -45, count: 5)
        let peak = feeder.peak(of: -20, seconds: 0.3)
        #expect(peak > 0.75)
        // The room itself reads as nothing.
        feeder.hold(-45, seconds: 1.5, wobble: 1.5)
        #expect(feeder.model.current < 0.05)
    }

    @Test("A silent room stays at zero from the first frame")
    func silenceStaysFlat() {
        var feeder = Feeder()
        var highest: Float = 0
        for _ in 0..<400 {
            feeder.hold(-78, seconds: 0.01, wobble: 2)
            highest = max(highest, feeder.model.current)
        }
        #expect(highest < 0.1)
    }

    @Test("Digital silence is not read as a very quiet room")
    func digitalSilenceDoesNotAmplify() {
        var feeder = Feeder()
        feeder.hold(-100, seconds: 1)
        // A tick at -60 dBFS is under the quietest speech the model expects.
        var highest: Float = 0
        for _ in 0..<5 {
            feeder.hold(-60, seconds: 0.01)
            highest = max(highest, feeder.model.current)
        }
        #expect(highest < 0.6)
    }

    @Test("After speech, the room goes back to near zero and stays there")
    func silenceAfterSpeech() {
        var feeder = Feeder()
        feeder.hold(-75, seconds: 0.5, wobble: 1.5)
        feeder.words(loud: -20, room: -75, count: 5)
        feeder.hold(-75, seconds: 3, wobble: 1.5)
        #expect(feeder.model.current < 0.05)
        feeder.hold(-75, seconds: 4, wobble: 1.5)
        #expect(feeder.model.current < 0.05)
    }

    @Test("A step up reaches 90% in about 35 ms")
    func attackTakesAboutThirtyFiveMilliseconds() {
        var parameters = VoiceTraceModel.Parameters()
        parameters.onsetRise = 5
        var feeder = Feeder(model: VoiceTraceModel(parameters: parameters))
        feeder.hold(-75, seconds: 1, wobble: 1.5)
        let target = Float(parameters.bodyCeiling)
        var elapsed = 0.0
        var reached: Double?
        while elapsed < 0.3, reached == nil {
            feeder.hold(-20, seconds: 0.01)
            elapsed += 0.01
            if feeder.model.current >= target * 0.9 { reached = elapsed }
        }
        let time = reached ?? 9
        #expect(time >= 0.03 && time <= 0.045)
    }

    @Test("A step down falls 90% in about 95 ms")
    func releaseTakesAboutNinetyFiveMilliseconds() {
        var parameters = VoiceTraceModel.Parameters()
        parameters.onsetRise = 5
        var feeder = Feeder(model: VoiceTraceModel(parameters: parameters))
        feeder.hold(-75, seconds: 1, wobble: 1.5)
        feeder.hold(-20, seconds: 1)
        let start = feeder.model.current
        #expect(start > 0.75)
        var elapsed = 0.0
        var halved: Double?
        var tenth: Double?
        while elapsed < 0.5 {
            feeder.hold(-75, seconds: 0.01)
            elapsed += 0.01
            if halved == nil, feeder.model.current < start * 0.5 { halved = elapsed }
            if tenth == nil, feeder.model.current < start * 0.1 { tenth = elapsed; break }
        }
        let half = halved ?? 9
        let ten = tenth ?? 9
        #expect(half >= 0.02 && half <= 0.045)
        #expect(ten >= 0.08 && ten <= 0.115)
    }

    @Test("An onset springs past the steady level, dips under it, and settles within 0.4 s")
    func onsetSpringOvershootsAndSettles() {
        var feeder = Feeder()
        feeder.hold(-75, seconds: 0.6, wobble: 1.5)
        let steady = Float(feeder.model.parameters.bodyCeiling)
        var series: [Float] = []
        for _ in 0..<60 {
            feeder.hold(-20, seconds: feeder.model.parameters.frameSeconds)
            series.append(feeder.model.current)
        }
        let top = series.max() ?? 0
        let peakIndex = series.firstIndex(of: top) ?? 0
        #expect(top > steady + 0.08, "overshoot")
        #expect(top <= 1)
        // After the peak it goes under the steady level, then rings back up and settles.
        let afterPeak = series[peakIndex...]
        #expect((afterPeak.min() ?? 1) < steady - 0.03, "undershoot")
        let tail = series[40...]
        #expect(tail.allSatisfy { abs($0 - steady) < 0.02 }, "settled by 0.4 s")
        // Its first peak is about as soon as the envelope's own rise, not seconds later.
        #expect(peakIndex <= 8)
    }

    @Test("Two words a little apart each get their own kick")
    func eachWordKicksTheSpring() {
        var feeder = Feeder()
        feeder.hold(-75, seconds: 0.6, wobble: 1.5)
        var peaks: [Float] = []
        for _ in 0..<2 {
            peaks.append(feeder.peak(of: -20, seconds: 0.3))
            feeder.hold(-75, seconds: 0.4, wobble: 1.5)
        }
        let steady = Float(feeder.model.parameters.bodyCeiling)
        #expect(peaks.allSatisfy { $0 > steady + 0.08 })
    }

    @Test("A word after a dip adds an overshoot above the steady level")
    func onsetAddsOvershoot() {
        func highest(onsets: Bool) -> Float {
            var parameters = VoiceTraceModel.Parameters()
            if !onsets { parameters.onsetRise = 5 }
            var feeder = Feeder(model: VoiceTraceModel(parameters: parameters))
            feeder.hold(-75, seconds: 0.6, wobble: 1.5)
            feeder.hold(-20, seconds: 0.5)
            feeder.hold(-75, seconds: 0.4, wobble: 1.5)
            return feeder.peak(of: -20, seconds: 0.3)
        }
        let with = highest(onsets: true)
        let without = highest(onsets: false)
        #expect(without <= Float(VoiceTraceModel.Parameters().bodyCeiling) + 0.001)
        #expect(with > without + 0.1)
        #expect(with <= 1)
    }

    @Test("A sustained sound kicks once, not a stream of times")
    func sustainedSoundDoesNotKickAgain() {
        var feeder = Feeder()
        feeder.hold(-75, seconds: 0.6, wobble: 1.5)
        feeder.hold(-20, seconds: 0.2)
        feeder.hold(-20, seconds: 1)
        #expect(feeder.model.current <= Float(feeder.model.parameters.bodyCeiling) + 0.001)
    }

    @Test("Older values sit further out as time passes")
    func historyMovesOutward() {
        var feeder = Feeder()
        feeder.hold(-75, seconds: 0.6, wobble: 1.5)
        feeder.hold(-20, seconds: 0.12)
        feeder.hold(-75, seconds: 0.2, wobble: 1.5)

        func ageOfPeak(at time: TimeInterval) -> Double {
            let trace = feeder.model.trace(points: 180, at: time)
            let index = trace.indices.max { trace[$0] < trace[$1] } ?? 0
            return Double(index) / 180 * feeder.model.parameters.historySeconds
        }

        let first = ageOfPeak(at: feeder.time)
        #expect(first > 0.1 && first < 0.5)
        // 0.5 s later with no new frames: the word has moved out by the same amount.
        let later = ageOfPeak(at: feeder.time + 0.5)
        #expect(abs((later - first) - 0.5) < 0.03)
        // And it leaves once it is older than the history.
        let gone = feeder.model.trace(points: 40, at: feeder.time + 3)
        #expect(gone.allSatisfy { $0 < 0.001 })
    }

    @Test("A stalled feed does not hold its last level")
    func stalledFeedDecays() {
        var feeder = Feeder()
        feeder.hold(-75, seconds: 0.5, wobble: 1.5)
        feeder.hold(-20, seconds: 0.5)
        let now = feeder.model.value(age: 0, at: feeder.time)
        #expect(now > 0.75)
        // Within a block's wait the middle holds; a second later it is gone.
        #expect(feeder.model.value(age: 0, at: feeder.time + 0.04) == now)
        #expect(feeder.model.value(age: 0, at: feeder.time + 1) < 0.01)
    }

    @Test("A pause keeps showing the last words, fading by age in the view")
    func pauseKeepsLastWords() {
        var feeder = Feeder()
        feeder.hold(-75, seconds: 0.6, wobble: 1.5)
        feeder.words(loud: -20, room: -75, count: 3)
        feeder.hold(-75, seconds: 1, wobble: 1.5)
        let trace = feeder.model.trace(points: 40, at: feeder.time)
        #expect(trace[0] < 0.05)
        #expect((trace.max() ?? 0) > 0.7)
    }

    @Test("A 2048 sample block at 48 kHz becomes four frames, and 16 kHz thirteen")
    func blocksSplitIntoFrames() {
        var model = VoiceTraceModel()
        model.ingest(samples: [Float](repeating: 0.1, count: 2048), rate: 48_000, at: 10)
        #expect(model.frameCount == 4)
        #expect(abs(model.lastDecibels - -20) < 0.01)
        model.reset()
        model.ingest(samples: [Float](repeating: 0.1, count: 2048), rate: 16_000, at: 10)
        #expect(model.frameCount == 13)
    }

    @Test("A level report covers the frames since the last one")
    func levelsFillGaps() {
        var model = VoiceTraceModel()
        model.ingest(rms: 0.01, at: 5)
        #expect(model.frameCount == 1)
        model.ingest(rms: 0.01, at: 5.033)
        #expect(model.frameCount == 4)
        // A long silence of reports does not loop for more frames than the history holds.
        model.ingest(rms: 0.01, at: 500)
        #expect(model.frameCount <= 4 + 181)
    }

    @Test("Block input is equivalent to frame input for the same audio")
    func blocksMatchFrames() {
        var blocks = VoiceTraceModel()
        var time: TimeInterval = 50
        // Room, then a tone: 4.096 blocks of 48 kHz audio, 23 a second.
        for block in 0..<60 {
            let amplitude: Float = block < 20 ? 0.0003 : 0.2
            let samples = (0..<2048).map { amplitude * sin(Float($0) * 0.3) }
            time += 2048.0 / 48_000
            blocks.ingest(samples: samples, rate: 48_000, at: time)
        }
        #expect(blocks.current > 0.75)
    }
}
