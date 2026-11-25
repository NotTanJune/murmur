import MurmurDesign
import ObjectiveC
import MurmurKit
import SwiftUI
import UIKit

/// A temporary bench for comparing keyboards on the same sentence in the same field.
///
/// Each field has autocorrection, spell checking, capitals and smart punctuation off, so what
/// arrives is what the keyboard typed. Every change is appended to `typing-lab.jsonl` in the App
/// Group with the field's name, the keyboard that typed it, the time and the field's whole text, and
/// `Tools/typing_live_log.py`'s sibling pull reads it on the Mac. Added 2026-11-25 to find out
/// whether Murmur's keyboard loses taps that Apple's does not; remove it once that is settled.
/// The first run typed all three fields with Murmur's keyboard, so each field now names the
/// keyboard it sees when that is not the one it is for.
struct TypingLab: View {
    static let sentence = "a quick brown fox jumps over the lazy dog"
    /// Each field's name and the keyboard it is for.
    static let fields: [(name: String, keyboard: String)] = [
        ("Apple", "Apple"), ("Murmur", "Murmur"), ("Gboard", "Gboard"), ("Murmur quiet", "Murmur"),
    ]
    static let quietNote = "Before this one: Settings tab, turn off Keep microphone ready and Haptics. Turn them back on after."

    @State private var cleared = 0
    /// The keyboard each field last saw, by field name.
    @State private var keyboards: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Note(text: "Type this in each field with that keyboard, three times, fast, without correcting: \(Self.sentence)")
            ForEach(Self.fields, id: \.name) { field in
                let name = field.name
                VStack(alignment: .leading, spacing: DS.Space.snug) {
                    Text(name)
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                    if name != field.keyboard { Note(text: Self.quietNote) }
                    LabField(name: name) { keyboards[name] = $0 }
                        .id("\(name)-\(cleared)")
                        .frame(height: DS.Control.recordSize)
                        .padding(.horizontal, DS.Space.base)
                        .background(DS.Color.chrome, in: .rect(cornerRadius: DS.Radius.control))
                    if let keyboard = keyboards[name], keyboard != field.keyboard {
                        Text("This is the \(keyboard) keyboard. Hold the globe key and pick \(field.keyboard).")
                            .font(DS.Font.bodyEmphasis)
                            .foregroundStyle(DS.Color.ink)
                    }
                }
            }
            Button("Clear the fields and the log") {
                TypingLabLog.clear()
                cleared += 1
            }
            .font(DS.Font.body)
        }
        .onAppear { LabTouchSpy.install() }
        .onDisappear { LabTouchSpy.field = nil }
    }
}

/// A plain `UITextField` with every text aid off, reporting each change.
private struct LabField: UIViewRepresentable {
    let name: String
    /// Called with the name of the keyboard showing for this field, whenever it changes.
    let onKeyboard: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(name: name, onKeyboard: onKeyboard) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.inlinePredictionType = .no
        field.font = UIFont.systemFont(ofSize: UIFont.labelFontSize)
        field.accessibilityLabel = "\(name) typing lab field"
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.addTarget(context.coordinator, action: #selector(Coordinator.began(_:)), for: .editingDidBegin)
        context.coordinator.watch(field)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {}

    final class Coordinator: NSObject {
        let name: String
        let onKeyboard: (String) -> Void
        private weak var field: UITextField?
        private var keyboard = ""

        init(name: String, onKeyboard: @escaping (String) -> Void) {
            self.name = name
            self.onKeyboard = onKeyboard
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @MainActor func watch(_ field: UITextField) {
            self.field = field
            NotificationCenter.default.addObserver(
                self, selector: #selector(modeChanged),
                name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
        }

        @MainActor @objc func began(_ field: UITextField) {
            LabTouchSpy.field = name
            noteKeyboard(field)
        }

        @MainActor @objc func modeChanged() {
            guard let field, field.isFirstResponder else { return }
            noteKeyboard(field)
        }

        @MainActor @objc func changed(_ field: UITextField) {
            noteKeyboard(field)
            TypingLabLog.append(field: name, keyboard: keyboard, text: field.text ?? "")
        }

        @MainActor private func noteKeyboard(_ field: UITextField) {
            let current = Self.keyboardName(field.textInputMode)
            guard current != keyboard else { return }
            keyboard = current
            onKeyboard(current)
        }

        /// Which keyboard an input mode is. `identifier` is not public API: this is for the lab
        /// alone, on the owner's phone, and goes when the lab does. Apple's modes read like
        /// "en_US@sw=QWERTY", an extension's is its bundle identifier.
        @MainActor private static func keyboardName(_ mode: UITextInputMode?) -> String {
            guard let mode else { return "Unknown" }
            let selector = NSSelectorFromString("identifier")
            let identifier = mode.responds(to: selector) ? (mode.value(forKey: "identifier") as? String ?? "") : ""
            if identifier.contains("ai.pivotstudio.murmur") { return "Murmur" }
            if identifier.contains("com.google") { return "Gboard" }
            if NSStringFromClass(type(of: mode)).contains("Extension") { return "Another" }
            return "Apple"
        }
    }
}

/// The lab's log file: one JSON object per change.
enum TypingLabLog {
    static var url: URL { AppStorage.directory.appendingPathComponent("typing-lab.jsonl") }
    private static let queue = DispatchQueue(label: "ai.pivotstudio.murmur.typing-lab", qos: .utility)

    static func append(field: String, keyboard: String, text: String) {
        write(["field": field, "kb": keyboard, "t": ProcessInfo.processInfo.systemUptime, "text": text])
    }

    static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        queue.async {
            let line = data + Data("\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }

    static func clear() {
        queue.async { try? FileManager.default.removeItem(at: url) }
    }
}

/// Watches every touch this app's own windows are sent while a lab field is being typed in, and
/// logs each one as a `spy` line. A third-party keyboard runs in its own process, so its key
/// presses should never show here; one that does was routed to the app instead of the keyboard,
/// which is one place a tap the keyboard never received could have gone. `UIWindow.sendEvent`
/// is swizzled once, for the lab alone, and goes when the lab does.
@MainActor
enum LabTouchSpy {
    private static var installed = false
    /// The lab field being typed in, or nil when none is.
    static var field: String?

    static func install() {
        guard !installed else { return }
        installed = true
        let original = #selector(UIWindow.sendEvent(_:))
        let spy = #selector(UIWindow.murmurLab_sendEvent(_:))
        guard let originalMethod = class_getInstanceMethod(UIWindow.self, original),
              let spyMethod = class_getInstanceMethod(UIWindow.self, spy)
        else { return }
        method_exchangeImplementations(originalMethod, spyMethod)
    }
}

extension UIWindow {
    @objc dynamic func murmurLab_sendEvent(_ event: UIEvent) {
        if let field = LabTouchSpy.field, event.type == .touches, let touches = event.allTouches {
            for touch in touches where touch.phase == .began {
                let point = touch.location(in: self)
                TypingLabLog.write([
                    "spy": String(describing: type(of: self)), "field": field, "t": touch.timestamp,
                    "view": touch.view.map { String(describing: type(of: $0)) } ?? "nil",
                    "x": Double(point.x), "y": Double(point.y), "h": Double(bounds.height),
                ])
            }
        }
        // After the swizzle this name holds the original implementation.
        murmurLab_sendEvent(event)
    }
}
