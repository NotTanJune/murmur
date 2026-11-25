import MurmurDesign
import MurmurKit
import SwiftUI

/// The fourth tab: cleanup, appearance, and the way into the model, training and licence pages.
struct SettingsView: View {
    @State private var settings = Settings.shared

    var body: some View {
        NavigationStack {
            PhonePage(title: "Settings") {
                let unavailable = FoundationModelFormatter.unavailableReason

                Card(title: "Cleanup") {
                    ToggleRow(
                        title: "Clean up what you say",
                        note: settings.cleanupEnabled
                            ? "Removes fillers and fixes spacing and punctuation before the text is typed."
                            : "Types the transcript as the engine heard it.",
                        isOn: $settings.cleanupEnabled
                    )
                    ToggleRow(
                        title: "Apple Intelligence",
                        note: unavailable ?? "Rewrites the text with Apple's on-device model. Off uses the basic rules.",
                        isOn: Binding(
                            get: { settings.cleanupEngine == .appleIntelligence },
                            set: { settings.cleanupEngine = $0 ? .appleIntelligence : .rules }
                        ),
                        isDisabled: !settings.cleanupEnabled || unavailable != nil
                    )
                }

                Card(title: "Microphone") {
                    ToggleRow(
                        title: "Keep microphone ready",
                        note: "Dictation starts the moment you press. The microphone stays ready for 30 seconds after each dictation, and iOS shows its microphone indicator for that time. The next press after that opens it again, a moment slower. Audio is kept in memory for a fraction of a second and only saved when you dictate. With Bluetooth headphones, iOS may switch them to their call microphone while it is open.",
                        isOn: $settings.alwaysOpenMic
                    )
                }

                Card {
                    ToggleRow(
                        title: "Sounds",
                        note: "A tone when dictation starts and when the text is typed.",
                        isOn: $settings.soundEnabled
                    )
                    ToggleRow(
                        title: "Haptics",
                        note: "A double tap when dictation starts, and a buzz then a double tap when the text is typed.",
                        isOn: $settings.hapticsEnabled
                    )
                    ToggleRow(title: "Swipe typing", isOn: $settings.swipeTyping)
                    ToggleRow(title: "Auto-capitalisation", isOn: $settings.autoCapitalise)
                    ToggleRow(title: "Smart predictions", isOn: $settings.smartPredictions)
                }
                // Turning it on is also how to try again after the model stopped the keyboard:
                // the keyboard never clears its own marker.
                .onChange(of: settings.smartPredictions) { _, isOn in
                    if isOn { CrashMarker.typingModel.disarm() }
                }

                if settings.swipeTyping {
                    Card(title: "Swipe trail") {
                        ChoiceKeys(
                            options: SwipeTrailChoice.allCases,
                            selection: $settings.swipeTrail,
                            title: \.displayName
                        )
                    }
                }

                Card(title: "Appearance") {
                    ChoiceKeys(
                        options: AppearanceChoice.allCases,
                        selection: $settings.appearance,
                        title: \.displayName
                    )
                }

                VStack(spacing: DS.Space.snug) {
                    SettingsLink(title: "Model", detail: settings.engine == .barkClean ? "Bark Clean" : "Apple") { ModelView() }
                    SettingsLink(title: "Training", detail: nil) { TrainingView() }
                    SettingsLink(title: "Licences", detail: nil) { LicencesView() }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// A card that pushes a page.
private struct SettingsLink<Destination: View>: View {
    let title: String
    let detail: String?
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
            .padding(DS.Space.roomy)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
