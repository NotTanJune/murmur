import Foundation
import MurmurKit

/// A short-lived log of the keyboard's touches, for finding where fast taps go missing.
///
/// Off unless the owner switches it on in Setup, which sets an expiry `duration` ahead in the
/// shared defaults; the keyboard stops logging by itself when it passes. While on, the keyboard
/// appends one JSON object per line to `typing-diagnostics.jsonl` in the App Group, and
/// `Tools/typing_live_log.py` on the Mac copies that file off the cabled phone about once a
/// second and prints it live. The lines carry the keys typed, which is why it is opt-in, ends on
/// its own, and the file is deleted when the switch goes off.
///
/// Events (`e`): `session` when the keyboard appears, `hit` when UIKit hit-tests the key plane
/// for a touch-down, `began` / `ended` / `cancelled` from the plane, `insert` / `delete` from the
/// typing effects, and `gesture` for a state change of a recognizer between the plane and its
/// window. `t` is `systemUptime`, the clock `UITouch.timestamp` uses.
enum TypingDiagnostics {
    static let defaultsKey = "typingDiagnosticsUntil"
    static let duration: TimeInterval = 600
    static var url: URL { AppStorage.directory.appendingPathComponent("typing-diagnostics.jsonl") }

    /// Writes happen on their own queue so a burst of touches never waits on the disk.
    private static let queue = DispatchQueue(label: "ai.pivotstudio.murmur.typing-diagnostics", qos: .utility)
    nonisolated(unsafe) private static var buffer: [String] = []
    nonisolated(unsafe) private static var flushScheduled = false
    nonisolated(unsafe) private static var enabledUntil: Date?

    /// Whether logging is on now. Read from the cached expiry; `refresh()` re-reads the defaults.
    static var isOn: Bool {
        guard let until = enabledUntil else { return false }
        return Date() < until
    }

    /// Re-reads the switch from the shared defaults. The keyboard calls this at each appearance.
    static func refresh() {
        let raw = MurmurEnvironment.defaults.double(forKey: defaultsKey)
        enabledUntil = raw > 0 ? Date(timeIntervalSince1970: raw) : nil
    }

    // MARK: - The app's switch

    static func turnOn() {
        MurmurEnvironment.defaults.set(Date().addingTimeInterval(duration).timeIntervalSince1970, forKey: defaultsKey)
    }

    static func turnOff() {
        MurmurEnvironment.defaults.removeObject(forKey: defaultsKey)
        try? FileManager.default.removeItem(at: url)
    }

    /// When the switch turns itself off, or nil when it is off already.
    static var expiry: Date? {
        let raw = MurmurEnvironment.defaults.double(forKey: defaultsKey)
        guard raw > 0 else { return nil }
        let until = Date(timeIntervalSince1970: raw)
        return until > Date() ? until : nil
    }

    // MARK: - Logging

    /// Starts a new session: the file is cleared so the live log begins at this appearance.
    static func startSession() {
        refresh()
        guard isOn else { return }
        let line = encode(["e": "session", "t": ProcessInfo.processInfo.systemUptime,
                           "start": ISO8601DateFormatter().string(from: Date())])
        queue.async {
            buffer.removeAll()
            try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Appends one event. Cheap when off: one comparison.
    static func log(_ event: String, _ fields: [String: Any] = [:]) {
        guard isOn else { return }
        var object = fields
        object["e"] = event
        if object["t"] == nil { object["t"] = ProcessInfo.processInfo.systemUptime }
        let line = encode(object)
        queue.async {
            buffer.append(line)
            guard !flushScheduled else { return }
            flushScheduled = true
            queue.asyncAfter(deadline: .now() + 0.3) { flush() }
        }
    }

    private static func flush() {
        flushScheduled = false
        guard !buffer.isEmpty else { return }
        let text = buffer.joined(separator: "\n") + "\n"
        buffer.removeAll()
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }
}
