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
    /// What the keys did since the keyboard last appeared (the counters reset at each
    /// appearance), so a device run says whether typed letters are being lost and where:
    /// touch-downs, characters typed, touches iOS cancelled, lifts that hit no key and typed the
    /// touch's last key, the slowest `handle` (event in to effects applied) and the largest gap
    /// between a touch's timestamp and the keyboard handling it. Optional so a file written
    /// before these fields existed still decodes.
    var typingTouchDowns: Int?
    var typingTyped: Int?
    var typingCancelled: Int?
    var typingOffKey: Int?
    var typingSlowestHandleMs: Double?
    var typingMaxDeliveryMs: Double?
    /// The slowest autocorrect evaluation on the main actor; nil in files written before it existed.
    var typingSlowestAutocorrectMs: Double?
    /// The strip's language model in the keyboard process (`SmartPredictions.State`): `off`,
    /// `missing` (not in this build), `waiting` (not loaded yet), `loading`, `ready`, `failed`,
    /// `stoppedLastTime` or `lowMemory`. With it, this process's load in seconds, the last
    /// prediction's forward pass in milliseconds, and what the process's footprint gained from
    /// just before the load to just after the first prediction, in megabytes. Optional so a file
    /// written before these fields existed still decodes.
    var predictionState: String?
    var predictionLoadSeconds: Double?
    var predictionLastMs: Double?
    var predictionFootprintMB: Double?
    /// Temporary (2026-11-25): `TypingStats`' four prediction counters since the keyboard last
    /// appeared, to find where the model's answer is lost on the phone.
    var predictionAnswers: Int?
    var predictionStale: Int?
    var stripPasses: Int?
    var stripPassesWithPrediction: Int?
    var predictionFreeMB: Double?

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
    /// the model and disarmed after the model's first prediction. Still armed at the next launch,
    /// it means the keyboard died in between, and the keyboard leaves the model alone until the
    /// app's Smart predictions switch is turned on again, which clears it. Bark's own marker is
    /// a different file and is not touched.
    static var typingModel: CrashMarker {
        CrashMarker(directory: AppStorage.directory, name: "typing-lm-loading")
    }
}
