import MurmurDictionary
import AppKit
import SwiftUI

/// The app's main window: a sidebar on the chrome colour and an inset content pane.
///
/// The sidebar holds navigation and everything you *operate* (record, level, counter,
/// engine and profile); the pane holds everything you *read*. The title bar is hidden, so
/// the traffic lights sit over the sidebar.
struct MainWindow: View {
    @Bindable var controller: DictationController

    @State private var navigation = MainNavigation.shared
    @Environment(\.openWindow) private var openWindow

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
        var symbol: String {
            switch self {
            case .transcriptions: "waveform"
            case .dictionary: "book.closed"
            case .settings: "gearshape"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(controller: controller, section: $navigation.section)
                .frame(width: DS.Window.sidebarWidth)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    AppearanceToggle()
                }
                .padding(.trailing, DS.Space.roomy)
                .frame(height: DS.Window.titleBarHeight)
                pane
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(DS.Color.chrome.ignoresSafeArea())
        .frame(minWidth: DS.Window.mainMinWidth, minHeight: DS.Window.mainMinHeight)
        .onAppear {
            navigation.openMainWindow = { [openWindow] in openWindow(id: "main") }
        }
    }

    /// The inset content pane: only its top-leading corner is rounded, so it reads as a
    /// sheet sliding out from under the sidebar.
    private var pane: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: DS.Radius.pane, style: .continuous)
        return Group {
            switch navigation.section {
            case .transcriptions: TranscriptionList()
            case .dictionary: DictionaryPanel()
            case .settings: SettingsPanel(controller: controller)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Color.pane)
        .clipShape(shape)
        .overlay { shape.strokeBorder(DS.Color.paneEdge, lineWidth: DS.Stroke.hairline) }
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
        section = section == .settings ? lastContentSection : .settings
    }

    /// Switches tab and brings the main window forward, reopening it if it was closed.
    func show(_ section: MainWindow.Section) {
        self.section = section
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
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Text(text)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { MainNavigation.shared.show(.settings) }
                .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
        }
        .padding(DS.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

// MARK: - Sidebar

/// App name, navigation, and the transport below it.
private struct Sidebar: View {
    @Bindable var controller: DictationController
    @Binding var section: MainWindow.Section

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Text("Murmur")
                .font(DS.Font.brand)
                .foregroundStyle(DS.Color.ink)
                .padding(.horizontal, DS.Space.base)
                .padding(.bottom, DS.Space.base)

            ForEach(MainWindow.Section.allCases) { item in
                // Not animated: a cross-fade keeps both pages alive for its whole duration.
                NavItem(item: item, isSelected: section == item) { section = item }
            }

            Spacer(minLength: DS.Space.roomy)

            if let notice = controller.recordingNotice {
                NoticeCard(text: notice)
            }
            SidebarTransport(controller: controller)
        }
        .padding(.top, DS.Window.trafficLightClearance)
        .padding(.horizontal, DS.Space.base)
        .padding(.bottom, DS.Space.base)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct NavItem: View {
    let item: MainWindow.Section
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.base) {
                Image(systemName: item.symbol)
                    .font(.system(size: DS.Icon.nav, weight: .medium))
                    .frame(width: DS.Icon.large)
                Text(item.title)
                    .font(DS.Font.bodyEmphasis)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? DS.Color.navSelectedInk : DS.Color.inkSecondary)
            .padding(.horizontal, DS.Space.base)
            .frame(height: DS.Control.navHeight)
            .background(
                isSelected ? DS.Color.navSelected : Color.clear,
                in: .rect(cornerRadius: DS.Radius.nav, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.nav, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Record, counter, level, engine and profile, stacked in the sidebar's footer.
private struct SidebarTransport: View {
    @Bindable var controller: DictationController

    @State private var settings = Settings.shared
    @State private var models = StreamingModelPreparation.shared
    @State private var elapsed: TimeInterval = 0
    @State private var startedAt: Date?

    private var isRecording: Bool { controller.isRecording }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack(spacing: DS.Space.base) {
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
            }

            LevelMeter(level: controller.level, isActive: isRecording)

            VStack(alignment: .leading, spacing: DS.Space.tight) {
                if !settings.compareMode, settings.engine.requiresPreparedModel,
                   models.state(for: settings.engine) == .loading {
                    Tag(text: "\(settings.engine.displayName) preparing · using Apple", isHighlighted: true)
                        .help(models.state(for: settings.engine).message)
                } else {
                    Tag(text: settings.compareMode ? "Compare mode" : settings.engine.displayName)
                }
                if settings.cleanupEnabled, !settings.compareMode {
                    Tag(text: settings.cleanupEngine.displayName)
                }
            }

            if settings.cleanupEnabled, settings.cleanupEngine.usesProfiles {
                VStack(alignment: .leading, spacing: DS.Space.snug) {
                    Eyebrow(text: "Profile")
                    ProfileKeys(dense: true, isVertical: true)
                }
            }
        }
        .padding(DS.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .onChange(of: controller.isRecording) { _, active in
            if active {
                startedAt = Date()
            } else {
                startedAt = nil
                elapsed = 0
            }
        }
        .task(id: startedAt) {
            guard let start = startedAt else { return }
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(start)
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
            Image(systemName: isDark ? "moon" : "sun.max")
                .font(.system(size: DS.Icon.large, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(KeyButtonStyle(kind: .plain))
        .help(isDark ? "Dark appearance. Click for light." : "Light appearance. Click for dark.")
        .accessibilityLabel(isDark ? "Switch to light appearance" : "Switch to dark appearance")
    }
}

// MARK: - Transcriptions

/// Past transcriptions grouped by day, searchable, each copyable and saveable.
private struct TranscriptionList: View {
    @State private var store = RunStore.shared
    @State private var query = ""
    @State private var isConfirmingClear = false
    @State private var toast: String?

    private var runs: [DictationRun] {
        let newestFirst = Array(store.runs.reversed())
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return newestFirst }
        return newestFirst.filter { $0.text.localizedStandardContains(needle) }
    }

    /// Newest first, split by calendar day.
    private var days: [(day: Date, runs: [DictationRun])] {
        var result: [(day: Date, runs: [DictationRun])] = []
        for run in runs {
            let day = Calendar.current.startOfDay(for: run.date)
            if let last = result.indices.last, result[last].day == day {
                result[last].runs.append(run)
            } else {
                result.append((day, [run]))
            }
        }
        return result
    }

    /// Words delivered across the whole history. Compare-mode groups are skipped: every
    /// engine transcribed the same speech, so counting each would multiply it.
    private var totalWords: Int {
        store.runs.reduce(0) { total, run in
            guard run.group == nil else { return total }
            return total + (run.label ?? run.text).split(whereSeparator: \.isWhitespace).count
        }
    }

    var body: some View {
        PageScroll(title: "Welcome back") {
            if totalWords > 0 {
                VStack(alignment: .leading, spacing: DS.Space.tight) {
                    Text("\(totalWords.formatted()) words")
                        .font(DS.Font.stat)
                        .foregroundStyle(DS.Color.stat)
                    Text("dictated with Murmur")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                }
            }

            if runs.isEmpty {
                HStack {
                    Spacer()
                    controls
                }
                EmptyPanel(
                    label: store.runs.isEmpty ? "Hold the key and speak." : "No matches",
                    highlight: store.runs.isEmpty ? "speak" : nil,
                    detail: store.runs.isEmpty ? "Or press Record in the sidebar." : "Try a different search."
                )
                .padding(.top, DS.Space.wide)
            } else {
                // Every row is its own lazy item, so only the rows on screen are built; a
                // day's card is drawn as slices (`cardSegment`) rather than one container.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.element.day) { index, group in
                        HStack(spacing: DS.Space.base) {
                            Eyebrow(text: title(for: group.day))
                            Spacer()
                            if index == 0 { controls }
                        }
                        .padding(.top, index == 0 ? 0 : DS.Space.wide)
                        .padding(.bottom, DS.Space.snug)

                        ForEach(Array(group.runs.enumerated()), id: \.element.id) { position, run in
                            TranscriptionRow(run: run) {
                                withAnimation(DS.Motion.panel) { RunLog.delete(run) }
                            } onToggleSave: {
                                RunLog.setSaved(!run.isSaved, for: run)
                            } onCopied: {
                                showToast("Copied")
                            }
                            .cardSegment(isFirst: position == 0, isLast: position == group.runs.count - 1)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Toast(text: toast)
                    .padding(.bottom, DS.Space.wide)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        // Wiping the whole history cannot be undone, so it asks first; a single row does not.
        .confirmationDialog(
            "Delete all \(store.runs.count) recordings?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete all", role: .destructive) { RunLog.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved recordings are deleted too. This can't be undone.")
        }
    }

    private var controls: some View {
        HStack(spacing: DS.Space.snug) {
            SearchToggle(text: $query, placeholder: "Search transcriptions")
            Button("Delete all") { isConfirmingClear = true }
                .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
                .disabled(store.runs.isEmpty)
        }
    }

    private func title(for day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private func showToast(_ text: String) {
        withAnimation(DS.Motion.panel) { toast = text }
        Task {
            try? await Task.sleep(for: DS.Motion.copiedHold)
            withAnimation(DS.Motion.panel) { toast = nil }
        }
    }
}

private struct TranscriptionRow: View {
    let run: DictationRun
    let onDelete: () -> Void
    let onToggleSave: () -> Void
    let onCopied: () -> Void

    @State private var didCopy = false
    @State private var isHovering = false
    @State private var isEditing = false
    @State private var draft = ""
    @Environment(\.isScrolling) private var isScrolling

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.base) {
            Text(run.date, style: .time)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .frame(width: DS.Window.timeColumnWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: DS.Space.snug) {
                if isEditing {
                    TextField("Corrected transcript", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                        .padding(DS.Space.snug)
                        .background(DS.Color.field, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .strokeBorder(DS.Color.hairline, lineWidth: DS.Stroke.hairline)
                        )
                        .onSubmit { commitEdit() }
                        .onExitCommand { isEditing = false }
                } else {
                    Text(run.label ?? run.text)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let corrections = run.corrections, !corrections.isEmpty {
                    CorrectionBadges(corrections: corrections)
                }

                metadata
            }

            actions
        }
        .padding(.horizontal, DS.Space.roomy)
        .padding(.vertical, DS.Space.base)
        .background(isHovering ? DS.Color.cardHover : Color.clear)
        // Rows pass under a still pointer while scrolling; ignore that and drop any stale
        // highlight when a scroll starts.
        .onHover { if !isScrolling { isHovering = $0 } }
        .onChange(of: isScrolling) { _, scrolling in
            if scrolling { isHovering = false }
        }
    }

    /// Engine, cleanup and timing on one quiet line.
    private var metadata: some View {
        HStack(spacing: DS.Space.snug) {
            Text(([run.engine] + (run.cleanup.map { [$0] } ?? [])).joined(separator: " · "))
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
            if run.label != nil {
                Tag(text: "Labelled", isHighlighted: true)
            }
            Text(String(format: "%.2fs", run.displayedLatency))
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .help(run.deliverySeconds == nil
                    ? "Recognition and cleanup time; insertion was not measured."
                    : "Release to AX insertion or paste event. Target app rendering is not measured.")
        }
    }

    /// Hidden until the pointer is over the row, except a kept transcription's Save chip,
    /// so saved reads as saved at a glance.
    /// The buttons are only built while visible; otherwise a glyph-only stand-in of the same
    /// size keeps the row height and the text column from shifting.
    @ViewBuilder private var actions: some View {
        let showsActions = isHovering || isEditing || run.isSaved
        Group {
            if showsActions {
                HStack(spacing: DS.Space.tight) {
                    copyButton
                    if TrainingLabel.editAllowed(run) {
                        editButton
                    }
                    saveButton
                        .opacity(isHovering || run.isSaved || isEditing ? 1 : 0)
                    deleteButton
                }
                .transition(.opacity)
            } else {
                actionsPlaceholder
            }
        }
        .animation(DS.Motion.panel, value: showsActions)
    }

    private var actionsPlaceholder: some View {
        HStack(spacing: DS.Space.tight) {
            placeholderGlyph("doc.on.doc")
            if TrainingLabel.editAllowed(run) {
                placeholderGlyph("pencil")
            }
            placeholderGlyph(run.isSaved ? "bookmark.fill" : "bookmark")
            placeholderGlyph("trash")
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private func placeholderGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: DS.Icon.regular, weight: .semibold))
            .padding(.horizontal, DS.Space.snug)
            .frame(minHeight: DS.Control.heightSmall)
    }

    private var editButton: some View {
        Button {
            if isEditing {
                commitEdit()
            } else {
                draft = run.label ?? run.text
                isEditing = true
            }
        } label: {
            Image(systemName: isEditing ? "checkmark" : "pencil")
                .font(.system(size: DS.Icon.regular, weight: .semibold))
        }
        .buttonStyle(KeyButtonStyle(kind: .secondary, isSelected: isEditing, compact: true, showsCheck: false))
        .help("Correct what was heard. Corrections train the model on the next export.")
        .accessibilityLabel(isEditing ? "Done" : "Fix")
    }

    private func commitEdit() {
        isEditing = false
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unchanged text is not a correction; clear any earlier label in that case.
        RunLog.setLabel(trimmed == run.text ? nil : trimmed, for: run)
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(run.text, forType: .string)
            didCopy = true
            onCopied()
            Task {
                try? await Task.sleep(for: DS.Motion.copiedHold)
                didCopy = false
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: DS.Icon.regular, weight: .semibold))
        }
        .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
        .help("Copy this transcription")
        .accessibilityLabel(didCopy ? "Copied" : "Copy")
    }

    private var saveButton: some View {
        Button(action: onToggleSave) {
            Image(systemName: run.isSaved ? "bookmark.fill" : "bookmark")
                .font(.system(size: DS.Icon.regular, weight: .semibold))
        }
        .buttonStyle(KeyButtonStyle(kind: .secondary, isSelected: run.isSaved, compact: true, showsCheck: false))
        .help(run.isSaved
            ? "Saved. Click to let this transcription expire after 30 days."
            : "Keep this transcription. Unsaved ones are deleted after 30 days.")
        .accessibilityLabel(run.isSaved ? "Saved" : "Save")
    }

    /// Deletes without a confirmation: a single transcript is cheap to redo, and a dialog
    /// on every row would make tidying up tedious. The irreversible one is "Delete all",
    /// which does confirm.
    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
                .font(.system(size: DS.Icon.regular, weight: .semibold))
        }
        .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
        .help("Delete this transcription")
        .accessibilityLabel("Delete")
    }
}

/// Which dictionary rules fired on a transcript, so you can see which ones earn their place.
/// One badge per rule, original struck through, then what replaced it.
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
                        .font(.system(size: DS.Icon.small, weight: .semibold))
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
                        .strokeBorder(DS.Color.hairline, lineWidth: DS.Stroke.hairline)
                )
            }
            Spacer()
        }
    }
}
