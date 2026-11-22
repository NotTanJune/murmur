import Foundation
import MurmurKit

/// What the keyboard last reported about itself, for the app's setup screen. The keyboard
/// writes it on each appearance and whenever Bark's state changes; the app only reads it.
struct KeyboardStatus: Codable, Equatable {
    /// `loading`, `ready`, `notDownloaded`, `stoppedLastTime` or `failed`, plus `off` while
    /// the setting names Apple's transcriber and the keyboard does not load Bark at all.
    var barkState: String
    var hasFullAccess: Bool
    var lastSeen: Date

    enum BarkState: String {
        case loading, ready, notDownloaded, stoppedLastTime, failed, off
    }

    static var url: URL { AppStorage.directory.appendingPathComponent("keyboard-status.json") }

    static func read() -> KeyboardStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(KeyboardStatus.self, from: data)
    }

    func write() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}
