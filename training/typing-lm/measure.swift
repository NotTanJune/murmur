// Measures a compiled next-token model on this Mac: load time, prediction latency and what the
// process's physical footprint gains, the number iOS holds against a keyboard extension.
//
//     swiftc -O training/typing-lm/measure.swift -o <dir>/measure
//     <dir>/measure <model.mlmodelc> cpu|ne|all [context 32] [runs 200]
//
// One process is one measurement: the load is the first in the process, and the footprint is
// read before the load, after it and after the predictions, with the process's lifetime peak.
// Token ids are pseudo-random with a fixed seed and `last` varies, so no run repeats another.
import CoreML
import Darwin
import Foundation

func footprint() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
}

func milliseconds(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: measure <model.mlmodelc> cpu|ne|all [context] [runs]")
    exit(2)
}
let url = URL(fileURLWithPath: arguments[1])
let context = arguments.count > 3 ? Int(arguments[3])! : 32
let runs = arguments.count > 4 ? Int(arguments[4])! : 200
let configuration = MLModelConfiguration()
switch arguments[2] {
case "cpu": configuration.computeUnits = .cpuOnly
case "ne": configuration.computeUnits = .cpuAndNeuralEngine
default: configuration.computeUnits = .all
}

let start = footprint()
var model: MLModel!
let load = try milliseconds { model = try MLModel(contentsOf: url, configuration: configuration) }
let loaded = footprint()

var seed: UInt64 = 0x4D75_726D_7572
func next() -> UInt64 {
    seed &+= 0x9E37_79B9_7F4A_7C15
    var z = seed
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}

let ids = try MLMultiArray(shape: [1, NSNumber(value: context)], dataType: .int32)
let last = try MLMultiArray(shape: [1], dataType: .int32)
var best = 0
func predict() throws {
    for index in 0..<context { ids[index] = NSNumber(value: Int32(next() % 40_000) + 1000) }
    last[0] = NSNumber(value: Int32(2 + next() % UInt64(context - 2)))
    let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "last": last])
    let output = try model.prediction(from: input)
    let logp = output.featureValue(for: "logp")!.multiArrayValue!
    // Read the whole answer, as the keyboard does when it maps tokens to words.
    func scan<Value: BinaryFloatingPoint & MLShapedArrayScalar>(_: Value.Type) {
        logp.withUnsafeBufferPointer(ofType: Value.self) { values in
            var top = -Value.infinity
            for (index, value) in values.enumerated() where value > top {
                top = value
                best = index
            }
        }
    }
    if logp.dataType == .float16 { scan(Float16.self) } else { scan(Float.self) }
}

let first = try milliseconds { try predict() }
let afterFirst = footprint()
var times: [Double] = []
for _ in 0..<runs { times.append(try milliseconds { try predict() }) }
times.sort()
let end = footprint()
func percentile(_ p: Double) -> Double { times[min(times.count - 1, Int(Double(times.count) * p))] }
print(String(
    format: "%@ %@ c%d: load %.0f ms, first %.1f ms, p50 %.1f ms, p95 %.1f ms, max %.1f ms | footprint +%.1f MB after load, +%.1f MB after first, +%.1f MB after %d runs, peak +%.1f MB (start %.1f MB)",
    url.lastPathComponent, arguments[2], context, load, first, percentile(0.5), percentile(0.95), times.last!,
    loaded.now - start.now, afterFirst.now - start.now, end.now - start.now, runs, end.peak - start.now, start.now))
