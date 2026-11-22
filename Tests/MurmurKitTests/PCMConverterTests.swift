import AVFoundation
import Foundation
import Testing
@testable import MurmurKit

@Test func decodesLittleEndianFloat32() {
    // 0.0, 0.5, -1.0 as IEEE-754 little-endian bytes
    let bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0x3F, 0, 0, 0x80, 0xBF]
    #expect(PCMBridge.decodeFloat32(base64: Data(bytes).base64EncodedString()) == [0, 0.5, -1])
}

@Test func rejectsTruncatedSample() {
    #expect(PCMBridge.decodeFloat32(base64: Data([0, 0, 0]).base64EncodedString()) == nil)
}

@Test func rejectsBadBase64() {
    #expect(PCMBridge.decodeFloat32(base64: "not base64!") == nil)
}

@Test func resamples44_1kTo16kFloat() throws {
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let converter = try #require(PCMConverter(sourceRate: 44_100, target: target))
    var frames = 0
    for _ in 0..<10 { frames += Int(converter.convert([Float](repeating: 0.25, count: 4_410))?.frameLength ?? 0) }
    frames += Int(converter.flush()?.frameLength ?? 0)
    // One second in, one second out once the resampler's held-back tail is flushed.
    #expect(abs(frames - 16_000) <= 4, "got \(frames)")
}

@Test func convertsToInt16Target() throws {
    let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
    let converter = try #require(PCMConverter(sourceRate: 48_000, target: target))
    let out = try #require(converter.convert([Float](repeating: 0.5, count: 4_800)))
    #expect(out.format.commonFormat == .pcmFormatInt16)
    #expect(out.frameLength > 0)
}

@Test func everyChunkIsAFreshBuffer() throws {
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let converter = try #require(PCMConverter(sourceRate: 16_000, target: target))
    let a = try #require(converter.convert([Float](repeating: 0.1, count: 1_600)))
    let b = try #require(converter.convert([Float](repeating: 0.2, count: 1_600)))
    #expect(a !== b)
}
