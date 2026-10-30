import AppKit
import Testing
@testable import Murmur

struct EngineChoiceTests {
    @Test("Persisted streaming selections restore as live engines")
    func streamingChoices() throws {
        for key in ["apple", "parakeetEOU", "nemotron"] {
            let choice = try #require(SpeechEngineChoice(rawValue: key))
            #expect(choice.showsLiveText)
            #expect(SpeechEngineChoice.allCases.contains(choice))
        }
        #expect(SpeechEngineChoice(rawValue: "parakeet")?.showsLiveText == false)
        #expect(SpeechEngineChoice(rawValue: "barkClean")?.showsLiveText == false)
    }

    @Test("Only engines with an explicit load step gate recording")
    func preparedModels() {
        #expect(SpeechEngineChoice.parakeet.requiresPreparedModel)
        #expect(SpeechEngineChoice.barkClean.requiresPreparedModel)
        #expect(SpeechEngineChoice.parakeetEOU.requiresPreparedModel)
        #expect(SpeechEngineChoice.nemotron.requiresPreparedModel)
        #expect(!SpeechEngineChoice.apple.requiresPreparedModel)
        #expect(SpeechEngineChoice.barkClean.streamingEngine == nil)
    }

    @Test("Engines without a local install check never auto-load")
    func installedCheck() {
        #expect(!SpeechEngineChoice.apple.isInstalledLocally)
        #expect(!SpeechEngineChoice.parakeetEOU.isInstalledLocally)
        #expect(!SpeechEngineChoice.nemotron.isInstalledLocally)
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
}
