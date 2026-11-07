import AppKit
import SwiftUI

/// Started from `main.swift`, which first diverts helper invocations.
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
        // One `Window`, not a `WindowGroup`: there is a single main window, and the
        // New Window shortcut (⌘N) has nothing to create.
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
                Button("Reveal Dictionary in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                }
            }
        }

        // Secondary surface: status and the hotkey while you work in another app.
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Diagnostic: run S1-mini from the installed bundle on fixed samples, print, and quit.
        // Exercises the real model folder and the bundled GPU kernels without a microphone.
        if let index = CommandLine.arguments.firstIndex(of: "--residency-check"),
           CommandLine.arguments.indices.contains(index + 1) {
            let output = CommandLine.arguments[index + 1]
            Task { @MainActor in exit(await ResidencyCheck.run(outputPath: output) ? EXIT_SUCCESS : EXIT_FAILURE) }
            return
        }
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
        if let index = CommandLine.arguments.firstIndex(of: "--decoder-check"),
           CommandLine.arguments.indices.contains(index + 2) {
            let slot = CommandLine.arguments[index + 1]
            let path = CommandLine.arguments[index + 2]
            Task { @MainActor in exit(await DecoderCheck.run(slot: slot, path: path) ? EXIT_SUCCESS : EXIT_FAILURE) }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--incremental-check"),
           CommandLine.arguments.indices.contains(index + 1) {
            let path = CommandLine.arguments[index + 1]
            Task { @MainActor in exit(await IncrementalCheck.run(path: path) ? EXIT_SUCCESS : EXIT_FAILURE) }
            return
        }
        if CommandLine.arguments.contains("--cleanup-check") {
            Task { @MainActor in exit(await CleanupCheck.run() ? EXIT_SUCCESS : EXIT_FAILURE) }
            return
        }

        // A regular app: Dock icon, app menu, ordinary windows. Keeping focus on the field
        // being dictated into is the HUD panel's own doing (non-activating, never key), so
        // this policy does not affect it.
        NSApp.setActivationPolicy(.regular)

        // Seed the personal dictionary at launch rather than waiting for the Dictionary
        // panel or the first completed dictation to touch its lazy singleton.
        _ = DictionaryStore.shared

        hud = HUDPanel(controller: controller)

        let hasAccessibility = Permissions.hasAccessibility
        let hasInputMonitoring = Permissions.hasInputMonitoring
        Log.app.info("privacy grant: Accessibility=\(hasAccessibility, privacy: .public) InputMonitoring=\(hasInputMonitoring, privacy: .public)")
        if !hasInputMonitoring {
            Permissions.requestInputMonitoring()
        }
        let hotkeyArmed = hasAccessibility && controller.activate()
        if !hasAccessibility {
            Permissions.promptForAccessibility()
        }
        if !hotkeyArmed {
            // Permission changes have no notification we can observe here, so poll until the
            // grant is present and the global monitor can be armed.
            retryActivation()
        }
        // Before capture opens, so a Bluetooth headset that grabbed the default input since
        // the last run is already moved off it.
        SystemInputGuard.shared.start()
        LoginItem.registerOnce()
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

        // The speech model loads now, in the background: it's small, and if macOS purged
        // its Neural Engine compile cache the recompile runs here rather than inside a
        // dictation (Apple's transcriber stands in until it's ready). S1-mini, the 500 MB
        // one, waits for the first press unless memory is no concern.
        CompileCacheGuard.ensure()
        StreamingModelPreparation.shared.loadIfInstalled(Settings.shared.engine)
        if Settings.shared.idleUnload == .never, Settings.shared.cleanupEngine == .s1Mini {
            S1MiniPreparation.shared.loadIfInstalled()
        }

        let willUseApple = Settings.shared.compareMode || Settings.shared.engine == .apple
        if willUseApple {
            Task.detached(priority: .utility) {
                await AppleSpeechEngine.prewarm()
            }
        }

        // Every `make install` relaunches the app and drops its windows; bring the comparison
        // window back if it was open last time so it survives rebuilds.
        if UserDefaults.standard.bool(forKey: "comparisonWindowOpen") {
            Task { @MainActor in
                // Let scene creation finish before looking for the window.
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
    /// It doubles as a scriptable way to raise the window.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "murmur" {
            switch url.host {
            case "clear": RunLog.clear()
            case "show": Self.showComparisonWindow()
            default: break
            }
        }
    }

    /// Raises the comparison window if SwiftUI has one; it does not create it. Only ever
    /// targets that window, never the HUD.
    static func showComparisonWindow() {
        RunStore.shared.reload()
        if let window = NSApp.windows.first(where: { $0.title == "Engine comparison" }) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        let comparisonOpen = NSApp.windows.contains { $0.title == "Engine comparison" && $0.isVisible }
        UserDefaults.standard.set(comparisonOpen, forKey: "comparisonWindowOpen")
        controller.deactivate()
    }

    /// Shows the HUD for as long as a hold is live. Tracking fires once, so each firing
    /// re-registers. Showing or hiding the HUD never activates the app or makes a window key.
    private func observeState() {
        withObservationTracking {
            _ = controller.state
        } onChange: { [weak self] in
            // Fires before the new value is stored and off the main actor; read it from a task.
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
                    Log.app.info("Accessibility granted; hotkey armed")
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

        Toggle("Start and stop tick", isOn: $settings.soundEnabled)

        Divider()

        Button("Open Engine Comparison…") {
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
        if !Permissions.hasInputMonitoring {
            Button("Grant Input Monitoring…") { Permissions.openInputMonitoringSettings() }
        }

        Button("Quit Murmur") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
