import MurmurDesign
import MurmurKit
import OSLog
import SwiftUI
import UIKit

// TEMPORARY: the Haptic Lab. The user designs a start and a done pattern by feel, copies the
// text and sends it back; the chosen patterns are then hard-coded in `KeyboardHaptics` and
// this file, `Shared/HapticPattern.swift`, `Shared/HapticPlayer.swift`, the Settings row and the
// keyboard hook are deleted. See AGENTS.md ("Haptic lab").

/// The starting points offered for either pattern.
private struct HapticPreset: Identifiable {
    let name: String
    let events: [HapticEvent]
    var id: String { name }

    static let all: [HapticPreset] = [
        HapticPreset(name: "Current start", events: [
            HapticEvent(kind: .tap, timeMs: 0, intensity: 0.7, sharpness: 0.5),
        ]),
        HapticPreset(name: "Current done", events: [
            HapticEvent(kind: .tap, timeMs: 0, intensity: 0.8, sharpness: 0.6),
            HapticEvent(kind: .tap, timeMs: 100, intensity: 0.8, sharpness: 0.6),
        ]),
        HapticPreset(name: "Rising", events: [
            HapticEvent(kind: .buzz, timeMs: 0, intensity: 0.3, sharpness: 0.2, durationMs: 60),
            HapticEvent(kind: .buzz, timeMs: 70, intensity: 0.5, sharpness: 0.3, durationMs: 60),
            HapticEvent(kind: .buzz, timeMs: 140, intensity: 0.7, sharpness: 0.4, durationMs: 60),
            HapticEvent(kind: .tap, timeMs: 210, intensity: 0.9, sharpness: 0.7),
        ]),
        HapticPreset(name: "Heartbeat", events: [
            HapticEvent(kind: .tap, timeMs: 0, intensity: 0.9, sharpness: 0.4),
            HapticEvent(kind: .tap, timeMs: 120, intensity: 0.6, sharpness: 0.3),
        ]),
        HapticPreset(name: "Soft tick", events: [
            HapticEvent(kind: .tap, timeMs: 0, intensity: 0.4, sharpness: 0.9),
        ]),
    ]
}

/// The lab's two patterns and the keyboard switch. Every change is saved to the shared defaults.
@MainActor
@Observable
private final class HapticLabModel {
    var start: HapticPattern { didSet { HapticLabStore.save(start, as: .start) } }
    var done: HapticPattern { didSet { HapticLabStore.save(done, as: .done) } }
    var isActive: Bool { didSet { HapticLabStore.isActive = isActive } }

    init() {
        start = HapticLabStore.load(.start) ?? HapticPattern(events: HapticPreset.all[0].events)
        done = HapticLabStore.load(.done) ?? HapticPattern(events: HapticPreset.all[1].events)
        isActive = HapticLabStore.isActive
    }

    func pattern(_ slot: HapticSlot) -> HapticPattern {
        slot == .start ? start : done
    }

    func binding(_ slot: HapticSlot) -> Binding<HapticPattern> {
        Binding(
            get: { self.pattern(slot) },
            set: { if slot == .start { self.start = $0 } else { self.done = $0 } }
        )
    }

    /// `start: ...` and `done: ...`, one per line.
    func text(_ slot: HapticSlot) -> String {
        "\(slot.rawValue): \(pattern(slot).text)"
    }

    var bothText: String {
        HapticSlot.allCases.map(text).joined(separator: "\n")
    }
}

struct HapticLabView: View {
    @State private var model = HapticLabModel()
    @State private var player = HapticPlayer()
    @State private var failure: String?
    @State private var toast: String?

    var body: some View {
        PhonePage(title: "Haptic lab") {
            Card {
                ToggleRow(
                    title: "Use these in the keyboard",
                    note: "When on, the keyboard plays these patterns instead of the built-in start and done haptics. Haptics must also be on in Settings.",
                    isOn: $model.isActive
                )
                if !HapticPlayer.isSupported {
                    Note(text: "This device reports no Core Haptics support, so nothing here will play.", color: DS.Color.record)
                }
                if let failure {
                    Note(text: failure, color: DS.Color.record)
                }
            }

            ForEach(HapticSlot.allCases, id: \.self) { slot in
                HapticSection(
                    slot: slot,
                    pattern: model.binding(slot),
                    onPlay: { play(slot) },
                    onCopy: { copy(model.text(slot)) }
                )
            }

            Card(title: "Pattern text") {
                Text(model.bothText)
                    .font(DS.Font.counter)
                    .foregroundStyle(DS.Color.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy both") { copy(model.bothText) }
                    .buttonStyle(KeyButtonStyle(kind: .secondary))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Toast(text: toast)
                    .padding(.bottom, DS.Phone.toastInset)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { player.prepare() }
    }

    private func play(_ slot: HapticSlot) {
        let ok = player.play(model.pattern(slot))
        failure = ok ? nil : "Playback failed. Check the log (category speech) for the Core Haptics error."
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        withAnimation(DS.Motion.panel) { toast = "Copied" }
        Task {
            try? await Task.sleep(for: DS.Motion.copiedHold)
            withAnimation(DS.Motion.panel) { toast = nil }
        }
    }
}

/// One pattern's editor: presets, the timeline, the events, Play and Copy.
private struct HapticSection: View {
    let slot: HapticSlot
    @Binding var pattern: HapticPattern
    let onPlay: () -> Void
    let onCopy: () -> Void

    var body: some View {
        Card(title: slot.title) {
            presets
            HapticTimeline(pattern: pattern)

            ForEach($pattern.events) { $event in
                HapticEventRow(
                    event: $event,
                    index: pattern.events.firstIndex(where: { $0.id == event.id }).map { $0 + 1 } ?? 0,
                    onDelete: { pattern.events.removeAll { $0.id == event.id } }
                )
            }

            HStack(spacing: DS.Space.snug) {
                Button("Add tap") { add(.tap) }
                Button("Add buzz") { add(.buzz) }
                Button("Sort by time") { pattern = pattern.sorted }
            }
            .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))

            Button(action: onPlay) {
                HStack(spacing: DS.Space.snug) {
                    Image(systemName: "play.fill")
                    Text("Play \(slot.rawValue)")
                }
                .font(DS.Font.heading)
                .foregroundStyle(DS.Color.onPrimary)
                .frame(maxWidth: .infinity, minHeight: DS.Phone.hapticPlayHeight)
                .background(DS.Color.primary, in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .disabled(pattern.events.isEmpty)

            Button("Copy \(slot.rawValue)", action: onCopy)
                .buttonStyle(KeyButtonStyle(kind: .secondary))
        }
    }

    private var presets: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.snug) {
                ForEach(HapticPreset.all) { preset in
                    Button(preset.name) {
                        pattern = HapticPattern(events: preset.events.map {
                            // A fresh identity per use, so two lists never share rows.
                            HapticEvent(
                                kind: $0.kind, timeMs: $0.timeMs, intensity: $0.intensity,
                                sharpness: $0.sharpness, durationMs: $0.durationMs
                            )
                        })
                    }
                    .buttonStyle(KeyButtonStyle(kind: .secondary, compact: true))
                }
            }
        }
    }

