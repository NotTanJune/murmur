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

    @Test("Louder is fatter: the lit mass grows with the level")
    func massGrowsWithVoice() {
        let g = grid(236, 36, pitch: DS.Keyboard.traceDotPitch)
        func litDots(_ level: Float) -> Int {
            brightness(level, grid: g, time: 1.7).filter { $0 > 0.5 }.count
        }
        let silent = litDots(0)
        let quiet = litDots(0.3)
        let loud = litDots(0.9)
        // Silence is one row of dots; speech is several times that.
        #expect(silent <= g.columns * 2)
        #expect(quiet > silent)
        #expect(loud > quiet + g.columns)
    }

    @Test("A loud syllable is a solid mass with no holes in it, not outlines")
    func loudIsSolid() {
        let g = grid(236, 36, pitch: DS.Keyboard.traceDotPitch)
        let lit = brightness(0.9, grid: g, time: 1.7)
        // Most columns near the middle have four or more brightly lit dots.
        var thick = 0
        var counted = 0
        for column in (g.middleColumn - 12)...(g.middleColumn + 12) {
            counted += 1
            let bright = (0..<g.rows).filter { lit[$0 * g.columns + column] > 0.6 }.count
            if bright >= 4 { thick += 1 }
        }
        #expect(thick * 2 >= counted, "\(thick) of \(counted) columns solid")
    }

    @Test("The mass flows: it changes shape with time and is not a repeating pattern")
    func massFlows() {
        let g = grid(236, 36, pitch: DS.Keyboard.traceDotPitch)
        let first = brightness(0.8, grid: g, time: 0)
        let later = brightness(0.8, grid: g, time: 2.3)
        let differing = zip(first, later).filter { abs($0 - $1) > 0.3 }.count
        #expect(differing > g.columns / 2)
        // Two stretches of the trace a carrier-wavelength apart are not copies.
        let width = g.columns / 3
        let left = (0..<g.rows).flatMap { row in (0..<width).map { first[row * g.columns + $0] } }
        let right = (0..<g.rows).flatMap { row in (0..<width).map { first[row * g.columns + $0 + width] } }
        #expect(left != right)
    }

    @Test("A spike in the level comes out as a rounded bulge")
    func spikeIsRounded() {
        let g = grid(236, 36, pitch: DS.Keyboard.traceDotPitch)
        var amplitudes = [Float](repeating: 0.05, count: g.middleColumn + 1)
        amplitudes[g.middleColumn / 2] = 1
        let lit = VoiceTrace.brightness(amplitudes: amplitudes, grid: g, time: 0.4, reduceMotion: false)
        func height(_ column: Int) -> Int {
            (0..<g.rows).filter { lit[$0 * g.columns + column] > 0.5 }.count
        }
        // The lit height changes by little from one column to the next (no spike or notch).
        var steepest = 0
        for column in 1..<g.columns { steepest = max(steepest, abs(height(column) - height(column - 1))) }
        #expect(steepest <= 2, "steepest step \(steepest) dots")
        // And no lit dot stands alone.
        for row in 0..<g.rows {
            for column in 1..<(g.columns - 1) where lit[row * g.columns + column] > 0.5 {
                let near = [
                    lit[row * g.columns + column - 1], lit[row * g.columns + column + 1],
                    row > 0 ? lit[(row - 1) * g.columns + column] : 0,
                    row < g.rows - 1 ? lit[(row + 1) * g.columns + column] : 0,
                ]
                #expect(near.contains { $0 > 0.3 }, "isolated dot at \(row), \(column)")
            }
        }
    }

    @Test("The level is blurred across columns, mirrored at the middle")
    func levelsAreBlurred() {
        let impulse: [Float] = [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]
        let blurred = VoiceTrace.smoothed(impulse, sigma: 2)
        #expect(abs(blurred.reduce(0, +) - 1) < 0.1)
        #expect((blurred.max() ?? 0) < 0.3)
        #expect(blurred[2] > blurred[0] && blurred[4] > blurred[8])
        // Mirrored: a level at the middle is not thinned by the blur reaching past it.
        let flat = VoiceTrace.smoothed([Float](repeating: 0.5, count: 12), sigma: 3)
        #expect(flat.allSatisfy { abs($0 - 0.5) < 1e-9 })
        // Off, it is the input.
        #expect(VoiceTrace.smoothed(impulse, sigma: 0) == impulse.map(Double.init))
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
