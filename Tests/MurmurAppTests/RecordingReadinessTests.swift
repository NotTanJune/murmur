import Foundation
import Testing
@testable import Murmur

@MainActor
@Suite(.serialized)
struct RecordingReadinessTests {
    @Test("Unloaded downloadable models block recording, but Apple does not")
    func unloadedModels() {
        let models = StreamingModelPreparation(isInstalled: { _ in false }, prepare: { _ in })
        #expect(models.recordingBlocker(for: .parakeetEOU) != nil)
        #expect(models.recordingBlocker(for: .nemotron) != nil)
        #expect(models.recordingBlocker(for: .barkClean) != nil)
        #expect(models.recordingBlocker(for: .parakeet) != nil)
        #expect(models.recordingBlocker(for: .apple) == nil)
    }

    @Test("An explicit successful load removes the recording blocker")
    func readyModels() async throws {
        let models = StreamingModelPreparation(isInstalled: { _ in false }, prepare: { _ in })
        let task = try #require(models.load(.parakeetEOU))
        #expect(models.recordingBlocker(for: .parakeetEOU) != nil)
        await task.value
        #expect(models.recordingBlocker(for: .parakeetEOU) == nil)
        #expect(models.recordingBlocker(for: .nemotron) != nil)
    }

    @Test("Auto-load never starts a download for a model that is not on disk")
    func autoLoadSkipsMissingModels() {
        let models = StreamingModelPreparation(isInstalled: { _ in false }, prepare: { _ in
            Issue.record("Auto-load must not prepare a model that is not installed")
        })
        #expect(models.loadIfInstalled(.apple) == nil)
        #expect(models.loadIfInstalled(.parakeetEOU) == nil)
        #expect(models.loadIfInstalled(.nemotron) == nil)
        #expect(models.state(for: .parakeetEOU) == .unloaded)
    }

    @Test("Failed loads keep recording blocked and expose the load error")
    func failedModel() async throws {
        let models = StreamingModelPreparation(isInstalled: { _ in false }, prepare: { _ in throw LoadFailure() })
        let task = try #require(models.load(.nemotron))
        await task.value
        let blocker = try #require(models.recordingBlocker(for: .nemotron))
        #expect(blocker.contains("Download unavailable"))
    }

    @Test("A blocked press never enters recording and the explanation survives release",
          arguments: [SpeechEngineChoice.parakeetEOU, .nemotron, .parakeet, .barkClean])
    func blockedPress(choice: SpeechEngineChoice) async {
        let settings = Settings.shared
        let previousEngine = settings.engine
        let previousCompareMode = settings.compareMode
        defer {
            settings.engine = previousEngine
            settings.compareMode = previousCompareMode
        }
        settings.engine = choice
        settings.compareMode = false
        let models = StreamingModelPreparation(isInstalled: { _ in false }, prepare: { _ in
            Issue.record("A blocked press must not load a model")
        })
        let controller = DictationController(makeEngine: {
            Issue.record("A blocked press must not create a recording engine")
            return AppleSpeechEngine()
        }, models: models)
        controller.startButtonRecording()
        #expect(controller.state == .idle)
        #expect(!controller.state.isActive)
        #expect(controller.recordingNotice == models.recordingBlocker(for: choice))
        controller.stopButtonRecording()
        await Task.yield()
        #expect(controller.recordingNotice != nil)
        #expect(controller.state == .idle)
        #expect(models.state(for: choice) == .unloaded)
        #expect(settings.engine == choice)
    }

    @Test("The recording notice tracks explicit load, failure, retry, and readiness")
    func noticeTracksPreparation() async throws {
        let settings = Settings.shared
        let previousEngine = settings.engine
        let previousCompareMode = settings.compareMode
        defer {
            settings.engine = previousEngine
            settings.compareMode = previousCompareMode
        }
        settings.engine = .nemotron
        settings.compareMode = false
        let preparation = RetryingPreparation()
        let models = StreamingModelPreparation(isInstalled: { _ in false }, prepare: { _ in try await preparation.prepare() })
        let controller = DictationController(models: models)
        controller.startButtonRecording()
        controller.stopButtonRecording()

        let firstLoad = try #require(models.load(.nemotron))
        #expect(controller.recordingNotice?.contains("Preparing") == true)
        #expect(models.load(.nemotron) == nil)
        await firstLoad.value
        #expect(controller.recordingNotice?.contains("Download unavailable") == true)

        let retry = try #require(models.load(.nemotron))
        #expect(controller.recordingNotice?.contains("Preparing") == true)
        await retry.value
        #expect(controller.recordingNotice == nil)
        #expect(models.load(.nemotron) == nil)
        #expect(controller.state == .idle)
    }

