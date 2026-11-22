import Foundation
import Testing
@testable import MurmurKit

/// These never call `MurmurEnvironment.configure`: the environment is process-global and
/// `Settings.shared`, `RecordingStore.shared` and `DictionaryStore.shared` pin what it says
/// on first use, so a test that changed it would leak into suites running beside it.
struct MurmurEnvironmentTests {
    @Test("Unconfigured, storage is the Mac's Application Support/Murmur folder")
    func unconfiguredRootIsMacApplicationSupport() {
        let resolved = MurmurEnvironment.resolve(nil)
        #expect(resolved.storageRoot.path.hasSuffix("Library/Application Support/Murmur"))
        #expect(MurmurEnvironment.storageRoot == resolved.storageRoot)
        #expect(AppStorage.directory == MurmurEnvironment.storageRoot)
    }

    @Test("A configuration's root is what resolves")
    func configuredRootIsUsed() {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resolved = MurmurEnvironment.resolve(.init(storageRoot: temp, defaults: .standard))
        #expect(resolved.storageRoot == temp)
        #expect(BarkModelStore.modelsRoot(in: resolved.storageRoot).path.hasPrefix(temp.path))
        #expect(CustomDecoderSlot.root(in: resolved.storageRoot).path.hasPrefix(temp.path))
    }

    @Test("Unconfigured, the Bark and decoder-slot folders sit where the Mac has always kept them")
    func macModelPathsAreUnchanged() {
        let support = MurmurEnvironment.resolve(nil).storageRoot
        #expect(BarkModelStore.modelsRoot == support.appendingPathComponent("Models", isDirectory: true))
        #expect(CustomDecoderSlot.root == support.appendingPathComponent("Models/bark-3.0-clean-custom", isDirectory: true))
    }

    @Test("A configuration's defaults object is what Settings reads")
    @MainActor
    func configuredDefaultsAreUsed() throws {
        let name = "murmur-tests-\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        suite.set("nemotron", forKey: "engine")
        let resolved = MurmurEnvironment.resolve(.init(storageRoot: FileManager.default.temporaryDirectory, defaults: suite))
        #expect(resolved.defaults === suite)
        #expect(Settings(defaults: resolved.defaults).engine == .nemotron)
    }

    @Test("Unconfigured, repeated reads return the same defaults instance")
    func unconfiguredDefaultsAreCached() {
        #expect(MurmurEnvironment.resolve(nil).defaults === MurmurEnvironment.resolve(nil).defaults)
        #expect(MurmurEnvironment.defaults === MurmurEnvironment.defaults)
    }
}
