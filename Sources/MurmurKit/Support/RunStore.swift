import Foundation
import Observation

/// Feeds the history and comparison views, which update live without a manual refresh.
@MainActor @Observable
public final class RunStore {
    public static let shared = RunStore()

    public private(set) var runs: [DictationRun] = []

    private init() { RunLog.refresh() }

    /// Asks the history queue to republish. The file is read once, in the background.
    public func reload() {
        RunLog.refresh()
    }

    /// Called by `RunLog` on the main queue, in the order its changes were made.
    public func apply(_ snapshot: [DictationRun]) {
        runs = snapshot
    }

    /// The comparison groups, newest first.
    public var comparisons: [[DictationRun]] {
        var order: [String] = []
        var groups: [String: [DictationRun]] = [:]
        for run in runs {
            guard let group = run.group else { continue }
            if groups[group] == nil { order.append(group) }
            groups[group, default: []].append(run)
        }
        return order
            .compactMap { groups[$0] }
            .sorted { ($0.first?.date ?? .distantPast) > ($1.first?.date ?? .distantPast) }
    }

    /// Recordings made outside a comparison, newest first. Storage is oldest first.
    public var singles: [DictationRun] {
        runs.filter { $0.group == nil }.reversed()
    }
}
