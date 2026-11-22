import AppKit
import MurmurKit
import Testing
@testable import Murmur

struct StreamingEngineMappingTests {
    @Test("Bark has no FluidAudio streaming engine")
    func barkHasNoStreamingEngine() {
        #expect(SpeechEngineChoice.barkClean.streamingEngine == nil)
    }
}

struct PushToTalkKeyTests {
    /// Device-dependent bits from IOLLEvent.h, plus the device-independent flag each sets.
    private static let rightOption = NSEvent.ModifierFlags(rawValue: 0x40 | NSEvent.ModifierFlags.option.rawValue)
    private static let leftOption = NSEvent.ModifierFlags(rawValue: 0x20 | NSEvent.ModifierFlags.option.rawValue)
    private static let rightCommand = NSEvent.ModifierFlags(rawValue: 0x10 | NSEvent.ModifierFlags.command.rawValue)
    private static let leftCommand = NSEvent.ModifierFlags(rawValue: 0x08 | NSEvent.ModifierFlags.command.rawValue)

    @Test("Key state comes from the event, so the left-hand twin never reads as a press")
    func deviceBits() {
        #expect(PushToTalkKey.rightOption.isDown(in: Self.rightOption))
        #expect(!PushToTalkKey.rightOption.isDown(in: Self.leftOption))
        #expect(!PushToTalkKey.rightOption.isDown(in: []))
        #expect(PushToTalkKey.rightCommand.isDown(in: Self.rightCommand))
        #expect(!PushToTalkKey.rightCommand.isDown(in: Self.leftCommand))
        #expect(PushToTalkKey.fn.isDown(in: .function))
        #expect(!PushToTalkKey.fn.isDown(in: Self.rightOption))
    }

    @Test("Releasing the key while its twin is held still reads as up")
    func releaseWithTwinHeld() {
        let leftStillHeld = Self.leftOption
        #expect(!PushToTalkKey.rightOption.isDown(in: leftStillHeld))
    }

    @Test("A repaired key-up clears only that key, keeping a held twin and other modifiers")
    func releasingFlags() {
        let shift = CGEventFlags.maskShift.rawValue | 0x02
        let stuck = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10 | shift)
        #expect(PushToTalkKey.rightCommand.releasing(from: stuck).rawValue == shift)

        let bothCommands = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10 | 0x08)
        #expect(PushToTalkKey.rightCommand.releasing(from: bothCommands).rawValue == CGEventFlags.maskCommand.rawValue | 0x08)

        let option = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        #expect(PushToTalkKey.rightOption.releasing(from: option).rawValue == 0)
        #expect(PushToTalkKey.fn.releasing(from: .maskSecondaryFn).rawValue == 0)
    }
}
