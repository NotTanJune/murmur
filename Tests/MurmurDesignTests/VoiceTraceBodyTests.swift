import Foundation
import SwiftUI
import Testing
@testable import MurmurDesign

/// The liquid body's silhouette, a pure function of the level, the size and time.
struct VoiceTraceBodyTests {
    private let width: CGFloat = 124
    private let height: CGFloat = 31

    private func outline(_ level: Float, time: TimeInterval = 1.7) -> VoiceTrace.Outline {
        let levels = [Float](repeating: level, count: Int(width / 2 / DS.HUD.traceSampleSpacing) + 1)
        return VoiceTrace.outline(levels: levels, width: width, height: height, time: time, reduceMotion: false)
    }

    private func thickness(_ shape: VoiceTrace.Outline, _ index: Int) -> CGFloat {
        shape.bottom[index] - shape.top[index]
    }

    @Test("Silence is a hairline along the middle")
    func silenceIsAHairline() {
        let shape = outline(0)
        let expected = CGFloat(2 * DS.HUD.traceThinHalf)
        for index in shape.top.indices {
            #expect(abs(thickness(shape, index) - expected) < 0.001)
            #expect(abs((shape.top[index] + shape.bottom[index]) / 2 - height / 2) < 0.001)
        }
    }

    @Test("A loud steady level is far thicker than the hairline and stays inside the height")
    func loudIsThickAndContained() {
        let shape = outline(0.9)
        let middle = shape.top.count / 2
        #expect(thickness(shape, middle) > 4 * CGFloat(2 * DS.HUD.traceThinHalf))
        for index in shape.top.indices {
            #expect(shape.top[index] >= 0 && shape.bottom[index] <= height)
            #expect(shape.top[index] < shape.bottom[index])
        }
    }

    @Test("The edges taper to the hairline, and the body moves with time but not with Reduce Motion")
    func edgesTaperAndFlow() {
        let shape = outline(0.9)
        let hairline = CGFloat(2 * DS.HUD.traceThinHalf)
        #expect(abs(thickness(shape, 0) - hairline) < 0.5)
        #expect(abs(thickness(shape, shape.top.count - 1) - hairline) < 0.5)
        #expect(outline(0.9, time: 0) != outline(0.9, time: 0.7))
        let levels = [Float](repeating: 0.9, count: 63)
        let still = { (time: TimeInterval) in
            VoiceTrace.outline(levels: levels, width: self.width, height: self.height, time: time, reduceMotion: true)
        }
        #expect(still(0) == still(9))
    }

    @Test("The level is blurred along the trace, mirrored at the middle")
    func levelsAreBlurred() {
        let impulse: [Float] = [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]
        let blurred = VoiceTrace.smoothed(impulse, sigma: 2)
        #expect(abs(blurred.reduce(0, +) - 1) < 0.1)
        #expect((blurred.max() ?? 0) < 0.3)
        let flat = VoiceTrace.smoothed([Float](repeating: 0.5, count: 12), sigma: 3)
        #expect(flat.allSatisfy { abs($0 - 0.5) < 1e-9 })
        #expect(VoiceTrace.smoothed(impulse, sigma: 0) == impulse.map(Double.init))
    }
}
