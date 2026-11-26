import CoreGraphics
import Foundation
import Testing

@testable import MurmurTyping

@Suite struct NumberPadTests {
    private let metrics = KeyboardMetrics(width: 393, isLandscape: false)

    private func center(_ kind: KeyKind, in engine: TypingEngine) -> CGPoint {
        let rect = engine.frames.first { $0.kind == kind }!.keycap
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private func tap(_ engine: inout TypingEngine, _ kind: KeyKind, id: Int, at time: TimeInterval)
        -> [TypingEffect]
    {
        let point = center(kind, in: engine)
        var effects = engine.handle(.began(id: id, point: point, time: time), bias: [:])
        effects += engine.handle(.ended(id: id, point: point, time: time + 0.05), bias: [:])
        return effects
    }

    @Test("The decimal pad's bottom row holds . and 0, and the pad has at most 12 keys")
    func padRows() {
        let rows = KeyboardLayout.rows(for: .numberPad, showsGlobe: true, field: .decimal)
        #expect(rows.count == 4)
        #expect(rows[3] == [.character("."), .character("0"), .delete])
        #expect(rows.flatMap { $0 }.count <= 12)
        let plain = KeyboardLayout.rows(for: .numberPad, showsGlobe: true, field: .number)
        #expect(plain[3] == [.globe, .character("0"), .delete])
        #expect(KeyboardLayout.rows(for: .numberPad, showsGlobe: false, field: .number)[3]
            == [.character("0"), .delete])
        // Three equal columns, and the same height as the other pages.
        let frames = metrics.frames(for: rows, isNumberPad: true)
        let one = frames.first { $0.kind == .character("1") }!.keycap
        let two = frames.first { $0.kind == .character("2") }!.keycap
        #expect(abs(one.width - two.width) < 0.001)
        #expect(abs(frames.map(\.keycap.maxY).max()! - (metrics.height - metrics.constants.bottomInset)) < 0.001)
    }

    @Test("A tap on the 5 of the number pad types it, with no pop-up")
    func padTapTypes() {
        var engine = TypingEngine(metrics: metrics, page: .numberPad)
        engine.setField(.number)
        let effects = tap(&engine, .character("5"), id: 1, at: 0)
        #expect(effects.contains(.insert("5", tap: center(.character("5"), in: engine))))
        #expect(!effects.contains { if case .showPopup = $0 { true } else { false } })
    }

    @Test("Space after a character on the numbers page returns to letters in the same batch")
    func spaceAfterDigitReturns() {
        var engine = TypingEngine(metrics: metrics)
        _ = tap(&engine, .pageSwitch(.numbers), id: 1, at: 0)
        _ = tap(&engine, .character("1"), id: 2, at: 1)
        let effects = tap(&engine, .space, id: 3, at: 2)
        #expect(effects.contains(.setPage(.letters)))
        #expect(engine.page == .letters)
    }

    @Test("Space with nothing typed on the numbers page stays there")
    func spaceAloneStays() {
        var engine = TypingEngine(metrics: metrics)
        _ = tap(&engine, .pageSwitch(.numbers), id: 1, at: 0)
        let effects = tap(&engine, .space, id: 2, at: 1)
        #expect(!effects.contains(.setPage(.letters)))
        #expect(engine.page == .numbers)
    }
}
