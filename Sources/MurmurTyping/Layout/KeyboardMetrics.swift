import CoreGraphics
import Foundation

/// Where one key sits. `keycap` is the rectangle the view draws; `hitRect` is the larger area
/// that counts as a touch on this key, so a finger that lands in a gap still reaches a key.
public struct KeyFrame: Equatable, Sendable {
    public let kind: KeyKind
    /// The drawn key, in the keyboard view's coordinates (origin at its top left).
    public let keycap: CGRect
    /// The touch area. Neighbouring hit rects meet in the middle of the gap between them, and
    /// only the space bar's overlaps another key's (see `KeyboardMetrics.frames(for:)`).
    public let hitRect: CGRect

    public init(kind: KeyKind, keycap: CGRect, hitRect: CGRect) {
        self.kind = kind
        self.keycap = keycap
        self.hitRect = hitRect
    }
}

/// The numbers the layout is built from. `MurmurTyping` cannot import the design system, so the
/// iPhone target fills this from its `DS.Keyboard` tokens; the defaults below are the values
/// measured on the stock iOS keyboard, which let the tests run without a view.
public struct MetricsConstants: Sendable {
    /// The suggestion strip above the keys.
    public var stripHeight: CGFloat
    /// The space between the strip and the first row.
    public var stripGap: CGFloat
    public var keycapHeight: CGFloat
    /// The space between two rows of keys.
    public var rowGap: CGFloat
    /// The space between two keys in a row.
    public var keyGap: CGFloat
    /// The space between the view's side edge and the outermost keycap.
    public var sideInset: CGFloat
    public var bottomInset: CGFloat
    /// The width the fixed key widths below were measured at. Shift and delete scale with the
    /// view's width relative to it, as on the stock keyboard; the bottom row does not.
    public var referenceWidth: CGFloat
    /// Shift, delete, and the `#+=` or `123` key beside the third row, at `referenceWidth`.
    public var modifierKeyWidth: CGFloat
    /// The `123` or `ABC` key in the bottom row.
    public var pageKeyWidth: CGFloat
    public var emojiKeyWidth: CGFloat
    public var globeKeyWidth: CGFloat
    public var returnKeyWidth: CGFloat
    /// How far the space bar's touch area reaches up into the row above it.
    public var spaceHitReach: CGFloat

    public init(
        stripHeight: CGFloat,
        stripGap: CGFloat,
        keycapHeight: CGFloat,
        rowGap: CGFloat,
        keyGap: CGFloat,
        sideInset: CGFloat,
        bottomInset: CGFloat,
        referenceWidth: CGFloat,
        modifierKeyWidth: CGFloat,
        pageKeyWidth: CGFloat,
        emojiKeyWidth: CGFloat,
        globeKeyWidth: CGFloat,
        returnKeyWidth: CGFloat,
        spaceHitReach: CGFloat
    ) {
        self.stripHeight = stripHeight
        self.stripGap = stripGap
        self.keycapHeight = keycapHeight
        self.rowGap = rowGap
        self.keyGap = keyGap
        self.sideInset = sideInset
        self.bottomInset = bottomInset
        self.referenceWidth = referenceWidth
        self.modifierKeyWidth = modifierKeyWidth
        self.pageKeyWidth = pageKeyWidth
        self.emojiKeyWidth = emojiKeyWidth
        self.globeKeyWidth = globeKeyWidth
        self.returnKeyWidth = returnKeyWidth
        self.spaceHitReach = spaceHitReach
    }

    /// Portrait, measured from the stock keyboard on a 393 pt iPhone: 43 pt keycaps on a 54 pt
    /// pitch. iOS adds about 16 pt of its own above a third-party keyboard, so the strip and its
    /// gap are 38 pt and not the stock 52 (the gap was 4 until the owner asked for more air
    /// between the strip and the keys): 243 pt tall in total.
    public static let portrait = MetricsConstants(
        stripHeight: 44, stripGap: 8, keycapHeight: 43, rowGap: 11, keyGap: 6, sideInset: 6,
        bottomInset: 0, referenceWidth: 393, modifierKeyWidth: 44, pageKeyWidth: 42,
        emojiKeyWidth: 42, globeKeyWidth: 42, returnKeyWidth: 91, spaceHitReach: 2.5)

