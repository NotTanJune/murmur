import Testing
@testable import MurmurKit

struct EngineChoiceTests {
    @Test("Persisted streaming selections restore as live engines")
    func streamingChoices() throws {
        for key in ["apple", "parakeetEOU", "nemotron"] {
            let choice = try #require(SpeechEngineChoice(rawValue: key))
            #expect(choice.showsLiveText)
            #expect(SpeechEngineChoice.allCases.contains(choice))
        }
        #expect(SpeechEngineChoice(rawValue: "parakeet")?.showsLiveText == true)
        #expect(SpeechEngineChoice(rawValue: "barkClean")?.showsLiveText == true)
    }

    @Test("Parakeet and Bark are named for how they transcribe; the others always stream")
    func namesFollowTiming() {
        #expect(SpeechEngineChoice.barkClean.displayName(timing: .whileSpeaking) == "Bark 3.0 Clean (streaming)")
        #expect(SpeechEngineChoice.barkClean.displayName(timing: .onRelease) == "Bark 3.0 Clean (batch)")
        #expect(SpeechEngineChoice.parakeet.displayName(timing: .whileSpeaking) == "Parakeet (streaming)")
        #expect(SpeechEngineChoice.parakeet.displayName(timing: .onRelease) == "Parakeet (batch)")
        for timing in TranscribeTiming.allCases {
            #expect(SpeechEngineChoice.apple.displayName(timing: timing) == "Apple (streaming)")
            #expect(SpeechEngineChoice.nemotron.displayName(timing: timing) == "Nemotron (streaming)")
        }
    }

    @Test("Only engines with an explicit load step gate recording")
    func preparedModels() {
        #expect(SpeechEngineChoice.parakeet.requiresPreparedModel)
        #expect(SpeechEngineChoice.barkClean.requiresPreparedModel)
        #expect(SpeechEngineChoice.parakeetEOU.requiresPreparedModel)
        #expect(SpeechEngineChoice.nemotron.requiresPreparedModel)
        #expect(!SpeechEngineChoice.apple.requiresPreparedModel)
    }

    @Test("Engines without a local install check never auto-load")
    func installedCheck() {
        #expect(!SpeechEngineChoice.apple.isInstalledLocally)
        #expect(!SpeechEngineChoice.parakeetEOU.isInstalledLocally)
        #expect(!SpeechEngineChoice.nemotron.isInstalledLocally)
    }
}
