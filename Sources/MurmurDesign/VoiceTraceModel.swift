import Foundation

/// The signal behind the listening trace: levels in, a short history of a 0...1 envelope out.
/// No SwiftUI and no clock of its own; callers pass the time each block arrived, so every
/// behaviour can be tested with synthetic audio.
///
/// What it does, in the order a frame goes through it:
/// 1. **Frames.** Audio is cut into frames of about 10 ms and each is reduced to its RMS in dB.
///    A phone block of 2048 samples arrives about 23 times a second, so it becomes four or more
///    frames; a level without samples (the Mac's) is repeated for the frames since the last one.
/// 2. **The room.** A noise floor falls quickly to a quieter frame and rises only slowly, and a
///    speech peak jumps to a louder frame and decays over seconds. A frame maps between them to
///    0...1, so a whisper and a shout both fill the height. The range between floor and peak
///    never shrinks below `minimumRangeDB`, and the floor never goes below `floorLimitDB`, so a
///    silent room is not amplified into motion (the same idea as the anticipation rule in
///    `OverlapWindowRecognizer`, which wants a tenfold range before it trusts the audio).
/// 3. **Envelope.** It jumps to a louder frame at once and eases down over `releaseSeconds`.
/// 4. **Onsets.** A frame that rises sharply out of a dip in the last 150 ms adds a short bump,
///    so each word or syllable shows as its own peak. The body of the trace is scaled to leave
///    headroom for it.
/// 5. **History.** Each frame's value goes into a ring of `historySeconds`. The view reads it by
///    age, newest in the middle and older values towards both edges.
public struct VoiceTraceModel: Sendable {
    public struct Parameters: Sendable {
        /// Length of one frame. The history ring has one slot per frame.
        public var frameSeconds = 0.01
        /// How much of the past the trace shows.
        public var historySeconds = 1.8
        /// Time constant at which the floor falls to a quieter frame.
        public var floorFallSeconds = 0.25
        /// How fast the floor creeps up towards a louder room. Slow, so speech does not drag it.
        public var floorRiseDBPerSecond = 1.0
        /// The floor never goes below this, so digital silence is not read as a very quiet room.
        public var floorLimitDB = -70.0
        /// How fast the peak falls when nothing reaches it.
        public var peakDecayDBPerSecond = 6.0
        /// The least distance from floor to peak. 20 dB is a tenfold range in amplitude.
        public var minimumRangeDB = 20.0
        /// The peak never counts as lower than this, so a quiet room's own ticks stay small.
        public var minimumPeakDB = -55.0
        /// A frame this far over the floor starts to count, so the room's own fluctuation is zero.
        public var gateDB = 4.0
        /// The envelope's time constant going down; going up it is instant. About 90% of a
        /// fall is done after 2.3 times this.
        public var releaseSeconds = 0.12
        /// Share of the height the steady level can reach. The rest is for an onset's bump.
        public var bodyCeiling = 0.8
        /// Look back this far for the dip an onset rises out of.
        public var onsetWindowSeconds = 0.15
        /// How much the level must climb out of the dip, and the level it must reach.
        public var onsetRise = 0.3
        public var onsetLevel = 0.35
        /// Least time between two onsets, and how long after one a still rising frame may add to it.
        public var onsetRefractorySeconds = 0.15
        public var onsetGrowSeconds = 0.05
        /// How long the newest frame stands in for time that has no frame yet, such as the wait
        /// for the next block of a phone's microphone, before it starts to die away.
        public var staleSeconds = 0.1
        /// How fast a bump dies away.
        public var bumpDecaySeconds = 0.07

        public init() {}
    }

    public let parameters: Parameters

    // Room.
    private var floorDB = 0.0
    private var peakDB = 0.0
    private var calibrated = false
    // Envelope and onsets.
    private var envelope = 0.0
    private var bump = 0.0
    private var recent: [Double] = []
    private var recentHead = 0
    private var sinceOnset = Double.infinity
    // History: `values[head]` is the newest frame.
    private var values: [Float]
    private var head = 0
    private var stored = 0
    private var frameClock: TimeInterval?

    /// Frames processed since the last `reset`.
    public private(set) var frameCount = 0
    /// The last frame's level in dB, for tests and the log.
    public private(set) var lastDecibels = -100.0
    /// The last frame's raw 0...1 position between floor and peak, before the envelope.
    public private(set) var lastNormalised = 0.0
    /// The envelope and bump of the last frame: what the centre of the trace shows.
    public var current: Float { values[head] }