    /// Landscape: the strip stays 44 pt, but the gap, the keys and the rows shrink to fit a
    /// screen that is barely taller than the keyboard.
    public static let landscape = MetricsConstants(
        stripHeight: 44, stripGap: 6, keycapHeight: 32, rowGap: 8, keyGap: 6, sideInset: 6,
        bottomInset: 0, referenceWidth: 393, modifierKeyWidth: 44, pageKeyWidth: 42,
        emojiKeyWidth: 42, globeKeyWidth: 42, returnKeyWidth: 91, spaceHitReach: 2.5)
}

/// The geometry of a keyboard of one width: its height, its key widths and every key's frame.
/// Coordinates start at the top left of the keyboard view, so the suggestion strip is the band
/// from y 0 to `stripHeight` and the first row of keycaps begins below the strip gap.
public struct KeyboardMetrics: Sendable {
    public let width: CGFloat
    public let isLandscape: Bool
    public let constants: MetricsConstants

    public init(width: CGFloat, isLandscape: Bool, constants: MetricsConstants) {
        self.width = width
        self.isLandscape = isLandscape
        self.constants = constants
    }

    /// Built from the stock constants for the orientation.
    public init(width: CGFloat, isLandscape: Bool) {
        self.init(
            width: width, isLandscape: isLandscape,
            constants: isLandscape ? .landscape : .portrait)
    }

    /// Every page has four rows of keys.
    public static let rowCount = 4

    /// The keyboard's full height: strip, gap, four rows and the gaps between them.
    public var height: CGFloat {
        constants.stripHeight + constants.stripGap
            + CGFloat(Self.rowCount) * constants.keycapHeight
            + CGFloat(Self.rowCount - 1) * constants.rowGap + constants.bottomInset
    }

    /// The width of a letter keycap: ten keys and nine gaps share the space between the insets.
    /// 32.7 pt at width 393, which matches the stock keyboard.
    public var letterKeyWidth: CGFloat {
        (width - 2 * constants.sideInset - 9 * constants.keyGap) / 10
    }

    /// Shift, delete and the page key beside the third row grow with the screen, as the stock
    /// keyboard's do; the bottom row's keys keep their measured widths.
    public var modifierKeyWidth: CGFloat {
        constants.modifierKeyWidth * width / constants.referenceWidth
    }

    /// The top of a row's keycaps.
    public func keycapTop(row: Int) -> CGFloat {
        constants.stripHeight + constants.stripGap
            + CGFloat(row) * (constants.keycapHeight + constants.rowGap)
    }

