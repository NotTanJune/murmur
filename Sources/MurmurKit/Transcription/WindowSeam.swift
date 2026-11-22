import Foundation

/// One decoded word with its place on the recording's timeline, in seconds.
public struct TimedWord: Sendable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }

    /// The word for comparison across windows: no punctuation, no case.
    var core: String {
        text.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).lowercased()
    }
}

/// Where two overlapping windows of one recording are joined.
///
/// Consecutive windows both decode the audio around the boundary between their centre
/// chunks. The earlier window is unreliable at its very end, where its audio stops in the
/// middle of speech: Bark writes whatever part of a word it heard and closes it with a
/// period ("inference." for "infringement", "act." for "actions"). The later window is
/// unreliable at its very start for the mirror reason. Around the boundary itself both have
/// context on both sides, so that is where the join goes: on a word both windows agree on,
/// taking everything before it from the earlier window and everything from it on from the
/// later one. Neither window's cut-off edge is ever kept.
public enum WindowSeam {
    /// How far either side of the boundary a join may land, in seconds. Both windows have at
    /// least this much audio beyond the join, and the earlier window's words before
    /// `boundary - reach` are final as soon as it is decoded.
    public static let reach: TimeInterval = 1.0
    /// Where the join is aimed, in seconds past the boundary. The earlier window reaches it
    /// with eleven seconds of its own words behind it and a second and a half of audio
    /// ahead; the later one has only just started writing. At the boundary itself the later
    /// window wrote "n. us" for the "N U S" the earlier one had right (2026-11-13).
    static let lean: TimeInterval = 0.5
    /// The same word in two windows starts within this many seconds of itself. Frames are
    /// 80 ms and the windows are offset by a fraction of one.
    static let tolerance: TimeInterval = 0.4

    /// Joins `next` onto `previous`, the earlier window's words not yet settled.
    /// `settledEnd` is where the last word already settled before them ended.
    public static func join(
        _ previous: [TimedWord], _ next: [TimedWord], boundary: TimeInterval, settledEnd: TimeInterval = 0
    ) -> [TimedWord] {
        if let (p, q) = agreedWord(previous, next, boundary: boundary) {
            return Array(previous[..<p]) + Array(next[q...])
        }

        // No word in common near the boundary: silence there, or the windows heard it
        // differently. Cut by time. The earlier window keeps the words it started before the
        // aim point; the later one resumes after the last of them, judged by each word's
        // midpoint so a word the two windows timed a frame apart is neither doubled nor lost.
        let target = boundary + lean
        let kept = previous.filter { $0.start < target }
        let resume = kept.last.map { max(target, $0.end) } ?? max(boundary - reach, settledEnd)
        return kept + next.filter { ($0.start + $0.end) / 2 >= resume }
    }

    /// The pair of indices of one word both windows decoded near the boundary, preferring a
    /// word inside a run of agreement and then the one closest to the aim point.
    private static func agreedWord(
        _ previous: [TimedWord], _ next: [TimedWord], boundary: TimeInterval
    ) -> (Int, Int)? {
        var best: (pair: (Int, Int), inRun: Bool, distance: TimeInterval)?
        for (p, word) in previous.enumerated() where abs(word.start - boundary) <= reach && !word.core.isEmpty {
            // The later window's first word is its cut-in edge; it is never the join.
            for q in next.indices.dropFirst()
            where next[q].core == word.core && abs(next[q].start - word.start) <= tolerance {
                func agrees(_ offset: Int) -> Bool {
                    let (i, j) = (p + offset, q + offset)
                    guard previous.indices.contains(i), next.indices.contains(j), j > 0 else { return false }
                    return !previous[i].core.isEmpty && previous[i].core == next[j].core
                }
                let inRun = agrees(1) || agrees(-1)
                let distance = abs(word.start - (boundary + lean))
                if let current = best {
                    if current.inRun && !inRun { continue }
                    if current.inRun == inRun && current.distance <= distance { continue }
                }
                best = ((p, q), inRun, distance)
            }
        }
        return best?.pair
    }
}
