import AppKit
import MurmurKit

extension AppearanceChoice {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension SpeechEngineChoice {
    var streamingEngine: FluidStreamingEngine? {
        switch self {
        case .parakeetEOU: StreamingEngines.parakeetEOU
        case .nemotron: StreamingEngines.nemotron
        case .apple, .parakeet, .barkClean: nil
        }
    }
}

extension Settings {
    /// The push-to-talk key as the Mac's event code sees it. Persisted under the same
    /// `pushToTalkKey` defaults key and defaulting to Right ⌥, as before.
    var pushToTalkKey: PushToTalkKey {
        get { PushToTalkKey(rawValue: pushToTalkKeyRawValue) ?? .rightOption }
        set { pushToTalkKeyRawValue = newValue.rawValue }
    }

    /// Pushes `appearance` to the app. Called before the first window exists, so a launch
    /// in a forced appearance never flashes the other one, and again on every change.
    func applyAppearance() {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    /// Makes every later change to `appearance` update the app, and applies the current one.
    func bindAppearanceToApp() {
        onAppearanceChange = { [weak self] _ in self?.applyAppearance() }
        applyAppearance()
    }
}
