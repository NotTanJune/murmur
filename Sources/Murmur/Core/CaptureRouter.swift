import AVFoundation
import Foundation

/// Where captured audio goes: into the hold in progress, or, between holds with the
/// microphone kept open, into a short pre-roll that the next hold starts from.
///
/// The pre-roll is what makes an always-open microphone feel instant. The key handler runs
/// a few milliseconds after the physical press, and people start talking as their finger
/// lands, so a hold begins with the last `preRollSeconds` of audio from *before* the press.
/// Nothing older is ever kept, and nothing is written anywhere.
///
/// Called from the real-time audio thread, so all state sits behind one lock.
final class CaptureRouter: @unchecked Sendable {
    static let preRollSeconds: Double = 0.3

    private let lock = NSLock()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var onLevel: (@Sendable (Float) -> Void)?
    private var preRoll: [AudioChunk] = []
    private var preRollSeconds: Double = 0

    /// Audio thread: one converted buffer.
    func route(_ chunk: AudioChunk) {
        lock.lock()
        defer { lock.unlock() }
        if let continuation {
            continuation.yield(chunk)
            return
        }
        preRoll.append(chunk)
        preRollSeconds += Self.duration(of: chunk)
        while let first = preRoll.first, preRollSeconds - Self.duration(of: first) >= Self.preRollSeconds {
            preRoll.removeFirst()
            preRollSeconds -= Self.duration(of: first)
        }
    }

    /// Audio thread: input level, forwarded only while a hold is attached.
    func level(_ value: Float) {
        lock.lock()
        let onLevel = onLevel
        lock.unlock()
        onLevel?(value)
    }

    /// Hands the audio to a hold, starting with whatever pre-roll was collected.
    func attach(
        _ continuation: AsyncStream<AudioChunk>.Continuation,
        onLevel: @escaping @Sendable (Float) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        for chunk in preRoll { continuation.yield(chunk) }
        preRoll.removeAll()
        preRollSeconds = 0
        self.continuation = continuation
        self.onLevel = onLevel
    }

    /// The hold is over; audio goes back to the pre-roll, starting empty.
    func detach() {
        lock.lock()
        defer { lock.unlock() }
        continuation = nil
        onLevel = nil
        preRoll.removeAll()
        preRollSeconds = 0
    }

    private static func duration(of chunk: AudioChunk) -> Double {
        let rate = chunk.buffer.format.sampleRate
        return rate > 0 ? Double(chunk.buffer.frameLength) / rate : 0
    }
}
