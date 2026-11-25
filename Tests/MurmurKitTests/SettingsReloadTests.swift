import Foundation
import Testing
@testable import MurmurKit

struct SettingsReloadTests {
    @MainActor
    @Test("reloadPicksUpExternalWrites")
    func reloadPicksUpExternalWrites() throws {
        let name = "murmur-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults)
        var appearanceCalls = 0
        settings.onAppearanceChange = { _ in appearanceCalls += 1 }
        #expect(settings.keepRecordings)
        #expect(settings.engine == .apple)

        // Another process (the app) writes behind this instance's back.
        defaults.set(false, forKey: "keepRecordings")
        defaults.set("barkClean", forKey: "engine")
        defaults.set("onRelease", forKey: "transcribeTiming")
        defaults.set(false, forKey: "cleanupEnabled")
        defaults.set("appleIntelligence", forKey: "cleanupEngine")
        defaults.set("dark", forKey: "appearance")
        // The old instance has not seen any of it.
        #expect(settings.keepRecordings)

        settings.reloadFromDefaults()

        #expect(settings.keepRecordings == false)
        #expect(settings.engine == .barkClean)
        #expect(settings.transcribeTiming == .onRelease)
        #expect(settings.cleanupEnabled == false)
        #expect(settings.cleanupEngine == .appleIntelligence)
        #expect(settings.appearance == .dark)
        #expect(appearanceCalls == 0, "a reload does not run the appearance hook")

        // Keys nobody wrote stay unwritten: the reload assigns without persisting.
        for key in ["soundEnabled", "alwaysOpenMic", "keepSystemInput", "idleUnload", "compareMode",
                    "barkDecoder", "cleanupProfile", "pushToTalkKey", "hapticsEnabled", "swipeTyping", "swipeTrail", "autoCapitalise", "smartPredictions"] {
            #expect(defaults.object(forKey: key) == nil, "\(key) was written back")
        }
        // The values written from outside are still what they were.
        #expect(defaults.string(forKey: "engine") == "barkClean")
        #expect(defaults.object(forKey: "keepRecordings") as? Bool == false)

        // A normal assignment still persists afterwards.
        settings.keepRecordings = true
        #expect(defaults.object(forKey: "keepRecordings") as? Bool == true)
    }

    @MainActor
    @Test("A reload applies the defaults again when a key is removed")
    func reloadFallsBackToDefaults() throws {
        let name = "murmur-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "keepRecordings")
        let settings = Settings(defaults: defaults)
        #expect(settings.keepRecordings == false)
        defaults.removeObject(forKey: "keepRecordings")
        settings.reloadFromDefaults()
        #expect(settings.keepRecordings)
    }

    @MainActor
    @Test("Haptics default on, persist, and reload from another process's write")
    func hapticsEnabledPersistsAndReloads() throws {
        let name = "murmur-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults)
        #expect(settings.hapticsEnabled)
        #expect(defaults.object(forKey: "hapticsEnabled") == nil, "the default is not written")

        settings.hapticsEnabled = false
        #expect(defaults.object(forKey: "hapticsEnabled") as? Bool == false)
        #expect(Settings(defaults: defaults).hapticsEnabled == false, "a new instance reads the stored value")

        // The app turns haptics back on while the keyboard's instance holds the old value.
        defaults.set(true, forKey: "hapticsEnabled")
        #expect(settings.hapticsEnabled == false)
        settings.reloadFromDefaults()
        #expect(settings.hapticsEnabled)

        defaults.set(false, forKey: "hapticsEnabled")
        settings.reloadFromDefaults()
        #expect(settings.hapticsEnabled == false)
        defaults.removeObject(forKey: "hapticsEnabled")
        settings.reloadFromDefaults()
        #expect(settings.hapticsEnabled, "a removed key falls back to on")
        #expect(defaults.object(forKey: "hapticsEnabled") == nil, "the reload does not write back")
    }

