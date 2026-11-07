import AppKit
import Foundation
import Observation

/// Names which speech engine transcribes an utterance. Raw values are persisted.
enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case apple
    case parakeet
    case barkClean
    case parakeetEOU
    case nemotron

    /// Parakeet and Bark stream or run as one batch depending on `Settings.transcribeTiming`,
    /// so their names follow it.
    @MainActor
    var displayName: String {
        displayName(timing: Settings.shared.transcribeTiming)
    }

    func displayName(timing: TranscribeTiming) -> String {
        let mode = timing == .whileSpeaking ? "streaming" : "batch"
        return switch self {
        case .apple: "Apple (streaming)"
        case .parakeet: "Parakeet (\(mode))"
        case .barkClean: "Bark 3.0 Clean (\(mode))"
        case .parakeetEOU: "Parakeet EOU (streaming)"
        case .nemotron: "Nemotron (streaming)"
        }
    }

    var detail: String {
        switch self {
        case .apple: "Apple's on-device transcriber. Streams while you speak; no separate download."
        case .parakeet: "Parakeet TDT on the Neural Engine. Load the model before recording; the first load downloads ~470 MB."
        case .barkClean: "English Parakeet fine-tune that removes fillers, false starts and repeats itself. Neural Engine. Load the model before recording: ~450 MB download, then about a minute to compile once."
        case .parakeetEOU: "English, on-device. 160 ms chunks with live text. Load the model before recording; the first load downloads it."
        case .nemotron: "English, on-device. 560 ms chunks with live text. Load the model before recording; the first load downloads it."
        }
    }

    var streamingEngine: FluidStreamingEngine? {
        switch self {
        case .parakeetEOU: StreamingEngines.parakeetEOU
        case .nemotron: StreamingEngines.nemotron
        case .apple, .parakeet, .barkClean: nil
        }
    }

    /// Engines whose model must be loaded explicitly before a hold can record. Loading
    /// on the first press would leave the user holding a key through a download or a
    /// minute-long Neural Engine compile.
    var requiresPreparedModel: Bool {
        streamingEngine != nil || self == .parakeet || self == .barkClean
    }

    /// Whether the model's files are already on disk, so loading needs no network and can
    /// start without asking. Unknown for the streaming models, which report `false`.
    var isInstalledLocally: Bool {
        switch self {
        case .parakeet: ParakeetModels.isDownloaded
        case .barkClean: BarkModelStore.isDownloaded
        case .apple, .parakeetEOU, .nemotron: false
        }
    }

    /// Every engine shows text while you talk: the Parakeet engines decode windows as the
    /// hold goes on (or, with `TranscribeTiming.onRelease`, simply resolve on release).
    var showsLiveText: Bool { true }
}

/// When the Parakeet-based engines transcribe.
enum TranscribeTiming: String, CaseIterable, Sendable {
    case whileSpeaking
    case onRelease

    var displayName: String {
        switch self {
        case .whileSpeaking: "While speaking"
        case .onRelease: "On release"
        }
    }

    var detail: String {
        switch self {
        case .whileSpeaking: "Decodes 11-second windows while you talk, so release only finishes the last few seconds. Live text appears as each window lands."
        case .onRelease: "Transcribes the whole recording after release. Slightly more context per pass; the wait grows with the length of the dictation."
        }
    }
}

/// Light, dark, or whatever macOS is set to. Applied app-wide through `NSApp.appearance`,
/// so every window, the HUD and the design tokens' adaptive colors follow it together.
enum AppearanceChoice: String, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// How long the models stay in memory after the last dictation.
enum IdleUnload: String, CaseIterable {
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case never

    var displayName: String {
        switch self {
        case .oneMinute: "1 min"
        case .fiveMinutes: "5 min"
        case .fifteenMinutes: "15 min"
        case .never: "Never"
        }
    }

    var delay: Duration? {
        switch self {
        case .oneMinute: .seconds(60)
        case .fiveMinutes: .seconds(5 * 60)
        case .fifteenMinutes: .seconds(15 * 60)
        case .never: nil
        }
    }
}

/// Which decoder and joint Bark Clean runs with: the pinned stock pair, or a fine-tuned pair
/// installed from a training export, named by its folder.
enum BarkDecoderChoice: Hashable, Sendable {
    case stock
    case custom(String)

    var rawValue: String {
        switch self {
        case .stock: "stock"
        case .custom(let name): "custom:\(name)"
        }
    }

    init?(rawValue: String) {
        if rawValue == "stock" { self = .stock; return }
        guard rawValue.hasPrefix("custom:"), rawValue.count > 7 else { return nil }
        self = .custom(String(rawValue.dropFirst(7)))
    }

