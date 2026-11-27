import Foundation

/// The keyboard's Frequently Used list, newest first, with one entry per emoji whatever its skin
/// tone: typing ✊🏼 after ✊🏽 leaves only ✊🏼, at the front, as Apple's picker does. Pure, so it
/// runs in tests; the keyboard stores the result (`EmojiRecents`).
public enum EmojiRecentList {
    /// What two forms share when they are one emoji in different tones: the untoned base.
    public static func family(of emoji: String) -> String { EmojiCatalog.base(ofToned: emoji) ?? emoji }

    /// `list` with `emoji` at the front, every other tone of it removed, cut to `limit`.
    public static func recording(_ emoji: String, in list: [String], limit: Int) -> [String] {
        let family = family(of: emoji)
        let rest = list.filter { self.family(of: $0) != family }
        return Array(deduplicated([emoji] + rest).prefix(limit))
    }

    /// `list` with only the first (newest) form of each emoji. A list stored before tones were
    /// folded together can hold several.
    public static func deduplicated(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert(family(of: $0)).inserted }
    }
}
