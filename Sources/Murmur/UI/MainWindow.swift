import MurmurDictionary
import AppKit
import SwiftUI

/// The app's main window.
///
/// Two layers: a glass dock pinned to the top holding everything you *operate* (record,
/// level, counter, section and profile), and brutalist cards beneath it holding everything
/// you *read*. The cards scroll under the dock, which is what makes the glass visibly glass.
struct MainWindow: View {
    @Bindable var controller: DictationController

    @State private var navigation = MainNavigation.shared
    @Environment(\.openWindow) private var openWindow
    /// Where the dock's inset begins, in window coordinates.
    @State private var insetTop: CGFloat = 0

    enum Section: String, CaseIterable, Identifiable {
        case transcriptions
        case dictionary
        case settings

        var id: String { rawValue }
        var title: String {
            switch self {
            case .transcriptions: "Transcriptions"
            case .dictionary: "Dictionary"
            case .settings: "Settings"
            }
        }
    }

    var body: some View {
        Group {
            switch navigation.section {
            case .transcriptions: TranscriptionList()
            case .dictionary: DictionaryPanel()
            case .settings: SettingsPanel(controller: controller)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Paper from the window's top edge down to the dock, so cards disappear under it
        // rather than scrolling up behind the traffic lights. Beside and under the dock they
        // stay visible: that's the glass doing its job. Measured rather than derived from the
        // safe area, which a hidden title bar reports inconsistently. Applied
        // before the inset so it sits under the dock, which draws its own outline.
        .overlay(alignment: .top) {
            PaperBackground()
                .frame(height: insetTop + DS.Window.dockTopInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: DS.Space.base) {
                TransportDock(controller: controller, section: $navigation.section)
                if let notice = controller.recordingNotice {
                    NoticeCard(text: notice)
                }
            }
            .padding(.horizontal, DS.Space.roomy)
            .padding(.top, DS.Window.dockTopInset)
            .padding(.bottom, DS.Space.snug)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                insetTop = $0
            }
        }
        .background(PaperBackground().ignoresSafeArea())
        .frame(minWidth: DS.Window.mainMinWidth, minHeight: DS.Window.mainMinHeight)
        .onAppear {
            navigation.openMainWindow = { [openWindow] in openWindow(id: "main") }
        }
    }
}

/// Which tab the main window shows. Shared so ⌘,, the menu bar and the recording notice can
/// all switch to Settings without a handle on the window's view state.
@MainActor
@Observable
final class MainNavigation {
    static let shared = MainNavigation()

    var section: MainWindow.Section = .transcriptions {
        didSet {
            if section != .settings { lastContentSection = section }
        }
    }

    /// The tab to return to when Settings is closed with the gear.
    private(set) var lastContentSection: MainWindow.Section = .transcriptions

    private init() {}

    /// The gear: opens Settings, or goes back to the tab you came from if already there.
    func toggleSettings() {
        withAnimation(DS.Motion.panel) {
            section = section == .settings ? lastContentSection : .settings
        }
    }

    /// Switches tab and brings the main window forward, reopening it if it was closed.
    func show(_ section: MainWindow.Section) {
        withAnimation(DS.Motion.panel) { self.section = section }
        // SwiftUI names the window after the scene id, with a suffix; the title is the
        // fallback, as for the comparison window.
        if let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix("main") == true || $0.title == "Murmur"
        }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Set by a view that has SwiftUI's `openWindow`; used only when the window is closed.
    var openMainWindow: (() -> Void)?
}

/// Why recording is blocked, with the way out.
private struct NoticeCard: View {
    let text: String

    var body: some View {
        HStack(spacing: DS.Space.base) {
            Text(text)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Open Settings") { MainNavigation.shared.show(.settings) }
                .buttonStyle(BrutalButtonStyle(compact: true))
        }
        .padding(DS.Space.base)
        .brutalSurface(radius: DS.Radius.control, lift: DS.Brutal.liftSmall)
    }
}

// MARK: - Dock

/// The glass control layer: transport on top, section and profile below.
private struct TransportDock: View {
    @Bindable var controller: DictationController
    @Binding var section: MainWindow.Section

    @State private var settings = Settings.shared
    @State private var elapsed: TimeInterval = 0
    @State private var startedAt: Date?

    private var isRecording: Bool { controller.isRecording }

