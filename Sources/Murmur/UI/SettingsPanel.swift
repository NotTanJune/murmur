import AppKit
import MurmurDictionary
import SwiftUI

/// Settings — appearance, hotkey, model and cleanup. A tab of the main window rather than a
/// separate window: ⌘, and the menu bar and the sidebar both switch to it (`MainNavigation`).
///
/// Every choice with a handful of options is a row of chips rather than a menu, so the
/// active one is visible without opening anything: cream, ink-stroked and checked.
struct SettingsPanel: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @State private var models = StreamingModelPreparation.shared
    @State private var s1Mini = S1MiniPreparation.shared
    @State private var store = RunStore.shared
    @State private var trainingMessage: String?
    @State private var slots = CustomDecoderSlot.installed()
    @State private var opensAtLogin = LoginItem.isEnabled

    var body: some View {
        PageScroll(title: "Settings") {
            VStack(alignment: .leading, spacing: DS.Space.wide) {
                Card(title: "Push to talk") {
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
                    Toggle(isOn: Binding(
                        get: { opensAtLogin },
                        set: { open in
                            LoginItem.set(open)
                            opensAtLogin = LoginItem.isEnabled
                        }
                    )) {
                        Text("Open at login")
                            .font(DS.Font.bodyEmphasis)
                            .foregroundStyle(DS.Color.ink)
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Color.stat)
                    .onAppear { opensAtLogin = LoginItem.isEnabled }
                }

                Card(title: "Microphone") {
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
                    .tint(DS.Color.stat)
                    Note(text: settings.alwaysOpenMic
                        ? "Recording starts the instant you press, including the moment just before it. "
                            + "Only the last 0.3 s is held, in memory. macOS shows its mic indicator the whole time; "
                            + "measured cost about 3% of one CPU core."
                        : "The mic opens when you press, which takes about 0.1 s (longer on the first press), "
                            + "so a word spoken right at the press can be clipped.")
                    Toggle(isOn: Binding(
                        get: { settings.keepSystemInput },
                        set: { keep in
                            settings.keepSystemInput = keep
                            SystemInputGuard.shared.enforce()
                        }
                    )) {
                        Text("Use it as the Mac's microphone")
                            .font(DS.Font.bodyEmphasis)
                            .foregroundStyle(DS.Color.ink)
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Color.stat)
                    Note(text: settings.keepSystemInput
                        ? "Every app records from it too. When macOS switches the input to a headset that "
                            + "connects, Murmur switches it back."
                        : "Other apps use whatever macOS picks, including a Bluetooth headset.")
                }

                Card(title: "Appearance") {
                    ChoiceKeys(
                        options: AppearanceChoice.allCases,
                        selection: $settings.appearance,
                        title: \.displayName
                    )
                }

                Card(title: "Memory") {
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
                        ? "S1-mini stays in memory (about 500 MB) for instant cleanup every time."
                        : "S1-mini leaves memory after this long without dictating and reloads at your "
                            + "next press, while you speak. The speech model stays loaded; it's small.")
                }

                Card(title: "Model") {
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
                                .buttonStyle(KeyButtonStyle(kind: .secondary))
                                .disabled(controller.state.isActive || status == .loading)
                            }
                            Note(text: status.message)
                        }
                    }
                    if settings.engine == .parakeet || settings.engine == .barkClean {
                        Eyebrow(text: "Transcribe")
                        ChoiceKeys(
                            options: TranscribeTiming.allCases,
                            selection: $settings.transcribeTiming,
                            title: \.displayName
                        )
                        Note(text: settings.transcribeTiming.detail)
                    }
                    if settings.compareMode {
                        Note(text: "Compare mode bypasses this choice and runs Apple vs Parakeet batch. "
                            + "Turn it off in the menu bar to dictate with the selected engine.")
                    }
                }

                Card(title: "Training") {
                    Toggle(isOn: Binding(
                        get: { settings.keepRecordings },
                        set: { on in
                            settings.keepRecordings = on
                            if !on { RunLog.deleteAllRecordings() }
                        }
                    )) {
                        Text("Keep recordings for training")
                            .font(DS.Font.bodyEmphasis)
                            .foregroundStyle(DS.Color.ink)
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Color.stat)
                    Note(text: settings.keepRecordings
                        ? "Each dictation's audio is kept on disk for 30 days (\(recordingsSize)), longer while it has a correction waiting to be exported. Nothing leaves this Mac."
                        : "No audio is kept. Corrections can't train the model without it.")

                    Eyebrow(text: "Export")
                    let pending = TrainingExport.pending(store.runs, corrector: DictionaryStore.shared.corrector)
                    HStack(spacing: DS.Space.base) {
                        Button("Export \(pending.count) labelled run\(pending.count == 1 ? "" : "s")") { export() }
                            .buttonStyle(KeyButtonStyle(kind: .secondary))
                            .disabled(pending.count == 0)
                        Note(text: String(format: "%.1f minutes of corrected speech since the last export.", pending.seconds / 60))
                    }

                    Eyebrow(text: "Decoder")
                    ChoiceKeys(
                        options: [BarkDecoderChoice.stock] + slots.map { BarkDecoderChoice.custom($0) },
                        selection: Binding(
                            get: { settings.barkDecoder },
                            set: { choice in
                                settings.barkDecoder = choice
                                Task { try? await ParakeetModels.barkClean.reload() }
                            }
                        ),
                        title: \.displayName
                    )
                    .disabled(controller.state.isActive)
                    if case .custom(let name) = settings.barkDecoder,
                       let manifest = try? CustomDecoderSlot.readManifest(at: CustomDecoderSlot.directory(for: name)) {
                        Note(text: String(format: "Trained on %d clips. Held-out WER %.1f%% · replay WER %.1f%%.", manifest.clips, manifest.heldOutWER, manifest.replayWER))
                    }
                    HStack(spacing: DS.Space.base) {
                        Button("Install fine-tuned decoder…") { importSlot() }
                            .buttonStyle(KeyButtonStyle(kind: .secondary))
                        if case .custom(let name) = settings.barkDecoder {
                            Button("Remove \(name)") {
                                settings.barkDecoder = .stock
                                CustomDecoderSlot.remove(name)
                                slots = CustomDecoderSlot.installed()
                                Task { try? await ParakeetModels.barkClean.reload() }
                            }
                            .buttonStyle(KeyButtonStyle(kind: .secondary))
                        }
                    }
                    if let trainingMessage {
                        Note(text: trainingMessage)
                    }
                }

                Card(title: "Cleanup") {
                    Toggle(isOn: $settings.cleanupEnabled) {
                        Text("Clean up transcripts")
                            .font(DS.Font.bodyEmphasis)
                            .foregroundStyle(DS.Color.ink)
                    }
                    .toggleStyle(.switch)
                    .tint(DS.Color.stat)

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
                                    .buttonStyle(KeyButtonStyle(kind: .secondary))
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
        }
    }

    private var recordingsSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(RecordingStore.shared.totalBytes()), countStyle: .file)
    }

    /// Runs on the main actor: an export is a deliberate, rare click that copies tens of MB.
    private func export() {
        let root = AppStorage.directory.appendingPathComponent("Training", isDirectory: true)
        do {
            let (summary, ids) = try TrainingExport.write(
                runs: store.runs, corrector: DictionaryStore.shared.corrector, recordings: RecordingStore.shared,
                to: root, date: Date(), barkRevision: BarkModelStore.revision
            )
            RunLog.markExported(ids: ids)
            trainingMessage = "Exported \(summary.labelled) labelled and \(summary.replay) replay clips to \(summary.zip.lastPathComponent)."
            NSWorkspace.shared.activateFileViewerSelecting([summary.zip])
        } catch {
            trainingMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importSlot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder the notebook produced (Decoder.mlmodelc, JointDecisionv3.mlmodelc, manifest.json)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let name = try CustomDecoderSlot.importFolder(url, baseRevision: BarkModelStore.revision)
            slots = CustomDecoderSlot.installed()
            settings.barkDecoder = .custom(name)
            trainingMessage = "Installed fine-tuned decoder \(name)."
            Task { try? await ParakeetModels.barkClean.reload() }
        } catch {
            trainingMessage = "Not installed: \(error.localizedDescription)"
        }
    }
}
