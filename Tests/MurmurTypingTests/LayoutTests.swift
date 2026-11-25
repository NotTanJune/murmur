import CoreGraphics
import Testing

@testable import MurmurTyping

@Suite struct LayoutTests {
    private let width: CGFloat = 393
    private var metrics: KeyboardMetrics { KeyboardMetrics(width: width, isLandscape: false) }

    private func frames(_ page: Page = .letters, globe: Bool = false) -> [KeyFrame] {
        metrics.frames(for: KeyboardLayout.rows(for: page, showsGlobe: globe))
    }

    private func frame(_ kind: KeyKind, in all: [KeyFrame]) throws -> KeyFrame {
        try #require(all.first { $0.kind == kind })
    }

    private func letter(_ s: String) -> KeyKind { .character(s) }

    @Test("Letters page: 10, 9, 9 and 4 keys (5 with the globe), 257 pt tall, 32.7 pt letters")
    func lettersPageShape() throws {
        let plain = KeyboardLayout.rows(for: .letters, showsGlobe: false)
        #expect(plain.map(\.count) == [10, 9, 9, 4])
        let withGlobe = KeyboardLayout.rows(for: .letters, showsGlobe: true)
        #expect(withGlobe.map(\.count) == [10, 9, 9, 5])
        let expected: CGFloat = 44 + 8 + 4 * 43 + 3 * 11
        #expect(abs(metrics.height - expected) < 0.001)
        #expect(metrics.height == 257)
        let q = try frame(letter("q"), in: frames())
        #expect(abs(q.keycap.width - 32.7) < 0.05)
        #expect(abs(metrics.letterKeyWidth - 32.7) < 0.05)
    }

    @Test("Every point below the strip hits exactly one key; the space bar wins where hit rects overlap")
    func coverage() {
        for globe in [false, true] {
            let all = frames(globe: globe)
            var y: CGFloat = 44
            while y < metrics.height {
                var x: CGFloat = 0
                while x < width {
                    let point = CGPoint(x: x, y: y)
                    let covering = all.filter { $0.hitRect.contains(point) }
                    #expect(!covering.isEmpty, "uncovered \(point)")
                    let hit = HitTester.key(at: point, frames: all, bias: [:])
                    #expect(hit != nil, "no key at \(point)")
                    if covering.count > 1 {
                        #expect(hit?.kind == .space, "overlap at \(point) went to \(String(describing: hit?.kind))")
                    }
                    x += 2
                }
                y += 2
            }
        }
    }

    @Test("A point in the gap between q and w goes to the nearer key")
    func gapSplitsAtMiddle() throws {
        let all = frames()
        let q = try frame(letter("q"), in: all)
        let w = try frame(letter("w"), in: all)
        let middle = (q.keycap.maxX + w.keycap.minX) / 2
        let y = q.keycap.midY
        #expect(HitTester.key(at: CGPoint(x: middle - 1, y: y), frames: all, bias: [:])?.kind == letter("q"))
        #expect(HitTester.key(at: CGPoint(x: middle + 1, y: y), frames: all, bias: [:])?.kind == letter("w"))
    }

    @Test("The first row reaches up to y 44; the strip above belongs to no key")
    func firstRowReachesTheStrip() throws {
        let all = frames()
        let q = try frame(letter("q"), in: all)
        let x = q.keycap.midX
        #expect(HitTester.key(at: CGPoint(x: x, y: 45), frames: all, bias: [:])?.kind == letter("q"))
        #expect(HitTester.key(at: CGPoint(x: x, y: 44), frames: all, bias: [:])?.kind == letter("q"))
        #expect(HitTester.key(at: CGPoint(x: x, y: 43), frames: all, bias: [:]) == nil)
        #expect(q.keycap.minY == 52)
    }