    var body: some View {
        GlassEffectContainer(spacing: DS.Glass.containerSpacing) {
            VStack(alignment: .leading, spacing: DS.Space.base) {
                HStack(spacing: DS.Space.roomy) {
                    RecordButton(isRecording: isRecording) {
                        if isRecording {
                            controller.stopButtonRecording()
                        } else {
                            controller.startButtonRecording()
                        }
                    }

                    VStack(alignment: .leading, spacing: DS.Space.hair) {
                        HStack(spacing: DS.Space.tight + DS.Space.hair) {
                            Lamp(isLit: isRecording)
                            Eyebrow(
                                text: isRecording ? "Recording" : "Hold \(settings.pushToTalkKey.displayName)",
                                color: isRecording ? DS.Color.record : DS.Color.inkSecondary
                            )
                        }
                        Text(counterText)
                            .font(DS.Font.counterLarge)
                            .foregroundStyle(DS.Color.ink)
                    }

                    LevelMeter(level: controller.level, isActive: isRecording)

                    Spacer(minLength: DS.Space.snug)

                    VStack(alignment: .trailing, spacing: DS.Space.tight) {
                        Tag(text: settings.compareMode ? "Compare mode" : settings.engine.displayName)
                        if settings.cleanupEnabled, !settings.compareMode {
                            Tag(text: settings.cleanupEngine.displayName)
                        }
                    }

                    HStack(spacing: DS.Space.snug) {
                        AppearanceToggle()
                        Button {
                            MainNavigation.shared.toggleSettings()
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: DS.Icon.large, weight: .bold))
                        }
                        .buttonStyle(BrutalButtonStyle(isSelected: section == .settings))
                        .help(section == .settings ? "Close Settings" : "Settings (⌘,)")
                        .accessibilityLabel(section == .settings ? "Close Settings" : "Settings")
                    }
                    .padding(.trailing, DS.Brutal.liftSmall)
                    .padding(.bottom, DS.Brutal.liftSmall)
                }

                HStack(spacing: DS.Space.base) {
                    ChoiceKeys(
                        options: MainWindow.Section.allCases,
                        selection: Binding(
                            get: { section },
                            set: { candidate in withAnimation(DS.Motion.panel) { section = candidate } }
                        ),
                        title: \.title,
                        dense: true
                    )
                    Spacer(minLength: DS.Space.snug)
                    if settings.cleanupEnabled, settings.cleanupEngine.usesProfiles {
                        Eyebrow(text: "Profile")
                        ProfileKeys(dense: true)
                    }
                }
            }
            .padding(DS.Space.roomy)
            .outlinedGlass()
        }
        .onChange(of: controller.isRecording) { _, active in
            startedAt = active ? Date() : nil
            if !active { elapsed = 0 }
        }
        .task(id: startedAt) {
            guard let startedAt else { return }
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(startedAt)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Minutes and seconds, zero-padded.
    private var counterText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Flips between light and dark. Shows the appearance you're in now; Settings has the
/// third option, following macOS.
private struct AppearanceToggle: View {
    @State private var settings = Settings.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        Button {
            settings.appearance = isDark ? .light : .dark
        } label: {
            Image(systemName: isDark ? "moon.fill" : "sun.max.fill")
                .font(.system(size: DS.Icon.large, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(BrutalButtonStyle())
        .help(isDark ? "Dark appearance. Click for light." : "Light appearance. Click for dark.")
        .accessibilityLabel(isDark ? "Switch to light appearance" : "Switch to dark appearance")
    }
}

// MARK: - Transcriptions

/// Past transcriptions, searchable, each copyable and saveable.
private struct TranscriptionList: View {
    @State private var store = RunStore.shared
    @State private var query = ""
    @State private var isConfirmingClear = false

    private var runs: [DictationRun] {
        let all = store.runs.reversed().map { $0 }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.text.localizedStandardContains(trimmed) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: DS.Space.roomy) {
                header

                if runs.isEmpty {
                    EmptyPanel(
                        label: store.runs.isEmpty ? "No recordings yet" : "No matches",
                        detail: store.runs.isEmpty ? "Hold the key or press Record." : "Try a different search."
                    )
                    .padding(.top, DS.Space.wide)
                } else {
                    ForEach(runs) { run in
                        TranscriptionRow(run: run) {
                            withAnimation(DS.Motion.panel) { RunLog.delete(run) }
                        } onToggleSave: {
                            RunLog.setSaved(!run.isSaved, for: run)
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Space.roomy)
            .padding(.top, DS.Space.snug)
            .padding(.bottom, DS.Space.wide)
            .padding(.trailing, DS.Brutal.lift)
        }
        .scrollEdgeEffectStyle(.hard, for: .top)
    }

    private var header: some View {
        HStack(spacing: DS.Space.base) {
            SearchField(text: $query, placeholder: "Search transcriptions")
            Eyebrow(text: "\(store.runs.count) recording\(store.runs.count == 1 ? "" : "s")")
                .fixedSize()
            Button("Delete all") { isConfirmingClear = true }
                .buttonStyle(BrutalButtonStyle())
                .disabled(store.runs.isEmpty)
        }
        .padding(.bottom, DS.Brutal.liftSmall)
        // Confirmed, unlike a single row: one row is trivially re-recorded, the whole
        // history is not, and there's no undo.
        .confirmationDialog(
            "Delete all \(store.runs.count) recordings?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { RunLog.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved recordings are deleted too. This can't be undone.")
        }
    }
}

private struct TranscriptionRow: View {
    let run: DictationRun
    let onDelete: () -> Void
    let onToggleSave: () -> Void

    @State private var didCopy = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack(spacing: DS.Space.snug) {
                Tag(text: run.engine)
                if let cleanup = run.cleanup {
                    Tag(text: cleanup)
                }
                Text(String(format: "%.2fs", run.displayedLatency))
                    .font(DS.Font.counter)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .help(run.deliverySeconds == nil
                        ? "Recognition and cleanup time; insertion was not measured."
                        : "Release to AX insertion or paste event. Target app rendering is not measured.")
                Spacer()
                Text(run.date, style: .time)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                deleteButton
                    .opacity(isHovering ? 1 : 0)
                saveButton
                copyButton
            }

            Text(run.text)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let corrections = run.corrections, !corrections.isEmpty {
                CorrectionBadges(corrections: corrections)
            }
        }
        .padding(DS.Space.roomy)
        .brutalSurface(isHovering ? DS.Color.cardHover : DS.Color.card)
        .onHover { isHovering = $0 }
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(run.text, forType: .string)
            didCopy = true
            Task {
                try? await Task.sleep(for: DS.Motion.copiedHold)
                didCopy = false
            }
        } label: {
            Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(BrutalButtonStyle(compact: true))
    }

    /// Always visible, unlike delete, so a kept transcription reads as kept at a glance:
    /// saved is yellow and sunk, like every other "on" state.
    private var saveButton: some View {
        Button(action: onToggleSave) {
            Label(run.isSaved ? "Saved" : "Save", systemImage: run.isSaved ? "bookmark.fill" : "bookmark")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(BrutalButtonStyle(isSelected: run.isSaved, compact: true))
        .help(run.isSaved
            ? "Saved. Click to let this transcription expire after 30 days."
            : "Keep this transcription. Unsaved ones are deleted after 30 days.")
    }

    /// Appears on hover only, and deletes without a confirmation — a single transcript is
    /// cheap to redo, and a dialog on every row would make tidying up tedious. The
    /// irreversible one is "Delete all", which does confirm.
    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
                .font(.system(size: DS.Icon.regular, weight: .bold))
        }
        .buttonStyle(BrutalButtonStyle(compact: true))
        .help("Delete this transcription")
        .accessibilityLabel("Delete")
    }
}

/// Shows that the dictionary fired, and on what. Without this the dictionary is invisible
/// and you can't tell a rule that works from one that never matches.
private struct CorrectionBadges: View {
    let corrections: [AppliedCorrection]

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            Eyebrow(text: "Corrected")
            ForEach(corrections, id: \.self) { correction in
                HStack(spacing: DS.Space.tight) {
                    Text(correction.from)
                        .strikethrough()
                        .foregroundStyle(DS.Color.inkSecondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: DS.Icon.small, weight: .bold))
                        .foregroundStyle(DS.Color.inkSecondary)
                    Text(correction.to)
                        .foregroundStyle(DS.Color.ink)
                    if correction.count > 1 {
                        Text("×\(correction.count)")
                            .foregroundStyle(DS.Color.inkSecondary)
                    }
                }
                .font(DS.Font.caption)
                .padding(.horizontal, DS.Space.snug)
                .padding(.vertical, DS.Space.hair)
                .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.tag, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.tag, style: .continuous)
                        .strokeBorder(DS.Color.ink, lineWidth: DS.Brutal.borderThin)
                )
            }
            Spacer()
        }
    }
}
