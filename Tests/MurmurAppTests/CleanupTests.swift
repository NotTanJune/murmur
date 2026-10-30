import Foundation
import Testing
@testable import Murmur

struct CleanupTests {
    @Test("Each profile sends a control line from S1-mini's trained set, exactly")
    func controlLines() {
        #expect(CleanupProfile.general.controlLine == "[Styling: semi-formal] [Structure: prose] [Context: general]")
        #expect(CleanupProfile.email.controlLine == "[Styling: semi-formal] [Structure: prose] [Context: email]")
        #expect(CleanupProfile.message.controlLine == "[Styling: semi-casual] [Structure: prose] [Context: general]")
        #expect(CleanupProfile.notes.controlLine == "[Styling: semi-formal] [Structure: lists] [Context: general]")
        #expect(Set(CleanupProfile.allCases.map(\.controlLine)).count == CleanupProfile.allCases.count)
    }

    /// Inputs and outputs recorded from the 4-bit model on an M2 during the benchmark.
    @Test("The guard accepts what S1-mini actually produced", arguments: [
        ("So I need to send the report by Friday. No wait, make that Thursday, and copy Priya on it.",
         "So I need to send the report by Thursday, and copy Priya on it."),
        ("The invoice came to twenty three thousand four hundred and fifty dollars and it's due on March third twenty twenty seven.",
         "The invoice came to $23,450 and it's due on March 3rd, 2027."),
        ("Hey, can you grab some milk on the way home? I'm gonna be like twenty minutes late.",
         "Hey, can you grab some milk on the way home? I'm going to be like 20 minutes late."),
        ("So for the trip we need to pack sunscreen and then also a first aid kit and chargers for everything and you know the passports.",
         "So for the trip we need to pack:\n- Sunscreen\n- A first aid kit\n- Chargers for everything\n- The passports"),
        ("Hey Sarah, just wanted to follow up on the proposal from last week. I think the numbers look good, but can you send me the updated budget by end of week? Also, I mean, let's set up a call on Tuesday, actually Wednesday works better for me. Thanks, John.",
         "Hey Sarah,\n\nJust wanted to follow up on the proposal from last week. I think the numbers look good, but can you send me the updated budget by end of week? Also, let's set up a call on Wednesday, which works better for me.\n\nThanks,\nJohn"),
        ("What is the capital of France?", "What is the capital of France?"),
        ("twenty three thousand four hundred and fifty", "23,450"),
    ])
    func guardAcceptsS1Mini(input: String, output: String) {
        #expect(FoundationModelFormatter.isPlausibleCleanup(original: input, cleaned: output, writesNumerals: true))
    }

    @Test("Numerals don't open a hole for answers")
    func guardStillRejectsAnswers() {
        #expect(!FoundationModelFormatter.isPlausibleCleanup(
            original: "What is the capital of France?", cleaned: "The capital of France is Paris.", writesNumerals: true))
        #expect(!FoundationModelFormatter.isPlausibleCleanup(
            original: "how many moons does mars have", cleaned: "Mars has 2 moons, Phobos and Deimos.", writesNumerals: true))
        // The Apple Intelligence path is unchanged: numerals still count as invented there.
        #expect(!FoundationModelFormatter.isPlausibleCleanup(
            original: "twenty three dollars", cleaned: "$23", writesNumerals: false))
    }

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
        let idle = S1MiniPreparation(load: { _ in Issue.record("must not load") })
        #expect(idle.loadIfInstalled(isInstalled: false) == nil)
        #expect(idle.state == .unloaded)

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
