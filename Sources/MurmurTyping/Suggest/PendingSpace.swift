import Foundation

/// The space a tapped suggestion typed for the user, and what the next key does with it.
///
/// Tapping a suggestion replaces the word and types a trailing space (`SuggestionEngine.edit`).
/// That space is "pending" until the next key: a space press is swallowed, because the user
/// already has one, though the controller still records the press time so two quick presses can
/// become the period shortcut; a closing mark (`, . ! ? ; : )`) takes the space, so the
/// controller deletes it before typing the mark; any other key just disarms it. The controller
/// owns one value of this type and is the only place it mutates, which is why it carries no
/// state besides the arming time.
public struct PendingSpace: Sendable {
    /// The marks that sit against the word before them: a suggestion's space goes when one of
    /// these is typed right after it.
    public static let closingMarks: Set<Character> = [",", ".", "!", "?", ";", ":", ")"]

    /// When the suggestion was inserted, in the caller's clock (seconds). Nil when not armed.
    public private(set) var armedAt: TimeInterval?

    public init() {}

    /// Whether a suggestion's trailing space is still the last thing typed.
    public var isArmed: Bool { armedAt != nil }

    /// Arms the pending space. `time` is the caller's own monotonic clock reading, kept so a test
    /// or the double-space logic can tell how long ago the suggestion landed.
    public mutating func noteSuggestionInserted(at time: TimeInterval) {
        armedAt = time
    }

    /// Whether the space key should be swallowed. True exactly once per arming: the space the
    /// suggestion typed already stands in for this press. The controller still records the press
    /// time for the double-space shortcut.
    public mutating func consumeSpace() -> Bool {
        guard isArmed else { return false }
        armedAt = nil
        return true
    }

    /// Whether `mark` should take the pending space with it, so the controller deletes the space
    /// before typing the mark. False when nothing is armed: a space the user typed themselves is
    /// theirs to keep. This does not disarm; the controller calls `disarm()` once it has acted.
    public func takesSpace(before mark: Character) -> Bool {
        isArmed && Self.closingMarks.contains(mark)
    }

    /// Any other key: the pending space becomes an ordinary one.
    public mutating func disarm() {
        armedAt = nil
    }
}
