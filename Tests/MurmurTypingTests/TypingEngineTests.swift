import CoreGraphics
import Foundation
import Testing

@testable import MurmurTyping

@Suite struct TypingEngineTests {
    private let metrics = KeyboardMetrics(width: 393, isLandscape: false)

    private func makeEngine(globe: Bool = false) -> TypingEngine {
        TypingEngine(metrics: metrics, showsGlobe: globe)
    }

    private func frame(_ kind: KeyKind, in engine: TypingEngine) -> KeyFrame {
        engine.frames.first { $0.kind == kind }!
    }

    private func center(_ kind: KeyKind, in engine: TypingEngine) -> CGPoint {
        let rect = frame(kind, in: engine).keycap
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private func letter(_ s: String) -> KeyKind { .character(s) }

    private func down(_ engine: inout TypingEngine, _ id: Int, _ point: CGPoint, _ t: TimeInterval)
        -> [TypingEffect]
    { engine.handle(.began(id: id, point: point, time: t), bias: [:]) }

    private func down(_ engine: inout TypingEngine, _ point: CGPoint, _ t: TimeInterval) -> [TypingEffect] {
        down(&engine, 1, point, t)
    }

    private func move(_ engine: inout TypingEngine, _ id: Int, _ point: CGPoint, _ t: TimeInterval)
        -> [TypingEffect]
    { engine.handle(.moved(id: id, point: point, time: t), bias: [:]) }

    private func move(_ engine: inout TypingEngine, _ point: CGPoint, _ t: TimeInterval) -> [TypingEffect] {
        move(&engine, 1, point, t)
    }

    private func up(_ engine: inout TypingEngine, _ id: Int, _ point: CGPoint, _ t: TimeInterval)
        -> [TypingEffect]
    { engine.handle(.ended(id: id, point: point, time: t), bias: [:]) }

    private func up(_ engine: inout TypingEngine, _ point: CGPoint, _ t: TimeInterval) -> [TypingEffect] {
        up(&engine, 1, point, t)
    }

    private func tick(_ engine: inout TypingEngine, _ t: TimeInterval) -> [TypingEffect] {
        engine.handle(.tick(time: t), bias: [:])
    }

    private func inserts(_ effects: [TypingEffect]) -> [String] {
        effects.compactMap { if case .insert(let s, _) = $0 { s } else { nil } }
    }

    @Test("A letter shows its pop-up at touch-down and types at touch-up, then hides the pop-up")
    func tapTypesAtLift() {
        var engine = makeEngine()
        let q = center(letter("q"), in: engine)
        let began = down(&engine, q, 0)
        #expect(began == [.feedback, .showPopup(letter("q"), alternates: [], selected: nil)])
        let ended = up(&engine, q, 0.08)
        #expect(ended == [.hidePopup, .insert("q", tap: q)])
    }

    @Test("Sliding to a neighbour types the neighbour and moves the pop-up there")
    func slideTypesNeighbour() {
        var engine = makeEngine()
        let q = center(letter("q"), in: engine)
        let w = center(letter("w"), in: engine)
        _ = down(&engine, q, 0)
        #expect(move(&engine, w, 0.05) == [.showPopup(letter("w"), alternates: [], selected: nil)])
        #expect(inserts(up(&engine, w, 0.1)) == ["w"])
    }

    @Test("A tap that rolls a few points onto the neighbour as it lifts types the key it landed on")
    func rollingTapTypesLandingKey() {
        var engine = makeEngine()
        let q = engine.frames.first { $0.kind == letter("q") }!.hitRect
        let landing = CGPoint(x: q.maxX - 3, y: q.midY)
        let lift = CGPoint(x: q.maxX + 4, y: q.midY)   // 7 pt on, inside w's hit rect
        _ = down(&engine, landing, 0)
        _ = move(&engine, lift, 0.04)
        #expect(inserts(up(&engine, lift, 0.06)) == ["q"])
    }

    @Test("A cancelled touch types nothing and hides its pop-up")
    func cancelledTypesNothing() {
        var engine = makeEngine()
        _ = down(&engine, center(letter("a"), in: engine), 0)
        #expect(engine.handle(.cancelled(id: 1), bias: [:]) == [.hidePopup])
        // The lift that follows a cancel is unknown to the engine and does nothing.
        #expect(up(&engine, center(letter("a"), in: engine), 0.1).isEmpty)
    }

    @Test("A lift that hits no key types the key the touch was last on")
    func offKeyLiftTypesLastKey() {
        var engine = makeEngine()
        let q = center(letter("q"), in: engine)
        // Straight up into the strip, which belongs to no key.
        let strip = CGPoint(x: q.x, y: 10)
        _ = down(&engine, q, 0)
        #expect(move(&engine, strip, 0.04) == [.hidePopup])
        #expect(inserts(up(&engine, strip, 0.08)) == ["q"])
        #expect(engine.offKeyLifts == 1)

        // Slid onto e, then past the right edge: e, the last key it was on.
        let w = center(letter("w"), in: engine)
        let outside = CGPoint(x: 500, y: w.y)
        _ = down(&engine, w, 1)
        _ = move(&engine, CGPoint(x: w.x + 24, y: w.y), 1.02)
        _ = move(&engine, outside, 1.04)
        #expect(inserts(up(&engine, outside, 1.08)) == ["e"])
        #expect(engine.offKeyLifts == 2)

        // A lift on a key is not counted.
        _ = down(&engine, q, 2)
        #expect(inserts(up(&engine, q, 2.04)) == ["q"])
        #expect(engine.offKeyLifts == 2)
    }

    @Test("Rollover: a down while another key is held commits the held key first")
    func rollover() {
        var engine = makeEngine()
        let a = center(letter("a"), in: engine)
        let s = center(letter("s"), in: engine)
        var typed: [String] = []
        typed += inserts(down(&engine, 1, a, 0))
        typed += inserts(down(&engine, 2, s, 0.05))
        #expect(typed == ["a"])
        typed += inserts(up(&engine, 1, a, 0.08))
        #expect(typed == ["a"])
        typed += inserts(up(&engine, 2, s, 0.12))
        #expect(typed == ["a", "s"])
    }

    @Test("The next-letter bias is passed to the hit tester at touch-down and touch-up")
    func biasReachesHitTester() {
        var engine = makeEngine()
        let e = frame(letter("e"), in: engine)
        // Just inside d's hit rect, below e's: without a bias that types d.
        let point = CGPoint(x: e.keycap.midX, y: e.hitRect.maxY + 1)
        _ = down(&engine, 1, point, 0)
        #expect(inserts(up(&engine, 1, point, 0.05)) == ["d"])
        let biased = engine.handle(.began(id: 2, point: point, time: 1), bias: ["e": 4])
        #expect(biased.contains(.showPopup(letter("e"), alternates: [], selected: nil)))
        let lifted = engine.handle(.ended(id: 2, point: point, time: 1.05), bias: ["e": 4])
        #expect(inserts(lifted) == ["e"])
    }

    @Test("Holding a letter with accents for 0.36 s opens the row; moving selects; lift types it")
    func accentHold() {
        var engine = makeEngine()
        let e = center(letter("e"), in: engine)
        _ = down(&engine, e, 0)
        #expect(tick(&engine, 0.359).isEmpty)
        let opened = tick(&engine, 0.36)
        let row = ["è", "é", "ê", "ë", "ē", "ė", "ę"]
        #expect(opened == [.showPopup(letter("e"), alternates: row, selected: 0)])
        // Cells are at least 20 pt wide, so 25 pt to the side is the second cell.
        let moved = move(&engine, CGPoint(x: e.x + 25, y: e.y), 0.5)
        #expect(moved == [.showPopup(letter("e"), alternates: row, selected: 1)])
        let ended = up(&engine, CGPoint(x: e.x + 25, y: e.y), 0.6)
        #expect(ended == [.hidePopup, .insert("é", tap: nil)])
    }

    @Test("A lift before the hold types the plain letter; keys without accents never open a row")
    func accentNotYet() {
        var engine = makeEngine()
        let e = center(letter("e"), in: engine)
        _ = down(&engine, e, 0)
        _ = tick(&engine, 0.2)
        #expect(inserts(up(&engine, e, 0.3)) == ["e"])
        let q = center(letter("q"), in: engine)
        _ = down(&engine, q, 1)
        #expect(tick(&engine, 2).isEmpty)
    }

    @Test("Leaving the accent row downward types nothing; shift capitalises the row")
    func accentLeaveDownwardAndCase() {
        var engine = makeEngine()
        engine.setShift(.on)
        let a = center(letter("a"), in: engine)
        _ = down(&engine, a, 0)
        let opened = tick(&engine, 0.4)
        guard case .showPopup(_, let row, _) = opened.first else {
            Issue.record("no accent row")
            return
        }
        #expect(row.first == "À")
        let k = frame(letter("a"), in: engine)
        let below = CGPoint(x: a.x, y: k.hitRect.maxY + 6)
        #expect(move(&engine, below, 0.5) == [.showPopup(letter("a"), alternates: row, selected: nil)])
        #expect(up(&engine, below, 0.6) == [.hidePopup])
        #expect(engine.shift == .on)
    }

    @Test("The accent row of a key in the right half grows leftward")
    func accentLeftward() {
        var engine = makeEngine()
        let o = center(letter("o"), in: engine)
        _ = down(&engine, o, 0)
        _ = tick(&engine, 0.4)
        let moved = move(&engine, CGPoint(x: o.x - 25, y: o.y), 0.5)
        #expect(moved.contains { if case .showPopup(_, _, let s) = $0 { s == 1 } else { false } })
    }

    @Test("Delete: one at touch-down, repeats from 0.36 s, faster from 0.85 s, words from 1.4 s")
    func deleteTimings() {
        var engine = makeEngine()
        let d = center(.delete, in: engine)
        #expect(down(&engine, d, 0) == [.feedback, .deleteBackward(count: 1)])
        #expect(tick(&engine, 0.359).isEmpty)
        #expect(tick(&engine, 0.36) == [.feedback, .deleteBackward(count: 1)])
        // 0.435 is the next repeat at the 0.075 pace.
        #expect(tick(&engine, 0.434).isEmpty)
        #expect(tick(&engine, 0.435).count == 2)
        // Catch up to 0.81 (the last slow one), then 0.85 starts the 0.05 pace.
        let slow = tick(&engine, 0.82)
        #expect(slow.filter { $0 == .deleteBackward(count: 1) }.count == 5)  // 0.51 ... 0.81
        #expect(tick(&engine, 0.85) == [.feedback, .deleteBackward(count: 1)])
        #expect(tick(&engine, 0.899).isEmpty)
        #expect(tick(&engine, 0.9) == [.feedback, .deleteBackward(count: 1)])
        // Up to 1.35 each repeat is a character; 1.4 is the first word.
        let beforeWords = tick(&engine, 1.399)
        #expect(!beforeWords.contains(.deleteWordBackward))
        #expect(tick(&engine, 1.4) == [.feedback, .deleteWordBackward])
        #expect(tick(&engine, 1.649).isEmpty)
        #expect(tick(&engine, 1.65) == [.feedback, .deleteWordBackward])
        // Lifting stops the repeat.
        #expect(up(&engine, d, 1.7).isEmpty)
        #expect(tick(&engine, 3).isEmpty)
    }

    @Test("Space types at touch-up, even after a slide before the 0.35 s hold")
    func spaceTapAndSlide() {
        var engine = makeEngine()
        let s = center(.space, in: engine)
        _ = down(&engine, s, 0)
        #expect(up(&engine, s, 0.1) == [.insert(" ", tap: nil)])

        // Slid more than 4 pt before 0.35 s: it never becomes a trackpad, even if held on.
        _ = down(&engine, 2, s, 1)
        _ = move(&engine, 2, CGPoint(x: s.x + 10, y: s.y), 1.2)
        #expect(tick(&engine, 1.5).isEmpty)
        #expect(up(&engine, 2, CGPoint(x: s.x + 10, y: s.y), 1.6) == [.insert(" ", tap: nil)])
    }

    @Test("A still hold of 0.35 s turns the space bar into a trackpad; no space is typed")
    func spaceTrackpad() {
        var engine = makeEngine()
        let s = center(.space, in: engine)
        _ = down(&engine, s, 0)
        // Wobble inside 4 pt does not disqualify the hold.
        _ = move(&engine, CGPoint(x: s.x + 3, y: s.y), 0.1)
        #expect(tick(&engine, 0.349).isEmpty)
        #expect(tick(&engine, 0.35) == [.trackpad(true)])
        // 30 pt in 0.1 s is 300 pt/s: gain 1 + 0.4 * (200 / 300), 38 effective points, 5 steps.
        let moved = move(&engine, CGPoint(x: s.x + 33, y: s.y), 0.45)
        #expect(moved == [.moveCursor(utf16Offset: 5)])
        // Leftward travel moves the other way; the leftover 0.5 pt carries over.
        let back = move(&engine, CGPoint(x: s.x + 3, y: s.y), 0.55)
        #expect(back == [.moveCursor(utf16Offset: -5)])
        let ended = up(&engine, CGPoint(x: s.x + 3, y: s.y), 0.6)
        #expect(ended == [.trackpad(false)])
    }

    @Test("Trackpad gain: 1 below 100 pt/s, 1.4 at 400, 2 at 1000, 2.6 at 2000 and above")
    func trackpadGainCurve() {
        #expect(TypingEngine.trackpadGain(speed: 0) == 1)
        #expect(TypingEngine.trackpadGain(speed: 100) == 1)
        #expect(abs(TypingEngine.trackpadGain(speed: 250) - 1.2) < 1e-9)
        #expect(abs(TypingEngine.trackpadGain(speed: 400) - 1.4) < 1e-9)
        #expect(abs(TypingEngine.trackpadGain(speed: 700) - 1.7) < 1e-9)
        #expect(abs(TypingEngine.trackpadGain(speed: 1000) - 2.0) < 1e-9)
        #expect(abs(TypingEngine.trackpadGain(speed: 1500) - 2.3) < 1e-9)
        #expect(abs(TypingEngine.trackpadGain(speed: 2000) - 2.6) < 1e-9)
        #expect(TypingEngine.trackpadGain(speed: 5000) == 2.6)
    }

    @Test("Shift: a tap turns one capital on, typing it turns shift off again")
    func shiftOneCapital() {
        var engine = makeEngine()
        let shift = center(.shift, in: engine)
        #expect(down(&engine, shift, 0) == [.feedback, .setShift(.on)])
        #expect(up(&engine, shift, 0.05).isEmpty)
        #expect(engine.shift == .on)
        let a = center(letter("a"), in: engine)
        _ = down(&engine, 2, a, 1)
        let typed = up(&engine, 2, a, 1.05)
        #expect(typed == [.hidePopup, .insert("A", tap: a), .setShift(.off)])
        #expect(engine.shift == .off)
        _ = down(&engine, 3, a, 2)
        #expect(inserts(up(&engine, 3, a, 2.05)) == ["a"])
    }

    @Test("Shift: a second tap within 0.3 s locks caps; a tap while locked, or a slow one, turns it off")
    func shiftDoubleTap() {
        var engine = makeEngine()
        let shift = center(.shift, in: engine)
        _ = down(&engine, shift, 0)
        _ = up(&engine, shift, 0.05)
        _ = down(&engine, 2, shift, 0.25)
        #expect(up(&engine, 2, shift, 0.3) == [.setShift(.capsLock)])
        // Caps lock keeps the capital through typing.
        let a = center(letter("a"), in: engine)
        _ = down(&engine, 3, a, 1)
        #expect(up(&engine, 3, a, 1.05) == [.hidePopup, .insert("A", tap: a)])
        #expect(engine.shift == .capsLock)
        _ = down(&engine, 4, shift, 2)
        #expect(up(&engine, 4, shift, 2.05) == [.setShift(.off)])

        // A second tap later than 0.3 after the first turns shift back off.
        _ = down(&engine, 5, shift, 3)
        _ = up(&engine, 5, shift, 3.05)
        _ = down(&engine, 6, shift, 3.4)
        #expect(up(&engine, 6, shift, 3.45) == [.setShift(.off)])
    }

    @Test("Holding shift and sliding to a letter types its capital, then shift is back as it was")
    func shiftSlide() {
        var engine = makeEngine()
        let shift = center(.shift, in: engine)
        let g = center(letter("g"), in: engine)
        _ = down(&engine, shift, 0)
        #expect(move(&engine, g, 0.1).contains(.showPopup(letter("g"), alternates: [], selected: nil)))
        let ended = up(&engine, g, 0.2)
        #expect(ended.first == .hidePopup)
        #expect(ended.contains(.insert("G", tap: g)))
        #expect(ended.last == .setShift(.off))
        #expect(engine.shift == .off)
    }

    @Test("Holding 123 and sliding to a key types it and returns to the letters page")
    func pageSlide() {
        var engine = makeEngine()
        let key = center(.pageSwitch(.numbers), in: engine)
        #expect(down(&engine, key, 0) == [.feedback, .setPage(.numbers)])
        #expect(engine.page == .numbers)
        let five = center(letter("5"), in: engine)
        _ = move(&engine, five, 0.1)
        let ended = up(&engine, five, 0.2)
        #expect(inserts(ended) == ["5"])
        #expect(ended.last == .setPage(.letters))
        #expect(engine.page == .letters)
    }

    @Test("A plain tap on 123 stays on the numbers page; #+= and ABC switch pages the same way")
    func pageTap() {
        var engine = makeEngine()
        let key = center(.pageSwitch(.numbers), in: engine)
        _ = down(&engine, key, 0)
        #expect(up(&engine, key, 0.05).isEmpty)
        #expect(engine.page == .numbers)
        let symbols = center(.pageSwitch(.symbols), in: engine)
        _ = down(&engine, 2, symbols, 1)
        _ = up(&engine, 2, symbols, 1.05)
        #expect(engine.page == .symbols)
        let abc = center(.pageSwitch(.letters), in: engine)
        _ = down(&engine, 3, abc, 2)
        _ = up(&engine, 3, abc, 2.05)
        #expect(engine.page == .letters)
        // Letters keys are lowercase on a non-letters page's own characters, and uppercase never applies.
        engine.setShift(.capsLock)
        engine.setPage(.numbers)
        let dollar = center(letter("$"), in: engine)
        _ = down(&engine, 4, dollar, 3)
        #expect(inserts(up(&engine, 4, dollar, 3.05)) == ["$"])
    }

    @Test("Return, emoji and globe act at touch-up, and only if the finger is still on the key")
    func buttons() {
        var engine = makeEngine(globe: true)
        let ret = center(.return, in: engine)
        _ = down(&engine, ret, 0)
        #expect(up(&engine, ret, 0.05) == [.insert("\n", tap: nil)])
        let emoji = center(.emoji, in: engine)
        #expect(down(&engine, 2, emoji, 1) == [.feedback])
        #expect(up(&engine, 2, emoji, 1.05) == [.showEmoji])
        let globe = center(.globe, in: engine)
        _ = down(&engine, 3, globe, 2)
        #expect(up(&engine, 3, globe, 2.05) == [.globe])
        // Slid off the return key before lifting: nothing.
        _ = down(&engine, 4, ret, 3)
        #expect(up(&engine, 4, center(letter("p"), in: engine), 3.05).isEmpty)
    }

    @Test("A touch outside every key does nothing; new frames take effect with setLayout")
    func layoutChange() {
        var engine = makeEngine()
        #expect(down(&engine, CGPoint(x: 100, y: 10), 0).isEmpty)
        let wide = KeyboardMetrics(width: 430, isLandscape: false)
        engine.setLayout(metrics: wide, showsGlobe: false)
        let q = frame(letter("q"), in: engine)
        #expect(abs(q.keycap.width - wide.letterKeyWidth) < 0.001)
        _ = down(&engine, 2, CGPoint(x: q.keycap.midX, y: q.keycap.midY), 1)
        #expect(inserts(up(&engine, 2, CGPoint(x: q.keycap.midX, y: q.keycap.midY), 1.05)) == ["q"])
    }
}