    @Test("A likelier letter claims part of its neighbour, across rows too")
    func biasShiftsTheBorder() throws {
        let all = frames()
        let w = try frame(letter("w"), in: all)
        // Two points inside w, 2 pt from the border it shares with e.
        let point = CGPoint(x: w.hitRect.maxX - 2, y: w.keycap.midY)
        #expect(HitTester.key(at: point, frames: all, bias: [:])?.kind == letter("w"))
        // 1.25 pt per unit: a difference of 3 claims 3.75 pt, so 2 pt in goes to e.
        #expect(HitTester.key(at: point, frames: all, bias: ["e": 3.0, "w": 0])?.kind == letter("e"))
        // A tiny difference claims less than 2 pt and changes nothing.
        #expect(HitTester.key(at: point, frames: all, bias: ["e": 0.5])?.kind == letter("w"))
        // The claim is capped at 5 pt however likely the letter.
        let far = CGPoint(x: w.hitRect.maxX - 6, y: w.keycap.midY)
        #expect(HitTester.key(at: far, frames: all, bias: ["e": 40])?.kind == letter("w"))
        // The plan's case: after "th", e (above d) claims a touch 2 pt inside d's top edge.
        let d = try frame(letter("d"), in: all)
        let e = try frame(letter("e"), in: all)
        let inD = CGPoint(x: min(d.hitRect.maxX, e.hitRect.maxX) - 3, y: d.hitRect.minY + 2)
        #expect(HitTester.key(at: inD, frames: all, bias: [:])?.kind == letter("d"))
        #expect(HitTester.key(at: inD, frames: all, bias: ["e": 3.0, "d": 0])?.kind == letter("e"))
    }

    @Test("Bias never crosses a modifier key")
    func biasStopsAtModifiers() throws {
        let all = frames()
        let z = try frame(letter("z"), in: all)
        let point = CGPoint(x: z.hitRect.minX + 1, y: z.keycap.midY)
        #expect(HitTester.key(at: point, frames: all, bias: ["z": 0, "x": 5])?.kind == letter("z"))
        let shift = try frame(.shift, in: all)
        #expect(shift.hitRect.maxX == z.hitRect.minX)
    }

