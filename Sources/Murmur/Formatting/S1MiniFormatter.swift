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

        // The budget grows with the text and with how slow this machine has measured, so a
        // long dictation under load is not cut off at the idle figure (see S1MiniEngine).
        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        let budget = await engine.budget(forWords: words)
        let startedAt = ContinuousClock.now

        do {
            let cleaned: String = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await engine.clean(trimmed, profile: profile) }
                group.addTask {
                    try await Task.sleep(for: budget)
                    throw S1MiniError.budgetExceeded
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
            if case S1MiniError.budgetExceeded = error {
                await engine.noteTimeout(words: words, elapsed: ContinuousClock.now - startedAt)
            }
            Log.speech.info("S1-mini cleanup failed (\(error.localizedDescription, privacy: .public)) — falling back")
            return await fallback.format(trimmed)
        }
    }
}
