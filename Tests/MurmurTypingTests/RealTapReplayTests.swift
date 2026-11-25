import CoreGraphics
import Foundation
import Testing

@testable import MurmurTyping

/// Replays the owner's real typing through the autocorrector, the way the keyboard runs it at a
/// word end. `real-taps.json` holds 14 lines of a pangram typed fast with two thumbs on the
/// device, 130 words, each word with the key the engine resolved every tap to and where the finger
/// landed, as an offset in points from the centre of the key. The intended word of each typed word
/// comes from an edit-distance alignment of the line to the sentence the owner was copying (a
/// typed word that holds two intended words, a missed space, is aligned to both).
///
/// The synthetic replay (`AutocorrectReplayTests`) draws Gaussian noise around key centres; this
/// one is what a hand actually does: letters that never land, two thumbs landing out of order and
/// a tap on a neighbouring key. Nothing is tuned against the synthetic noise here, and the sample
/// is small, so the gates below are loose and the printed list of unfixed words is the real output.
@Suite struct RealTapReplayTests {
    struct File: Decodable {
        struct Tap: Decodable {
            let k: String
            let dx: Double
            let dy: Double
            let t: Double
        }
        struct Word: Decodable {
            /// The word or words the owner meant, nil for a fragment of a word split by a stray space.
            let intended: String?
            let taps: [Tap]
        }
        struct Line: Decodable {
            let run: String
            let sentence: String
            let words: [Word]
        }
        let lines: [File.Line]
    }

    /// What happened to one typed word.
    enum Outcome: String {
        case fixed, left, madeWorse, correctKept, correctChanged, notScored
    }

    struct Result {
        let line: Int
        let typed: String
        let intended: String?
        let final: String
        let previous: String
        let outcome: Outcome
        /// The decoder's best few readings: text, posterior, kind.
        let top: String
        let milliseconds: Double
    }

    static func load() throws -> File {
        let url = try #require(Bundle.module.url(forResource: "real-taps", withExtension: "json"))
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
    }

    /// Runs every line. The first letter of a line is typed capital, as the keyboard's
    /// auto-shift does, and the field text grows with what the keyboard would have typed.
    static func replay(
        _ file: File, fixture: TypingFixture, configuration: TapDecoder.Configuration = .tuned,
        thresholds: AutocorrectPolicy.Thresholds = .tuned
    ) -> [Result] {
        var corrector = Autocorrector(
            model: fixture.model, lettersFrames: fixture.frames, configuration: configuration)
        corrector.thresholds = thresholds
        var results: [Result] = []
        let clock = ContinuousClock()
        for (lineIndex, line) in file.lines.enumerated() {
            var text = ""
            for (wordIndex, word) in line.words.enumerated() {
                var tracker = WordTapTracker()
                for (tapIndex, tap) in word.taps.enumerated() {
                    let center = fixture.frame(Character(tap.k)).keycap
                    let shown = wordIndex == 0 && tapIndex == 0 ? tap.k.uppercased() : tap.k
                    tracker.append(
                        letter: shown,
                        at: CGPoint(x: center.midX + tap.dx, y: center.midY + tap.dy))
                }
                let typed = tracker.typed
                let before = text + typed
                var evaluation: Autocorrector.Evaluation?
                let elapsed = clock.measure {
                    evaluation = corrector.evaluate(textBefore: before, tracker: tracker, field: .standard)
                }
                let milliseconds =
                    Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
                let final = evaluation?.replacement?.text ?? typed
                let previous = WordAtCursor.ending(textBefore: before)?.previous ?? ""
                let outcome: Outcome
                if let intended = word.intended {
                    if typed.lowercased() == intended {
                        outcome = final == typed ? .correctKept : .correctChanged
                    } else if final.lowercased() == intended {
                        outcome = .fixed
                    } else {
                        outcome = final == typed ? .left : .madeWorse
                    }
                } else {
                    outcome = .notScored
                }
                results.append(
                    Result(
                        line: lineIndex, typed: typed, intended: word.intended, final: final,
                        previous: previous, outcome: outcome,
                        top: evaluation?.decoding.candidates.prefix(4).map {
                            "\($0.text) \(String(format: "%.2f", $0.posterior))/\(String(format: "%.1f", $0.score))/\($0.kind)"
                        }.joined(separator: ", ") ?? "-",
                        milliseconds: milliseconds))
                text += final + " "
            }
        }
        return results
    }

