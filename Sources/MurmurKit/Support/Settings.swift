import Foundation
import Observation

/// Names which speech engine transcribes an utterance. Raw values are persisted.
public enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case apple
    case parakeet
    case barkClean
    case parakeetEOU
    case nemotron

    /// Parakeet and Bark stream or run as one batch depending on `Settings.transcribeTiming`,
    /// so their names follow it.
    @MainActor
    public var displayName: String {
        displayName(timing: Settings.shared.transcribeTiming)
    }

    public func displayName(timing: TranscribeTiming) -> String {
        let mode = timing == .whileSpeaking ? "streaming" : "batch"
        return switch self {
        case .apple: "Apple (streaming)"
        case .parakeet: "Parakeet (\(mode))"
        case .barkClean: "Bark 3.0 Clean (\(mode))"
        case .parakeetEOU: "Parakeet EOU (streaming)"
        case .nemotron: "Nemotron (streaming)"
        }
    }

    public var detail: String {
        switch self {
        case .apple: "Apple's on-device transcriber. Streams while you speak; no separate download."
        case .parakeet: "Parakeet TDT on the Neural Engine. Load the model before recording; the first load downloads ~470 MB."
        case .barkClean: "English Parakeet fine-tune that removes fillers, false starts and repeats itself. Neural Engine. Load the model before recording: ~450 MB download, then about a minute to compile once."
        case .parakeetEOU: "English, on-device. 160 ms chunks with live text. Load the model before recording; the first load downloads it."
        case .nemotron: "English, on-device. 560 ms chunks with live text. Load the model before recording; the first load downloads it."
        }
    }

    /// Engines whose model must be loaded explicitly before a hold can record. Loading
    /// on the first press would leave the user holding a key through a download or a
    /// minute-long Neural Engine compile.
    public var requiresPreparedModel: Bool {
        switch self {
        case .parakeetEOU, .nemotron, .parakeet, .barkClean: true
        case .apple: false
        }
    }

    /// Whether the model's files are already on disk, so loading needs no network and can
    /// start without asking. Unknown for the streaming models, which report `false`.
    public var isInstalledLocally: Bool {
        switch self {
        case .parakeet: ParakeetModels.isDownloaded
        case .barkClean: BarkModelStore.isDownloaded
        case .apple, .parakeetEOU, .nemotron: false
        }
    }

    /// Every engine shows text while you talk: the Parakeet engines decode windows as the
    /// hold goes on (or, with `TranscribeTiming.onRelease`, simply resolve on release).
    public var showsLiveText: Bool { true }
}

/// When the Parakeet-based engines transcribe.
public enum TranscribeTiming: String, CaseIterable, Sendable {
    case whileSpeaking
    case onRelease

    public var displayName: String {
        switch self {
        case .whileSpeaking: "While speaking"
        case .onRelease: "On release"
        }
    }

    public var detail: String {
        switch self {
        case .whileSpeaking: "Decodes 11-second windows while you talk, so release only finishes the last few seconds. Live text appears as each window lands."
        case .onRelease: "Transcribes the whole recording after release. Slightly more context per pass; the wait grows with the length of the dictation."
        }
    }
}

/// Light, dark, or whatever macOS is set to. The Mac applies it app-wide through
/// `NSApp.appearance` (see `Settings+Mac.swift`), so every window, the HUD and the design
/// tokens' adaptive colors follow it together.
public enum AppearanceChoice: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// How thick the line is that follows a finger swiping across the iPhone keyboard.
public enum SwipeTrailChoice: String, CaseIterable, Sendable {
    case thin
    case regular
    case thick
    case bold

    public var displayName: String {
        switch self {
        case .thin: "Thin"
        case .regular: "Regular"
        case .thick: "Thick"
        case .bold: "Bold"
        }
    }
}

/// How long the models stay in memory after the last dictation.
public enum IdleUnload: String, CaseIterable, Sendable {
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case never

    public var displayName: String {
        switch self {
        case .oneMinute: "1 min"
        case .fiveMinutes: "5 min"
        case .fifteenMinutes: "15 min"
        case .never: "Never"
        }
    }

