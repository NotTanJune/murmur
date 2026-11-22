import Foundation

/// What a touch on the keyboard's talk key means, kept free of UIKit so the Mac can test it.
///
/// Touch-down starts recording at once, so a hold loses nothing to the tap check. A touch
/// shorter than `tapLimit` locks recording on instead; the next touch ends it.
public struct HoldGesture: Sendable {
    /// A touch shorter than this locks recording instead of ending it.
    public static let tapLimit: TimeInterval = 0.3

    public enum Action: Sendable, Equatable {
        /// Begin a hold.
        case start
        /// The touch was a tap: keep recording after the finger lifts.
        case lock
        /// End the hold and type what was said.
        case finish
        case none
    }

    private enum Phase {
        case idle
        case pressing(since: Date)
        case locked
        /// A touch landed while locked; lifting it finishes.
        case endingLock
        /// A touch landed while the last hold was still finishing; it does nothing.
        case ignored
    }

    private var phase = Phase.idle

    public init() {}

    /// `busy` is true while the previous hold is still finishing.
    public mutating func touchDown(at time: Date, busy: Bool) -> Action {
        switch phase {
        case .idle:
            if busy {
                phase = .ignored
                return .none
            }
            phase = .pressing(since: time)
            return .start
        case .locked:
            phase = .endingLock
            return .none
        case .pressing, .endingLock, .ignored:
            return .none
        }
    }

    public mutating func touchUp(at time: Date) -> Action {
        switch phase {
        case .pressing(let since):
            if time.timeIntervalSince(since) < Self.tapLimit {
                phase = .locked
                return .lock
            }
            phase = .idle
            return .finish
        case .endingLock:
            phase = .idle
            return .finish
        case .ignored:
            phase = .idle
            return .none
        case .idle, .locked:
            return .none
        }
    }

    /// Forgets the touch, for when the hold ended some other way (a failure, the keyboard
    /// closing) and a lock or a press would otherwise outlive it.
    public mutating func reset() {
        phase = .idle
    }
}
