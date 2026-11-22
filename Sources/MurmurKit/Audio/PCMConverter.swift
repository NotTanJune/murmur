import AVFoundation
import Foundation

/// Decodes the samples `WebMicrophone`'s page posts: a `Float32Array`'s bytes, base64.
public enum PCMBridge {
    /// Little-endian Float32 samples, or nil when the text is not base64 or its byte count is
    /// not a whole number of samples.
    public static func decodeFloat32(base64: String) -> [Float]? {
        guard let data = Data(base64Encoded: base64), data.count % 4 == 0 else { return nil }
        return data.withUnsafeBytes { raw in
            (0..<(data.count / 4)).map { index in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
            }
        }
    }
}

/// Mono Float32 at the page's capture rate in, the engine's format out.
///
/// One converter per hold: its resampler keeps history between chunks, so splitting the audio
/// into messages leaves no seams. Every call returns a newly allocated buffer, as `AudioChunk`
/// requires of producers.
public final class PCMConverter {
    private let source: AVAudioFormat
    private let target: AVAudioFormat
    private let converter: AVAudioConverter

    public init?(sourceRate: Double, target: AVAudioFormat) {
        guard sourceRate > 0,
              let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target)
        else { return nil }
        self.source = source
        self.target = target
        self.converter = converter
    }

    /// The frames the resampler still holds back (a few milliseconds), at the end of a hold.
    /// The converter is finished afterwards.
    public func flush() -> AVAudioPCMBuffer? {
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4_096) else { return nil }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    public func convert(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0]
        else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }

        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        // Hand the chunk over once, then say "no data for now" (not "end of stream"), so the
        // converter keeps its resampler state for the next chunk.
        let feed = ChunkFeed(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if let buffer = feed.take() {
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

/// The one input buffer for a single `convert` call. The converter calls its input block
/// synchronously inside `convert(to:error:withInputFrom:)`, so there is no concurrent access.
private final class ChunkFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