    /// The frames of every key in `rows`, in row order and then left to right. `rows` is one
    /// page's four rows (`KeyboardLayout.rows`).
    ///
    /// Hit rects follow the stock keyboard: neighbours meet in the middle of the gap between
    /// them, the outermost keys reach the view's side edges, the first row reaches up through
    /// the strip gap to the strip's bottom edge, and the bottom row reaches the view's bottom.
    /// The one overlap is the space bar, which reaches `spaceHitReach` up into the row above;
    /// `HitTester` gives the space bar the touch there, because the thumb that hits the
    /// bottom edge of the row above is far likelier to be aiming at the space bar below.
    ///
    /// `isNumberPad` seats every row in three equal columns across the full width; a row with
    /// fewer than three keys (the pad's bottom row without a globe or `.`) fills the right-hand
    /// columns and leaves the left one empty. The rows, gaps and height are the other pages'.
    public func frames(for rows: [[KeyKind]], isNumberPad: Bool = false) -> [KeyFrame] {
        var result: [KeyFrame] = []
        for (rowIndex, row) in rows.enumerated() {
            let rowTop = isNumberPad ? numberPadTop(row: rowIndex) : keycapTop(row: rowIndex)
            let rowHeight = isNumberPad ? numberPadKeycapHeight : constants.keycapHeight
            let rowGap = isNumberPad ? numberPadRowGap : constants.rowGap
            let keycaps = isNumberPad
                ? numberPadRects(count: row.count, top: rowTop)
                : keycapRects(for: row, top: rowTop)
            let isLast = rowIndex == rows.count - 1
            let top = rowIndex == 0 ? constants.stripHeight : rowTop - rowGap / 2
            let bottom = isLast
                ? rowTop + rowHeight + constants.bottomInset
                : rowTop + rowHeight + rowGap / 2
            for (index, keycap) in keycaps.enumerated() {
                // The pad's empty bottom-left slot is not part of the first key's touch area.
                let leadingEdge = isNumberPad && keycap.minX > Self.numberPadSideInset + 1
                    ? keycap.minX - Self.numberPadKeyGap / 2 : 0
                let left = index == 0 ? leadingEdge : (keycaps[index - 1].maxX + keycap.minX) / 2
                let right = index == keycaps.count - 1
                    ? width : (keycap.maxX + keycaps[index + 1].minX) / 2
                var hitTop = top
                if row[index] == .space, rowIndex > 0 { hitTop -= constants.spaceHitReach }
                result.append(
                    KeyFrame(
                        kind: row[index],
                        keycap: keycap,
                        hitRect: CGRect(x: left, y: hitTop, width: right - left, height: bottom - hitTop)))
            }
        }
        return result
    }

    // MARK: - Row widths

    /// The stock number pad, measured on a 393 pt iPhone (2026-11-26): 48 pt keys on a 54 pt
    /// pitch, 5 pt side margins, 6 pt between columns. Murmur keeps the keyboard's height, so
    /// the four rows share the 205 pt the letter rows span (4 x 43 + 3 x 11) in the stock
    /// proportions: 46.5 pt keys and 6.33 pt gaps. In another orientation the same fractions
    /// of that orientation's span apply.
    public static let numberPadSideInset: CGFloat = 5
    public static let numberPadKeyGap: CGFloat = 6
    private static let numberPadKeycapFraction: CGFloat = 46.5 / 205

    /// The height the four rows and three gaps span, the same as every other page's.
    private var rowsSpan: CGFloat {
        CGFloat(Self.rowCount) * constants.keycapHeight + CGFloat(Self.rowCount - 1) * constants.rowGap
    }

    public var numberPadKeycapHeight: CGFloat { rowsSpan * Self.numberPadKeycapFraction }

    public var numberPadRowGap: CGFloat {
        (rowsSpan - CGFloat(Self.rowCount) * numberPadKeycapHeight) / CGFloat(Self.rowCount - 1)
    }

    /// The top of a number pad row's keycaps.
    public func numberPadTop(row: Int) -> CGFloat {
        constants.stripHeight + constants.stripGap + CGFloat(row) * (numberPadKeycapHeight + numberPadRowGap)
    }

    /// The number pad's keycaps: three equal columns between the side insets. A row of fewer
    /// than three keys takes the rightmost columns, so `0` and delete keep their places.
    private func numberPadRects(count: Int, top: CGFloat) -> [CGRect] {
        let columns: CGFloat = 3
        let keyWidth = (width - 2 * Self.numberPadSideInset - (columns - 1) * Self.numberPadKeyGap) / columns
        let firstColumn = Int(columns) - count
        return (0..<count).map { index in
            let x = Self.numberPadSideInset + CGFloat(firstColumn + index) * (keyWidth + Self.numberPadKeyGap)
            return CGRect(x: x, y: top, width: keyWidth, height: numberPadKeycapHeight)
        }
    }

