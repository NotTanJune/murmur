import CoreML
import Foundation
import MurmurKit
import UIKit
import os

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
    /// Runs `race` instead: the language model beside a Bark load, in this process.
    static let raceArgument = "--typing-lm-bark-race"
    static let raceResultName = "typing-lm-bark-race.json"
    /// Read by the typing lab: focus its Murmur field at launch, so the keyboard comes up.
    static let focusArgument = "--typing-lab-focus"

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
        if arguments.contains(raceArgument) {
            Task.detached(priority: .userInitiated) { await race() }
            return
        }
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

    // MARK: - The model beside a Bark load

    /// Temporary (2026-11-26). In the keyboard the model's load took 104.75 s, ending with
    /// Bark's 105.83 s Neural Engine compile, and 0.64 s here with nothing else loading. This
    /// reproduces the two together in the app, where no typing is needed, and asks the two
    /// questions the keyboard's fix rests on: does a model load that starts during Bark's load
    /// wait for it (`secondLoad`), and does a model that loaded first keep answering while Bark
    /// loads (`samples`, one prediction every half second)? Bark compiles for the Neural Engine
    /// only when this process's cache is cold, so `barkSeconds` says whether the run tested
    /// that: a load of a second or two tested nothing.
    ///
    /// The one run (2026-11-26, iPhone 15 Pro): Bark took 84.1 s, the model answered all 160
    /// times, median 5.8 ms and slowest 12.1 ms, and the second load returned in 1 ms. That
    /// second load was of a model this process had already compiled and loaded, so it says
    /// nothing about a first load, which is the one that waited in the keyboard.
    private static func race() async {
        let model = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("MurmurKeyboard.appex/TypingLM/NextWord.mlmodelc")
        let target = AppStorage.directory.appendingPathComponent(raceResultName)
        var report: [String: Any] = ["done": false]
        func write() {
            let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: target, options: .atomic)
        }
        guard let model, FileManager.default.fileExists(atPath: model.path), BarkModelStore.isDownloaded else {
            report["error"] = "the model or Bark is not on this phone"
            report["done"] = true
            write()
            return
        }
        write()
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuOnly
            var clock = ContinuousClock.now
            let first = try MLModel(contentsOf: model, configuration: configuration)
            report["firstLoadSeconds"] = (ContinuousClock.now - clock) / .seconds(1)
            let window = first.modelDescription.inputDescriptionsByName["input_ids"]?
                .multiArrayConstraint?.shape.last?.intValue ?? 32
            let question = questions[0].ids
            let ids = try MLMultiArray(shape: [1, NSNumber(value: window)], dataType: .int32)
            for index in 0..<window { ids[index] = NSNumber(value: index < question.count ? question[index] : 0) }
            let last = try MLMultiArray(shape: [1], dataType: .int32)
            last[0] = NSNumber(value: Int32(question.count - 1))
            let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "last": last])
            // A function that is not async, so the call is the blocking prediction the keyboard
            // makes and not `MLModel`'s async one.
            func ask() throws { _ = try first.prediction(from: input) }
            clock = ContinuousClock.now
            try ask()
            report["firstPredictionMs"] = (ContinuousClock.now - clock) / .milliseconds(1)
            write()

            let started = ContinuousClock.now
            let barkDone = OSAllocatedUnfairLock(initialState: false)
            async let bark: (seconds: Double, error: String?) = {
                var failure: String?
                do { _ = try await ParakeetModels.barkClean.loadedModels() } catch { failure = String(describing: error) }
                barkDone.withLock { $0 = true }
                return ((ContinuousClock.now - started) / .seconds(1), failure)
            }()
            async let second: (at: Double, seconds: Double, error: String?) = {
                try? await Task.sleep(for: .seconds(2))
                let at = (ContinuousClock.now - started) / .seconds(1)
                let began = ContinuousClock.now
                var failure: String?
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .cpuOnly
                do { _ = try MLModel(contentsOf: model, configuration: configuration) } catch {
                    failure = String(describing: error)
                }
                return (at, (ContinuousClock.now - began) / .seconds(1), failure)
            }()

            var samples: [[Double]] = []
            while !barkDone.withLock({ $0 }), samples.count < 600 {
                let at = (ContinuousClock.now - started) / .seconds(1)
                clock = ContinuousClock.now
                try ask()
                samples.append([at, (ContinuousClock.now - clock) / .milliseconds(1)])
                if samples.count % 10 == 0 {
                    report["samples"] = samples
                    write()
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            let barkResult = await bark
            let secondLoad = await second
            report["samples"] = samples
            report["barkSeconds"] = barkResult.seconds
            if let error = barkResult.error { report["barkError"] = error }
            report["secondLoad"] = ["startedAt": secondLoad.at, "seconds": secondLoad.seconds, "error": secondLoad.error ?? ""]
        } catch {
            report["error"] = String(describing: error)
        }
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = false }
        report["done"] = true
        write()
    }
}
