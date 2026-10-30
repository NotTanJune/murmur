import AppKit
import Foundation
import Observation

/// Which speech engine transcribes an utterance.
enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case apple
    case parakeet
    case barkClean
    case parakeetEOU
    case nemotron

    var displayName: String {
        switch self {
        case .apple: "Apple (streaming)"
        case .parakeet: "Parakeet (batch)"
        case .barkClean: "Bark 3.0 Clean (batch)"
        case .parakeetEOU: "Parakeet EOU (streaming)"
        case .nemotron: "Nemotron (streaming)"
        }
    }

    var detail: String {
        switch self {
        case .apple: "Apple's on-device transcriber. Streams while you speak; no separate download."
        case .parakeet: "Parakeet TDT on the Neural Engine. Resolves on release. Load the model before recording; the first load downloads ~470 MB."
        case .barkClean: "English Parakeet fine-tune that removes fillers, false starts and repeats itself. Neural Engine, resolves on release. Load the model before recording: ~450 MB download, then about a minute to compile once."
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

    /// Apple shows text while you talk; the batch engines only resolve on release.
    var showsLiveText: Bool { self != .parakeet && self != .barkClean }
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

    /// Run every engine on each recording and show them side by side, instead of
    /// transcribing with one. Nothing is typed into the focused app in this mode.
    var compareMode: Bool {
        didSet { defaults.set(compareMode, forKey: Keys.compareMode) }
    }

    /// Run the cleanup pass before injecting. Off = raw engine output.
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

    /// Release Bark and S1-mini after this long without a dictation.
    var idleUnload: IdleUnload {
        didSet { defaults.set(idleUnload.rawValue, forKey: Keys.idleUnload) }
    }

    /// Play a short tick when capture starts and stops.
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
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
        static let idleUnload = "idleUnload"
    }

    /// Internal rather than private so tests can migrate a throwaway defaults suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: Keys.pushToTalkKey) ?? PushToTalkKey.rightOption.rawValue
        pushToTalkKey = PushToTalkKey(rawValue: raw) ?? .rightOption
        // Apple by default: no download, no dependency, live text while speaking.
        engine = SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        let legacySmartCleanup = defaults.object(forKey: Keys.smartCleanup) as? Bool ?? false
        cleanupEngine = CleanupEngine(rawValue: defaults.string(forKey: Keys.cleanupEngine) ?? "")
            ?? (legacySmartCleanup ? .appleIntelligence : .rules)
        cleanupProfile = CleanupProfile(rawValue: defaults.string(forKey: Keys.cleanupProfile) ?? "") ?? .general
        compareMode = defaults.object(forKey: Keys.compareMode) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        appearance = AppearanceChoice(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        alwaysOpenMic = defaults.object(forKey: Keys.alwaysOpenMic) as? Bool ?? true
        idleUnload = IdleUnload(rawValue: defaults.string(forKey: Keys.idleUnload) ?? "") ?? .fiveMinutes
    }
}
