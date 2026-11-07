import SwiftUI

/// Feeds the comparison window, which updates live without a manual refresh.
@MainActor @Observable
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

    /// The comparison groups, newest first.
    var comparisons: [[DictationRun]] {
        var order: [String] = []
        var groups: [String: [DictationRun]] = [:]
        for run in runs {
            guard let group = run.group else { continue }
            if groups[group] == nil { order.append(group) }
            groups[group, default: []].append(run)
        }
        return order
            .compactMap { groups[$0] }
            .sorted { ($0.first?.date ?? .distantPast) > ($1.first?.date ?? .distantPast) }
    }

    /// Recordings made outside a comparison, newest first. Storage is oldest first.
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
                    ForEach(store.comparisons, id: \.first?.id) { runs in
                        ComparisonCard(runs: runs)
                    }
                    ForEach(store.singles, id: \.id) { run in
                        SingleCard(run: run)
                    }
                }
            }
            .padding(DS.Space.wide)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Color.pane.ignoresSafeArea())
        .frame(minWidth: DS.Window.comparisonMinWidth, minHeight: DS.Window.comparisonMinHeight)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Text("Engine comparison")
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                Eyebrow(text: "\(store.runs.count) recording\(store.runs.count == 1 ? "" : "s")")
            }
            Spacer()
            if !store.runs.isEmpty {
                Button("Clear") { RunLog.clear() }
                    .buttonStyle(KeyButtonStyle(kind: .secondary))
            }
        }
    }

    /// One button starts every engine at once, no hotkeys, and the results land in this
    /// window. `isActive` rather than `isRecording` keeps it showing stop through finishing.
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
        .cardSurface()
    }

    private func statusLine(isRecording: Bool) -> String {
        if isRecording { return "Click stop when you're done talking." }
        // During a comparison the controller writes its progress here, then the transcript.
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

    /// Wispr's row is timed differently from the rest (see `margin`), so it stays out of
    /// the ranking.
    private func isComparable(_ run: DictationRun) -> Bool {
        run.engine != WisprReader.engineName
    }

    private var comparableRuns: [DictationRun] {
        runs.filter { isComparable($0) }
    }

    /// Ordered by measured time, not arrival, since the engines run one after another.
    /// Wispr Flow's row, when present, comes last.
    private var ranked: [DictationRun] {
        comparableRuns.sorted { $0.processSeconds < $1.processSeconds }
            + runs.filter { !isComparable($0) }
    }

    /// The winner's lead, defined once at least two comparable engines have reported. The
    /// Wispr Flow time is a different measure (its own end-to-end latency, including a
    /// network round trip and cloud cleanup) and is left out.
    private var margin: String? {
        let times = comparableRuns.sorted { $0.processSeconds < $1.processSeconds }
        guard times.count >= 2, let fastest = times.first, let slowest = times.last,
              fastest.processSeconds > 0 else { return nil }
        let ratio = slowest.processSeconds / fastest.processSeconds
        let delta = slowest.processSeconds - fastest.processSeconds
        if delta <= 0.005 { return "tied" }
        return "\(fastest.engine) is \(String(format: "%.1f", ratio))x faster, "
            + "\(String(format: "%.2f", delta))s ahead"
    }

    /// Texts are compared ignoring case and punctuation, because engines format differently
    /// (Apple punctuates, batch Parakeet does not) and that is not a recognition difference.
    private var verdict: (text: String, agrees: Bool) {
        if Set(runs.map(\.text)).count == 1 { return ("identical", true) }
        let normalized: Set<String> = Set(runs.map { run in
            run.text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .joined(separator: " ")
        })
        return normalized.count == 1 ? ("same words", true) : ("words differ", false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack(spacing: DS.Space.snug) {
                Text(runs.first.map {
                    "\($0.date.formatted(date: .omitted, time: .standard)) · "
                        + "\(String(format: "%.1f", $0.audioSeconds))s"
                } ?? "")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                Spacer()
                Tag(text: verdict.text, isHighlighted: verdict.agrees)

                // Deletes every row at once: the rows are one utterance seen by different engines.
                if let group = runs.first?.group {
                    Button {
                        withAnimation(DS.Motion.panel) { RunLog.deleteGroup(group) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: DS.Icon.regular, weight: .semibold))
                    }
                    .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
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
                    Text("The next engine is still running")
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
            }

            Rectangle().fill(DS.Color.divider).frame(height: DS.Stroke.hairline)

            ForEach(Array(ranked.enumerated()), id: \.element.id) { index, run in
                EngineRow(
                    run: run,
                    rank: index + 1,
                    showRank: isComparable(run) && comparableRuns.count >= 2
                )
            }
        }
        .padding(DS.Space.roomy)
        .cardSurface()
    }
}

private struct EngineRow: View {
    let run: DictationRun
    let rank: Int
    let showRank: Bool

    private var isWinner: Bool { showRank && rank == 1 }

    /// Wispr's time is its own end-to-end figure, not compute time, so it gets no
    /// real-time multiple.
    private var detail: String {
        if run.engine == WisprReader.engineName {
            return "Wispr's own end-to-end time, with network and cleanup · \(run.characters) characters"
        }
        return "\(String(format: "%.0f", run.realtimeFactor))x realtime · \(run.characters) characters"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            HStack(alignment: .firstTextBaseline) {
                Tag(text: run.engine + (isWinner ? " · fastest" : ""), isHighlighted: isWinner)
                Spacer()
                Text("\(String(format: "%.2f", run.processSeconds))s")
                    .font(isWinner ? DS.Font.counterLarge : DS.Font.counter)
                    .foregroundStyle(DS.Color.ink)
            }
            Text(detail)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
            Text(run.text.isEmpty ? "Nothing recognized" : run.text)
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
                Text("\(String(format: "%.2f", run.processSeconds))s")
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
        .cardSurface()
    }
}
