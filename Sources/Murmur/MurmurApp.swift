import AppKit
import SwiftUI

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        do {
            try AppStorage.prepare()
        } catch {
            NSAlert(error: error).runModal()
            exit(EXIT_FAILURE)
        }
        Settings.shared.applyAppearance()
    }

    var body: some Scene {
        // The main window. A `Window` rather than a `WindowGroup`: this app has one front
        // panel, and letting ⌘N spawn a second copy of a tape deck makes no sense.
        Window("Murmur", id: "main") {
            MainWindow(controller: delegate.controller)
        }
        // The dock replaces the title bar; the paper runs edge to edge under the traffic
        // lights, and dragging any bare paper moves the window.
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: DS.Window.mainDefaultWidth, height: DS.Window.mainDefaultHeight)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Settings is a tab of the main window, not a separate settings scene, so the
            // standard "Settings…" item is replaced to switch to that tab.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { MainNavigation.shared.show(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Reveal Dictionary File") {
                    NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                }
            }
        }

        // Secondary now: status and the hotkey while you're working in another app.
        MenuBarExtra {
            MenuContent(controller: delegate.controller)
        } label: {
            Image(systemName: delegate.controller.state.isActive ? "waveform.circle.fill" : "waveform")
        }

        Window("Engine comparison", id: "comparison") {
            ComparisonWindow(controller: delegate.controller)
        }
        .defaultSize(width: DS.Window.comparisonDefaultWidth, height: DS.Window.comparisonDefaultHeight)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DictationController()
    private var hud: HUDPanel?
    private var stateObservation: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Diagnostic: run S1-mini from the installed bundle on fixed samples, print, and quit.
        // Exercises the real model folder and the bundled GPU kernels without a microphone.
        if let index = CommandLine.arguments.firstIndex(of: "--mic-benchmark"),
           CommandLine.arguments.indices.contains(index + 1) {
            let output = CommandLine.arguments[index + 1]
            let window = CommandLine.arguments.indices.contains(index + 2)
                ? Double(CommandLine.arguments[index + 2]) : nil
            Task { @MainActor in
                exit(await MicBenchmark.run(outputPath: output, window: window) ? EXIT_SUCCESS : EXIT_FAILURE)
            }
            return
        }
        if CommandLine.arguments.contains("--cleanup-check") {
            Task { @MainActor in exit(await CleanupCheck.run() ? EXIT_SUCCESS : EXIT_FAILURE) }
            return
        }

        // A regular app now: dock icon, app menu, standard windows. The HUD is still a
        // non-activating panel, so dictating into another app never steals its focus — that
        // property belongs to the panel, not to the activation policy.
        NSApp.setActivationPolicy(.regular)

        // Seed the personal dictionary at launch rather than waiting for the Dictionary
        // panel or the first completed dictation to touch its lazy singleton.
        _ = DictionaryStore.shared

        hud = HUDPanel(controller: controller)

        let hasAccessibility = Permissions.hasAccessibility
        Log.app.info("privacy grant: Accessibility=\(hasAccessibility, privacy: .public)")
        let hotkeyArmed = hasAccessibility && controller.activate()
        if !hasAccessibility {
            Permissions.promptForAccessibility()
        }
        if !hotkeyArmed {
            // Permission changes have no notification we can observe here, so poll until the
            // grant is present and the global monitor can be armed.
            retryActivation()
        }
        if Permissions.hasMicrophone {
            controller.prepareAudio()
        }

        // Load history and write the dashboard in the background, so a long history never
        // delays launch or the first press.
        RunLog.prepare()

        // Compare mode bypasses the recording gate, so it warms Parakeet directly rather than
        // leave the first comparison after launch waiting on a model load.
        if Settings.shared.compareMode, ParakeetModels.isDownloaded {
            Task.detached(priority: .utility) {
                _ = try? await ParakeetModels.shared.manager()
            }
        }

        // Parakeet and Bark are gated behind an explicit load, but once their files are on
        // disk loading needs no network, so do it now rather than make the user click Load
        // after every launch. Core ML caches the Neural Engine compile, so this is seconds.
        StreamingModelPreparation.shared.loadIfInstalled(Settings.shared.engine)
        if Settings.shared.cleanupEngine == .s1Mini {
            S1MiniPreparation.shared.loadIfInstalled()
        }

        let willUseApple = Settings.shared.compareMode || Settings.shared.engine == .apple
        if willUseApple {
            Task.detached(priority: .utility) {
                await AppleSpeechEngine.prewarm()
            }
        }

        // Every `make install` relaunches the app and drops its windows. Restoring the
        // window when it was open last time keeps it from vanishing on each rebuild.
        if UserDefaults.standard.bool(forKey: "comparisonWindowOpen") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                Self.showComparisonWindow()
            }
        }

        observeState()
        if hotkeyArmed {
            Log.app.info("Murmur ready — hold \(Settings.shared.pushToTalkKey.displayName) to dictate")
        } else {
            Log.app.error("Murmur ready — waiting for Accessibility before arming the hotkey")
        }
    }

    /// `murmur://clear` and `murmur://show`, used by the legacy HTML dashboard and
    /// as a scriptable way to raise the window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "murmur" {
            switch url.host {
            case "clear":
                RunLog.clear()
            case "show":
                Self.showComparisonWindow()
            default:
                break
            }
        }
    }

    /// Raises the comparison window without needing SwiftUI's `openWindow` environment
    /// value — usable from the app delegate and from a URL handler.
    static func showComparisonWindow() {
        RunStore.shared.reload()
        if let existing = NSApp.windows.first(where: { $0.title == "Engine comparison" }) {
            existing.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        let isOpen = NSApp.windows.contains { $0.title == "Engine comparison" && $0.isVisible }
        UserDefaults.standard.set(isOpen, forKey: "comparisonWindowOpen")
        controller.deactivate()
    }

    /// Shows and hides the HUD in step with the controller's state.
    private func observeState() {
        withObservationTracking {
            _ = controller.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.controller.state.isActive {
                    self.hud?.present()
                } else {
                    self.hud?.dismiss()
                }
                self.observeState()
            }
        }
    }

    private func retryActivation() {
        Task { @MainActor in
            while !Task.isCancelled {
                if Permissions.hasAccessibility, controller.activate() {
                    controller.prepareAudio()
                    Log.app.info("Accessibility granted — hotkey armed")
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct MenuContent: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared
    @Environment(\.openWindow) private var openWindow
    @State private var streamingModels = StreamingModelPreparation.shared
    @State private var s1Mini = S1MiniPreparation.shared

    var body: some View {
        Text("Hold \(settings.pushToTalkKey.displayName) to dictate")

        if let notice = controller.recordingNotice {
            Text(notice)
            Button("Open Model Settings") { MainNavigation.shared.show(.settings) }
        }

        Divider()

        Picker("Push-to-talk key", selection: Binding(
            get: { settings.pushToTalkKey },
            set: { key in
                settings.pushToTalkKey = key
                controller.reloadHotkey()
            }
        )) {
            ForEach(PushToTalkKey.allCases, id: \.self) { key in
                Text(key.displayName).tag(key)
            }
        }

        Toggle("Compare Apple vs Parakeet batch", isOn: $settings.compareMode)
            .disabled(controller.state.isActive)

        if !settings.compareMode {
            Picker("Engine", selection: Binding(
                get: { settings.engine },
                set: { choice in
                    settings.engine = choice
                    streamingModels.loadIfInstalled(choice)
                }
            )) {
                ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .disabled(controller.state.isActive)
        }

        if settings.engine.requiresPreparedModel {
            let status = streamingModels.state(for: settings.engine)
            Button(status == .loading ? "Loading model…" : "Load selected model…") {
                streamingModels.load(settings.engine)
            }
            .disabled(controller.state.isActive || status == .loading || status == .ready)
            Text(status.message)
        }

        Toggle("Clean up text", isOn: $settings.cleanupEnabled)

        if settings.cleanupEnabled {
            Picker("Cleanup", selection: Binding(
                get: { settings.cleanupEngine },
                set: { choice in
                    settings.cleanupEngine = choice
                    if choice == .s1Mini { s1Mini.loadIfInstalled() }
                }
            )) {
                ForEach(CleanupEngine.allCases, id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            if settings.cleanupEngine == .s1Mini {
                Picker("Profile", selection: $settings.cleanupProfile) {
                    ForEach(CleanupProfile.allCases, id: \.self) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                if s1Mini.state != .ready {
                    Button(s1Mini.state.isBusy ? "Loading S1-mini…" : "Load S1-mini…") { s1Mini.start() }
                        .disabled(s1Mini.state.isBusy)
                    Text(s1Mini.state.message)
                }
            }
            if settings.cleanupEngine == .appleIntelligence, let reason = FoundationModelFormatter.unavailableReason {
                Text(reason)
            }
        }

        Toggle("Sound", isOn: $settings.soundEnabled)

        Divider()

        Button("Show comparison window") {
            RunStore.shared.reload()
            openWindow(id: "comparison")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("d")

        if !Permissions.hasAccessibility {
            Button("Grant Accessibility…") { Permissions.openAccessibilitySettings() }
        }
        if !Permissions.hasMicrophone {
            Button("Grant Microphone…") { Permissions.openMicrophoneSettings() }
        }

        Button("Quit Murmur") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
