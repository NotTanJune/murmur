import SwiftUI

/// Settings — appearance, hotkey, model and cleanup. A tab of the main window rather than a
/// separate window: ⌘, and the dock's gear both switch to it (`MainNavigation`).
///
/// Every choice with a handful of options is a row of keys rather than a menu, so the
/// active one is visible without opening anything: sunk, yellow and checked.
struct SettingsPanel: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @State private var models = StreamingModelPreparation.shared
    @State private var s1Mini = S1MiniPreparation.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.roomy + DS.Brutal.lift) {
                BrutalCard(title: "Push to talk") {
                    ChoiceKeys(
                        options: PushToTalkKey.allCases,
                        selection: Binding(
                            get: { settings.pushToTalkKey },
                            set: { key in
                                settings.pushToTalkKey = key
                                controller.reloadHotkey()
                            }
                        ),
                        title: \.displayName
                    )
                    Note(text: "Hold this key anywhere to dictate. The window's Record button works "
                        + "regardless of what's focused.")
                }

                BrutalCard(title: "Microphone") {
                    Text(controller.microphoneName ?? "None available")
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                    Note(text: "Always the HyperX SoloCast when it's connected, otherwise the MacBook's "
                        + "built-in mic. Never a Bluetooth headset or the system default.")
                    Toggle(isOn: $settings.alwaysOpenMic) {
                        Text("Keep microphone open")
                            .font(DS.Font.bodyEmphasis)
                            .foregroundStyle(DS.Color.ink)
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Color.accent)
                    Note(text: settings.alwaysOpenMic
                        ? "Recording starts the instant you press, including the moment just before it. "
                            + "Only the last 0.3 s is held, in memory. macOS shows its mic indicator the whole time; "
                            + "measured cost about 3% of one CPU core."
                        : "The mic opens when you press, which takes about 0.1 s (longer on the first press), "
                            + "so a word spoken right at the press can be clipped.")
                }

                BrutalCard(title: "Appearance") {
                    ChoiceKeys(
                        options: AppearanceChoice.allCases,
                        selection: $settings.appearance,
                        title: \.displayName
                    )
                }

                BrutalCard(title: "Memory") {
                    Eyebrow(text: "Free models after")
                    ChoiceKeys(
                        options: IdleUnload.allCases,
                        selection: Binding(
                            get: { settings.idleUnload },
                            set: { choice in
                                settings.idleUnload = choice
                                ModelResidency.shared.scheduleRelease()
                            }
                        ),
                        title: \.displayName
                    )
                    Note(text: settings.idleUnload == .never
                        ? "Bark and S1-mini stay in memory (about 600 MB) for instant cleanup every time."
                        : "Bark and S1-mini leave memory after this long without dictating and reload at "
                            + "your next press, while you speak. Idle, Murmur holds well under 100 MB.")
                }

                BrutalCard(title: "Model") {
                    Picker("Transcription engine", selection: $settings.engine) {
                        ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(controller.state.isActive)
                    .onChange(of: settings.engine) { _, choice in
                        models.loadIfInstalled(choice)
                    }
                    Note(text: settings.engine.detail)
                    if settings.engine.requiresPreparedModel {
                        let status = models.state(for: settings.engine)
                        HStack(spacing: DS.Space.base) {
                            if status != .ready {
                                Button(status == .loading ? "Loading model…" : "Load model") {
                                    models.load(settings.engine)
                                }
                                .buttonStyle(BrutalButtonStyle())
                                .disabled(controller.state.isActive || status == .loading)
                            }
                            Note(text: status.message)
                        }
                    }
                    if settings.compareMode {
                        Note(text: "Compare mode bypasses this choice and runs Apple vs Parakeet batch. "
                            + "Turn it off in the menu bar to dictate with the selected engine.")
                    }
                }

                BrutalCard(title: "Cleanup") {
                    Toggle(isOn: $settings.cleanupEnabled) {
                        Text("Clean up transcripts")
                            .font(DS.Font.bodyEmphasis)
                            .foregroundStyle(DS.Color.ink)
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Color.accent)

                    if settings.cleanupEnabled {
                        Eyebrow(text: "Engine")
                        ChoiceKeys(
                            options: CleanupEngine.allCases,
                            selection: Binding(
                                get: { settings.cleanupEngine },
                                set: { choice in
                                    settings.cleanupEngine = choice
                                    if choice == .s1Mini { s1Mini.loadIfInstalled() }
                                }
                            ),
                            title: \.displayName,
                            help: \.detail
                        )
                        Note(text: settings.cleanupEngine.detail)

                        switch settings.cleanupEngine {
                        case .s1Mini:
                            HStack(spacing: DS.Space.base) {
                                if s1Mini.state != .ready {
                                    Button(s1Mini.state.isBusy ? "Loading S1-mini…" : "Load S1-mini") {
                                        s1Mini.start()
                                    }
                                    .buttonStyle(BrutalButtonStyle())
                                    .disabled(s1Mini.state.isBusy)
                                }
                                Note(text: s1Mini.state.message)
                            }
                            Eyebrow(text: "Profile")
                            ProfileKeys()
                            Note(text: settings.cleanupProfile.detail)
                        case .appleIntelligence:
                            if let reason = FoundationModelFormatter.unavailableReason { Note(text: reason) }
                        case .rules:
                            EmptyView()
                        }
                    }
                    Note(text: "The dictionary's corrections run either way.")
                }
            }
            .padding(.horizontal, DS.Space.roomy)
            .padding(.top, DS.Space.snug)
            .padding(.bottom, DS.Space.wide)
            .padding(.trailing, DS.Brutal.lift)
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
    }
}
