import Foundation
import MurmurTyping

/// Diagnostics only: finds which part of a key press costs taps.
///
/// Armed from Setup ("Two-key test"), it starts at the next touch-down and runs the keyboard
/// through five stages of `stageSeconds` each while the owner taps f and j in turn as fast as
/// they type. Each stage does less per key than the one before: everything; no text rules,
/// autocorrect or strip refresh; no pop-up either; no haptic or click either; and finally
/// nothing at all (touches are only logged). Two fingers alternating must produce f, j, f, j,
/// so a tap the keyboard never received shows in the log as the same key twice running, and the
/// stage where those repeats stop names the cause. If even the last stage repeats, nothing the
/// keys do is to blame and the loss is below the keyboard's code.
struct TypingStageTest {
    enum Stage: Int, CaseIterable {
        case full, noRefresh, noPopup, insertOnly, bare

        var inserts: Bool { self != .bare }
        var feedback: Bool { self == .noRefresh || self == .noPopup }
        var popups: Bool { self == .noRefresh }

        var label: String {
            switch self {
            case .full: "full"
            case .noRefresh: "no rules or strip"
            case .noPopup: "no pop-up"
            case .insertOnly: "insert only"
            case .bare: "nothing"
            }
        }
    }

    static let stageSeconds: TimeInterval = 5

    private var start: TimeInterval?
    private var current: Stage?
    /// True for the one event on which the test ended.
    private(set) var justFinished = false

    /// The stage this event runs under, or nil when no test is running.
    mutating func stage(for event: TouchEvent, at time: TimeInterval) -> Stage? {
        justFinished = false
        let isDown: Bool = if case .began = event { true } else { false }
        if start == nil {
            guard isDown, TypingDiagnostics.takeStageTest() else { return nil }
            start = time
        }
        guard let start else { return nil }
        // Stages change, and the test ends, on a touch-down only, so every press is handled
        // whole by one stage.
        guard isDown else { return current }
        let index = Int((time - start) / Self.stageSeconds)
        guard let stage = Stage(rawValue: index) else {
            self.start = nil
            current = nil
            justFinished = true
            TypingDiagnostics.log("stage", ["name": "done"])
            return nil
        }
        if stage != current {
            current = stage
            TypingDiagnostics.log("stage", ["name": stage.label, "index": stage.rawValue])
        }
        return current
    }
}
