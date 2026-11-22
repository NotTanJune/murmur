import Testing
@testable import MurmurKit

struct PreRollBufferTests {
    @Test("Only the newest window is kept")
    func keepsOnlyNewestWindow() {
        var buffer = PreRollBuffer(maxSeconds: 0.3)
        // One second at 48 kHz, each sample its own index so the survivors can be identified.
        let samples = (0..<48_000).map { Float($0) }
        buffer.append(samples, rate: 48_000)
        #expect(abs(buffer.seconds - 0.3) < 1e-9)
        let drained = buffer.drain()
        #expect(drained.rate == 48_000)
        #expect(drained.samples.count == 14_400)
        #expect(drained.samples == Array(samples.suffix(14_400)))
    }

    @Test("Many small appends keep the same newest window")
    func trimsAcrossAppends() {
        var buffer = PreRollBuffer(maxSeconds: 0.3)
        var all: [Float] = []
        for block in 0..<40 {
            let samples = (0..<2_048).map { Float(block * 2_048 + $0) }
            all += samples
            buffer.append(samples, rate: 48_000)
        }
        #expect(buffer.drain().samples == Array(all.suffix(14_400)))
    }

    @Test("Less than the window is kept whole")
    func shortAudioIsKept() {
        var buffer = PreRollBuffer(maxSeconds: 0.3)
        buffer.append([1, 2, 3], rate: 16_000)
        let drained = buffer.drain()
        #expect(drained.samples == [1, 2, 3])
        #expect(drained.rate == 16_000)
    }

    @Test("Draining empties the buffer")
    func drainEmpties() {
        var buffer = PreRollBuffer(maxSeconds: 0.3)
        buffer.append([Float](repeating: 0.5, count: 4_800), rate: 48_000)
        #expect(buffer.seconds > 0)
        _ = buffer.drain()
        #expect(buffer.seconds == 0)
        let second = buffer.drain()
        #expect(second.samples.isEmpty)
        #expect(second.rate == nil)
    }

    @Test("A new rate clears what was kept at the old one")
    func rateChangeClears() {
        var buffer = PreRollBuffer(maxSeconds: 0.3)
        buffer.append([Float](repeating: 1, count: 4_800), rate: 48_000)
        buffer.append([Float](repeating: 2, count: 1_600), rate: 16_000)
        let drained = buffer.drain()
        #expect(drained.rate == 16_000)
        #expect(drained.samples == [Float](repeating: 2, count: 1_600))
    }
}
