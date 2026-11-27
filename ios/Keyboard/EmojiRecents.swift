import Foundation
import MurmurKit

/// Emoji typed from the keyboard's picker, most recent first, one entry per emoji whatever its
/// skin tone (`EmojiRecentList`). Kept in the shared defaults (the App Group's on the phone) so
/// the list survives the keyboard process being recycled.
enum EmojiRecents {
    static let limit = 32
    private static let key = "emojiRecents"

    /// A list stored before tones were folded together reads with only its newest tone of each.
    static func load() -> [String] {
        EmojiRecentList.deduplicated(MurmurEnvironment.defaults.stringArray(forKey: key) ?? [])
    }

    static func record(_ emoji: String) {
        MurmurEnvironment.defaults.set(EmojiRecentList.recording(emoji, in: load(), limit: limit), forKey: key)
    }
}
