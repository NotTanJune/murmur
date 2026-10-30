import AVFoundation
import Testing
@testable import Murmur

@Suite struct CaptureRouterTests {
    /// A 0.1 s buffer at 16 kHz whose first sample identifies it.
    private func chunk(_ id: Float) -> AudioChunk {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        buffer.floatChannelData![0][0] = id
        return AudioChunk(buffer: buffer)
    }

    private func ids(_ stream: AsyncStream<AudioChunk>, count: Int) async -> [Float] {
        var result: [Float] = []
        for await chunk in stream {
            result.append(chunk.buffer.floatChannelData![0][0])
            if result.count == count { break }
        }
        return result
    }

    @Test("Between holds only the last ~0.3 s is kept, and a press starts from it, in order")
    func preRollThenLive() async {
        let router = CaptureRouter()
        for id in 1...10 { router.route(chunk(Float(id))) }   // 1 s of idle audio

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        router.attach(continuation) { _ in }
        router.route(chunk(11))
        router.route(chunk(12))

        // 0.3 s of pre-roll (chunks 8–10), then live audio.
        #expect(await ids(stream, count: 5) == [8, 9, 10, 11, 12])
    }

    @Test("Releasing a hold sends audio back to an empty pre-roll")
    func detachClears() async {
        let router = CaptureRouter()
        let (first, firstContinuation) = AsyncStream<AudioChunk>.makeStream()
        router.attach(firstContinuation) { _ in }
        router.route(chunk(1))
        router.detach()
        router.route(chunk(2))

        let (second, secondContinuation) = AsyncStream<AudioChunk>.makeStream()
        router.attach(secondContinuation) { _ in }
        router.route(chunk(3))
        #expect(await ids(first, count: 1) == [1])
        #expect(await ids(second, count: 2) == [2, 3])
    }
}