    private func add(_ kind: HapticEvent.Kind) {
        let last = pattern.events.map(\.endMs).max() ?? -HapticEvent.timeStepMs * 10
        pattern.events.append(HapticEvent(
            kind: kind,
            timeMs: last + HapticEvent.timeStepMs * 10,
            intensity: 0.7,
            sharpness: 0.5
        ))
    }
}

/// One event: its kind, time, intensity and sharpness, and its duration when it is a buzz.
private struct HapticEventRow: View {
    @Binding var event: HapticEvent
    let index: Int
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Divider().overlay(DS.Color.divider)
            HStack {
                Eyebrow(text: "Event \(index)")
                Spacer()
                ChoiceKeys(options: HapticEvent.Kind.allCases, selection: $event.kind, title: { $0.rawValue.capitalized })
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: DS.Icon.large))
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete event \(index)")
            }
            HapticSlider(
                label: "Time",
                value: Binding(get: { Double(event.timeMs) }, set: { event.timeMs = Int($0) }),
                range: Double(HapticEvent.timeRangeMs.lowerBound)...Double(HapticEvent.timeRangeMs.upperBound),
                step: Double(HapticEvent.timeStepMs),
                display: "\(event.timeMs) ms"
            )
            HapticSlider(
                label: "Intensity",
                value: $event.intensity, range: 0...1, step: HapticEvent.levelStep,
                display: String(format: "%.2f", event.intensity)
            )
            HapticSlider(
                label: "Sharpness",
                value: $event.sharpness, range: 0...1, step: HapticEvent.levelStep,
                display: String(format: "%.2f", event.sharpness)
            )
            if event.kind == .buzz {
                HapticSlider(
                    label: "Duration",
                    value: Binding(get: { Double(event.durationMs) }, set: { event.durationMs = Int($0) }),
                    range: Double(HapticEvent.durationRangeMs.lowerBound)...Double(HapticEvent.durationRangeMs.upperBound),
                    step: Double(HapticEvent.timeStepMs),
                    display: "\(event.durationMs) ms"
                )
            }
        }
    }
}

private struct HapticSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: String

    var body: some View {
        HStack(spacing: DS.Space.base) {
            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .frame(width: DS.Phone.hapticValueWidth, alignment: .leading)
            Slider(value: $value, in: range, step: step)
                .tint(DS.Color.stat)
            Text(display)
                .font(DS.Font.counter)
                .foregroundStyle(DS.Color.ink)
                .frame(width: DS.Phone.hapticValueWidth, alignment: .trailing)
        }
    }
}

/// A tick per tap and a bar per buzz, height = intensity, on a plain shape layout with no
/// state of its own.
private struct HapticTimeline: View {
    let pattern: HapticPattern

    private var spanMs: Double {
        let end = max(pattern.events.map(\.endMs).max() ?? 0, DS.Phone.hapticStripMinSpanMs)
        let step = DS.Phone.hapticStripSpanStepMs
        return Double((end + step - 1) / step * step)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(DS.Color.field)
                ForEach(pattern.events) { event in
                    let x = proxy.size.width * Double(event.timeMs) / spanMs
                    let width = event.kind == .buzz
                        ? max(proxy.size.width * Double(event.durationMs) / spanMs, DS.Phone.hapticTickWidth)
                        : DS.Phone.hapticTickWidth
                    RoundedRectangle(cornerRadius: DS.Phone.hapticTickWidth / 2)
                        .fill(event.kind == .buzz ? DS.Color.stat.opacity(DS.Phone.hapticBuzzOpacity) : DS.Color.ink)
                        .frame(width: width, height: proxy.size.height * event.intensity)
                        .offset(x: min(x, proxy.size.width - width))
                }
            }
        }
        .frame(height: DS.Phone.hapticStripHeight)
        .clipShape(.rect(cornerRadius: DS.Radius.control, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Timeline, \(pattern.events.count) events over \(Int(spanMs)) milliseconds")
    }
}
