import AVFoundation
import Foundation

/// One buffer of captured audio, handed from the audio thread to an engine.
///
/// `AVAudioPCMBuffer` is not `Sendable`, so the unchecked conformance holds only while the
/// producer allocates a new buffer for every chunk and never writes to it afterwards.
/// Producers must never wrap a borrowed or reused render buffer: the capture code copies or
/// converts into fresh storage first. After hand-off the buffer is read-only and may have
/// several readers (engines in compare mode, the recording writer).
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// A transcript update from an engine.
struct TranscriptionChunk: Sendable {
    /// The whole transcript so far, never a delta. Engines revise earlier words, so
    /// consumers replace what they hold and never append.
    let text: String
    /// The engine's last word for the session: all text is committed and this is the last
    /// chunk before the stream ends.
    let isFinal: Bool
    /// The leading part of `text` the engine promises not to revise. Only the incremental
    /// Parakeet engine sets it; the controller uses it to start cleanup while the key is
    /// still held.
    var stable: String? = nil
}

/// The seam that keeps Murmur engine-agnostic. Apple's analyzer ships with macOS 26 and
/// installs its own assets; Parakeet and Bark (FluidAudio, Core ML on the Neural Engine) are
/// the heavier alternative. Adding an engine means implementing this protocol.
protocol TranscriptionEngine: Actor {
    /// The format the engine wants capture to deliver, or nil when none is usable. May be
    /// called repeatedly, on an instance that was never started, and on a different
    /// instance than the one that ends up recording.
    func preferredInputFormat() async -> AVAudioFormat?

    /// Begins a session and returns its transcript stream. One engine is made per
    /// utterance, except the shared FluidAudio streaming engines, so this may run again on a
    /// used instance and must reset all per-session state. Emitted chunks are buffered until
    /// a reader arrives.
    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error>

    /// Supplies the next buffer. Called only after `start()` returned, one chunk at a time
    /// in capture order, and never after `finish()`. The buffer is read-only and must not
    /// be kept after the call.
    func feed(_ chunk: AudioChunk) async

    /// Ends the session after the last `feed`. Safe when `start()` threw, when it was never
    /// called, and when called twice. Never waits for a reader. Afterwards the stream
    /// delivers its final chunk (possibly a moment later) and ends, or ends by throwing.
    func finish() async
}

enum TranscriptionError: LocalizedError {
    case localeUnsupported(Locale)
    case modelInstallFailed(String)
    case noAudioFormat
    case notRunning

    var errorDescription: String? {
        switch self {
        case .localeUnsupported(let locale):
            "Dictation is not available for \(locale.identifier) on this Mac."
        case .modelInstallFailed(let detail):
            "The speech model could not be installed or verified: \(detail)"
        case .noAudioFormat:
            "No audio format compatible with the speech engine was found."
        case .notRunning:
            "The speech engine or its model is not running or not loaded."
        }
    }
}
