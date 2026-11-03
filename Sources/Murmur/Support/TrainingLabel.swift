import Foundation
import MurmurDictionary

/// What a history run can teach the model, and where that came from.
///
/// An edit of a rules-cleaned transcript is a transcript: the user fixed what was heard. An
/// edit of an S1-mini or Apple Intelligence output is a rewrite, so those runs may only
/// contribute through the dictionary, which is applied to the engine's raw text.
enum TrainingLabel {
    enum Source: String, Sendable {
        case edit
        case dictionary
    }

    struct Resolved: Equatable, Sendable {
        let text: String
        let source: Source
    }

    /// Whether the history edit field is a transcript correction for this run.
    static func editAllowed(_ run: DictationRun) -> Bool {
        run.cleanup == nil
    }

    static func resolve(_ run: DictationRun, corrector: DictionaryCorrector) -> Resolved? {
        if editAllowed(run), let label = run.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return Resolved(text: label, source: .edit)
        }
        guard let raw = run.rawText, !raw.isEmpty else { return nil }
        let (corrected, applied) = corrector.apply(to: raw)
        guard !applied.isEmpty else { return nil }
        return Resolved(text: corrected, source: .dictionary)
    }
}
