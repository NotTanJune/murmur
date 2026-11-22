import Foundation
import MurmurKit

/// Emoji typed from the keyboard's picker, most recent first. Kept in the shared defaults
/// (the App Group's on the phone) so the list survives the keyboard process being recycled.
enum EmojiRecents {
    static let limit = 32
    private static let key = "emojiRecents"

    static func load() -> [String] { MurmurEnvironment.defaults.stringArray(forKey: key) ?? [] }

    static func record(_ emoji: String) {
        var recents = load().filter { $0 != emoji }
        recents.insert(emoji, at: 0)
        MurmurEnvironment.defaults.set(Array(recents.prefix(limit)), forKey: key)
    }
}
