import MurmurDesign
import MurmurKit
import SwiftUI
import UIKit

/// A temporary bench for comparing keyboards on the same sentence in the same field.
///
/// Each field has autocorrection, spell checking, capitals and smart punctuation off, so what
/// arrives is what the keyboard typed. Every change is appended to `typing-lab.jsonl` in the App
/// Group with the field's name, the time and the field's whole text, and
/// `Tools/typing_live_log.py`'s sibling pull reads it on the Mac. Added 2026-11-25 to find out
/// whether Murmur's keyboard loses taps that Apple's does not; remove it once that is settled.
struct TypingLab: View {
    static let sentence = "a quick brown fox jumps over the lazy dog"
    static let fields = ["Apple", "Murmur", "Gboard"]

    @State private var cleared = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Note(text: "Type this in each field with that keyboard, three times, fast, without correcting: \(Self.sentence)")
            ForEach(Self.fields, id: \.self) { name in
                VStack(alignment: .leading, spacing: DS.Space.snug) {
                    Text(name)
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                    LabField(name: name)
                        .id("\(name)-\(cleared)")
                        .frame(height: DS.Control.recordSize)
                        .padding(.horizontal, DS.Space.base)
                        .background(DS.Color.chrome, in: .rect(cornerRadius: DS.Radius.control))
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

    func makeCoordinator() -> Coordinator { Coordinator(name: name) }

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
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {}

    final class Coordinator: NSObject {
        let name: String
        init(name: String) { self.name = name }

        @MainActor @objc func changed(_ field: UITextField) {
            TypingLabLog.append(field: name, text: field.text ?? "")
        }
    }
}

/// The lab's log file: one JSON object per change.
enum TypingLabLog {
    static var url: URL { AppStorage.directory.appendingPathComponent("typing-lab.jsonl") }
    private static let queue = DispatchQueue(label: "ai.pivotstudio.murmur.typing-lab", qos: .utility)

    static func append(field: String, text: String) {
        let object: [String: Any] = [
            "field": field, "t": ProcessInfo.processInfo.systemUptime, "text": text,
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
