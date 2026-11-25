import CoreML
import Foundation
import MurmurKit

/// Temporary (2026-11-25): runs the keyboard's language model inside the app on the phone and
/// writes what it returned to `typing-lm-selftest.json` in the App Group, so the Mac can read it
/// with `devicectl`. Remove with the typing lab before any TestFlight build.
///
/// Why: on the owner's phone the keyboard reported the model `ready` at 17 ms a prediction while
/// the strip showed only the pair model's words. The code between the model and the strip reads
/// right, so the question is whether Core ML returns usable numbers on the phone's processor.
/// This asks the model the same three questions the Mac was asked and records the raw answer:
/// how many values are numbers, the largest, and the five likeliest tokens.
///
/// Launch the app with `--typing-lm-selftest` to test the model in the keyboard's bundle, or
/// follow the argument with a folder name inside the App Group's storage folder to test a
/// compiled model pushed there.
enum PredictionSelfTest {
    static let argument = "--typing-lm-selftest"
    static let resultName = "typing-lm-selftest.json"

    /// Token ids from the reference tokenizer (`bpe-vectors.json`), with the start token in front.
    private static let questions: [(name: String, ids: [Int32])] = [
        ("my dog", [50256, 1820, 3290]),
        ("I am", [50256, 40, 716]),
        ("The quick brown fox jumps over the lazy dog.", [50256, 464, 2068, 7586, 21831, 18045, 625, 262, 16931, 3290, 13]),
    ]

    private static let units: [(name: String, value: MLComputeUnits)] = [
        ("cpuOnly", .cpuOnly), ("cpuAndGPU", .cpuAndGPU), ("cpuAndNeuralEngine", .cpuAndNeuralEngine),
    ]

    static func runIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let at = arguments.firstIndex(of: argument) else { return }
        let folder = at + 1 < arguments.count ? arguments[at + 1] : nil
        DispatchQueue.global(qos: .userInitiated).async { run(folder: folder) }
    }

    private static func run(folder: String?) {
        let model: URL? =
            if let folder {
                AppStorage.directory.appendingPathComponent(folder)
            } else {
                Bundle.main.builtInPlugInsURL?
                    .appendingPathComponent("MurmurKeyboard.appex/TypingLM/NextWord.mlmodelc")
            }
        var report: [String: Any] = ["model": model?.lastPathComponent ?? "none", "folder": folder ?? "bundle"]
        var runs: [[String: Any]] = []
        func write(done: Bool) {
            report["runs"] = runs
            report["done"] = done
            let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: AppStorage.directory.appendingPathComponent(resultName), options: .atomic)
        }
        guard let model, FileManager.default.fileExists(atPath: model.path) else {
            report["error"] = "no model at \(model?.path ?? "nil")"
            write(done: true)
            return
        }
        write(done: false)
        for unit in units {
            var entry: [String: Any] = ["units": unit.name]
            do {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = unit.value
                var clock = ContinuousClock.now
                let loaded = try MLModel(contentsOf: model, configuration: configuration)
                entry["loadMs"] = (ContinuousClock.now - clock) / .milliseconds(1)
                let window = loaded.modelDescription.inputDescriptionsByName["input_ids"]?
                    .multiArrayConstraint?.shape.last?.intValue ?? 32
                var answers: [[String: Any]] = []
                for question in questions {
                    let ids = try MLMultiArray(shape: [1, NSNumber(value: window)], dataType: .int32)
                    for index in 0..<window {
                        ids[index] = NSNumber(value: index < question.ids.count ? question.ids[index] : 0)
                    }
                    let last = try MLMultiArray(shape: [1], dataType: .int32)
                    last[0] = NSNumber(value: Int32(question.ids.count - 1))
                    clock = ContinuousClock.now
                    let output = try loaded.prediction(
                        from: MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "last": last]))
                    var answer: [String: Any] = [
                        "question": question.name, "ms": (ContinuousClock.now - clock) / .milliseconds(1),
                    ]
                    if let logp = output.featureValue(for: "logp")?.multiArrayValue {
                        answer["type"] = logp.dataType.rawValue
                        answer["count"] = logp.count
                        var values: [Float] = []
                        values.reserveCapacity(logp.count)
                        for index in 0..<logp.count { values.append(logp[index].floatValue) }
                        let numbers = values.filter { $0.isFinite }
                        answer["finite"] = numbers.count
                        answer["nan"] = values.filter { $0.isNaN }.count
                        answer["max"] = numbers.max().map { Double($0) } ?? "none"
                        answer["probabilitySum"] = Double(numbers.reduce(Float(0)) { $0 + exp($1) })
                        answer["top"] = values.indices.filter { values[$0].isFinite }
                            .sorted { values[$0] > values[$1] }.prefix(5).map { [$0, Double(values[$0])] as [Any] }
                    } else {
                        answer["error"] = "no logp in the output"
                    }
                    answers.append(answer)
                }
                entry["answers"] = answers
            } catch {
                entry["error"] = String(describing: error)
            }
            runs.append(entry)
            write(done: false)
        }
        write(done: true)
    }
}
