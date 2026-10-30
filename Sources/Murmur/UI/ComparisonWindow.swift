import SwiftUI

/// Live-updating store behind the comparison window.
///
/// The window replaced a generated HTML file opened in the browser. That approach needed a
/// `file://` URL, spawned a fresh tab on every open, and left stale tabs showing old data
/// with no way to tell which was current. A window owned by the app has none of those
/// problems: one instance, always live, nothing to refresh.
@MainActor
@Observable
final class RunStore {
    static let shared = RunStore()

    private(set) var runs: [DictationRun] = []

    private init() { RunLog.refresh() }

    /// Asks the history queue to republish. The file is read once, in the background.
    func reload() {
        RunLog.refresh()
    }

    /// Called by `RunLog` on the main queue, in the order its changes were made.
    func apply(_ snapshot: [DictationRun]) {
        runs = snapshot
    }

    /// Recordings grouped by comparison, newest first.
    var comparisons: [[DictationRun]] {
        Dictionary(grouping: runs.filter { $0.group != nil }, by: { $0.group! })
            .values
            .sorted { ($0.first?.date ?? .distantPast) > ($1.first?.date ?? .distantPast) }
    }

    var singles: [DictationRun] {
        runs.filter { $0.group == nil }.reversed()
    }
}

struct ComparisonWindow: View {
    @Bindable var controller: DictationController
    @State private var store = RunStore.shared
    @State private var settings = Settings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.wide) {
                header
                recordBar

                if store.runs.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(store.comparisons.enumerated()), id: \.offset) { _, group in
                        ComparisonCard(runs: group)
                    }
                    ForEach(Array(store.singles.enumerated()), id: \.offset) { _, run in
                        SingleCard(run: run)
                    }
                }
            }
            .padding(DS.Space.wide)
            .padding(.trailing, DS.Brutal.lift)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(PaperBackground().ignoresSafeArea())
        .frame(minWidth: DS.Window.comparisonMinWidth, minHeight: DS.Window.comparisonMinHeight)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Text("Engine comparison")
                    .font(DS.Font.display)
                    .foregroundStyle(DS.Color.ink)
                Eyebrow(text: "\(store.runs.count) recording\(store.runs.count == 1 ? "" : "s")")
            }
            Spacer()
            if !store.runs.isEmpty {
                Button("Clear") { RunLog.clear() }
                    .buttonStyle(BrutalButtonStyle())
            }
        }
    }

    /// One button that records every engine at once — no hotkeys, and the results appear in
    /// this same window, so there's nowhere to go afterwards to read them.
    private var recordBar: some View {
        let isRecording = controller.state.isActive

        return HStack(spacing: DS.Space.roomy) {
            RecordButton(isRecording: isRecording) {
                if isRecording {
                    controller.stopButtonRecording()
                } else {
                    controller.startButtonRecording()
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Eyebrow(
                    text: isRecording ? "Recording" : "Record all engines",
                    color: isRecording ? DS.Color.record : DS.Color.inkSecondary
                )
                Text(statusLine(isRecording: isRecording))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(DS.Space.roomy)
        .outlinedGlass()
    }

    private func statusLine(isRecording: Bool) -> String {
        if isRecording { return "Click stop when you're done talking." }
        if !controller.transcript.isEmpty { return controller.transcript }
        return WisprReader.isInstalled
            ? "Click record, talk, click stop. Apple, Parakeet and Wispr Flow all hear it."
            : "Click record, talk, click stop. Wispr Flow isn't installed, so it's Apple vs Parakeet."
    }

    private var emptyState: some View {
        EmptyPanel(
            label: "Hold \(settings.pushToTalkKey.displayName), say a sentence, let go.",
            detail: settings.compareMode
                ? "Every engine runs on that one recording and appears here."
                : "Turn on Compare mode in the menu bar to see the engines side by side."
        )
        .padding(.top, DS.Space.wide)
    }
}

private struct ComparisonCard: View {
    let runs: [DictationRun]

    /// Fastest first. The engines are *measured* sequentially, so arrival order reflects
    /// which ran first, not which is quicker — sorting by measured time is what makes the
    /// winner readable at a glance.
    private var ranked: [DictationRun] {
        runs.sorted { $0.processSeconds < $1.processSeconds }
    }

    /// How much faster the winner was, once both are in.
    private var margin: String? {
        guard runs.count > 1,
              let best = ranked.first,
              let worst = ranked.last,
              best.processSeconds > 0
        else { return nil }
        let ratio = worst.processSeconds / best.processSeconds
        let delta = worst.processSeconds - best.processSeconds
        guard delta > 0.005 else { return "tied" }
        return String(format: "%@ %.1f× faster · %.2fs ahead", best.engine, ratio, delta)
    }

    /// Case and punctuation are normalized away: Apple auto-punctuates and Parakeet
    /// doesn't, and that's a formatting difference, not a recognition error.
    private var verdict: (text: String, agrees: Bool) {
        if Set(runs.map(\.text)).count == 1 { return ("identical", true) }
        let normalized = Set(runs.map {
            $0.text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        })
        return normalized.count == 1 ? ("same words", true) : ("words differ", false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack(spacing: DS.Space.snug) {
                Text(runs.first.map { "\($0.date.formatted(date: .omitted, time: .standard)) · held \($0.audioSeconds, format: .number.precision(.fractionLength(1)))s" } ?? "")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                Spacer()
                Tag(text: verdict.text, isHighlighted: verdict.agrees)

                // Deletes the whole group: every engine here transcribed one utterance, so
                // removing that utterance means removing all of its rows together.
                if let group = runs.first?.group {
                    Button {
                        withAnimation(DS.Motion.panel) { RunLog.deleteGroup(group) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: DS.Icon.regular, weight: .bold))
                    }
                    .buttonStyle(BrutalButtonStyle(compact: true))
                    .help("Delete this comparison")
                    .accessibilityLabel("Delete comparison")
                }
            }
            if let margin {
                HStack(spacing: DS.Space.tight) {
                    Image(systemName: margin == "tied" ? "equal" : "bolt.fill")
                    Text(margin)
                }
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            } else if runs.count == 1 {
                HStack(spacing: DS.Space.tight) {
                    ProgressView().controlSize(.small)
                    Text("running second engine…")
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
            }

            Rectangle().fill(DS.Color.ink).frame(height: DS.Brutal.border)

            ForEach(Array(ranked.enumerated()), id: \.offset) { index, run in
                EngineRow(run: run, rank: index + 1, showRank: runs.count > 1)
            }
        }
        .padding(DS.Space.roomy)
        .brutalSurface()
    }
}

private struct EngineRow: View {
    let run: DictationRun
    let rank: Int
    let showRank: Bool

    private var isWinner: Bool { showRank && rank == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            HStack(alignment: .firstTextBaseline) {
                Tag(text: run.engine + (isWinner ? " · fastest" : ""), isHighlighted: isWinner)
                Spacer()
                Text("\(run.processSeconds, format: .number.precision(.fractionLength(2)))s")
                    .font(isWinner ? DS.Font.counterLarge : DS.Font.counter)
                    .foregroundStyle(DS.Color.ink)
            }
            Text("\(run.realtimeFactor, format: .number.precision(.fractionLength(0)))× realtime · \(run.characters) chars")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
            Text(run.text.isEmpty ? "(nothing recognized)" : run.text)
                .font(DS.Font.body)
                .foregroundStyle(run.text.isEmpty ? DS.Color.inkSecondary : DS.Color.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DS.Space.tight)
    }
}

private struct SingleCard: View {
    let run: DictationRun

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack {
                Tag(text: run.engine)
                Spacer()
                Text("\(run.processSeconds, format: .number.precision(.fractionLength(2)))s")
                    .font(DS.Font.counter)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            Text(run.text)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.roomy)
        .brutalSurface(radius: DS.Radius.control, lift: DS.Brutal.liftSmall)
    }
}
