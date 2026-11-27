import Foundation
import SwiftUI
import Testing
@testable import MurmurDesign

/// The silk fan's lines, a pure function of the level, the size and time.
struct VoiceTraceBodyTests {
    private let width: CGFloat = 124
    private let height: CGFloat = 31

    private func fan(_ level: Double, time: TimeInterval = 1.7, reduceMotion: Bool = false) -> [VoiceTrace.Strand] {
        VoiceTrace.strands(level: level, width: width, height: height, time: time, reduceMotion: reduceMotion)
    }

    @Test("Silence lays every line flat along the middle")
    func silenceIsFlat() {
        let lines = fan(0)
        #expect(lines.count == DS.HUD.traceEchoLags.count)
        for line in lines { #expect(line.y.allSatisfy { abs($0 - height / 2) < 0.001 }) }
    }

    @Test("A loud voice swings the main line far from the middle, inside the view, ends pinned")
    func loudSwingsAndStaysInside() {
        let lines = fan(1)
        let main = lines[lines.count - 1]
        #expect(main.opacity == 1)
        #expect((main.y.map { abs($0 - height / 2) }.max() ?? 0) > height * 0.3)
        for line in lines {
            #expect(line.y.allSatisfy { $0 - line.width / 2 >= 0 && $0 + line.width / 2 <= height })
            #expect(abs(line.y[0] - height / 2) < 0.001)
            #expect(abs(line.y[line.y.count - 1] - height / 2) < 0.001)
        }
    }

    @Test("Echoes are fainter, thinner and lower than the main line")
    func echoesFanOut() {
        let lines = fan(1)
        let main = lines[lines.count - 1]
        let peak = { (line: VoiceTrace.Strand) in line.y.map { abs($0 - self.height / 2) }.max() ?? 0 }
        for echo in lines.dropLast() {
            #expect(echo.opacity < main.opacity && echo.width <= main.width)
            #expect(peak(echo) < peak(main))
        }
    }

    @Test("The fan moves with time, and not with Reduce Motion")
    func motion() {
        #expect(fan(0.8, time: 0) != fan(0.8, time: 0.7))
        #expect(fan(0.8, time: 0, reduceMotion: true) == fan(0.8, time: 9, reduceMotion: true))
    }
}
