import Foundation
import Testing
@testable import MurmurKit

struct HoldGestureTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test("A short touch locks recording; the next touch ends it")
    func touchStateMachine() {
        var gesture = HoldGesture()
        #expect(gesture.touchDown(at: t0, busy: false) == .start)
        #expect(gesture.touchUp(at: t0.addingTimeInterval(0.29)) == .lock)
        // Locked: the second touch begins nothing, and lifting it finishes.
        #expect(gesture.touchDown(at: t0.addingTimeInterval(1.0), busy: false) == .none)
        #expect(gesture.touchUp(at: t0.addingTimeInterval(1.1)) == .finish)

        // Back to idle: a fresh hold longer than the limit finishes on release.
        #expect(gesture.touchDown(at: t0, busy: false) == .start)
        #expect(gesture.touchUp(at: t0.addingTimeInterval(0.31)) == .finish)
    }

    @Test("A touch while the last hold is still finishing does nothing, and neither does its release")
    func busyTouchIsIgnored() {
        var gesture = HoldGesture()
        #expect(gesture.touchDown(at: t0, busy: true) == .none)
        #expect(gesture.touchUp(at: t0.addingTimeInterval(0.1)) == .none)
        #expect(gesture.touchDown(at: t0.addingTimeInterval(2), busy: false) == .start)
    }

    @Test("Reset forgets a lock the hold's failure left behind")
    func resetClearsLock() {
        var gesture = HoldGesture()
        _ = gesture.touchDown(at: t0, busy: false)
        #expect(gesture.touchUp(at: t0.addingTimeInterval(0.1)) == .lock)
        gesture.reset()
        #expect(gesture.touchDown(at: t0.addingTimeInterval(5), busy: false) == .start)
    }

    @Test("A touch-up with no touch-down does nothing")
    func strayTouchUp() {
        var gesture = HoldGesture()
        #expect(gesture.touchUp(at: t0) == .none)
    }
}

struct KeyboardEngineChoiceTests {
    @Test("Apple stands in unless Bark is selected, loaded and the crash marker is clear")
    func engineChoiceFallsBackToApple() {
        #expect(KeyboardEngineChoice.choose(setting: .barkClean, barkReady: true, markerArmed: false) == .bark)
        #expect(KeyboardEngineChoice.choose(setting: .barkClean, barkReady: false, markerArmed: false) == .apple)
        #expect(KeyboardEngineChoice.choose(setting: .barkClean, barkReady: true, markerArmed: true) == .apple)
        #expect(KeyboardEngineChoice.choose(setting: .apple, barkReady: true, markerArmed: false) == .apple)
        // The keyboard offers only Bark and Apple, so any other saved choice reads as Apple.
        for other in [SpeechEngineChoice.parakeet, .parakeetEOU, .nemotron] {
            #expect(KeyboardEngineChoice.choose(setting: other, barkReady: true, markerArmed: false) == .apple)
        }
    }
}
