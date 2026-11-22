import Foundation
import MurmurDictionary

/// What a finished transcript looks like: the text to type and the dictionary corrections
/// that shaped it.
public struct FinishedText: Sendable {
    public let text: String
    public let applied: [AppliedCorrection]

    public init(text: String, applied: [AppliedCorrection]) {
        self.text = text
        self.applied = applied
    }
}

/// Turns a raw transcript into the text that gets typed, in one fixed order that every
/// front end shares: cleanup (off, pipelined or whole-text), then the dictionary.
public enum TranscriptFinisher {
    /// - With cleanup off the raw transcript goes straight to the dictionary.
    /// - With a `pipeline`, pieces cleaned while the key was held are joined with the cleaned
    ///   remainder, and `formatter` cleans the whole transcript if the pipeline has to give up.
    /// - Otherwise `formatter` cleans the whole transcript.
    ///
    /// The dictionary always runs last, whatever the cleanup setting: engine biasing only
    /// raises the odds of the right word, and this pass is what guarantees it.
    @MainActor
    public static func finish(
        raw: String,
        cleanupEnabled: Bool,
        formatter: any TextFormatter,
        pipeline: CleanupPipeline?,
        corrector: DictionaryCorrector
    ) async -> FinishedText {
        let cleaned: String
        if !cleanupEnabled {
            cleaned = raw
        } else if let pipeline {
            cleaned = await pipeline.finish(transcript: raw) {
                await formatter.format(raw)
            }
        } else {
            cleaned = await formatter.format(raw)
        }
        let applied = corrector.apply(to: cleaned)
        return FinishedText(text: applied.text, applied: applied.applied)
    }
}
