import Foundation
import Testing
@testable import MurmurKit

struct EmojiCatalogTests {
    /// A throwaway defaults domain; the Makefile's `test` target sweeps `murmur-tests-*`.
    private func scratchDefaults() -> UserDefaults {
        let name = "murmur-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("A thumbs up has five tones, light to dark")
    func thumbsUpHasFiveTones() {
        #expect(EmojiCatalog.tones(for: "👍") == ["👍🏻", "👍🏼", "👍🏽", "👍🏾", "👍🏿"])
    }

    @Test("A face has no tones")
    func grinningHasNoTones() {
        #expect(EmojiCatalog.tones(for: "😀").isEmpty)
    }

    @Test("A toned form maps back to its base")
    func tonedFormMapsToBase() {
        #expect(EmojiCatalog.base(ofToned: "👍🏾") == "👍")
        #expect(EmojiCatalog.base(ofToned: "👍") == nil)
    }

    @Test("A chosen tone is remembered for its base only")
    func preferenceRoundTrips() {
        var preference = EmojiTonePreference(defaults: scratchDefaults())
        preference.set("👍🏽", for: "👍")
        #expect(preference.preferred(for: "👍") == "👍🏽")
        #expect(preference.preferred(for: "👋") == "👋")
        // A second value over the same defaults reads what the first stored.
        preference.set("👍🏿", for: "👍")
        #expect(preference.preferred(for: "👍") == "👍🏿")
    }

    @Test("With nothing chosen the base comes back")
    func unsetPreferenceReturnsBase() {
        let preference = EmojiTonePreference(defaults: scratchDefaults())
        #expect(preference.preferred(for: "👍") == "👍")
        #expect(preference.preferred(for: "😀") == "😀")
    }
}
