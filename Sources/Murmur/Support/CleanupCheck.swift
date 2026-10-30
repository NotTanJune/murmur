import Foundation

/// `Murmur --cleanup-check`: loads S1-mini from the installed bundle, cleans one fixed
/// transcript per profile through the production formatter, and prints what happened.
///
/// It exists because the parts most likely to break are invisible in unit tests: the GPU
/// kernels must be found inside the .app, and the converted model must load from the real
/// models folder. Passing means every sample came back from S1-mini, not from the fallback.
@MainActor
enum CleanupCheck {
    static let samples: [(CleanupProfile, String)] = [
        (.general, "So I need to send the report by Friday. No wait, make that Thursday, and copy Priya on it."),
        (.email, "Hey Sarah, just wanted to follow up on the proposal. Can you send me the updated budget by end of week? Thanks, John."),
        (.message, "Hey, can you grab some milk on the way home? I'm gonna be like twenty minutes late."),
        (.notes, "For the trip we need to pack sunscreen and then also a first aid kit and chargers for everything."),
    ]

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
        for (profile, text) in samples {
            let direct = (try? await S1MiniEngine.shared.clean(text, profile: profile)) ?? ""
            let clock = ContinuousClock()
            let start = clock.now
            let formatted = await S1MiniFormatter(profile: profile).format(text)
            let elapsed = clock.now - start
            let fromModel = !direct.isEmpty && formatted == direct
            passed = passed && fromModel
            print("[\(profile.displayName)] \(elapsed.formatted(.units(allowed: [.milliseconds]))) "
                + (fromModel ? "S1-mini" : "FALLBACK"))
            print("  " + formatted.replacingOccurrences(of: "\n", with: " ⏎ "))
        }
        print(passed ? "PASS" : "FAIL")
        return passed
    }
}
