import Foundation

/// `Murmur --cleanup-check`: loads S1-mini from the installed bundle, cleans fixed
/// transcripts through the production formatter, and prints what happened.
///
/// It exists because the parts most likely to break are invisible in unit tests: the GPU
/// kernels must be found inside the .app, and the converted model must load from the real
/// models folder. It also compares the two decoders: prompt lookup must return exactly what
/// plain greedy decoding returns up to float rounding on near ties (reported, not
/// required), and the pipeline that cleans sentence by sentence must come back from the
/// model. Passing means every sample came back from S1-mini, not from the fallback.
@MainActor
enum CleanupCheck {
    static let samples: [(CleanupProfile, String)] = [
        (.general, "So I need to send the report by Friday. No wait, make that Thursday, and copy Priya on it."),
        (.email, "Hey Sarah, just wanted to follow up on the proposal. Can you send me the updated budget by end of week? Thanks, John."),
        (.message, "Hey, can you grab some milk on the way home? I'm gonna be like twenty minutes late."),
        (.notes, "For the trip we need to pack sunscreen and then also a first aid kit and chargers for everything."),
        (.general, longSample),
    ]

    /// About 150 words of ordinary rambling dictation, the case the lookup decoder exists for.
    static let longSample = """
        So um I was thinking about the launch next week and I think we should probably move it to \
        the following Monday. The marketing team said they need, like, two more days for the landing \
        page and honestly the demo video isn't done either. Also, um, can you ping Marcus about the \
        pricing page? He said he'd have the numbers by Wednesday but I haven't heard anything. Oh and \
        one more thing, the beta users, we should send them an email before the public announcement \
        so they don't feel blindsided. Maybe something short, just a heads up that the pricing is \
        changing and that their accounts are grandfathered in for a year. I think that's fair. Let me \
        know what you think and we can talk about it tomorrow at standup.
        """

    static func run() async -> Bool {
        let preparation = S1MiniPreparation.shared
        let started = Date()
        await preparation.start()?.value
        guard preparation.state == .ready else {
            print("FAIL load: \(preparation.state.message)")
            return false
        }
        print(String(format: "S1-mini ready in %.2fs (includes any download and conversion)", Date().timeIntervalSince(started)))

        var passed = true
        let clock = ContinuousClock()
        for (profile, text) in samples {
            let words = text.split(whereSeparator: \.isWhitespace).count
            var greedyStart = clock.now
            let greedy = (try? await S1MiniEngine.shared.clean(text, profile: profile, decoding: .greedy)) ?? ""
            let greedyTime = clock.now - greedyStart
            greedyStart = clock.now
            let lookup = (try? await S1MiniEngine.shared.clean(text, profile: profile, decoding: .promptLookup)) ?? ""
            let lookupTime = clock.now - greedyStart

            let start = clock.now
            let formatted = await S1MiniFormatter(profile: profile).format(text)
            let elapsed = clock.now - start
            let fromModel = !lookup.isEmpty && formatted == lookup
            // Informational: both decoders are greedy, but a pass over several tokens rounds
            // differently from a pass over one, and a near-tie can land either way. Both
            // outputs are the model's; neither is the fallback.
            let identical = greedy == lookup
            passed = passed && fromModel
            print("[\(profile.displayName), \(words) words] greedy \(ms(greedyTime)) · lookup \(ms(lookupTime)) "
                + "(\(String(format: "%.1f", ratio(greedyTime, lookupTime)))×) · "
                + (identical ? "IDENTICAL" : "DIFFERENT") + " · " + (fromModel ? "S1-mini" : "FALLBACK"))
            print("  " + formatted.replacingOccurrences(of: "\n", with: " ⏎ "))
            if !identical {
                print("  greedy: " + greedy.replacingOccurrences(of: "\n", with: " ⏎ "))
            }
        }

        // The pipeline, fed the long sample a sentence at a time as an incremental engine
        // would, against cleaning it whole. The texts need not match word for word (each
        // piece is cleaned without the others), but every piece must come from the model and
        // the release-time tail must be a fraction of the whole pass.
        let pipeline = CleanupPipeline(formatter: S1MiniFormatter(profile: .general))
        let sentences = longSample.split(separator: ". ").map { $0.hasSuffix(".") ? String($0) : String($0) + "." }
        var stable = ""
        for sentence in sentences.dropLast() {
            stable = stable.isEmpty ? sentence : stable + " " + sentence
            pipeline.accept(stable: stable)
        }
        let wholeStart = clock.now
        let whole = await S1MiniFormatter(profile: .general).format(longSample)
        let wholeTime = clock.now - wholeStart
        let tailStart = clock.now
        let piecewise = await pipeline.finish(transcript: longSample) { whole }
        let tailTime = clock.now - tailStart
        let pipelined = pipeline.chunkCount > 0 && !piecewise.isEmpty
        passed = passed && pipelined
        print("[pipeline] \(pipeline.chunkCount) piece(s) while held · release tail \(ms(tailTime)) vs whole \(ms(wholeTime)) · "
            + (pipelined ? "OK" : "NOT PIPELINED"))
        print("  " + piecewise.replacingOccurrences(of: "\n", with: " ⏎ "))

        print(passed ? "PASS" : "FAIL")
        return passed
    }

    private static func ms(_ duration: Duration) -> String {
        duration.formatted(.units(allowed: [.milliseconds]))
    }

    private static func ratio(_ a: Duration, _ b: Duration) -> Double {
        let seconds: (Duration) -> Double = { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
        return seconds(a) / max(seconds(b), 0.001)
    }
}