    @MainActor
    @Test("Auto-capitalisation is off by default, persists and reloads without writing back")
    func autoCapitalisePersistsAndReloads() throws {
        let name = "murmur-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults)
        #expect(settings.autoCapitalise == false)
        #expect(defaults.object(forKey: "autoCapitalise") == nil, "the default is not written")

        settings.autoCapitalise = true
        #expect(defaults.object(forKey: "autoCapitalise") as? Bool == true)
        #expect(Settings(defaults: defaults).autoCapitalise, "a new instance reads the stored value")

        defaults.removeObject(forKey: "autoCapitalise")
        settings.reloadFromDefaults()
        #expect(settings.autoCapitalise == false, "a removed key falls back to off")
        #expect(defaults.object(forKey: "autoCapitalise") == nil, "the reload does not write back")
    }

    @MainActor
    @Test("The swipe trail's thickness persists and reloads without writing back")
    func swipeTrailPersistsAndReloads() throws {
        let name = "murmur-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults)
        #expect(settings.swipeTrail == .regular)
        #expect(defaults.object(forKey: "swipeTrail") == nil, "the default is not written")

        settings.swipeTrail = .thick
        #expect(defaults.string(forKey: "swipeTrail") == "thick")
        #expect(Settings(defaults: defaults).swipeTrail == .thick, "a new instance reads the stored value")

        defaults.set("thin", forKey: "swipeTrail")
        settings.reloadFromDefaults()
        #expect(settings.swipeTrail == .thin)
        defaults.removeObject(forKey: "swipeTrail")
        settings.reloadFromDefaults()
        #expect(settings.swipeTrail == .regular, "a removed key falls back to regular")
        #expect(defaults.object(forKey: "swipeTrail") == nil, "the reload does not write back")
    }

    @MainActor
    @Test("Swipe typing defaults on, persists, and reloads from another process's write")
    func swipeTypingPersistsAndReloads() throws {
        let name = "murmur-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults)
        #expect(settings.swipeTyping)
        #expect(defaults.object(forKey: "swipeTyping") == nil, "the default is not written")

        settings.swipeTyping = false
        #expect(defaults.object(forKey: "swipeTyping") as? Bool == false)
        #expect(Settings(defaults: defaults).swipeTyping == false, "a new instance reads the stored value")

        // The app turns it back on while the keyboard's instance holds the old value.
        defaults.set(true, forKey: "swipeTyping")
        #expect(settings.swipeTyping == false)
        settings.reloadFromDefaults()
        #expect(settings.swipeTyping)

        defaults.set(false, forKey: "swipeTyping")
        settings.reloadFromDefaults()
        #expect(settings.swipeTyping == false)
        defaults.removeObject(forKey: "swipeTyping")
        settings.reloadFromDefaults()
        #expect(settings.swipeTyping, "a removed key falls back to on")
        #expect(defaults.object(forKey: "swipeTyping") == nil, "the reload does not write back")
    }

    @MainActor
    @Test("Smart predictions default on, persist, and reload from another process's write")
    func smartPredictionsPersistsAndReloads() throws {
        let name = "murmur-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults)
        #expect(settings.smartPredictions)
        #expect(defaults.object(forKey: "smartPredictions") == nil, "the default is not written")

        settings.smartPredictions = false
        #expect(defaults.object(forKey: "smartPredictions") as? Bool == false)
        #expect(Settings(defaults: defaults).smartPredictions == false, "a new instance reads the stored value")

        // The app turns it back on while the keyboard's instance holds the old value.
        defaults.set(true, forKey: "smartPredictions")
        #expect(settings.smartPredictions == false)
        settings.reloadFromDefaults()
        #expect(settings.smartPredictions)

        defaults.removeObject(forKey: "smartPredictions")
        settings.reloadFromDefaults()
        #expect(settings.smartPredictions, "a removed key falls back to on")
        #expect(defaults.object(forKey: "smartPredictions") == nil, "the reload does not write back")
    }
}
