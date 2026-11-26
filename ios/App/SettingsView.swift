import MurmurDesign
import MurmurKit
import SwiftUI

/// The fourth tab. One card per thing the owner sets: how the keys type, how dictation hears
/// and cleans up, what the keyboard plays back, and how the app looks. Each card holds its own
/// way deeper (the model's page from Dictation), so nothing is set in two places.
struct SettingsView: View {
    @State private var settings = Settings.shared

    var body: some View {
        NavigationStack {
            PhonePage(title: "Settings") {
                Card(title: "Typing") {
                    ToggleRow(title: "Swipe typing", isOn: $settings.swipeTyping)
                    if settings.swipeTyping {
                        ChoiceRow(
                            title: "Swipe trail",
                            options: SwipeTrailChoice.allCases,
                            selection: $settings.swipeTrail,
                            name: \.displayName
                        )
                    }
                    ToggleRow(title: "Smart predictions", isOn: $settings.smartPredictions)
                    ToggleRow(title: "Auto-capitalisation", isOn: $settings.autoCapitalise)
                }
                // Turning it on is also how to try again after the model stopped the keyboard:
                // the keyboard never clears its own markers.
                .onChange(of: settings.smartPredictions) { _, isOn in
                    if isOn {
                        CrashMarker.typingModel.disarm()
                        CrashMarker.typingModelStrike.disarm()
                    }
                }

                Card(title: "Dictation") {
                    let unavailable = FoundationModelFormatter.unavailableReason
                    LinkRow(title: "Model", detail: settings.engine == .barkClean ? "Bark Clean" : "Apple") {
                        ModelView()
                    }
                    ToggleRow(
                        title: "Clean up what you say",
                        note: "Removes fillers and fixes punctuation.",
                        isOn: $settings.cleanupEnabled
                    )
                    ToggleRow(
                        title: "Apple Intelligence",
                        note: unavailable ?? "Rewrites the text with Apple's on-device model.",
                        isOn: Binding(
                            get: { settings.cleanupEngine == .appleIntelligence },
                            set: { settings.cleanupEngine = $0 ? .appleIntelligence : .rules }
                        ),
                        isDisabled: !settings.cleanupEnabled || unavailable != nil
                    )
                    ToggleRow(
                        title: "Keep microphone ready",
                        note: "On, the microphone opens when the keyboard appears so dictation starts at once, and closes 30 seconds after the last dictation. While music or other audio plays it waits for a press instead, so the music keeps playing. Off, it always waits for a press.",
                        isOn: $settings.alwaysOpenMic
                    )
                }

                Card(title: "Feedback") {
                    ToggleRow(title: "Sounds", isOn: $settings.soundEnabled)
                    ToggleRow(title: "Haptics", isOn: $settings.hapticsEnabled)
                }

                Card(title: "Appearance") {
                    ChoiceKeys(
                        options: AppearanceChoice.allCases,
                        selection: $settings.appearance,
                        title: \.displayName
                    )
                }

                Card {
                    LinkRow(title: "Training") { TrainingView() }
                    LinkRow(title: "Licences") { LicencesView() }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// A choice with a handful of options, as a titled row inside a card: the title in the rows'
/// own type, the chips under it.
private struct ChoiceRow<Option: Hashable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let name: (Option) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Text(title)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            ChoiceKeys(options: options, selection: $selection, title: name)
        }
    }
}

/// A row inside a card that pushes a page: the title, what is chosen there, and a chevron.
private struct LinkRow<Destination: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: DS.Space.base) {
                Text(title)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                Spacer()
                if let detail {
                    Text(detail)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: DS.Icon.small, weight: .semibold))
                    .foregroundStyle(DS.Color.inkTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
