import AVFoundation
import Darwin
import Foundation

/// `Murmur --mic-benchmark <output-file>`: what an always-open microphone would cost.
///
/// Measures this process and `coreaudiod` (which does the device I/O for every open mic)
/// over three equal windows: microphone closed, open on the SoloCast, open on the built-in
/// mic. While open, capture runs exactly as an always-on mode would: converted to 16 kHz
/// and kept in a rolling one-second buffer in memory. Diagnostic only; launched with
/// `open`, so the microphone grant is Murmur's own.
@MainActor
enum MicBenchmark {
    static let settle: Duration = .seconds(3)
    static var window: Double = 40

    struct Sample {
        let label: String
        let seconds: Double
        let processCPU: Double
        let coreaudiodCPU: Double?
        let footprintMB: Double
        let wakeupsPerSecond: Double
    }

    static func run(outputPath: String, window override: Double? = nil) async -> Bool {
        if let override { window = override }
        var lines: [String] = []
        func emit(_ line: String) {
            print(line)
            lines.append(line)
            try? lines.joined(separator: "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
        }

        emit("mic benchmark · \(Int(window)) s per window, \(settle) settle")
        emit("devices: \(MicrophonePolicy.inputDevices().map(\.name).joined(separator: ", "))")

        var results: [Sample] = []
        try? await Task.sleep(for: settle)
        results.append(await measure("mic closed", capture: nil))

        let devices = MicrophonePolicy.inputDevices()
        let soloCast = devices.first { $0.name.localizedCaseInsensitiveContains("SoloCast") }
        let builtIn = devices.first(where: \.isBuiltIn)
        for (label, device) in [("open · SoloCast", soloCast), ("open · built-in", builtIn)] {
            guard let device else {
                emit("\(label): device not connected, skipped")
                continue
            }
            let capture = AudioCapture()
            capture.forcedDevice = device
            let ring = Ring(capacity: 16_000)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            do {
                try capture.start(outputFormat: format, onBuffer: { ring.append($0) }, onLevel: { _ in })
            } catch {
                emit("\(label): capture failed: \(error.localizedDescription)")
                return false
            }
            try? await Task.sleep(for: settle)
            results.append(await measure(label, capture: capture))
            capture.stop()
            emit("\(label): \(ring.total) samples captured (\(String(format: "%.1f", Double(ring.total) / 16_000)) s of audio)")
            try? await Task.sleep(for: settle)
        }

        emit("")
        emit("window            | Murmur CPU | audio daemons CPU | footprint | wakeups/s")
        for sample in results {
            let core = sample.coreaudiodCPU.map { String(format: "%6.2f %%", $0) } ?? "   n/a"
            emit(String(
                format: "%-17@ | %8.2f %% | %17@ | %6.1f MB | %8.0f",
                sample.label as NSString, sample.processCPU, core as NSString, sample.footprintMB, sample.wakeupsPerSecond
            ))
        }
        return true
    }

    /// One window: CPU as a percentage of one core, averaged over the window.
    private static func measure(_ label: String, capture: AudioCapture?) async -> Sample {
        let start = Date()
        let cpu0 = processCPUSeconds()
        let core0 = coreaudiodCPUSeconds()
        let wake0 = wakeups()
        try? await Task.sleep(for: .seconds(window))
        let elapsed = Date().timeIntervalSince(start)
        let coreCPU: Double? = if let core0, let core1 = coreaudiodCPUSeconds() {
            (core1 - core0) / elapsed * 100
        } else { nil }
        _ = capture
        return Sample(
            label: label,
            seconds: elapsed,
            processCPU: (processCPUSeconds() - cpu0) / elapsed * 100,
            coreaudiodCPU: coreCPU,
            footprintMB: footprintMB(),
            wakeupsPerSecond: Double(wakeups() - wake0) / elapsed
        )
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private static func wakeups() -> UInt64 {
        var info = task_power_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.task_interrupt_wakeups + info.task_platform_idle_wakeups : 0
    }

    /// The system audio daemons: `coreaudiod` (device I/O for every open mic) and
    /// `usbaudiod` (the USB audio driver behind the SoloCast). They run as another user, so
    /// their CPU time comes from `ps`, summed.
    private static func coreaudiodCPUSeconds() -> Double? {
        guard let output = run("/bin/ps", ["-axo", "time=,comm="]) else { return nil }
        var total: Double?
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1)
            guard fields.count == 2,
                  fields[1].hasSuffix("/coreaudiod") || fields[1].hasSuffix("/usbaudiod")
            else { continue }
            // [[h:]m:]s.cc
            let seconds = fields[0].split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
            total = (total ?? 0) + seconds
        }
        return total
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// A one-second rolling buffer, as an always-on mode would keep.
    private final class Ring: @unchecked Sendable {
        private var samples: [Float]
        private var index = 0
        private let lock = NSLock()
        private(set) var total = 0

        init(capacity: Int) { samples = Array(repeating: 0, count: capacity) }

        func append(_ chunk: AudioChunk) {
            guard let data = chunk.buffer.floatChannelData?[0] else { return }
            let count = Int(chunk.buffer.frameLength)
            lock.lock()
            for i in 0..<count {
                samples[index] = data[i]
                index = (index + 1) % samples.count
            }
            total += count
            lock.unlock()
        }
    }
}
