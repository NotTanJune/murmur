import Foundation
import Testing
import MurmurKit
@testable import Murmur

struct CleanupAppTests {
    @Test("Appearance defaults to following macOS and persists an explicit choice")
    @MainActor
    func appearancePersists() throws {
        let name = "murmur-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(Settings(defaults: defaults).appearance == .system)
        #expect(AppearanceChoice.system.nsAppearance == nil)
        #expect(AppearanceChoice.dark.nsAppearance?.name == .darkAqua)

        defaults.set("dark", forKey: "appearance")
        #expect(Settings(defaults: defaults).appearance == .dark)
        defaults.set("bogus", forKey: "appearance")
        #expect(Settings(defaults: defaults).appearance == .system)
    }

    @Test("smartCleanup migrates to Apple Intelligence; new installs default to the rule pass")
    @MainActor
    func settingsMigration() throws {
        let name = "murmur-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(Settings(defaults: defaults).cleanupEngine == .rules)
        #expect(Settings(defaults: defaults).cleanupProfile == .general)

        defaults.set(true, forKey: "smartCleanup")
        #expect(Settings(defaults: defaults).cleanupEngine == .appleIntelligence)

        let settings = Settings(defaults: defaults)
        settings.cleanupEngine = .s1Mini
        settings.cleanupProfile = .email
        let reloaded = Settings(defaults: defaults)
        #expect(reloaded.cleanupEngine == .s1Mini)
        #expect(reloaded.cleanupProfile == .email)
    }

    @Test("The S1-mini manifest pins one commit and carries the license files")
    func manifest() throws {
        #expect(S1MiniModelStore.revision.count == 40)
        let paths = Set(S1MiniModelStore.sourceFiles.map(\.path))
        #expect(paths.count == S1MiniModelStore.sourceFiles.count)
        for name in ["config.json", "model.safetensors", "tokenizer.json", "LICENSE", "NOTICE"] {
            #expect(paths.contains(name))
        }
        #expect(Set(S1MiniModelStore.carriedFiles).isSubset(of: paths))
        #expect(S1MiniModelStore.carriedFiles.contains("LICENSE"))
        #expect(S1MiniModelStore.carriedFiles.contains("NOTICE"))
        for file in S1MiniModelStore.sourceFiles {
            #expect(file.sha256.count == 64)
            #expect(file.size > 0)
        }

        let config = try S1MiniModelStore.quantizedConfig(from: Data(#"{"model_type":"qwen3","hidden_size":1024}"#.utf8))
        let object = try #require(try JSONSerialization.jsonObject(with: config) as? [String: Any])
        let quantization = try #require(object["quantization"] as? [String: Any])
        #expect(quantization["bits"] as? Int == 4)
        #expect(quantization["group_size"] as? Int == 64)
        #expect(object["model_type"] as? String == "qwen3")
    }

    @Test("Load state: nothing starts when not installed; success and failure are reported")
    @MainActor
    func preparation() async {
        let idle = S1MiniPreparation(isInstalled: false, load: { _ in Issue.record("must not load") })
        #expect(idle.loadIfInstalled(isInstalled: false) == nil)
        #expect(idle.state == .unloaded)
        idle.wake()
        #expect(idle.state == .unloaded)

        // Installed but released: not in memory until a press wakes it.
        let sleeping = S1MiniPreparation(isInstalled: true, load: { _ in })
        #expect(sleeping.state == .sleeping)
        sleeping.wake()
        #expect(sleeping.state == .loading)

        let ok = S1MiniPreparation(load: { phase in phase(.downloading); phase(.converting); phase(nil) })
        await ok.start()?.value
        #expect(ok.state == .ready)
        #expect(ok.start() == nil)

        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let failing = S1MiniPreparation(load: { _ in throw Boom() })
        await failing.start()?.value
        #expect(failing.state == .failed("boom"))
    }

    @Test("Without a loaded model the formatter falls back to the rule pass")
    func fallsBackWhenUnloaded() async {
        let text = "um so this is uh a test"
        let s1 = await S1MiniFormatter(profile: .general, engine: S1MiniEngine()).format(text)
        let rules = await RuleBasedFormatter().format(text)
        #expect(s1 == rules)
    }
}

struct ShortUtteranceTests {
    @Test("Three words or fewer take the rule pass in the General profile; longer text and other profiles take the model")
    func rulesSuffice() {
        #expect(S1MiniFormatter.rulesSuffice(for: "NUS.", profile: .general))
        #expect(S1MiniFormatter.rulesSuffice(for: "Yes, do that.", profile: .general))
        #expect(!S1MiniFormatter.rulesSuffice(for: "Yes, go do that.", profile: .general))
        #expect(!S1MiniFormatter.rulesSuffice(for: "Thanks", profile: .message))
    }

    @Test("An app that refused an accessibility insert is pasted into directly for ten minutes")
    func pasteOnlyMemory() {
        var apps = PasteOnlyApps()
        let now = Date(timeIntervalSinceReferenceDate: 0)
        #expect(!apps.contains("com.example.terminal", at: now))
        apps.note("com.example.terminal", at: now)
        #expect(apps.contains("com.example.terminal", at: now.addingTimeInterval(599)))
        #expect(!apps.contains("com.example.terminal", at: now.addingTimeInterval(601)))
        #expect(!apps.contains("com.example.notes", at: now))
    }
}

