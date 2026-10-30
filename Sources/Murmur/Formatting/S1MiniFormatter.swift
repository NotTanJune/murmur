import Foundation

/// Cleanup through S1-mini, steered by the profile chosen when the hold started.
///
/// Same contract as `FoundationModelFormatter`: anything that goes wrong (model not loaded,
/// input too long, a timeout, an implausible result) degrades to `RuleBasedFormatter`, so an
/// utterance is never lost to the cleanup pass.
struct S1MiniFormatter: TextFormatter {
    let profile: CleanupProfile
    var engine: S1MiniEngine = .shared
    private let fallback = RuleBasedFormatter()

    func format(_ raw: String) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // After an idle unload the model reloads at the press, in parallel with speaking. A
        // short hold can end before that finishes; wait for it rather than silently giving
        // this utterance the rule pass. The generation budget starts after.
        guard await engine.waitUntilReady() else {
            Log.speech.info("S1-mini not loaded — using rule-based cleanup")
            return await fallback.format(trimmed)
        }

        // Generation runs at about 165 tokens/s on an M2: a 135-word paragraph took 1.2 s.
        // The budget grows with length so long dictation isn't cut off at a fixed limit.
        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        let budget = Duration.milliseconds(1_500 + words * 20)

        do {
            let cleaned = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await engine.clean(trimmed, profile: profile) }
                group.addTask {
                    try await Task.sleep(for: budget)
                    throw CancellationError()
                }
                guard let first = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return first
            }

            // S1-mini returns nothing for input that was only filler, which is correct.
            if cleaned.isEmpty, FoundationModelFormatter.spokenWordCount(trimmed) == 0 {
                return ""
            }
            guard FoundationModelFormatter.isPlausibleCleanup(original: trimmed, cleaned: cleaned, writesNumerals: true) else {
                Log.speech.info("S1-mini output rejected — using rule-based cleanup")
                return await fallback.format(trimmed)
            }
            return cleaned
        } catch {
            Log.speech.info("S1-mini cleanup failed (\(error.localizedDescription, privacy: .public)) — falling back")
            return await fallback.format(trimmed)
        }
    }
}
