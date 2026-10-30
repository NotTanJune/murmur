import Darwin
import Foundation

/// `Murmur --residency-check <output-file>`: memory at rest, with both models loaded, and
/// after the idle release, plus how long a reload takes. S1-mini lives in a helper process,
/// so its memory is reported separately and must be gone after release. Diagnostic only;
/// launched with `open` so it runs as the installed app.
@MainActor
enum ResidencyCheck {
    static func run(outputPath: String) async -> Bool {
        var lines: [String] = []
        func emit(_ line: String) {
            print(line)
            lines.append(line)
            try? lines.joined(separator: "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
        }
        func footprint() -> String { String(format: "%.0f MB", ModelResidency.footprintMB()) }
        func settle() async { try? await Task.sleep(for: .seconds(3)) }

        let speech = StreamingModelPreparation.shared
        let cleanup = S1MiniPreparation.shared

        await settle()
        emit("at launch, nothing loaded: app \(footprint()), helpers \(helpers())")

        for round in 1...3 {
            var started = Date()
            await speech.load(.barkClean)?.value
            let bark = Date().timeIntervalSince(started)
            started = Date()
            await cleanup.start()?.value
            let s1 = Date().timeIntervalSince(started)
            guard speech.state(for: .barkClean) == .ready, cleanup.state == .ready else {
                emit("load failed: Bark \(speech.state(for: .barkClean)), S1-mini \(cleanup.state)")
                return false
            }
            started = Date()
            let cleaned = (try? await S1MiniEngine.shared.clean(
                "um so i need the report by friday no wait thursday", profile: .general
            )) ?? "(failed)"
            let clean = Date().timeIntervalSince(started)
            emit(String(
                format: "round %d: Bark load %.2f s, S1-mini helper start %.2f s, cleanup %.0f ms → \"%@\"",
                round, bark, s1, clean * 1000, cleaned
            ))
            await settle()
            emit("round \(round): loaded: app \(footprint()), helpers \(helpers())")

            await ModelResidency.shared.releaseAll()
            await settle()
            emit("round \(round): released: app \(footprint()), helpers \(helpers())")
        }
        return true
    }

    /// Running S1-mini helpers and their resident size, from `ps`.
    private static func helpers() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,rss=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return "?" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let rows = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.contains("--s1-server") }
        guard !rows.isEmpty else { return "none" }
        return rows.map { row in
            let fields = row.split(separator: " ")
            let rss = fields.count > 1 ? (Double(fields[1]) ?? 0) / 1024 : 0
            return String(format: "pid %@ %.0f MB", String(fields.first ?? "?"), rss)
        }.joined(separator: ", ")
    }
}
