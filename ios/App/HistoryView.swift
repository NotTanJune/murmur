import MurmurDesign
import MurmurDictionary
import MurmurKit
import SwiftUI
import UIKit

/// The second tab: every dictation on this iPhone, newest first, with the audio, the Save
/// chip and the correction editor that feed the training loop.
struct HistoryView: View {
    @State private var store = RunStore.shared
    @State private var player = RunAudioPlayer.shared
    @State private var editing: DictationRun?
    @State private var deleting: DictationRun?
    @State private var toast: String?

    private var days: [(day: Date, runs: [DictationRun])] {
        var result: [(day: Date, runs: [DictationRun])] = []
        for run in store.singles {
            let day = Calendar.current.startOfDay(for: run.date)
            if let last = result.indices.last, result[last].day == day {
                result[last].runs.append(run)
            } else {
                result.append((day, [run]))
            }
        }
        return result
    }

    var body: some View {
        PhonePage(title: "History") {
            if let failure = player.failure {
                Note(text: failure)
            }
            if store.singles.isEmpty {
                EmptyPanel(
                    label: "Hold the key and speak.",
                    highlight: "speak",
                    detail: "Switch to the Murmur keyboard in any text field."
                )
            } else {
                ForEach(days, id: \.day) { group in
                    VStack(alignment: .leading, spacing: DS.Space.snug) {
                        Eyebrow(text: title(for: group.day))
                        ForEach(group.runs) { run in
                            RunRow(
                                run: run,
                                isPlaying: player.playingID == run.id,
                                onPlay: { player.toggle(run) },
                                onCopy: {
                                    UIPasteboard.general.string = TrainingLabel.displayText(run)
                                    showToast("Copied")
                                },
                                onEdit: { editing = run },
                                onToggleSave: { RunLog.setSaved(!run.isSaved, for: run) },
                                onDelete: { deleting = run }
                            )
                        }
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) {
            if let toast {
                Toast(text: toast)
                    .padding(.bottom, DS.Phone.toastInset)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .sheet(item: $editing) { run in
            RunEditor(run: run)
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { run in
            Button("Delete", role: .destructive) {
                if player.playingID == run.id { player.stop() }
                withAnimation(DS.Motion.panel) { RunLog.delete(run) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its audio and any correction go with it. This can't be undone.")
        }
        .onAppear { store.reload() }
        .onDisappear { player.stop() }
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

/// One dictation as a card: the text, its corrections, a quiet line of facts, and the actions.
private struct RunRow: View {
    let run: DictationRun
    let isPlaying: Bool
    let onPlay: () -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onToggleSave: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Text(TrainingLabel.displayText(run))
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .lineLimit(DS.Phone.rowTextLines)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let corrections = run.corrections, !corrections.isEmpty {
                CorrectionBadges(corrections: corrections)
            }

            metadata

            actions
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .contain)
    }

    /// Engine, cleanup, time and latency on one quiet line.
    private var metadata: some View {
        HStack(spacing: DS.Space.snug) {
            Text(([run.engine] + (run.cleanup.map { [$0] } ?? [])).joined(separator: " · "))
                .lineLimit(1)
            Text(run.date, style: .time)
            Text(String(format: "%.2fs", run.displayedLatency))
                .monospacedDigit()
            if run.label != nil {
                Tag(text: "Labelled", isHighlighted: true)
            }
        }
        .font(DS.Font.caption)
        .foregroundStyle(DS.Color.inkSecondary)
    }

    private var actions: some View {
        HStack(spacing: DS.Space.snug) {
            if run.hasAudio {
                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: DS.Icon.regular, weight: .semibold))
                }
                .buttonStyle(KeyButtonStyle(kind: .secondary, isSelected: isPlaying, compact: true, showsCheck: false))
                .accessibilityLabel(isPlaying ? "Stop" : "Play recording")
            }
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: DS.Icon.regular, weight: .semibold))
            }
            .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
            .accessibilityLabel("Copy")
            if TrainingLabel.editAllowed(run) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: DS.Icon.regular, weight: .semibold))
                }
                .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
                .accessibilityLabel("Fix")
            }
            Button(action: onToggleSave) {
                Image(systemName: run.isSaved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: DS.Icon.regular, weight: .semibold))
            }
            .buttonStyle(KeyButtonStyle(kind: .secondary, isSelected: run.isSaved, compact: true, showsCheck: false))
            .accessibilityLabel(run.isSaved ? "Saved" : "Save")
            .accessibilityHint(run.isSaved
                ? "Lets this recording expire after 30 days."
                : "Keeps this recording past 30 days.")
            Spacer(minLength: 0)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: DS.Icon.regular, weight: .semibold))
            }
            .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
            .accessibilityLabel("Delete")
        }
    }
}

/// Which dictionary rules fired on a transcript. One badge per rule: the original struck
/// through, then what replaced it.
private struct CorrectionBadges: View {
    let corrections: [AppliedCorrection]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
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
        }
    }
}
