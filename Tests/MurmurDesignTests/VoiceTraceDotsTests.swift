import Foundation
import SwiftUI
import Testing
@testable import MurmurDesign

/// The dot grid and the braid's brightness, which are pure functions of the level, the size and time.
struct VoiceTraceDotsTests {
    private typealias Grid = VoiceTrace.Grid

    private func grid(_ width: CGFloat = 124, _ height: CGFloat = 31, pitch: CGFloat = DS.HUD.traceDotPitch) -> Grid {
        Grid(size: CGSize(width: width, height: height), pitch: pitch)
    }

    private func brightness(_ level: Float, grid: Grid, time: TimeInterval = 0, reduceMotion: Bool = false) -> [Float] {
        let amplitudes = [Float](repeating: level, count: grid.middleColumn + 1)
        return VoiceTrace.brightness(amplitudes: amplitudes, grid: grid, time: time, reduceMotion: reduceMotion)
    }

    @Test("The grid holds whole dots, with a middle column and a middle row")
    func gridIsOddAndCentred() {
        for (width, height) in [(124.0, 31.0), (236.0, 36.0), (17.0, 5.0), (3.0, 3.0)] {
            let g = grid(width, height)
            #expect(g.columns % 2 == 1 && g.rows % 2 == 1)
            #expect(CGFloat(g.columns) * g.pitch <= width + 0.001)
            #expect(CGFloat(g.rows) * g.pitch <= height + 0.001)
            // The first and last dots sit the same distance from either side.
            let left = g.center(column: 0, row: 0).x
            let right = width - g.center(column: g.columns - 1, row: 0).x
            #expect(abs(left - right) < 0.001)
        }
        // A room too small for a dot still gives one, so nothing divides by zero.
        #expect(grid(0, 0).columns == 1)
    }

    @Test("Silence closes the braid onto the middle row")
    func silenceIsTheMiddleRow() {
        let g = grid()
        let lit = brightness(0, grid: g)
        for column in 0..<g.columns {
            let middle = lit[g.middleRow * g.columns + column]
            #expect(middle > 0.5)
            // Two rows off the line is dark.
            #expect(lit[(g.middleRow - 2) * g.columns + column] < 0.1)
            #expect(lit[(g.middleRow + 2) * g.columns + column] < 0.1)
        }
    }

    @Test("Speech swells the braid across the rows")
    func speechSpreadsTheBraid() {
        let g = grid()
        let lit = brightness(0.9, grid: g)
        var rowsTouched = Set<Int>()
        for row in 0..<g.rows {
            for column in 0..<g.columns where lit[row * g.columns + column] > 0.5 { rowsTouched.insert(row) }
        }
        #expect(rowsTouched.count >= g.rows - 2)
        #expect(lit.max() ?? 0 <= 1)
    }

    @Test("The newest column is the brightest, and the oldest has faded")
    func newestIsBrightest() {
        let g = grid()
        let silent = brightness(0, grid: g)
        let centre = silent[g.middleRow * g.columns + g.middleColumn]
        let edge = silent[g.middleRow * g.columns]
        #expect(centre > 0.99)
        #expect(abs(Double(edge) - DS.HUD.traceEdgeOpacity) < 0.01)
        // Level is what makes the two halves alike: the same history either side of the middle.
        #expect(silent[g.middleRow * g.columns + 3] == silent[g.middleRow * g.columns + g.columns - 4])
    }

    @Test("The braid travels with time, and stands still with Reduce Motion")
    func carrierTravels() {
        let g = grid()
        let early = brightness(0.8, grid: g, time: 0)
        let later = brightness(0.8, grid: g, time: 0.7)
        #expect(early != later)
        #expect(brightness(0.8, grid: g, time: 0, reduceMotion: true) == brightness(0.8, grid: g, time: 9, reduceMotion: true))
    }

    @Test("No history draws nothing lit")
    func emptyHistoryIsDark() {
        let g = grid()
        let lit = VoiceTrace.brightness(amplitudes: [], grid: g, time: 0, reduceMotion: false)
        #expect(lit.allSatisfy { $0 == 0 })
    }
}
