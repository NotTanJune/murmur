import Foundation
import Testing
@testable import Murmur

/// The cleanup budget follows the machine's measured speed, so a long dictation under load
/// is cleaned by the model instead of being cut off at the idle figure.
struct S1MiniBudgetTests {
    typealias Throughput = S1MiniEngine.Throughput

    @Test("An idle machine keeps a tight budget for a short sentence")
    func idleShortSentence() {
        let budget = Throughput.budget(words: 19, millisecondsPerWord: Throughput.idleMillisecondsPerWord)
        #expect(budget >= .milliseconds(1_900))
        #expect(budget <= .milliseconds(2_100))
    }

    @Test("A machine measured four times slower gets a budget that covers the clean")
    func loadedMachine() {
        // 131 words at 40 ms per word is 5.2 s of generation, which the old fixed budget
        // (4.1 s) cancelled.
        let budget = Throughput.budget(words: 131, millisecondsPerWord: 40)
        #expect(budget > .seconds(5.2))
        #expect(budget <= Throughput.ceiling)
    }

    @Test("The budget never passes the ceiling")
    func ceiling() {
        #expect(Throughput.budget(words: 2_000, millisecondsPerWord: 500) == Throughput.ceiling)
    }

    @Test("Slower measurements are taken up at once and faster ones eased in")
    func smoothing() {
        let slower = Throughput.smoothed(10, sample: 40)
        #expect(slower == 40)
        let faster = Throughput.smoothed(40, sample: 10)
        #expect(faster > 10 && faster < 40)
    }

    @Test("A measurement below the idle figure does not shrink the budget below idle")
    func idleFloor() {
        let fast = Throughput.budget(words: 100, millisecondsPerWord: 1)
        let idle = Throughput.budget(words: 100, millisecondsPerWord: Throughput.idleMillisecondsPerWord)
        #expect(fast == idle)
    }
}
