import MurmurDesign
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
    static let fields = ["Apple", "Murmur"]

    @State private var cleared = 0
    /// The keyboard each field last saw, by field name.
    @State private var keyboards: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Note(text: "Type this in each field with that keyboard, three times, fast, without correcting: \(Self.sentence)")
            ForEach(Self.fields, id: \.self) { name in
                VStack(alignment: .leading, spacing: DS.Space.snug) {
                    Text(name)
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                    LabField(name: name) { keyboards[name] = $0 }
                        .id("\(name)-\(cleared)")
                        .frame(height: DS.Control.recordSize)
                        .padding(.horizontal, DS.Space.base)
                        .background(DS.Color.chrome, in: .rect(cornerRadius: DS.Radius.control))
                    if let keyboard = keyboards[name], keyboard != name {
                        Text("This is the \(keyboard) keyboard. Hold the globe key and pick \(name).")
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

        @MainActor @objc func began(_ field: UITextField) { noteKeyboard(field) }

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
        let object: [String: Any] = [
            "field": field, "kb": keyboard, "t": ProcessInfo.processInfo.systemUptime, "text": text,
        ]
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
