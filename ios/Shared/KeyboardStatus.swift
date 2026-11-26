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
    /// The strip's language model in the keyboard process (`SmartPredictions.State`): `off`,
    /// `missing` (not in this build), `waiting` (not loaded yet), `loading`, `ready`, `failed`,
    /// `stoppedLastTime` or `lowMemory`. Optional so a file written before this field existed
    /// still decodes.
    var predictionState: String?

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

extension CrashMarker {
    /// The language model's marker (`typing-lm-loading`), armed by the keyboard before it loads
    /// the model and disarmed when the load's first prediction has answered. Still armed at the
    /// next launch, it means the keyboard ended in between (`SmartPredictions` says what
    /// follows). Bark's own marker is a different file and is not touched.
    static var typingModel: CrashMarker {
        CrashMarker(directory: AppStorage.directory, name: "typing-lm-loading")
    }

    /// Armed when a keyboard finds `typingModel` left armed by the process before it, and tries
    /// the load once more. Both armed means two processes in a row ended while loading the
    /// model: the keyboard stops trying for `SmartPredictions.lockSeconds`, measured from this
    /// marker's date. A load that answers disarms it; so do Setup's "Try again" and the Smart
    /// predictions switch.
    static var typingModelStrike: CrashMarker {
        CrashMarker(directory: AppStorage.directory, name: "typing-lm-strike")
    }
}