    public init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
        let capacity = max(2, Int((parameters.historySeconds / parameters.frameSeconds).rounded(.up)) + 1)
        values = [Float](repeating: 0, count: capacity)
        recent = [Double](repeating: 0, count: max(1, Int((parameters.onsetWindowSeconds / parameters.frameSeconds).rounded())))
    }

    /// Forgets the room and the history, as at the start of a hold.
    public mutating func reset() {
        self = VoiceTraceModel(parameters: parameters)
    }

    // MARK: - Input

    /// A block of mono samples that ended at `time`. It is cut into frames of about
    /// `frameSeconds`, each frame's RMS goes through the model, and the history's clock moves to `time`.
    public mutating func ingest(samples: [Float], rate: Double, at time: TimeInterval) {
        guard rate > 0, !samples.isEmpty else { return }
        let target = max(1, Int((rate * parameters.frameSeconds).rounded()))
        let frames = max(1, Int((Double(samples.count) / Double(target)).rounded()))
        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<frames {
                // Equal chunks, so the last one absorbs a remainder instead of being a sliver.
                let start = frame * buffer.count / frames
                let end = (frame + 1) * buffer.count / frames
                var sum: Float = 0
                for index in start..<end { sum += buffer[index] * buffer[index] }
                let rms = (sum / Float(max(1, end - start))).squareRoot()
                process(rms: Double(rms))
            }
        }
        frameClock = time
    }

    /// One level that was measured at `time`, repeated for the frames since the previous call
    /// (at least one). For a source that reports a level and not the samples.
    public mutating func ingest(rms: Float, at time: TimeInterval) {
        var frames = 1
        if let frameClock {
            // A long gap is capped: the history is a ring, so more frames than it holds is waste.
            frames = min(values.count, max(1, Int(((time - frameClock) / parameters.frameSeconds).rounded())))
        }
        for _ in 0..<frames { process(rms: Double(rms)) }
        frameClock = time
    }

    // MARK: - Output

    /// The value shown `age` seconds from now, as seen at `time`. Time since the newest frame
    /// pushes every older value outward, so a pause moves the last words away instead of
    /// freezing them, and the middle, which has nothing newer yet, holds the newest frame. 0
    /// where there is no history.
    public func value(age: TimeInterval, at time: TimeInterval) -> Float {
        guard stored > 0, let frameClock else { return 0 }
        let elapsed = max(0, time - frameClock)
        guard age >= elapsed else {
            // Nothing newer has arrived for this part of the middle. The newest frame stands in
            // for a moment, then dies away with the envelope, so a stalled feed does not hold a level.
            let late = max(0, elapsed - parameters.staleSeconds)
            return slot(0) * Float(exp(-late / parameters.releaseSeconds))
        }
        let position = (max(0, age) - elapsed) / parameters.frameSeconds
        guard position < Double(stored) else { return 0 }
        let lower = Int(position)
        let fraction = Float(position - Double(lower))
        let a = slot(lower)
        guard lower + 1 < stored else { return a * (1 - fraction) }
        return a + (slot(lower + 1) - a) * fraction
    }

    /// `points + 1` values from age 0 to `historySeconds`, evenly spaced, for drawing.
    public func trace(points: Int, at time: TimeInterval) -> [Float] {
        let count = max(1, points)
        return (0...count).map { index in
            value(age: parameters.historySeconds * Double(index) / Double(count), at: time)
        }
    }

    private func slot(_ framesAgo: Int) -> Float {
        values[(head - framesAgo + values.count * 2) % values.count]
    }

    // MARK: - One frame

    private mutating func process(rms: Double) {
        let p = parameters
        let dt = p.frameSeconds
        let db = max(-100, 20 * log10(max(rms, 1e-7)))
        lastDecibels = db

        // The room.
        if !calibrated {
            floorDB = max(db, p.floorLimitDB)
            peakDB = floorDB
            calibrated = true
        }
        if db < floorDB {
            floorDB += (db - floorDB) * (1 - exp(-dt / p.floorFallSeconds))
        } else {
            floorDB += min(p.floorRiseDBPerSecond * dt, db - floorDB)
        }
        floorDB = max(floorDB, p.floorLimitDB)
        peakDB = db > peakDB ? db : max(floorDB, peakDB - p.peakDecayDBPerSecond * dt)
        let effectivePeak = max(peakDB, floorDB + p.minimumRangeDB, p.minimumPeakDB)
        let gate = floorDB + p.gateDB
        let normalised = min(1, max(0, (db - gate) / (effectivePeak - gate)))
        lastNormalised = normalised

        // Instant up, eased down.
        if normalised >= envelope {
            envelope = normalised
        } else {
            envelope += (normalised - envelope) * (1 - exp(-dt / p.releaseSeconds))
        }

        // Onsets.
        bump *= exp(-dt / p.bumpDecaySeconds)
        sinceOnset += dt
        let dip = recent.min() ?? 0
        let rise = normalised - dip
        if frameCount > 0, normalised >= p.onsetLevel, rise >= p.onsetRise {
            let fresh = sinceOnset >= p.onsetRefractorySeconds
            if fresh || sinceOnset < p.onsetGrowSeconds {
                if fresh { sinceOnset = 0 }
                bump = max(bump, (1 - p.bodyCeiling) * min(1, rise))
            }
        }
        recent[recentHead] = normalised
        recentHead = (recentHead + 1) % recent.count

        // History.
        head = (head + 1) % values.count
        values[head] = Float(min(1, p.bodyCeiling * envelope + bump))
        stored = min(values.count, stored + 1)
        frameCount += 1
    }
}
