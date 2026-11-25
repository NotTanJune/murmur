import MurmurDesign
import MurmurKit
import SwiftUI

/// The app's entry point and its four tabs. The app is the keyboard's home: it asks for the
/// permissions, downloads Bark, and keeps the history, dictionary and settings the keyboard uses.
@main
struct MurmurPhoneApp: App {
    @State private var settings: Settings

    init() {
        PhoneEnvironment.configure()
        RunLog.prepare()
        PredictionSelfTest.runIfAsked()
        _settings = State(initialValue: Settings.shared)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(colorScheme)
        }
    }

    /// Nil follows the system, so the toggle never fights the system setting.
    private var colorScheme: ColorScheme? {
        switch settings.appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private enum AppTab: Hashable {
    case setup, history, dictionary, settings
}

private struct RootView: View {
    @State private var selection = AppTab.setup

    var body: some View {
        TabView(selection: $selection) {
            Tab("Setup", systemImage: "checklist", value: AppTab.setup) {
                SetupView()
            }
            Tab("History", systemImage: "text.bubble", value: AppTab.history) {
                HistoryView()
            }
            Tab("Dictionary", systemImage: "character.book.closed", value: AppTab.dictionary) {
                DictionaryView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tint(DS.Color.ink)
        // The keyboard's "Open Murmur" button lands here: murmur://setup.
        .onOpenURL { url in
            guard url.scheme == "murmur", url.host() == "setup" else { return }
            selection = .setup
        }
    }
}