    var displayName: String {
        switch self {
        case .stock: "Stock"
        case .custom(let name): "Fine-tuned \(name)"
        }
    }
}

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var pushToTalkKey: PushToTalkKey {
        didSet { defaults.set(pushToTalkKey.rawValue, forKey: Keys.pushToTalkKey) }
    }

    var engine: SpeechEngineChoice {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }

    /// Runs every engine on each recording and shows them side by side instead of
    /// transcribing with one. This mode never types into the focused app.
    var compareMode: Bool {
        didSet { defaults.set(compareMode, forKey: Keys.compareMode) }
    }

    /// Runs the cleanup pass before injecting; off means raw engine output.
    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled) }
    }

    /// Which pass cleans the transcript when `cleanupEnabled` is on.
    var cleanupEngine: CleanupEngine {
        didSet { defaults.set(cleanupEngine.rawValue, forKey: Keys.cleanupEngine) }
    }

    /// Where the text is going. Read when a hold starts, so it applies to the next one.
    var cleanupProfile: CleanupProfile {
        didSet { defaults.set(cleanupProfile.rawValue, forKey: Keys.cleanupProfile) }
    }

    /// Keep the microphone open between holds, so a press starts instantly and includes the
    /// moment just before it. macOS shows its microphone indicator the whole time.
    var alwaysOpenMic: Bool {
        didSet { defaults.set(alwaysOpenMic, forKey: Keys.alwaysOpenMic) }
    }

    /// Keep the Mac's default input on the allowed microphone for every app, moving it back
    /// whenever macOS switches it (a Bluetooth headset connecting). See `SystemInputGuard`.
    var keepSystemInput: Bool {
        didSet { defaults.set(keepSystemInput, forKey: Keys.keepSystemInput) }
    }

    /// Keep each dictation's audio on disk for training exports.
    var keepRecordings: Bool {
        didSet { defaults.set(keepRecordings, forKey: Keys.keepRecordings) }
    }

    var barkDecoder: BarkDecoderChoice {
        didSet { defaults.set(barkDecoder.rawValue, forKey: Keys.barkDecoder) }
    }

    /// Release Bark and S1-mini after this long without a dictation.
    var idleUnload: IdleUnload {
        didSet { defaults.set(idleUnload.rawValue, forKey: Keys.idleUnload) }
    }

    /// Plays a short tick when capture starts and stops; also gates the compare-mode
    /// completion sound.
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    /// When Parakeet and Bark transcribe: as windows fill during the hold, or on release.
    var transcribeTiming: TranscribeTiming {
        didSet { defaults.set(transcribeTiming.rawValue, forKey: Keys.transcribeTiming) }
    }

    var appearance: AppearanceChoice {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            applyAppearance()
        }
    }

    /// Pushes `appearance` to the app. Called before the first window exists, so a launch
    /// in a forced appearance never flashes the other one, and again on every change.
    func applyAppearance() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let pushToTalkKey = "pushToTalkKey"
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let engine = "engine"
        /// Legacy: the old on/off for Apple Intelligence cleanup. Read once to migrate.
        static let smartCleanup = "smartCleanup"
        static let cleanupEngine = "cleanupEngine"
        static let cleanupProfile = "cleanupProfile"
        static let compareMode = "compareMode"
        static let appearance = "appearance"
        static let alwaysOpenMic = "alwaysOpenMic"
        static let keepSystemInput = "keepSystemInput"
        static let idleUnload = "idleUnload"
        static let transcribeTiming = "transcribeTiming"
        static let keepRecordings = "keepRecordings"
        static let barkDecoder = "barkDecoder"
    }

    /// Internal rather than private so tests can migrate a throwaway defaults suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pushToTalkKey = PushToTalkKey(
            rawValue: defaults.string(forKey: Keys.pushToTalkKey) ?? PushToTalkKey.rightOption.rawValue
        ) ?? .rightOption
        // Apple needs no download or extra dependency and shows live text while you speak.
        engine = SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
        // `object(forKey:)`, because `bool(forKey:)` cannot tell a stored false from no value.
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        let legacySmartCleanup = defaults.object(forKey: Keys.smartCleanup) as? Bool ?? false
        cleanupEngine = CleanupEngine(rawValue: defaults.string(forKey: Keys.cleanupEngine) ?? "")
            ?? (legacySmartCleanup ? .appleIntelligence : .rules)
        cleanupProfile = CleanupProfile(rawValue: defaults.string(forKey: Keys.cleanupProfile) ?? "") ?? .general
        compareMode = defaults.object(forKey: Keys.compareMode) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        appearance = AppearanceChoice(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        alwaysOpenMic = defaults.object(forKey: Keys.alwaysOpenMic) as? Bool ?? true
        keepSystemInput = defaults.object(forKey: Keys.keepSystemInput) as? Bool ?? true
        idleUnload = IdleUnload(rawValue: defaults.string(forKey: Keys.idleUnload) ?? "") ?? .fiveMinutes
        transcribeTiming = TranscribeTiming(rawValue: defaults.string(forKey: Keys.transcribeTiming) ?? "") ?? .whileSpeaking
        keepRecordings = defaults.object(forKey: Keys.keepRecordings) as? Bool ?? true
        barkDecoder = BarkDecoderChoice(rawValue: defaults.string(forKey: Keys.barkDecoder) ?? "") ?? .stock
    }
}