    @Test("The recorded taps sit on the keys the engine resolved them to")
    func geometryMatchesTheLog() throws {
        let file = try Self.load()
        let fixture = try TypingFixture()
        var total = 0
        var agree = 0
        for line in file.lines {
            for word in line.words {
                for tap in word.taps {
                    let center = fixture.frame(Character(tap.k)).keycap
                    let point = CGPoint(x: center.midX + tap.dx, y: center.midY + tap.dy)
                    total += 1
                    if HitTester.key(at: point, frames: fixture.frames, bias: [:])?.kind == .character(tap.k) {
                        agree += 1
                    }
                }
            }
        }
        // The device resolves with its next-letter bias, so a few taps differ from the bare hit test.
        print("REAL geometry: \(agree) of \(total) taps hit the key they were logged on")
        #expect(total > 400, "\(total) taps")
        #expect(Double(agree) / Double(total) > 0.9, "\(agree) of \(total)")
    }

    @Test("The owner's real taps: errors fixed, left, made worse, and correct words changed")
    func replay() throws {
        let file = try Self.load()
        var configuration = TapDecoder.Configuration.tuned
        var thresholds = AutocorrectPolicy.Thresholds.tuned
        if let tune = ProcessInfo.processInfo.environment["MURMUR_TYPING_TUNE"] {
            AutocorrectReplayTests.apply(tune, to: &configuration, thresholds: &thresholds)
        }
        let fixture = try TypingFixture(configuration: configuration)
        // A first pass touches the mapped model pages, so the timings below are a keyboard's that
        // has been typing, as `AutocorrectTests.decodeIsFast` does.
        _ = Self.replay(file, fixture: fixture, configuration: configuration, thresholds: thresholds)
        let results = Self.replay(file, fixture: fixture, configuration: configuration, thresholds: thresholds)

        func count(_ outcome: Outcome) -> Int { results.filter { $0.outcome == outcome }.count }
        let fixed = count(.fixed)
        let left = count(.left)
        let worse = count(.madeWorse)
        let wrong = fixed + left + worse
        let correct = count(.correctKept) + count(.correctChanged)
        let changed = count(.correctChanged)
        let unscored = count(.notScored)
        let sorted = results.map(\.milliseconds).sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }

        print("REAL lines \(file.lines.count), words \(results.count), scored \(wrong + correct), not scored \(unscored)")
        print("REAL typed wrong: \(wrong): fixed \(fixed), left \(left), changed to another wrong word \(worse)")
        print("REAL correct words: \(correct), changed \(changed)")
        print(
            String(
                format: "REAL evaluate ms per word: p50 %.3f  p99 %.3f  max %.3f", percentile(0.5),
                percentile(0.99), sorted.last ?? 0))
        for result in results where [.left, .madeWorse, .correctChanged].contains(result.outcome) {
            print(
                "REAL \(result.outcome.rawValue): \(result.typed) -> \(result.final) "
                    + "(wanted \(result.intended ?? "?"), after \"\(result.previous)\"; \(result.top))")
        }
        for result in results where result.outcome == .fixed {
            print("REAL fixed: \(result.typed) -> \(result.final) (after \"\(result.previous)\", top \(result.top))")
        }
        for result in results where result.outcome == .notScored {
            print("REAL not scored: \(result.typed) (\(result.intended ?? "stray space fragment"))")
        }

        #expect(wrong >= 40, "the log holds \(wrong) wrong words")
        #expect(Double(fixed) / Double(max(wrong, 1)) >= Gate.fixedShare, "fixed \(fixed) of \(wrong)")
        #expect(Double(changed) / Double(max(correct, 1)) <= Gate.correctChangedShare, "changed \(changed) of \(correct)")
        #expect(Double(worse) / Double(max(wrong, 1)) <= Gate.worseShare, "made worse \(worse) of \(wrong)")
        // The spec is a p99 under 8 ms in a debug build; the gate leaves room for a loaded machine.
        #expect(percentile(0.99) < 20, "p99 \(percentile(0.99)) ms")
    }

    /// Loose regression gates, set under the numbers of 2026-11-25 (31 of 47 wrong words fixed, 4
    /// changed to another wrong word, none of 83 correct words changed). The log is 14 lines of one
    /// pangram, so a few words either way is noise, and the gates only catch a real regression.
    enum Gate {
        static let fixedShare = 0.55
        static let correctChangedShare = 0.02
        static let worseShare = 0.2
    }
}
