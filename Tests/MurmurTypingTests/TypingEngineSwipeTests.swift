import CoreGraphics
import Foundation
import Testing

@testable import MurmurTyping

/// The touch precedence of swipe typing (Milestone 6): when a touch on a letter becomes a swipe,
/// and that nothing else about a touch changed. Kept apart from `TypingEngineTests`, whose tests
/// are the standing proof that the tap path did not move.
@Suite struct TypingEngineSwipeTests {
    private let metrics = KeyboardMetrics(width: 393, isLandscape: false)

    private func makeEngine(swipe: Bool = true) -> TypingEngine {
        var engine = TypingEngine(metrics: metrics)
        engine.swipeEnabled = swipe
        return engine
    }

    private func centre(_ kind: KeyKind, in engine: TypingEngine) -> CGPoint {
        let rect = engine.frames.first { $0.kind == kind }!.keycap
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private func letter(_ s: String) -> KeyKind { .character(s) }

    /// q to w across: a key's width plus the gap.
    private func pitch(_ engine: TypingEngine) -> CGFloat {
        centre(letter("w"), in: engine).x - centre(letter("q"), in: engine).x
    }

    private func down(_ engine: inout TypingEngine, _ id: Int, _ point: CGPoint, _ t: TimeInterval) -> [TypingEffect] {
        engine.handle(.began(id: id, point: point, time: t), bias: [:])
    }

    private func move(_ engine: inout TypingEngine, _ id: Int, _ point: CGPoint, _ t: TimeInterval) -> [TypingEffect] {
        engine.handle(.moved(id: id, point: point, time: t), bias: [:])
    }

    private func up(_ engine: inout TypingEngine, _ id: Int, _ point: CGPoint, _ t: TimeInterval) -> [TypingEffect] {
        engine.handle(.ended(id: id, point: point, time: t), bias: [:])
    }

    private func tick(_ engine: inout TypingEngine, _ t: TimeInterval) -> [TypingEffect] {
        engine.handle(.tick(time: t), bias: [:])
    }

    private func inserts(_ effects: [TypingEffect]) -> [String] {
        effects.compactMap { if case .insert(let s, _) = $0 { s } else { nil } }
    }

    private func swipeUpdates(_ effects: [TypingEffect]) -> [[CGPoint]] {
        effects.compactMap { if case .swipeUpdate(let path) = $0 { path } else { nil } }
    }

    private func swipeEnds(_ effects: [TypingEffect]) -> [([CGPoint], [TimeInterval])] {
        effects.compactMap { if case .swipeEnded(let path, let times) = $0 { (path, times) } else { nil } }
    }

    // MARK: - Starting a swipe

    @Test("A letter touch that travels 1.2 pitches becomes a swipe and types nothing by itself")
    func travelBecomesSwipe() {
        var engine = makeEngine()
        let g = centre(letter("g"), in: engine)
        let far = CGPoint(x: g.x + 1.2 * pitch(engine), y: g.y)

        _ = down(&engine, 1, g, 0)
        // Just over half a pitch is still a touch on keys, with its pop-up following.
        let near = move(&engine, 1, CGPoint(x: g.x + 0.55 * pitch(engine), y: g.y), 0.02)
        #expect(swipeUpdates(near).isEmpty)
        #expect(near.contains(.showPopup(letter("h"), alternates: [], selected: nil)))

        let started = move(&engine, 1, far, 0.05)
        #expect(started.first == .hidePopup, "a swipe shows no key preview")
        #expect(swipeUpdates(started).last == [g, CGPoint(x: g.x + 0.55 * pitch(engine), y: g.y), far])
        #expect(inserts(started).isEmpty)

        let more = move(&engine, 1, CGPoint(x: far.x + 5, y: far.y), 0.07)
        #expect(swipeUpdates(more).last?.count == 4, "each move reports the whole path so far")
        #expect(!more.contains(where: { if case .showPopup = $0 { true } else { false } }))

        let lift = CGPoint(x: far.x + 5, y: far.y)
        let ended = up(&engine, 1, lift, 0.1)
        #expect(inserts(ended).isEmpty, "the key a swipe starts on types nothing")
        let end = swipeEnds(ended)
        #expect(end.count == 1)
        #expect(end.first?.0.first == g)
        #expect(end.first?.0.last == lift)
        #expect(end.first?.1 == [0, 0.02, 0.05, 0.07])
    }

    @Test("With swipe typing off the same touch types the key under the lift, as before")
    func disabledIsTheOldTouch() {
        var engine = makeEngine(swipe: false)
        let g = centre(letter("g"), in: engine)
        let far = CGPoint(x: g.x + 1.2 * pitch(engine), y: g.y)
        _ = down(&engine, 1, g, 0)
        let moved = move(&engine, 1, far, 0.05)
        #expect(swipeUpdates(moved).isEmpty)
        let ended = up(&engine, 1, far, 0.1)
        #expect(swipeEnds(ended).isEmpty)
        #expect(inserts(ended) == ["h"])
    }

    @Test("A slide of 20 points still types the key under the lift, with swipe typing on")
    func shortSlideStillTypesTheLiftKey() {
        for enabled in [false, true] {
            var engine = makeEngine(swipe: enabled)
            let q = centre(letter("q"), in: engine)
            let lift = CGPoint(x: q.x + 21, y: q.y)   // inside w's hit rect, past the 12 pt commit
            let began = down(&engine, 1, q, 0)
            #expect(began == [.feedback, .showPopup(letter("q"), alternates: [], selected: nil)])
            #expect(move(&engine, 1, lift, 0.04) == [.showPopup(letter("w"), alternates: [], selected: nil)])
            #expect(up(&engine, 1, lift, 0.08) == [.hidePopup, .insert("w", tap: lift)])
        }
    }

    @Test("A touch that travels one pitch or less gives the same effects whether swipe typing is on or off")
    func upToOnePitchIsUnchanged() {
        var traces: [[TypingEffect]] = []
        for enabled in [false, true] {
            var engine = makeEngine(swipe: enabled)
            let g = centre(letter("g"), in: engine)
            let step = 0.95 * pitch(engine) / 4
            var trace = down(&engine, 1, g, 0)
            for index in 1...4 {
                trace += move(&engine, 1, CGPoint(x: g.x + step * CGFloat(index), y: g.y), 0.01 * Double(index))
            }
            trace += up(&engine, 1, CGPoint(x: g.x + step * 4, y: g.y), 0.06)
            traces.append(trace)
        }
        #expect(traces[0] == traces[1])
        #expect(inserts(traces[1]) == ["h"])
    }

    @Test("A swipe that comes back to its starting key within 1.6 pitches is a tap on that key")
    func returningSwipeIsATap() {
        var engine = makeEngine()
        let g = centre(letter("g"), in: engine)
        let out = CGPoint(x: g.x + 1.2 * pitch(engine), y: g.y)
        _ = down(&engine, 1, g, 0)
        _ = move(&engine, 1, out, 0.05)
        _ = move(&engine, 1, CGPoint(x: g.x + 2, y: g.y), 0.1)
        let ended = up(&engine, 1, g, 0.12)
        #expect(swipeEnds(ended).isEmpty)
        #expect(ended == [.insert("g", tap: g)])
    }

    @Test("A swipe that went past 1.6 pitches is not a tap even if it lifts on its key")
    func farReturningSwipeIsASwipe() {
        var engine = makeEngine()
        let g = centre(letter("g"), in: engine)
        _ = down(&engine, 1, g, 0)
        _ = move(&engine, 1, CGPoint(x: g.x + 1.2 * pitch(engine), y: g.y), 0.04)
        _ = move(&engine, 1, CGPoint(x: g.x + 1.8 * pitch(engine), y: g.y), 0.08)
        let ended = up(&engine, 1, g, 0.14)
        #expect(inserts(ended).isEmpty)
        #expect(swipeEnds(ended).count == 1)
    }

    @Test("A tap-shaped swipe spends shift like a typed letter")
    func tapShapedSwipeUsesShift() {
        var engine = makeEngine()
        engine.setShift(.on)
        let g = centre(letter("g"), in: engine)
        _ = down(&engine, 1, g, 0)
        _ = move(&engine, 1, CGPoint(x: g.x + 1.2 * pitch(engine), y: g.y), 0.05)
        let ended = up(&engine, 1, g, 0.1)
        #expect(ended == [.insert("G", tap: g), .setShift(.off)])
    }

    // MARK: - Holds and the clock

    @Test("A hold past 0.36 s opens the accents, and moving afterwards selects instead of swiping")
    func holdOpensAccentsAndNeverSwipes() {
        var engine = makeEngine()
        let e = centre(letter("e"), in: engine)
        _ = down(&engine, 1, e, 0)
        let opened = tick(&engine, 0.36)
        #expect(opened.count == 1)
        guard case .showPopup(_, let row, _)? = opened.first, !row.isEmpty else {
            Issue.record("no accent row")
            return
        }
        let moved = move(&engine, 1, CGPoint(x: e.x + 1.5 * pitch(engine), y: e.y), 0.5)
        #expect(swipeUpdates(moved).isEmpty)
        let ended = up(&engine, 1, CGPoint(x: e.x + 1.5 * pitch(engine), y: e.y), 0.6)
        #expect(swipeEnds(ended).isEmpty)
        #expect(inserts(ended).count == 1, "the accent row's choice types, not a swipe")
    }

    @Test("A key without accents that is held past 0.36 s before it travels is the old touch too")
    func lateTravelIsNotASwipe() {
        var engine = makeEngine()
        let g = centre(letter("g"), in: engine)
        let far = CGPoint(x: g.x + 1.2 * pitch(engine), y: g.y)
        _ = down(&engine, 1, g, 0)
        _ = tick(&engine, 0.4)
        let moved = move(&engine, 1, far, 0.5)
        #expect(swipeUpdates(moved).isEmpty)
        let ended = up(&engine, 1, far, 0.55)
        #expect(inserts(ended) == ["h"])
        #expect(swipeEnds(ended).isEmpty)
    }

    @Test("Once a swipe has begun the accent hold never fires, however long it dwells")
    func swipeIgnoresTheAccentHold() {
        var engine = makeEngine()
        let a = centre(letter("a"), in: engine)
        _ = down(&engine, 1, a, 0)
        let far = CGPoint(x: a.x + 1.2 * pitch(engine), y: a.y)
        _ = move(&engine, 1, far, 0.1)
        // Resting on e's neighbour d for a long time: no row opens.
        let waited = tick(&engine, 1.0)
        #expect(waited.isEmpty)
        #expect(inserts(up(&engine, 1, far, 1.1)).isEmpty)
    }

    // MARK: - Keys that never swipe

    @Test("A touch that goes down on space, shift, delete, 123, return or emoji never swipes")
    func otherKeysNeverSwipe() {
        let kinds: [KeyKind] = [.space, .shift, .delete, .pageSwitch(.numbers), .return, .emoji]
        for kind in kinds {
            var engine = makeEngine()
            let start = centre(kind, in: engine)
            let step = pitch(engine) * 0.5
            _ = down(&engine, 1, start, 0)
            // Straight up and across a few pitches, inside 0.36 s.
            var trace: [TypingEffect] = []
            for count in 1...4 {
                trace += move(&engine, 1, CGPoint(x: start.x - CGFloat(count) * step, y: start.y - CGFloat(count) * 10), 0.02 * Double(count))
            }
            trace += up(&engine, 1, CGPoint(x: start.x - 4 * step, y: start.y - 40), 0.12)
            #expect(swipeUpdates(trace).isEmpty, "\(kind) started a swipe")
            #expect(swipeEnds(trace).isEmpty, "\(kind) ended a swipe")
        }
    }

    @Test("Swipe typing starts only on the letters page")
    func notOnTheNumbersPage() {
        let letterPitch = pitch(makeEngine())
        var engine = TypingEngine(metrics: metrics, page: .numbers)
        engine.swipeEnabled = true
        let one = centre(letter("1"), in: engine)
        _ = down(&engine, 1, one, 0)
        let moved = move(&engine, 1, CGPoint(x: one.x + 2 * letterPitch, y: one.y), 0.05)
        #expect(swipeUpdates(moved).isEmpty)
    }

    // MARK: - Fingers

    @Test("A second finger ends the swipe first, then is handled as usual")
    func secondFingerEndsTheSwipe() {
        var engine = makeEngine()
        let g = centre(letter("g"), in: engine)
        let far = CGPoint(x: g.x + 1.2 * pitch(engine), y: g.y)
        _ = down(&engine, 1, g, 0)
        _ = move(&engine, 1, far, 0.05)
        let a = centre(letter("a"), in: engine)
        let landed = down(&engine, 2, a, 0.08)
        #expect(landed.count == 3)
        #expect(swipeEnds(landed).count == 1)
        #expect(swipeEnds(landed).first?.0.last == far)
        if case .swipeEnded? = landed.first {} else { Issue.record("the swipe did not end first: \(landed)") }
        #expect(landed.dropFirst() == [.feedback, .showPopup(letter("a"), alternates: [], selected: nil)])
        // The first finger's own lift and moves now do nothing; the second types normally.
        #expect(move(&engine, 1, CGPoint(x: far.x + 20, y: far.y), 0.09).isEmpty)
        #expect(up(&engine, 1, far, 0.1).isEmpty)
        #expect(inserts(up(&engine, 2, a, 0.12)) == ["a"])
    }

    @Test("Another finger on shift while swiping ends the swipe with shift as it was")
    func shiftFingerKeepsTheOldShiftForTheSwipe() {
        var engine = makeEngine()
        let g = centre(letter("g"), in: engine)
        _ = down(&engine, 1, g, 0)
        _ = move(&engine, 1, CGPoint(x: g.x + 1.2 * pitch(engine), y: g.y), 0.05)
        let landed = down(&engine, 2, centre(.shift, in: engine), 0.08)
        #expect(swipeEnds(landed).count == 1)
        #expect(landed.contains(.setShift(.on)))
        #expect(engine.shiftAtSwipeEnd == .off, "shift went on after the swipe ended, not before")
        let spent = engine.spendShiftAfterSwipe()
        #expect(!spent, "a held shift key is not spent by a word it did not capitalise")
    }

    @Test("A cancelled swipe types nothing and clears the trail with an empty update")
    func cancelledSwipeClearsTheTrail() {
        var engine = makeEngine()
        let g = centre(letter("g"), in: engine)
        _ = down(&engine, 1, g, 0)
        _ = move(&engine, 1, CGPoint(x: g.x + 1.2 * pitch(engine), y: g.y), 0.05)
        #expect(engine.handle(.cancelled(id: 1), bias: [:]) == [.swipeUpdate([])])
        #expect(up(&engine, 1, g, 0.1).isEmpty)
    }

    @Test("A cancelled touch that never swiped emits what it always did")
    func cancelledTouchIsUnchanged() {
        var engine = makeEngine()
        _ = down(&engine, 1, centre(letter("a"), in: engine), 0)
        #expect(engine.handle(.cancelled(id: 1), bias: [:]) == [.hidePopup])
    }

    @Test("Shift state is noted at the end of the swipe and spent afterwards like a typed capital")
    func shiftForSwipes() {
        var engine = makeEngine()
        engine.setShift(.on)
        let g = centre(letter("g"), in: engine)
        _ = down(&engine, 1, g, 0)
        _ = move(&engine, 1, CGPoint(x: g.x + 1.2 * pitch(engine), y: g.y), 0.05)
        let ended = up(&engine, 1, CGPoint(x: g.x + 1.2 * pitch(engine), y: g.y), 0.1)
        #expect(swipeEnds(ended).count == 1)
        #expect(engine.shiftAtSwipeEnd == .on)
        #expect(engine.shift == .on, "the engine leaves it to the controller, which types the word")
        let spentOnce = engine.spendShiftAfterSwipe()
        #expect(spentOnce)
        #expect(engine.shift == .off)

        engine.setShift(.capsLock)
        let spentLock = engine.spendShiftAfterSwipe()
        #expect(!spentLock)
        #expect(engine.shift == .capsLock)
    }
}
