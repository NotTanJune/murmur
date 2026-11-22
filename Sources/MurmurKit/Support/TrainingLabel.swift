import Foundation
import MurmurDictionary

/// What a history run can teach the model, and where that came from.
///
/// A label is always what was said, in Bark's own form. On a rules-cleaned run the typed
/// text is that transcript, so the history edit starts from it. S1-mini and Apple
/// Intelligence rewrite, so their rows are corrected against the engine's raw text instead:
/// the edit opens on `rawText`, and the row shows the correction once there is one.
public enum TrainingLabel {
    public enum Source: String, Sendable {
        case edit
        case dictionary
    }

    public struct Resolved: Equatable, Sendable {
        public let text: String
        public let source: Source
    }

    /// Whether the run can be corrected by hand. A model-cleaned run needs its raw text;
    /// runs filed before that was kept have nothing to correct against.
    public static func editAllowed(_ run: DictationRun) -> Bool {
        run.cleanup == nil || !(run.rawText ?? "").isEmpty
    }

    /// The transcript an edit starts from and is compared with.
    public static func editBase(_ run: DictationRun) -> String {
        run.cleanup == nil ? run.text : (run.rawText ?? "")
    }

    /// What the history row shows: the correction once there is one, on every kind of run.
    /// A corrected row that went back to its uncorrected text read as the edit being lost.
    public static func displayText(_ run: DictationRun) -> String {
        run.label ?? run.text
    }

    public static func resolve(_ run: DictationRun, corrector: DictionaryCorrector) -> Resolved? {
        if editAllowed(run), let label = run.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return Resolved(text: label, source: .edit)
        }
        guard let raw = run.rawText, !raw.isEmpty else { return nil }
        let (corrected, applied) = corrector.apply(to: raw)
        guard !applied.isEmpty else { return nil }
        return Resolved(text: corrected, source: .dictionary)
    }
}
