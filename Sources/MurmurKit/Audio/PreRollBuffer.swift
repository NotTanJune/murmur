import Foundation

/// The last moments of audio before a press, kept so a hold can start from them.
///
/// A warm microphone delivers samples between holds. They go here instead of anywhere durable:
/// only the newest `maxSeconds` stay, at the rate they arrived in, and a press drains them into
/// the start of the hold's audio. A change of rate (a new capture session) clears the buffer,
/// because samples at two rates cannot be joined without resampling. The Mac's `CaptureRouter`
/// does the same with converted chunks; this type holds raw samples for the phone, whose page
/// reports its own rate.
public struct PreRollBuffer: Sendable {
    public let maxSeconds: Double
    private var samples: [Float] = []
    private var rate: Double?

    public init(maxSeconds: Double) {
        self.maxSeconds = max(0, maxSeconds)
    }

    /// How much audio is held, in seconds.
    public var seconds: Double {
        guard let rate, rate > 0 else { return 0 }
        return Double(samples.count) / rate
    }

    /// Adds samples captured at `rate`, then drops the oldest beyond the window.
    public mutating func append(_ new: [Float], rate newRate: Double) {
        guard newRate > 0, !new.isEmpty else { return }
        if let rate, rate != newRate { samples.removeAll(keepingCapacity: true) }
        rate = newRate
        samples.append(contentsOf: new)
        let limit = Int((maxSeconds * newRate).rounded())
        if samples.count > limit { samples.removeFirst(samples.count - limit) }
    }

    /// Everything held, oldest first, with its rate (nil when nothing is held). Leaves the
    /// buffer empty.
    public mutating func drain() -> (samples: [Float], rate: Double?) {
        defer {
            samples.removeAll(keepingCapacity: true)
            rate = nil
        }
        return (samples, samples.isEmpty ? nil : rate)
    }
}
