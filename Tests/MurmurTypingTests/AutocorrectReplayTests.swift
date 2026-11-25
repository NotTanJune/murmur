import CoreGraphics
import Foundation
import Testing

@testable import MurmurTyping

/// The autocorrect benchmark: synthetic typing of everyday sentences with noise the decoder does
/// not assume, run through the decoder and the policy.
///
/// Skipped unless `MURMUR_TYPING_BENCH=1`. Taps are drawn around each intended key's centre with
/// σ = 1.3 times the decoder's σ (0.3 key widths across, 0.4 key heights down, the values the
/// decoder starts from, not whatever it was tuned to), plus one fixed 3 pt offset in a random
/// direction per sentence, as a hand that sits a little off the keys. The generator's seed is
/// fixed, so every run sees the same taps.
///
/// Contractions are typed without their apostrophe (`dont`), because that is how they are typed
/// on the letters page; the intended word keeps it. That makes the contraction rule part of the
/// measurement, as it is in use, at about one word in two hundred.
///
/// Tuning knobs without a rebuild: `MURMUR_TYPING_TUNE="beam=64,sigmaX=0.3,..."` overrides
/// decoder and policy constants (see `apply`), and `MURMUR_TYPING_BENCH_REPEATS` sets how many
/// times the sentences are replayed with fresh noise (default 10, about 2,300 sentences).
@Suite struct AutocorrectReplayTests {
    static let enabled = ProcessInfo.processInfo.environment["MURMUR_TYPING_BENCH"] == "1"

    /// Gate: errors reduced by at least half, and under 1% of correct words changed.
    static let requiredReduction = 0.5
    static let allowedChanged = 0.01

    @Test(.enabled(if: AutocorrectReplayTests.enabled))
    func replay() throws {
        let environment = ProcessInfo.processInfo.environment
        var configuration = TapDecoder.Configuration.tuned
        var thresholds = AutocorrectPolicy.Thresholds.tuned
        if let tune = environment["MURMUR_TYPING_TUNE"] {
            Self.apply(tune, to: &configuration, thresholds: &thresholds)
        }
        let repeats = Int(environment["MURMUR_TYPING_BENCH_REPEATS"] ?? "") ?? 10

        let fixture = try TypingFixture(configuration: configuration)
        let sentences = try Self.sentences()
        #expect(sentences.count >= 200)

        // What the generator assumes, fixed here so that tuning the decoder cannot move it.
        let sigmaX = 1.3 * 0.3 * Double(fixture.frame("a").keycap.width)
        let sigmaY = 1.3 * 0.4 * Double(fixture.frame("a").keycap.height)
        var random = SplitMix64(seed: 0x4D75_726D_7572)
        let letterFrames = fixture.frames.filter { $0.kind.characterValue.map { $0.count == 1 && $0.first!.isLetter } ?? false }

        var words = 0
        var rawErrors = 0
        var finalErrors = 0
        var correctWords = 0
        var correctChanged = 0
        var fixed = 0
        var broken = 0
        var outOfModel = Set<String>()
        var decodeMilliseconds: [Double] = []
        var kinds: [CandidateKind: Int] = [:]
        var sentenceCount = 0
        var examples: [String] = []

        for _ in 0..<repeats {
            for sentence in sentences {
                sentenceCount += 1
                let angle = Double.random(in: 0..<(2 * .pi), using: &random)
                let offset = CGPoint(x: 3 * cos(angle), y: 3 * sin(angle))
                var previous: Int?
                for (position, intended) in sentence.split(separator: " ").map(String.init).enumerated() {
                    if fixture.model.id(of: intended) == nil { outOfModel.insert(intended) }
                    let letters = intended.filter { $0 != "'" }
                    var taps: [WordTap] = []
                    for letter in letters {
                        let keycap = fixture.frame(letter).keycap
                        let point = CGPoint(
                            x: keycap.midX + offset.x + sigmaX * Self.gaussian(&random),
                            y: keycap.midY + offset.y + sigmaY * Self.gaussian(&random))
                        taps.append(WordTap(point: point, key: Self.resolve(point, fixture: fixture, letters: letterFrames)))
                    }
                    let typed = taps.compactMap(\.key.characterValue).joined()

                    let clock = ContinuousClock()
                    var decoding = TapDecoder.Decoding(typed: typed, typedID: nil, candidates: [])
                    let elapsed = clock.measure {
                        decoding = fixture.decoder.decode(taps: taps, previous: previous)
                    }
                    decodeMilliseconds.append(
                        Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)

                    let decision = AutocorrectPolicy.decide(
                        typed: typed, decoding: decoding, field: .standard,
                        knowledge: UserLexicon.empty.knowledge(of: typed, model: fixture.model),
                        position: position == 0 ? .start : .middle, rejections: RejectionSet(),
                        model: fixture.model, thresholds: thresholds)
                    var final = typed
                    if case .replace(let replacement) = decision {
                        final = replacement.text
                        kinds[replacement.kind, default: 0] += 1
                    }

                    words += 1
                    let rawWrong = typed != intended
                    let finalWrong = final != intended
                    if rawWrong { rawErrors += 1 }
                    if finalWrong { finalErrors += 1 }
                    if rawWrong && !finalWrong { fixed += 1 }
                    if !rawWrong && finalWrong { broken += 1 }
                    if !rawWrong {
                        correctWords += 1
                        if final != typed { correctChanged += 1 }
                    }
                    if examples.count < 40, finalWrong != rawWrong || (finalWrong && final != typed) {
                        examples.append("\(intended): typed \(typed) -> \(final)")
                    }
                    previous = final.split(separator: " ").last.flatMap { fixture.model.id(of: String($0)) }
                }
            }
        }

        let rawWER = Double(rawErrors) / Double(words)
        let finalWER = Double(finalErrors) / Double(words)
        let reduction = rawErrors == 0 ? 0 : 1 - Double(finalErrors) / Double(rawErrors)
        let changed = correctWords == 0 ? 0 : Double(correctChanged) / Double(correctWords)
        let sorted = decodeMilliseconds.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }

        func percent(_ value: Double) -> String { String(format: "%.2f%%", value * 100) }
        print("REPLAY sentences: \(sentenceCount), words: \(words), intended words outside the model: \(outOfModel.sorted())")
        print("REPLAY raw WER: \(percent(rawWER)) (\(rawErrors) of \(words))")
        print("REPLAY corrected WER: \(percent(finalWER)) (\(finalErrors) of \(words))")
        print("REPLAY errors reduced: \(percent(reduction)) (fixed \(fixed), broke \(broken))")
        print("REPLAY correct words changed: \(percent(changed)) (\(correctChanged) of \(correctWords))")
        print(
            String(
                format: "REPLAY decode ms per word: p50 %.3f  p90 %.3f  p99 %.3f  max %.3f  mean %.3f",
                percentile(0.5), percentile(0.9), percentile(0.99), sorted.last ?? 0,
                sorted.reduce(0, +) / Double(max(sorted.count, 1))))
        print("REPLAY replacements by kind: \(kinds)")
        for example in examples { print("REPLAY example \(example)") }

        #expect(reduction >= Self.requiredReduction, "errors reduced \(percent(reduction))")
        #expect(changed < Self.allowedChanged, "correct words changed \(percent(changed))")
    }

    /// The synthetic sentences again, typed the way the owner's real taps behave: a tight hand
    /// (the taps of `real-taps.json` spread 8 and 9 pt around a key's centre, not the 12.8 and
    /// 22 pt of the noise above) whose errors are discrete. Rates are the ones counted in that file
    /// (483 intended letters): a letter left out 8.7%, a tap on a neighbouring key 2%, two
    /// neighbours swapped 1% of pairs, a stray extra tap 0.3%. This is the guard against fixing the
    /// real log by loosening what the decoder accepts: the correct words must still come out alone.
    @Test(.enabled(if: AutocorrectReplayTests.enabled))
    func replayWithTypingErrors() throws {
        var configuration = TapDecoder.Configuration.tuned
        var thresholds = AutocorrectPolicy.Thresholds.tuned
        if let tune = ProcessInfo.processInfo.environment["MURMUR_TYPING_TUNE"] {
            Self.apply(tune, to: &configuration, thresholds: &thresholds)
        }
        let repeats = Int(ProcessInfo.processInfo.environment["MURMUR_TYPING_BENCH_REPEATS"] ?? "") ?? 10
        let fixture = try TypingFixture(configuration: configuration)
        let sentences = try Self.sentences()
        var random = SplitMix64(seed: 0x4D75_726D_7572 ^ 0x51)
        let letterFrames = fixture.frames.filter { $0.kind.characterValue.map { $0.count == 1 && $0.first!.isLetter } ?? false }
        let pitchX = fixture.frame("w").keycap.midX - fixture.frame("q").keycap.midX
        let pitchY = fixture.frame("a").keycap.midY - fixture.frame("q").keycap.midY
        func neighbours(of letter: Character) -> [Character] {
            let here = fixture.frame(letter).keycap
            return letterFrames.compactMap { frame -> Character? in
                guard let other = frame.kind.characterValue?.first, other != letter else { return nil }
                let dx = abs(frame.keycap.midX - here.midX)
                let dy = abs(frame.keycap.midY - here.midY)
                return dx <= 1.15 * pitchX && dy <= 1.15 * pitchY ? other : nil
            }
        }
        func chance(_ probability: Double) -> Bool { Double.random(in: 0..<1, using: &random) < probability }

        var words = 0, rawErrors = 0, finalErrors = 0, correctWords = 0, correctChanged = 0, fixed = 0, broke = 0
        var milliseconds: [Double] = []
        var examples: [String] = []
        for _ in 0..<repeats {
            for sentence in sentences {
                var previous: Int?
                for (position, intended) in sentence.split(separator: " ").map(String.init).enumerated() {
                    let letters = Array(intended.filter { $0 != "'" })
                    var aimed: [Character] = []
                    for letter in letters {
                        if chance(0.003) { aimed.append(neighbours(of: letter).randomElement(using: &random)!) }
                        if chance(0.087) { continue }
                        aimed.append(chance(0.02) ? neighbours(of: letter).randomElement(using: &random)! : letter)
                    }
                    var index = 0
                    while index + 1 < aimed.count {
                        if chance(0.01), aimed[index] != aimed[index + 1] {
                            aimed.swapAt(index, index + 1)
                            index += 1
                        }
                        index += 1
                    }
                    var taps: [WordTap] = []
                    for letter in aimed {
                        let keycap = fixture.frame(letter).keycap
                        let point = CGPoint(
                            x: keycap.midX + 8 * Self.gaussian(&random), y: keycap.midY + 9 * Self.gaussian(&random))
                        taps.append(WordTap(point: point, key: Self.resolve(point, fixture: fixture, letters: letterFrames)))
                    }
                    let typed = taps.compactMap(\.key.characterValue).joined()
                    // One tap is never decoded (the keyboard skips it), and a word with nothing typed has none.
                    guard taps.count >= 2 else { previous = nil; continue }

                    let clock = ContinuousClock()
                    var decoding = TapDecoder.Decoding(typed: typed, typedID: nil, candidates: [])
                    let elapsed = clock.measure { decoding = fixture.decoder.decode(taps: taps, previous: previous) }
                    milliseconds.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                    let decision = AutocorrectPolicy.decide(
                        typed: typed, decoding: decoding, field: .standard,
                        knowledge: UserLexicon.empty.knowledge(of: typed, model: fixture.model),
                        position: position == 0 ? .start : .middle, rejections: RejectionSet(),
                        model: fixture.model, thresholds: thresholds)
                    var final = typed
                    if case .replace(let replacement) = decision { final = replacement.text }
                    words += 1
                    let rawWrong = typed != intended
                    let target = intended
                    let finalWrong = final != target
                    if rawWrong { rawErrors += 1 }
                    if finalWrong { finalErrors += 1 }
                    if rawWrong && !finalWrong { fixed += 1 }
                    if !rawWrong && finalWrong { broke += 1 }
                    if !rawWrong {
                        correctWords += 1
                        if final != typed { correctChanged += 1 }
                    }
                    if examples.count < 30, !rawWrong, final != typed { examples.append("\(intended): typed \(typed) -> \(final)") }
                    previous = final.split(separator: " ").last.flatMap { fixture.model.id(of: String($0)) }
                }
            }
        }
        let reduction = rawErrors == 0 ? 0 : 1 - Double(finalErrors) / Double(rawErrors)
        let changed = correctWords == 0 ? 0 : Double(correctChanged) / Double(correctWords)
        let sorted = milliseconds.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        func percent(_ value: Double) -> String { String(format: "%.2f%%", value * 100) }
        print("TYPOS words \(words), raw wrong \(percent(Double(rawErrors) / Double(words))), corrected wrong \(percent(Double(finalErrors) / Double(words)))")
        print("TYPOS errors reduced: \(percent(reduction)) (fixed \(fixed), broke \(broke))")
        print("TYPOS correct words changed: \(percent(changed)) (\(correctChanged) of \(correctWords))")
        print(String(format: "TYPOS decode ms per word: p50 %.3f  p99 %.3f  max %.3f", percentile(0.5), percentile(0.99), sorted.last ?? 0))
        for example in examples { print("TYPOS correct word changed: \(example)") }
        #expect(reduction >= 0.4, "errors reduced \(percent(reduction))")
        #expect(changed < Self.allowedChanged, "correct words changed \(percent(changed))")
    }

    // MARK: - Generator

    /// A deterministic generator, so a run's taps never change (`SplitMix64`).
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A standard normal draw (Box-Muller).
    static func gaussian(_ random: inout SplitMix64) -> Double {
        let u1 = Double.random(in: Double.leastNonzeroMagnitude..<1, using: &random)
        let u2 = Double.random(in: 0..<1, using: &random)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    /// The letter key a tap lands on. A tap on any other key (shift, delete, the strip) would
    /// type something else entirely; the replay counts it as the nearest letter instead, so one
    /// stray tap does not end the sentence.
    static func resolve(_ point: CGPoint, fixture: TypingFixture, letters: [KeyFrame]) -> KeyKind {
        if let hit = HitTester.key(at: point, frames: fixture.frames, bias: [:]),
            let letter = hit.kind.characterValue, letter.count == 1, letter.first!.isLetter
        {
            return hit.kind
        }
        let nearest = letters.min {
            hypot($0.keycap.midX - point.x, $0.keycap.midY - point.y)
                < hypot($1.keycap.midX - point.x, $1.keycap.midY - point.y)
        }
        return nearest!.kind
    }

    static func sentences() throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: "replay-sentences", withExtension: "txt"))
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Tuning knobs

    /// Applies `name=value` pairs to the decoder and policy constants.
    static func apply(
        _ tune: String, to configuration: inout TapDecoder.Configuration,
        thresholds: inout AutocorrectPolicy.Thresholds
    ) {
        for pair in tune.split(separator: ",") {
            let parts = pair.split(separator: "=").map(String.init)
            guard parts.count == 2, let value = Double(parts[1]) else { continue }
            switch parts[0] {
            case "sigmaX": configuration.sigmaXFactor = value
            case "sigmaY": configuration.sigmaYFactor = value
            case "lambda": configuration.languageWeight = value
            case "backoff": configuration.backoffWeight = value
            case "beam": configuration.beamWidth = Int(value)
            case "editBeam": configuration.editBeamWidth = Int(value)
            case "beam2": configuration.secondStageBeamWidth = Int(value)
            case "prune": configuration.pruneSigmas = value
            case "transposition": configuration.transpositionPenalty = value
            case "omission": configuration.omissionPenalty = value
            case "insertion": configuration.insertionPenalty = value
            case "split": configuration.splitPenalty = value
            case "substitution": configuration.substitutionPenalty = value
            case "substitutionSpread": configuration.substitutionSpread = value
            case "secondEdit": configuration.secondEditPenalty = value
            case "twoEditMinTaps": configuration.twoEditMinTaps = Int(value)
            case "literalShortLetters": configuration.literalShortLetters = Int(value)
            case "splitEditBeam": configuration.splitEditBeamWidth = Int(value)
            case "splitEditMinTaps": configuration.splitEditMinTaps = Int(value)
            case "splitEditCuts": configuration.splitEditCuts = Int(value)
            case "settled": configuration.settledPosterior = value
            case "apostrophe": configuration.apostrophePenalty = value
            case "literalBase": configuration.literalLogPriorBase = value
            case "literalPerLetter": configuration.literalLogPriorPerLetter = value
            case "unknownPosterior": thresholds.unknownPosterior = value
            case "unknownRatio": thresholds.unknownRatio = value
            case "knownPosterior": thresholds.knownPosterior = value
            case "knownMaxEdits": thresholds.knownMaxEdits = Int(value)
            default: print("REPLAY unknown tuning knob \(parts[0])")
            }
        }
    }
}
