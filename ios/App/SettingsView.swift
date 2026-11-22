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