    @Test("Numbers and symbols pages list the stock rows")
    func otherPages() {
        func text(_ page: Page) -> [[String]] {
            KeyboardLayout.rows(for: page, showsGlobe: true).map { row in
                row.map { kind -> String in
                    switch kind {
                    case .character(let value): value
                    case .shift: "shift"
                    case .delete: "delete"
                    case .space: "space"
                    case .return: "return"
                    case .pageSwitch(.letters): "ABC"
                    case .pageSwitch(.numbers): "123"
                    case .pageSwitch(.symbols): "#+="
                    case .emoji: "emoji"
                    case .globe: "globe"
                    }
                }
            }
        }
        #expect(text(.numbers) == [
            ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
            ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
            ["#+=", ".", ",", "?", "!", "'", "delete"],
            ["ABC", "globe", "emoji", "space", "return"],
        ])
        #expect(text(.symbols) == [
            ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
            ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
            ["123", ".", ",", "?", "!", "'", "delete"],
            ["ABC", "globe", "emoji", "space", "return"],
        ])
        #expect(KeyboardLayout.rows(for: .numbers, showsGlobe: false)[3].count == 4)
    }

    @Test("Row two is inset half a key plus half a gap; shift and delete are 44 pt")
    func letterRowGeometry() throws {
        let all = frames()
        let a = try frame(letter("a"), in: all)
        let q = try frame(letter("q"), in: all)
        #expect(abs((a.keycap.minX - q.keycap.minX) - (metrics.letterKeyWidth + 6) / 2) < 0.001)
        let shift = try frame(.shift, in: all)
        let delete = try frame(.delete, in: all)
        #expect(abs(shift.keycap.width - 44) < 0.001)
        #expect(abs(delete.keycap.width - 44) < 0.001)
        // The leftover space splits evenly beside shift and delete, about 14 pt each.
        let z = try frame(letter("z"), in: all)
        let m = try frame(letter("m"), in: all)
        let left = z.keycap.minX - shift.keycap.maxX
        let right = delete.keycap.minX - m.keycap.maxX
        #expect(abs(left - right) < 0.001)
        #expect(abs(left - 14) < 0.1)
        #expect(abs(z.keycap.width - metrics.letterKeyWidth) < 0.001)
        // Shift and delete scale with the width.
        let wide = KeyboardMetrics(width: 786, isLandscape: false)
        #expect(abs(wide.modifierKeyWidth - 88) < 0.001)
    }

    @Test("The numbers row keeps the letters row's edge gaps and fills the row")
    func punctuationRowFills() throws {
        let letters = frames(.letters)
        let numbers = frames(.numbers)
        let lettersShift = try frame(.shift, in: letters)
        let hash = try frame(.pageSwitch(.symbols), in: numbers)
        #expect(abs(hash.keycap.minX - lettersShift.keycap.minX) < 0.001)
        #expect(hash.keycap.width == lettersShift.keycap.width)
        let dot = try frame(letter("."), in: numbers)
        let quote = try frame(letter("'"), in: numbers)
        let delete = try frame(.delete, in: numbers)
        #expect(abs((dot.keycap.minX - hash.keycap.maxX) - 14) < 0.1)
        #expect(abs(delete.keycap.minX - quote.keycap.maxX - 14) < 0.1)
        #expect(abs(dot.keycap.width - 48.2) < 0.1)
    }

    @Test("Bottom row: fixed keys, a space bar that fills, hit rects to the view's bottom")
    func bottomRow() throws {
        for globe in [false, true] {
            let all = frames(globe: globe)
            let page = try frame(.pageSwitch(.numbers), in: all)
            let emoji = try frame(.emoji, in: all)
            let space = try frame(.space, in: all)
            let ret = try frame(.return, in: all)
            #expect(page.keycap.width == 42 && emoji.keycap.width == 42 && ret.keycap.width == 91)
            #expect(page.keycap.minX == 6)
            #expect(abs(ret.keycap.maxX - (width - 6)) < 0.001)
            #expect(abs(space.keycap.maxX + 6 - ret.keycap.minX) < 0.001)
            #expect(space.hitRect.maxY == metrics.height)
            #expect(emoji.hitRect.maxY == metrics.height)
            #expect(page.hitRect.minX == 0)
            #expect(ret.hitRect.maxX == width)
            if globe {
                let g = try frame(.globe, in: all)
                #expect(g.keycap.width == 42)
            }
        }
    }

    @Test("An email field adds @ and . beside a narrower space bar; the other pages do not change")
    func emailRow() throws {
        let rows = KeyboardLayout.rows(for: .letters, showsGlobe: false, field: .email)
        #expect(rows[3] == [.pageSwitch(.numbers), .emoji, .space, letter("@"), letter("."), .return])
        #expect(Array(rows[0..<3]) == Array(KeyboardLayout.rows(for: .letters, showsGlobe: false)[0..<3]))
        #expect(KeyboardLayout.rows(for: .numbers, showsGlobe: false, field: .email)
            == KeyboardLayout.rows(for: .numbers, showsGlobe: false))
        let all = metrics.frames(for: rows)
        let space = try frame(.space, in: all)
        let at = try frame(letter("@"), in: all)
        let dot = try frame(letter("."), in: all)
        let ret = try frame(.return, in: all)
        #expect(at.keycap.width == 42 && dot.keycap.width == 42 && ret.keycap.width == 91)
        #expect(abs(space.keycap.maxX + 6 - at.keycap.minX) < 0.001)
        #expect(abs(at.keycap.maxX + 6 - dot.keycap.minX) < 0.001)
        #expect(abs(dot.keycap.maxX + 6 - ret.keycap.minX) < 0.001)
        #expect(abs(ret.keycap.maxX - (width - 6)) < 0.001)
        let plain = try frame(.space, in: frames())
        #expect(abs(plain.keycap.width - space.keycap.width - 96) < 0.001)
        #expect(dot.hitRect.maxY == metrics.height)
    }

    @Test("A web address field has . / .com and no space bar; a web search has a space bar and .")
    func addressRows() throws {
        let rows = KeyboardLayout.rows(for: .letters, showsGlobe: true, field: .url)
        #expect(rows[3] == [.pageSwitch(.numbers), .globe, .emoji, letter("."), letter("/"), letter(".com"), .return])
        let all = metrics.frames(for: rows)
        let dot = try frame(letter("."), in: all)
        let slash = try frame(letter("/"), in: all)
        let com = try frame(letter(".com"), in: all)
        let emoji = try frame(.emoji, in: all)
        let ret = try frame(.return, in: all)
        #expect(abs(dot.keycap.width - slash.keycap.width) < 0.001)
        #expect(abs(slash.keycap.width - com.keycap.width) < 0.001)
        #expect(abs(emoji.keycap.maxX + 6 - dot.keycap.minX) < 0.001)
        #expect(abs(com.keycap.maxX + 6 - ret.keycap.minX) < 0.001)
        #expect(abs(ret.keycap.maxX - (width - 6)) < 0.001)
        // Every point of the bottom row still hits exactly one key.
        let y = ret.keycap.midY
        for x in stride(from: CGFloat(0.5), to: width, by: 1) {
            #expect(all.filter { $0.hitRect.contains(CGPoint(x: x, y: y)) }.count == 1)
        }
        #expect(KeyboardLayout.rows(for: .letters, showsGlobe: false, field: .webSearch)[3]
            == [.pageSwitch(.numbers), .emoji, .space, letter("."), .return])
        for field in [FieldKeyboardKind.default, .number, .phone] {
            #expect(KeyboardLayout.rows(for: .letters, showsGlobe: false, field: field)
                == KeyboardLayout.rows(for: .letters, showsGlobe: false))
        }
    }

    @Test("A mark beside the space bar is never given to a likelier letter above it")
    func marksKeepTheirKey() throws {
        let all = metrics.frames(for: KeyboardLayout.rows(for: .letters, showsGlobe: false, field: .email))
        let at = try frame(letter("@"), in: all)
        let point = CGPoint(x: at.keycap.midX, y: at.hitRect.minY + 0.5)
        #expect(HitTester.key(at: point, frames: all, bias: ["n": 6, "m": 6, "b": 6])?.kind == letter("@"))
    }

    @Test("The space bar's hit rect reaches 2.5 pt up into the row above and wins there")
    func spaceReachesUp() throws {
        let all = frames()
        let space = try frame(.space, in: all)
        let rowAboveBottom = space.keycap.minY - 11 / 2
        let point = CGPoint(x: space.keycap.midX, y: rowAboveBottom - 2)
        #expect(space.hitRect.minY == rowAboveBottom - 2.5)
        #expect(HitTester.key(at: point, frames: all, bias: [:])?.kind == .space)
        let above = CGPoint(x: space.keycap.midX, y: rowAboveBottom - 3)
        #expect(HitTester.key(at: above, frames: all, bias: [:])?.kind != .space)
        // Only the space bar overlaps another key.
        let overlapping = all.filter { first in
            all.contains { $0 != first && $0.hitRect.intersects(first.hitRect) && !$0.hitRect.intersection(first.hitRect).isEmpty }
        }
        #expect(overlapping.allSatisfy { $0.kind == .space || $0.keycap.maxY < space.keycap.minY })
    }

    @Test("Outer keys reach the side edges")
    func outerKeysReachTheEdges() throws {
        let all = frames()
        #expect(try frame(letter("q"), in: all).hitRect.minX == 0)
        #expect(try frame(letter("p"), in: all).hitRect.maxX == width)
        #expect(try frame(letter("a"), in: all).hitRect.minX == 0)
        #expect(try frame(letter("l"), in: all).hitRect.maxX == width)
        #expect(HitTester.key(at: CGPoint(x: 0, y: 70), frames: all, bias: [:])?.kind == letter("q"))
        #expect(HitTester.key(at: CGPoint(x: width, y: metrics.height), frames: all, bias: [:])?.kind == .return)
    }

    @Test("Landscape uses the smaller keys and rows")
    func landscape() {
        let landscape = KeyboardMetrics(width: 852, isLandscape: true)
        let expected: CGFloat = 44 + 6 + 4 * 32 + 3 * 8
        #expect(abs(landscape.height - expected) < 0.001)
        #expect(landscape.keycapTop(row: 0) == 50)
    }
}
