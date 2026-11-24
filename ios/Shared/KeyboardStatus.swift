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
    /// Touch-down to the first audio the last hold received, in milliseconds; 0 when the
    /// pre-roll supplied it. Optional so a file written before this field existed still decodes.
    var lastStartLatencyMs: Int?
    /// This process's Bark load, in seconds. It is the model load as `ParakeetModels` does it,
    /// including its own one-second warm-up pass, and ends before `barkWarmupSeconds` begins.
    /// Optional, like every field below, so an older file still decodes.
    var barkLoadSeconds: Double?
    /// The throwaway decode through the hold's own engine that follows the load, in seconds.
    var barkWarmupSeconds: Double?
    /// The last delivered hold: release to the engine's final text, in milliseconds.
    var lastReleaseEngineMs: Int?
    /// The same hold: the engine's final text to the cleaned text (finisher and dictionary).
    var lastReleaseCleanupMs: Int?
    /// The engine that hold used, as the history names it.
    var lastReleaseEngine: String?
    /// How the keyboard's page captures audio, as it last delivered audio: `recordOnly` (nothing
    /// connected to the audio output) or `playAndRecord` (the fallback, with the output
    /// connected). Optional so a file written before this field existed still decodes.
    var captureMode: String?
    /// The keyboard's requested height (the key page's, which the emoji and history panels
    /// share) and the height its view actually got at the last layout, in points. Equal means
    /// the system honoured the height constraint. The names date from when the emoji panel was
    /// taller. Optional so a file written before these fields existed still decodes.
    var emojiPanelRequestedHeight: Int?
    var emojiPanelShownHeight: Int?
    /// The keyboard process's physical footprint when last sampled, and the largest sample this
    /// process has seen, in megabytes. The Setup tab shows them so the memory ceiling can be
    /// read off a device. Optional so a file written before these fields existed still decodes.
    var footprintMB: Double?
    var peakFootprintMB: Double?

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