    /// The keycaps of one row, left to right. Three shapes of row exist, told apart by their
    /// content so the layout needs no per-page table: the bottom row (it ends with return),
    /// a row between a modifier and delete, and a plain row of characters.
    private func keycapRects(for row: [KeyKind], top: CGFloat) -> [CGRect] {
        let widths: [CGFloat]
        let gaps: [CGFloat]
        if row.last == .return {
            widths = bottomRowWidths(row)
            gaps = Array(repeating: constants.keyGap, count: max(row.count - 1, 0))
        } else if row.count >= 3, row.last == .delete {
            (widths, gaps) = modifierRowWidths(row)
        } else {
            // A plain row of letter-width keys, centred. Ten keys fill the row; nine (the
            // second row of letters) leave half a key plus half a gap each side.
            widths = Array(repeating: letterKeyWidth, count: row.count)
            gaps = Array(repeating: constants.keyGap, count: max(row.count - 1, 0))
        }
        let total = widths.reduce(0, +) + gaps.reduce(0, +)
        var x = (width - total) / 2
        var rects: [CGRect] = []
        for (index, keyWidth) in widths.enumerated() {
            rects.append(CGRect(x: x, y: top, width: keyWidth, height: constants.keycapHeight))
            x += keyWidth + (index < gaps.count ? gaps[index] : 0)
        }
        return rects
    }

    /// Page key, emoji, globe and return keep fixed widths; the space bar takes what is left, so
    /// the row always spans exactly the view between its insets. A field's own keys beside the
    /// space bar (`@` and `.` in an email field) are as wide as the page key. A row with no
    /// space bar (a web address field's `.`, `/` and `.com`) shares what is left between its
    /// character keys.
    private func bottomRowWidths(_ row: [KeyKind]) -> [CGFloat] {
        let hasSpace = row.contains(.space)
        let characters = row.indices.filter { row[$0].characterValue != nil }
        var widths = row.map { kind -> CGFloat in
            switch kind {
            case .pageSwitch: constants.pageKeyWidth
            case .emoji: constants.emojiKeyWidth
            case .globe: constants.globeKeyWidth
            case .return: constants.returnKeyWidth
            case .character: hasSpace ? constants.pageKeyWidth : 0
            default: 0
            }
        }
        let gaps = CGFloat(max(row.count - 1, 0)) * constants.keyGap
        let fixed = widths.reduce(0, +)
        let left = max(width - 2 * constants.sideInset - fixed - gaps, 0)
        if let index = row.firstIndex(of: .space) {
            widths[index] = left
        } else if !characters.isEmpty {
            for index in characters { widths[index] = left / CGFloat(characters.count) }
        }
        return widths
    }

    /// A row of `modifier, characters..., delete`: shift and delete (or `#+=`/`123` and delete)
    /// at the edges. The stock keyboard leaves a wider gap beside them than between letters, and
    /// its numbers row keeps the same gap with wider punctuation keys, so the modifiers sit in
    /// the same place on every page. That gap is fixed by the letters row (seven letters at
    /// letter width, the leftover space split into the two edge gaps: about 14 pt at 393). Any
    /// other number of characters, such as the five punctuation keys, then share what is left
    /// between those gaps equally (about 48 pt each at 393).
    private func modifierRowWidths(_ row: [KeyKind]) -> (widths: [CGFloat], gaps: [CGFloat]) {
        let modifier = modifierKeyWidth
        let usable = width - 2 * constants.sideInset
        let referenceLetters: CGFloat = 7
        let edgeGap = max(
            (usable - 2 * modifier - referenceLetters * letterKeyWidth
                - (referenceLetters - 1) * constants.keyGap) / 2, 0)
        let count = CGFloat(row.count - 2)
        let characterWidth =
            (usable - 2 * modifier - 2 * edgeGap - (count - 1) * constants.keyGap) / count
        var widths: [CGFloat] = [modifier]
        widths.append(contentsOf: Array(repeating: characterWidth, count: row.count - 2))
        widths.append(modifier)
        var gaps: [CGFloat] = [edgeGap]
        gaps.append(contentsOf: Array(repeating: constants.keyGap, count: row.count - 3))
        gaps.append(edgeGap)
        return (widths, gaps)
    }
}