    public var delay: Duration? {
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
public enum BarkDecoderChoice: Hashable, Sendable {
    case stock
    case custom(String)

    public var rawValue: String {
        switch self {
        case .stock: "stock"
        case .custom(let name): "custom:\(name)"
        }
    }

    public init?(rawValue: String) {
        if rawValue == "stock" { self = .stock; return }
        guard rawValue.hasPrefix("custom:"), rawValue.count > 7 else { return nil }
        self = .custom(String(rawValue.dropFirst(7)))
    }

    public var displayName: String {
        switch self {
        case .stock: "Stock"
        case .custom(let name): "Fine-tuned \(name)"
        }
    }
}

@MainActor
@Observable
public final class Settings {
    /// The app's own settings, read from `MurmurEnvironment.defaults` the first time they are
    /// used, so a host calls `MurmurEnvironment.configure` before touching this. Unconfigured,
    /// that is the standard defaults, or the `MURMUR_SETTINGS_DOMAIN` suite the `bench/` runner
    /// names because its `swift test` process domain holds whatever earlier tests wrote.
    public static let shared = Settings(defaults: MurmurEnvironment.defaults)

    /// The persisted name of the push-to-talk key. The Mac reads it as a `PushToTalkKey`
    /// through `Settings.pushToTalkKey` (`Settings+Mac.swift`); that type needs AppKit, so it
    /// stays out of this library. The key name and default are unchanged.
    public var pushToTalkKeyRawValue: String {
        didSet { persist(pushToTalkKeyRawValue, Keys.pushToTalkKey) }
    }

    public var engine: SpeechEngineChoice {
        didSet { persist(engine.rawValue, Keys.engine) }
    }

    /// Runs every engine on each recording and shows them side by side instead of
    /// transcribing with one. This mode never types into the focused app.
    public var compareMode: Bool {
        didSet { persist(compareMode, Keys.compareMode) }
    }

    /// Runs the cleanup pass before injecting; off means raw engine output.
    public var cleanupEnabled: Bool {
        didSet { persist(cleanupEnabled, Keys.cleanupEnabled) }
    }

    /// Which pass cleans the transcript when `cleanupEnabled` is on.
    public var cleanupEngine: CleanupEngine {
        didSet { persist(cleanupEngine.rawValue, Keys.cleanupEngine) }
    }

    /// Where the text is going. Read when a hold starts, so it applies to the next one.
    public var cleanupProfile: CleanupProfile {
        didSet { persist(cleanupProfile.rawValue, Keys.cleanupProfile) }
    }

    /// Keep the microphone open between holds, so a press starts instantly and includes the
    /// moment just before it. macOS shows its microphone indicator the whole time.
    public var alwaysOpenMic: Bool {
        didSet { persist(alwaysOpenMic, Keys.alwaysOpenMic) }
    }

    /// Keep the Mac's default input on the allowed microphone for every app, moving it back
    /// whenever macOS switches it (a Bluetooth headset connecting). See `SystemInputGuard`.
    public var keepSystemInput: Bool {
        didSet { persist(keepSystemInput, Keys.keepSystemInput) }
    }

    /// Keep each dictation's audio on disk for training exports.
    public var keepRecordings: Bool {
        didSet { persist(keepRecordings, Keys.keepRecordings) }
    }

    public var barkDecoder: BarkDecoderChoice {
        didSet { persist(barkDecoder.rawValue, Keys.barkDecoder) }
    }

    /// Release Bark and S1-mini after this long without a dictation.
    public var idleUnload: IdleUnload {
        didSet { persist(idleUnload.rawValue, Keys.idleUnload) }
    }

    /// Plays a short tick when capture starts and stops; also gates the compare-mode
    /// completion sound.
    public var soundEnabled: Bool {
        didSet { persist(soundEnabled, Keys.soundEnabled) }
    }

    /// The iPhone keyboard's haptics: a tap when dictation starts, a double tap when the text is
    /// typed, an error pattern when a hold fails. The Mac ignores it.
    public var hapticsEnabled: Bool {
        didSet { persist(hapticsEnabled, Keys.hapticsEnabled) }
    }

    /// The iPhone keyboard's swipe typing: a finger dragged across the letters types a word.
    /// Off, or with VoiceOver on, the keys only tap. The Mac ignores it.
    public var swipeTyping: Bool {
        didSet { persist(swipeTyping, Keys.swipeTyping) }
    }

    /// The thickness of the swipe trail on the iPhone keyboard. The Mac ignores it.
    public var swipeTrail: SwipeTrailChoice {
        didSet { persist(swipeTrail.rawValue, Keys.swipeTrail) }
    }

    /// When Parakeet and Bark transcribe: as windows fill during the hold, or on release.
    public var transcribeTiming: TranscribeTiming {
        didSet { persist(transcribeTiming.rawValue, Keys.transcribeTiming) }
    }

    public var appearance: AppearanceChoice {
        didSet {
            guard !isReloading else { return }
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            onAppearanceChange?(appearance)
        }
    }

    /// Called after every change to `appearance`. The Mac installs its `NSApp.appearance`
    /// update here (`Settings.bindAppearanceToApp()`); nothing else needs to react.
    @ObservationIgnored public var onAppearanceChange: (@MainActor (AppearanceChoice) -> Void)?

    private let defaults: UserDefaults

    private enum Keys {
        static let pushToTalkKey = "pushToTalkKey"
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let hapticsEnabled = "hapticsEnabled"
        static let swipeTyping = "swipeTyping"
        static let swipeTrail = "swipeTrail"
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

    /// Every value, read from a defaults suite. One reader for `init` and `reloadFromDefaults()`,
    /// so the defaults, the fallbacks and the legacy migration cannot drift apart.
    private struct Snapshot {
        let pushToTalkKeyRawValue: String
        let engine: SpeechEngineChoice
        let cleanupEnabled: Bool
        let cleanupEngine: CleanupEngine
        let cleanupProfile: CleanupProfile
        let compareMode: Bool
        let soundEnabled: Bool
        let hapticsEnabled: Bool
        let swipeTyping: Bool
        let swipeTrail: SwipeTrailChoice
        let appearance: AppearanceChoice
        let alwaysOpenMic: Bool
        let keepSystemInput: Bool
        let idleUnload: IdleUnload
        let transcribeTiming: TranscribeTiming
        let keepRecordings: Bool
        let barkDecoder: BarkDecoderChoice

        init(_ defaults: UserDefaults) {
            pushToTalkKeyRawValue = defaults.string(forKey: Keys.pushToTalkKey) ?? "rightOption"
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
            hapticsEnabled = defaults.object(forKey: Keys.hapticsEnabled) as? Bool ?? true
            swipeTyping = defaults.object(forKey: Keys.swipeTyping) as? Bool ?? true
            swipeTrail = SwipeTrailChoice(rawValue: defaults.string(forKey: Keys.swipeTrail) ?? "") ?? .regular
            appearance = AppearanceChoice(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
            alwaysOpenMic = defaults.object(forKey: Keys.alwaysOpenMic) as? Bool ?? true
            keepSystemInput = defaults.object(forKey: Keys.keepSystemInput) as? Bool ?? true
            idleUnload = IdleUnload(rawValue: defaults.string(forKey: Keys.idleUnload) ?? "") ?? .fiveMinutes
            transcribeTiming = TranscribeTiming(rawValue: defaults.string(forKey: Keys.transcribeTiming) ?? "") ?? .whileSpeaking
            keepRecordings = defaults.object(forKey: Keys.keepRecordings) as? Bool ?? true
            barkDecoder = BarkDecoderChoice(rawValue: defaults.string(forKey: Keys.barkDecoder) ?? "") ?? .stock
        }
    }

    /// True while `reloadFromDefaults()` assigns, so the property observers do not write the
    /// values just read back to the suite.
    @ObservationIgnored private var isReloading = false

    private func persist(_ value: Any, _ key: String) {
        guard !isReloading else { return }
        defaults.set(value, forKey: key)
    }

    /// Public so tests and hosts can migrate a throwaway defaults suite.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let values = Snapshot(defaults)
        pushToTalkKeyRawValue = values.pushToTalkKeyRawValue
        engine = values.engine
        cleanupEnabled = values.cleanupEnabled
        cleanupEngine = values.cleanupEngine
        cleanupProfile = values.cleanupProfile
        compareMode = values.compareMode
        soundEnabled = values.soundEnabled
        hapticsEnabled = values.hapticsEnabled
        swipeTyping = values.swipeTyping
        swipeTrail = values.swipeTrail
        appearance = values.appearance
        alwaysOpenMic = values.alwaysOpenMic
        keepSystemInput = values.keepSystemInput
        idleUnload = values.idleUnload
        transcribeTiming = values.transcribeTiming
        keepRecordings = values.keepRecordings
        barkDecoder = values.barkDecoder
    }

    /// Re-reads every value from the defaults suite, for a process that outlives a change made
    /// by another one. The keyboard extension and the app share a suite but not memory: without
    /// this a keyboard that stays alive keeps the values it read at launch, such as
    /// `keepRecordings` after the app turned it off. Assigns without writing back, and does not
    /// call `onAppearanceChange`. The suite is read fresh each time, so no `synchronize()`.
    public func reloadFromDefaults() {
        let values = Snapshot(defaults)
        isReloading = true
        defer { isReloading = false }
        pushToTalkKeyRawValue = values.pushToTalkKeyRawValue
        engine = values.engine
        cleanupEnabled = values.cleanupEnabled
        cleanupEngine = values.cleanupEngine
        cleanupProfile = values.cleanupProfile
        compareMode = values.compareMode
        soundEnabled = values.soundEnabled
        hapticsEnabled = values.hapticsEnabled
        swipeTyping = values.swipeTyping
        swipeTrail = values.swipeTrail
        appearance = values.appearance
        alwaysOpenMic = values.alwaysOpenMic
        keepSystemInput = values.keepSystemInput
        idleUnload = values.idleUnload
        transcribeTiming = values.transcribeTiming
        keepRecordings = values.keepRecordings
        barkDecoder = values.barkDecoder
    }
}
