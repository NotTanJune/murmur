import CoreGraphics
import Foundation

/// Decides which key a touch means. The base answer is the key whose hit rect holds the point;
/// a likelier next letter can then claim a few points of its neighbour's area.
public enum HitTester {
    /// The most a likelier letter may take from a neighbour, in points. Without a cap a very
    /// confident prediction would swallow the key beside it and make that key untypable.
    public static let maximumClaim: CGFloat = 5
    /// Points claimed per unit of log-odds by which a letter is likelier than its neighbour.
    public static let claimPerLogOdd: CGFloat = 1.25

    /// The key under `point`, or nil when the point is outside every hit rect (the strip, for
    /// one). `bias` maps a letter to the log-odds of it being typed next; letters it does not
    /// list count as 0. A letter likelier than the one under the finger claims the part of that
    /// key within `min(maximumClaim, claimPerLogOdd × difference)` points of its own hit rect,
    /// in any direction: after "th" a touch just inside d, below e, types e, as on the stock
    /// keyboard. Only character keys claim or are claimed, so a modifier never moves.
    public static func key(
        at point: CGPoint, frames: [KeyFrame], bias: [String: Double]
    ) -> KeyFrame? {
        guard let base = baseKey(at: point, frames: frames) else { return nil }
        guard let letter = base.kind.characterValue, !bias.isEmpty else { return base }
        // A mark beside the space bar (an email field's "@", a web search's ".") is not a letter
        // the bias knows, so every letter would count as likelier: it keeps its own key.
        guard letter.count == 1, letter.first?.isLetter == true else { return base }
        let own = bias[letter] ?? 0

        // Of the likelier letters close enough to claim the point, the likeliest wins.
        var best: (frame: KeyFrame, difference: Double)?
        for frame in frames where frame != base {
            guard let other = frame.kind.characterValue else { continue }
            let difference = (bias[other] ?? 0) - own
            guard difference > 0 else { continue }
            let claim = min(maximumClaim, claimPerLogOdd * CGFloat(difference))
            guard distance(from: point, to: frame.hitRect) <= claim else { continue }
            if difference > (best?.difference ?? 0) { best = (frame, difference) }
        }
        return best?.frame ?? base
    }

    /// How far `point` lies outside `rect`, 0 when inside.
    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - Internals

    /// The key whose hit rect holds the point. Where two do, only the space bar's reach into the
    /// row above can be the cause, and the space bar wins there.
    private static func baseKey(at point: CGPoint, frames: [KeyFrame]) -> KeyFrame? {
        // A rect's right and bottom edges are exclusive, as in CoreGraphics, except the
        // outermost ones: a touch exactly on the view's last edge still belongs to a key.
        let maxX = frames.map(\.hitRect.maxX).max() ?? 0
        let maxY = frames.map(\.hitRect.maxY).max() ?? 0
        let matches = frames.filter { frame in
            let rect = frame.hitRect
            let insideX = point.x >= rect.minX && (point.x < rect.maxX || (rect.maxX == maxX && point.x == maxX))
            let insideY = point.y >= rect.minY && (point.y < rect.maxY || (rect.maxY == maxY && point.y == maxY))
            return insideX && insideY
        }
        return matches.first(where: { $0.kind == .space }) ?? matches.first
    }
}
