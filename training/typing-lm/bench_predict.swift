// Times the keyboard's whole prediction path on this Mac, outside SwiftPM: tokenize, the Core ML
// pass, and the token-to-word mapping, as `NextWordPredictor.predict` does them, in a release
// build. `measure.swift` times the model alone.
//
//     swiftc -O -parse-as-library training/typing-lm/bench_predict.swift Sources/MurmurTyping/Predict/*.swift \
//         Sources/MurmurTyping/Lexicon/TypingModel.swift -o <dir>/bench_predict
//     <dir>/bench_predict ios/TypingLM Sources/MurmurTyping/Resources/en.mtm \
//         training/typing-lm/eval-sentences.tsv
//
// The first 505 word boundaries of the evaluation entries are each predicted once.
import Darwin
import Foundation

/// `TypingModel.bundled()` reads this in the package; here the model is opened by path.
enum TypingResources {
    static var modelURL: URL? { nil }
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return Double(info.phys_footprint) / 1_048_576
}

@main
enum BenchPredict {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            print("usage: bench_predict <TypingLM folder> <en.mtm> <eval-sentences.tsv>")
            exit(2)
        }
        guard let files = NextWordPredictor.Files(folder: URL(fileURLWithPath: arguments[1])) else {
            print("no model in \(arguments[1])")
            exit(1)
        }
        let start = footprintMB()
        let words = try TypingModel(url: URL(fileURLWithPath: arguments[2]))
        var clock = ContinuousClock.now
        let predictor = try NextWordPredictor(files: files, words: words)
        let load = (ContinuousClock.now - clock) / .milliseconds(1)
        let loaded = footprintMB()

        var boundaries: [String] = []
        for line in try String(contentsOfFile: arguments[3], encoding: .utf8).split(separator: "\n")
        where !line.hasPrefix("#") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            var text = ""
            for word in line[line.index(after: tab)...].split(separator: " ") {
                boundaries.append(text)
                text += word + " "
            }
            if boundaries.count > 500 { break }
        }

        var times: [Double] = []
        var checksum = 0
        for boundary in boundaries {
            clock = ContinuousClock.now
            let answer = try predictor.predict(before: boundary)
            times.append((ContinuousClock.now - clock) / .milliseconds(1))
            checksum &+= answer.best.first?.id ?? 0
        }
        let first = times[0]
        times.sort()
        func percentile(_ p: Double) -> Double { times[min(times.count - 1, Int(Double(times.count) * p))] }
        print(String(
            format: "predict(): load %.0f ms (model, tokenizer, word tables), first %.1f ms, p50 %.2f ms, p95 %.2f ms, max %.1f ms over %d boundaries | footprint +%.1f MB after load, +%.1f MB after all (%d predictable words, checksum %d)",
            load, first, percentile(0.5), percentile(0.95), times[times.count - 1], times.count, loaded - start,
            footprintMB() - start, predictor.predictableWordCount, checksum))
    }
}