    @Test("The recording notice does not follow unrelated engines or compare mode")
    func noticeFollowsSelection() {
        let settings = Settings.shared
        let previousEngine = settings.engine
        let previousCompareMode = settings.compareMode
        defer {
            settings.engine = previousEngine
            settings.compareMode = previousCompareMode
        }
        settings.engine = .parakeetEOU
        settings.compareMode = false
        let models = StreamingModelPreparation(isInstalled: { _ in false }, prepare: { _ in })
        let controller = DictationController(models: models)
        controller.startButtonRecording()
        controller.stopButtonRecording()
        #expect(controller.recordingNotice != nil)

        settings.engine = .apple
        #expect(controller.recordingNotice == nil)
        settings.engine = .nemotron
        #expect(controller.recordingNotice == nil)
        settings.engine = .parakeetEOU
        #expect(controller.recordingNotice != nil)
        settings.compareMode = true
        #expect(controller.recordingNotice == nil)
    }
}

private actor RetryingPreparation {
    private var attempts = 0

    func prepare() throws {
        attempts += 1
        if attempts == 1 { throw LoadFailure() }
    }
}

private struct LoadFailure: LocalizedError {
    var errorDescription: String? { "Download unavailable" }
}

@MainActor
@Suite struct ModelResidencyTests {
    @Test("An installed model released to save memory never blocks recording, and a press loads it")
    func sleepingModelsDoNotBlock() async {
        let models = StreamingModelPreparation(isInstalled: { $0 == .barkClean }, prepare: { _ in })
        #expect(models.state(for: .barkClean) == .sleeping)
        #expect(models.recordingBlocker(for: .barkClean) == nil)
        // Not installed still blocks: that one would need a download.
        #expect(models.recordingBlocker(for: .parakeet) != nil)

        models.wake(.barkClean)
        #expect(models.state(for: .barkClean) == .loading)
        #expect(models.recordingBlocker(for: .barkClean) == nil)
    }

    @Test("An installed model still preparing never holds the dictation: Apple stands in")
    func appleStandsInWhilePreparing() async {
        let settings = Settings.shared
        let previousEngine = settings.engine
        let previousCompareMode = settings.compareMode
        defer {
            settings.engine = previousEngine
            settings.compareMode = previousCompareMode
        }
        settings.engine = .barkClean
        settings.compareMode = false
        let models = StreamingModelPreparation(isInstalled: { _ in true }, prepare: { _ in
            try await Task.sleep(for: .seconds(60))    // a long Neural Engine compile
        })
        models.wake(.barkClean)
        #expect(models.state(for: .barkClean) == .loading)
        // The configured engine may legitimately be built after the hold (the open-mic
        // path prefetches its input format on release); during the hold it must not be.
        let holding = Holding()
        let controller = DictationController(makeEngine: {
            if await holding.value { Issue.record("the stand-in must bypass the configured engine") }
            return AppleSpeechEngine()
        }, models: models)
        await holding.set(true)
        controller.startButtonRecording()
        #expect(controller.state.isActive)
        #expect(controller.recordingNotice == nil)
        await Task.yield()
        await holding.set(false)
        controller.stopButtonRecording()
        controller.deactivate()
    }

    @Test("Idle release choices map to the right delays")
    func idleDelays() {
        #expect(IdleUnload.oneMinute.delay == .seconds(60))
        #expect(IdleUnload.fiveMinutes.delay == .seconds(300))
        #expect(IdleUnload.never.delay == nil)
    }
}

private actor Holding {
    var value = false
    func set(_ new: Bool) { value = new }
}
