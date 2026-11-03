import AVFoundation
import Foundation

/// `Murmur --decoder-check <slot-folder> <audio-file>`: transcribes the file with the stock
/// decoder pair and with the given fine-tuned pair over the same encoder, and prints both.
/// Installs the folder into the custom slot first (verifying it), so it is a real import test.
@MainActor
enum DecoderCheck {
    static func run(slot: String, path: String) async -> Bool {
        let source = URL(fileURLWithPath: slot)
        let name: String
        do {
            name = try CustomDecoderSlot.importFolder(source, baseRevision: BarkModelStore.revision)
        } catch {
            print("FAIL import: \(error.localizedDescription)")
            return false
        }
        let chunks: [AudioChunk]
        do { chunks = try IncrementalCheck.load(path) } catch {
            print("FAIL audio: \(error.localizedDescription)")
            return false
        }
        var texts: [String] = []
        for (label, models) in [("stock", ParakeetModels.stockBarkClean), ("fine-tuned \(name)", ParakeetModels.custom(name))] {
            let engine = ParakeetEngine(models: models)
            do {
                let stream = try await engine.start()
                let started = Date()
                for chunk in chunks { await engine.feed(chunk) }
                await engine.finish()
                var text = ""
                for try await chunk in stream where chunk.isFinal { text = chunk.text }
                print(String(format: "%@: %.2fs", label, Date().timeIntervalSince(started)))
                print("  " + text)
                texts.append(text)
            } catch {
                print("FAIL \(label): \(error.localizedDescription)")
                return false
            }
        }
        let a = texts[0].split(whereSeparator: \.isWhitespace), b = texts[1].split(whereSeparator: \.isWhitespace)
        let changed = zip(a, b).filter { $0 != $1 }.count + abs(a.count - b.count)
        print("words differing: \(changed)")
        print("PASS")
        return true
    }
}
