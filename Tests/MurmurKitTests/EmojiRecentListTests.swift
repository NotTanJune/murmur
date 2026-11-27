import Testing
@testable import MurmurKit

struct EmojiRecentListTests {
    @Test("A new tone of an emoji replaces the older tone and moves to the front")
    func newToneReplacesOlderTone() {
        let list = EmojiRecentList.recording("✊🏼", in: ["😀", "✊🏽", "🔥"], limit: 32)
        #expect(list == ["✊🏼", "😀", "🔥"])
    }

    @Test("The plain form and a toned form are one entry")
    func plainAndTonedAreOneEntry() {
        #expect(EmojiRecentList.recording("👊", in: ["👊🏻", "😘"], limit: 32) == ["👊", "😘"])
        #expect(EmojiRecentList.recording("👊🏻", in: ["😘", "👊"], limit: 32) == ["👊🏻", "😘"])
    }

    @Test("Emoji without tones are kept apart as before")
    func untonedEmojiStayDistinct() {
        #expect(EmojiRecentList.recording("😀", in: ["😃", "😀", "😄"], limit: 32) == ["😀", "😃", "😄"])
    }

    @Test("The list is cut to its limit")
    func cutToLimit() {
        #expect(EmojiRecentList.recording("🔥", in: ["😀", "😃", "😄"], limit: 3) == ["🔥", "😀", "😃"])
    }

    @Test("A stored list with several tones of one emoji keeps only the newest")
    func storedDuplicatesCollapse() {
        // The phone's list on 2026-11-27, newest first.
        let stored = ["🤣", "🪞", "👆🏼", "✊🏽", "🥹", "😘", "✊🏼", "👊🏼", "🤛🏼", "👊🏻", "👊", "😉"]
        #expect(EmojiRecentList.deduplicated(stored) == ["🤣", "🪞", "👆🏼", "✊🏽", "🥹", "😘", "👊🏼", "🤛🏼", "😉"])
    }
}
