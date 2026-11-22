import CoreHaptics
import Foundation
import MurmurKit
import OSLog

// TEMPORARY: part of the Haptic Lab. Delete with `ios/App/HapticLabView.swift` and
// `ios/Shared/HapticPlayer.swift` once the user has picked their patterns and they are
// hard-coded in `KeyboardHaptics`. See AGENTS.md ("Haptic lab").

/// One haptic event: a tap (`hapticTransient`) or a buzz (`hapticContinuous`).
struct HapticEvent: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case tap, buzz
    }

    /// Identity for the lab's list only; not stored.
    var id = UUID()
    var kind: Kind
    /// Start offset from the pattern's start, in milliseconds.
    var timeMs: Int
    var intensity: Double
    var sharpness: Double
    /// Buzz only; ignored for a tap.
    var durationMs: Int

    private enum CodingKeys: String, CodingKey {
        case kind, timeMs, intensity, sharpness, durationMs
    }

    static let timeRangeMs = 0...1000
    static let durationRangeMs = 10...600
    static let timeStepMs = 10
    static let levelStep = 0.05

    init(kind: Kind, timeMs: Int, intensity: Double, sharpness: Double, durationMs: Int = 100) {
        self.kind = kind
        self.timeMs = timeMs
        self.intensity = intensity
        self.sharpness = sharpness
        self.durationMs = durationMs
        self = normalized()
    }

    /// Clamped and rounded to what the lab's controls can produce, so the copied text
    /// reproduces the stored value exactly.
    func normalized() -> HapticEvent {
        var copy = self
        copy.timeMs = Self.snap(timeMs, step: Self.timeStepMs, range: Self.timeRangeMs)
        copy.durationMs = Self.snap(durationMs, step: Self.timeStepMs, range: Self.durationRangeMs)
        copy.intensity = Self.level(intensity)
        copy.sharpness = Self.level(sharpness)
        return copy
    }

    private static func snap(_ value: Int, step: Int, range: ClosedRange<Int>) -> Int {
        let rounded = Int((Double(value) / Double(step)).rounded()) * step
        return min(max(rounded, range.lowerBound), range.upperBound)
    }

    private static func level(_ value: Double) -> Double {
        let rounded = (value / levelStep).rounded() * levelStep
        return (min(max(rounded, 0), 1) * 100).rounded() / 100
    }

    /// `tap@0 i0.70 s0.50` or `buzz@40 i0.40 s0.20 d120`.
    var text: String {
        let base = "\(kind.rawValue)@\(timeMs) i\(String(format: "%.2f", intensity)) s\(String(format: "%.2f", sharpness))"
        return kind == .buzz ? base + " d\(durationMs)" : base
    }

    /// The end of the event, in milliseconds.
    var endMs: Int { kind == .buzz ? timeMs + durationMs : timeMs }
}

/// An ordered list of events, played together from one start.
struct HapticPattern: Codable, Hashable, Sendable {
    var events: [HapticEvent]

    init(events: [HapticEvent] = []) {
        self.events = events
    }

    /// Events in time order; ties keep their list order.
    var sorted: HapticPattern {
        HapticPattern(events: events.enumerated()
            .sorted { ($0.element.timeMs, $0.offset) < ($1.element.timeMs, $1.offset) }
            .map(\.element))
    }

    /// Human readable and exactly reproducible: `tap@0 i0.70 s0.50 | buzz@40 i0.40 s0.20 d120`,
    /// in time order. An empty pattern reads `none`.
    var text: String {
        events.isEmpty ? "none" : sorted.events.map(\.text).joined(separator: " | ")
    }

    /// The Core Haptics pattern. Throws when the pattern is empty or Core Haptics refuses it.
    func coreHapticsPattern() throws -> CHHapticPattern {
        let events = sorted.events.map { event -> CHHapticEvent in
            let parameters = [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(event.intensity)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(event.sharpness)),
            ]
            let time = TimeInterval(event.timeMs) / 1000
            switch event.kind {
            case .tap:
                return CHHapticEvent(eventType: .hapticTransient, parameters: parameters, relativeTime: time)
            case .buzz:
                return CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: parameters,
                    relativeTime: time,
                    duration: TimeInterval(event.durationMs) / 1000
                )
            }
        }
        return try CHHapticPattern(events: events, parameters: [])
    }
}

/// Which of the two lab patterns.
enum HapticSlot: String, CaseIterable, Sendable {
    case start, done

    var title: String { self == .start ? "Start" : "Done" }
    fileprivate var key: String { self == .start ? HapticLabStore.startKey : HapticLabStore.doneKey }
}

/// The lab's patterns and switch, kept in the shared defaults so the app edits them and the
/// keyboard reads them at play time.
enum HapticLabStore {
    static let startKey = "hapticLabStart"
    static let doneKey = "hapticLabDone"
    static let activeKey = "hapticLabActive"

    private static let log = Logger(subsystem: "ai.pivotstudio.murmur", category: "speech")

    static var isActive: Bool {
        get { MurmurEnvironment.defaults.bool(forKey: activeKey) }
        set { MurmurEnvironment.defaults.set(newValue, forKey: activeKey) }
    }

    /// The stored pattern, or nil when none was saved or it does not decode.
    static func load(_ slot: HapticSlot) -> HapticPattern? {
        guard let data = MurmurEnvironment.defaults.data(forKey: slot.key) else { return nil }
        do {
            return try JSONDecoder().decode(HapticPattern.self, from: data)
        } catch {
            log.error("haptic lab: cannot decode \(slot.rawValue, privacy: .public) pattern: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func save(_ pattern: HapticPattern, as slot: HapticSlot) {
        do {
            MurmurEnvironment.defaults.set(try JSONEncoder().encode(pattern), forKey: slot.key)
        } catch {
            log.error("haptic lab: cannot encode \(slot.rawValue, privacy: .public) pattern: \(error.localizedDescription, privacy: .public)")
        }
    }
}
