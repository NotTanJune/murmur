import Foundation

/// What the keyboard's emoji picker lists, and which of it takes a skin tone. The data is
/// generated (`Tools/gen_emoji.py`); this is the pure logic over it, so it runs in tests.
public enum EmojiCatalog {
    public struct Category: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        /// An SF Symbol for the category bar.
        public let symbol: String
        public let emoji: [String]

        public init(id: String, title: String, symbol: String, emoji: [String]) {
            self.id = id
            self.title = title
            self.symbol = symbol
            self.emoji = emoji
        }
    }

    /// Apple's eight sections, in Apple's order.
    public static let categories: [Category] = EmojiData.categories

    /// The five toned forms of `base`, light to dark; empty when it takes no tone.
    public static func tones(for base: String) -> [String] { toneTable[base] ?? [] }

    /// The base of a toned form, or nil when `emoji` is not one.
    public static func base(ofToned emoji: String) -> String? { baseTable[emoji] }

    private static let baseTable: [String: String] = {
        var table: [String: String] = [:]
        for (base, toned) in toneTable { for form in toned { table[form] = base } }
        return table
    }()

    private static let toneTable: [String: [String]] = {
        var table: [String: [String]] = [:]
        for line in EmojiData.toneTable.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            table[String(parts[0])] = parts[1].split(separator: " ").map(String.init)
        }
        return table
    }()
}

/// The tone a person last picked for each emoji. A value over an injected `UserDefaults`, so a
/// test uses a scratch domain and the keyboard uses the App Group's.
public struct EmojiTonePreference {
    private let defaults: UserDefaults
    private static let key = "emojiTonePreferences"

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// The remembered form of `base`, or `base` itself when none is set or the stored form is
    /// no longer one of its tones.
    public func preferred(for base: String) -> String {
        guard let toned = stored[base], EmojiCatalog.tones(for: base).contains(toned) else { return base }
        return toned
    }

    /// Remembers `toned` as the form to type for `base`. Choosing the base itself clears it.
    public mutating func set(_ toned: String, for base: String) {
        var table = stored
        if toned == base {
            table[base] = nil
        } else {
            table[base] = toned
        }
        defaults.set(table, forKey: Self.key)
    }

    private var stored: [String: String] { defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:] }
}
