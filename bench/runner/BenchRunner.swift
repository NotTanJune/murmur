import AVFoundation
import Foundation
import Testing
@testable import Murmur

/// The model benchmark's Swift half. `bench/bench.py` writes a job file and runs this
/// target through `swift test` with `MURMUR_BENCH_JOB` set; without it the test is skipped,
/// so `make test` never runs a benchmark.
///
/// The baseline is the current setup: whatever engine, timing, Bark decoder, cleanup and
/// profile the installed app's Settings hold right now, built through the app's own
/// `engine(for:)`. Adopting a candidate in the app therefore makes it the next baseline with
/// no change here. Each candidate runs in place of the current engine with everything else
/// the same, and a `command` candidate (any model the app can't load) contributes only what
/// it heard; its text still goes through the same cleanup and dictionary.
///
/// It reads recordings, the app's settings and dictionary, and writes one JSON file. Nothing
/// is typed, filed in history, labelled or written back to the app's settings.
@Suite struct BenchRunner {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MURMUR_BENCH_JOB"] != nil))
    @MainActor
    func run() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MURMUR_BENCH_JOB"])
        let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let ok = await Bench.run(job)
        #expect(ok)
    }
}

struct Job: Decodable {
    struct Item: Decodable {
        let id: String
        let path: String
    }

    struct Candidate: Decodable {
        let name: String
        /// `parakeet-coreml` (a Parakeet v3-layout Core ML folder) or `command`.
        let kind: String
        let folder: String?
        /// The joint's file name inside `folder`; FluidAudio's generic layout is the default.
        let joint: String?
        /// For `command`: argv, with `{audio}` replaced by a 16 kHz mono WAV of the recording.
        /// It must print the transcript on stdout.
        let command: [String]?
    }

    let items: [Item]
    let candidates: [Candidate]
    let paced: Bool
    let output: String
}

@MainActor
enum Bench {
    struct Outcome: Encodable {
        /// What the engine heard, before any cleanup.
        var heard = ""
        /// What a hold would have typed: cleanup, then the dictionary.
        var typed = ""
        /// The same through the rule pass, whatever cleanup is selected.
        var typedByRules = ""
        /// The engine alone on the whole clip fed at once, release to final text. For a
        /// command, its wall time.
        var decodeSeconds = 0.0
        /// Release to typed text in the hold pass. Meaningful only when paced; nil for a
        /// command, which has no hold.
        var tailSeconds: Double?
        var piecesCleanedWhileHeld = 0
        /// Whether the two passes heard the same words.
        var repeatable = true
        var error: String?
    }

    struct Contender {
        enum Kind {
            case engine(@MainActor () -> any TranscriptionEngine)
            case command([String])
        }

        let name: String
        let label: String
        let kind: Kind
    }

    struct Meta: Encodable {
        let baseline: String
        let contenders: [String: String]
        let cleanup: String
        let paced: Bool
        let started: Date
    }

    struct Row: Encodable {
        let id: String
        let audioSeconds: Double
        let results: [String: Outcome]
    }

    struct Report: Encodable {
        let meta: Meta
        let rows: [Row]
    }

    private struct Hold {
        var text = ""
        var releasedAt = ContinuousClock.now
        var heardSeconds = 0.0
    }

    static let clock = ContinuousClock()

    static func run(_ job: Job) async -> Bool {
        // `Settings.shared` reads `MURMUR_SETTINGS_DOMAIN`, a copy of the installed app's
        // domain made here before anything touches it, so the baseline is the app's current
        // setup and nothing this process sets reaches the app. The copy goes afterwards.
        guard let domain = ProcessInfo.processInfo.environment["MURMUR_SETTINGS_DOMAIN"],
              domain != "ai.pivotstudio.murmur", let copy = UserDefaults(suiteName: domain),
              let app = UserDefaults.standard.persistentDomain(forName: "ai.pivotstudio.murmur") else {
            print("FAIL settings: set MURMUR_SETTINGS_DOMAIN to a scratch domain name (bench.py does)")
            return false
        }
        copy.setPersistentDomain(app, forName: domain)
        defer { copy.removePersistentDomain(forName: domain) }
        print("settings: engine \(Settings.shared.engine.rawValue), timing \(Settings.shared.transcribeTiming.rawValue), "
            + "decoder \(Settings.shared.barkDecoder.rawValue), cleanup \(Settings.shared.cleanupEnabled ? Settings.shared.cleanupEngine.rawValue : "off")")
        linkCompileCache()
        guard let contenders = await prepare(job.candidates) else { return false }

        let settings = Settings.shared
        let cleanupEngine = settings.cleanupEngine
        let profile = settings.cleanupProfile
        let formatter: any TextFormatter = switch cleanupEngine {
        case .rules: RuleBasedFormatter()
        case .s1Mini: S1MiniFormatter(profile: profile)
        case .appleIntelligence: FoundationModelFormatter()
        }
        if settings.cleanupEnabled, cleanupEngine == .s1Mini {
            await S1MiniPreparation.shared.start()?.value
            guard S1MiniPreparation.shared.state == .ready else {
                print("FAIL S1-mini: \(S1MiniPreparation.shared.state.message)")
                return false
            }
        }
        // The controller's condition for cleaning sentences while the key is held.
        let pipelined = settings.cleanupEnabled && cleanupEngine != .rules && profile == .general
        // Loading a model starts the idle timer, and a benchmark has no presses to stop it.
        // An unloaded S1-mini would make every cleanup fall back to the rule pass unnoticed.
        ModelResidency.shared.isBusy = { true }
        let cleanupLabel = settings.cleanupEnabled ? "\(cleanupEngine.displayName) · \(profile.displayName)" : "off"
        print("cleanup: \(cleanupLabel)" + (pipelined ? " · pipelined" : "") + (job.paced ? " · paced at 2× real time" : " · unpaced"))

        let meta = Meta(
            baseline: contenders[0].label,
            contenders: Dictionary(uniqueKeysWithValues: contenders.map { ($0.name, $0.label) }),
            cleanup: cleanupLabel, paced: job.paced, started: Date()
        )
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-bench-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var rows: [Row] = []
        var warmedUp = false
        for (index, item) in job.items.enumerated() {
            var outcomes: [String: Outcome] = [:]
            var audioSeconds = 0.0
            // Alternate the order so no contender always runs straight after another.
            let order = index.isMultiple(of: 2) ? contenders : contenders.reversed()
            if !warmedUp {
                // The first decode on each model and the first cleanup pay one-off costs.
                for contender in contenders {
                    if case .engine(let make) = contender.kind, let chunks = try? await chunks(item.path, for: make()) {
                        _ = try? await hold(make(), chunks: chunks, paced: false, pipeline: nil)
                    }
                }
                _ = await formatter.format("So this is a warm up sentence for the cleanup model, nothing more.")
                warmedUp = true
            }
            for contender in order {
                ModelResidency.shared.wake(engine: settings.engine, cleanup: settings.cleanupEnabled ? cleanupEngine : nil)
                var outcome = Outcome()
                do {
                    switch contender.kind {
                    case .engine(let make):
                        let audio = try await chunks(item.path, for: make())
                        audioSeconds = duration(audio)
                        let alone = try await hold(make(), chunks: audio, paced: false, pipeline: nil)
                        outcome.decodeSeconds = alone.heardSeconds
                        let pipeline = pipelined ? CleanupPipeline(formatter: formatter) : nil
                        let whole = try await hold(make(), chunks: audio, paced: job.paced, pipeline: pipeline)
                        outcome.heard = whole.text
                        outcome.repeatable = whole.text == alone.text
                        outcome.typed = await typed(whole.text, formatter: formatter, pipeline: pipeline)
                        outcome.tailSeconds = seconds(clock.now - whole.releasedAt)
                        outcome.piecesCleanedWhileHeld = pipeline?.chunkCount ?? 0
                    case .command(let argv):
                        let wav = scratch.appendingPathComponent("\(item.id).wav")
                        if !FileManager.default.fileExists(atPath: wav.path) {
                            let audio = try load(item.path, as: monoSixteenK)
                            audioSeconds = duration(audio)
                            try writeWAV(audio, to: wav)
                        }
                        let started = clock.now
                        outcome.heard = try runCommand(argv, audio: wav.path)
                        outcome.decodeSeconds = seconds(clock.now - started)
                        outcome.typed = await typed(outcome.heard, formatter: formatter, pipeline: nil)
                    }
                    outcome.typedByRules = await typed(outcome.heard, formatter: RuleBasedFormatter(), pipeline: nil)
                } catch {
                    outcome.error = error.localizedDescription
                    print("\(item.id) \(contender.name) failed: \(error.localizedDescription)")
                }
                outcomes[contender.name] = outcome
            }
            rows.append(Row(id: item.id, audioSeconds: audioSeconds, results: outcomes))
            let summary = contenders.map { c in
                let o = outcomes[c.name]
                return String(format: "%@ %.2fs", c.name, o?.tailSeconds ?? o?.decodeSeconds ?? 0)
            }.joined(separator: " · ")
            print(String(format: "%d/%d %@ %.1fs · %@", index + 1, job.items.count, String(item.id.prefix(8)), audioSeconds, summary))
            // After every recording, so an interrupted run keeps what it measured.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            do {
                try encoder.encode(Report(meta: meta, rows: rows)).write(to: URL(fileURLWithPath: job.output), options: .atomic)
            } catch {
                print("FAIL write: \(error.localizedDescription)")
                return false
            }
        }
        print(rows.isEmpty ? "FAIL: no recording could be read" : "PASS: \(rows.count) recording(s) → \(job.output)")
        return !rows.isEmpty
    }

    /// The current setup first, then the candidates. Loads every model up front and never
    /// starts a download.
    private static func prepare(_ candidates: [Job.Candidate]) async -> [Contender]? {
        let settings = Settings.shared
        let choice = settings.engine
        if choice.requiresPreparedModel {
            guard choice.isInstalledLocally else {
                print("FAIL baseline: \(choice.displayName) is not confirmed on disk, and the benchmark never downloads")
                return nil
            }
            let started = clock.now
            await StreamingModelPreparation.shared.load(choice)?.value
            guard StreamingModelPreparation.shared.state(for: choice) == .ready else {
                print("FAIL load \(choice.displayName): \(StreamingModelPreparation.shared.state(for: choice).message)")
                return nil
            }
            print(String(format: "current: %@ ready in %.2fs", choice.displayName, seconds(clock.now - started)))
        }
        var label = choice.displayName
        if choice == .barkClean, settings.barkDecoder != .stock { label += " · decoder \(settings.barkDecoder.rawValue)" }
        var contenders = [Contender(name: "current", label: label, kind: .engine { engine(for: choice) })]

        let streaming = settings.transcribeTiming == .whileSpeaking
        for candidate in candidates {
            guard candidate.name != "current", !contenders.contains(where: { $0.name == candidate.name }) else {
                print("FAIL candidate name \(candidate.name) is taken")
                return nil
            }
            switch candidate.kind {
            case "parakeet-coreml":
                guard let folder = candidate.folder else {
                    print("FAIL \(candidate.name): parakeet-coreml needs a folder")
                    return nil
                }
                let models = ParakeetModels(source: .folder(URL(fileURLWithPath: folder), joint: candidate.joint ?? "JointDecision.mlmodelc"))
                let started = clock.now
                do {
                    _ = try await models.manager()
                } catch {
                    print("FAIL load \(candidate.name): \(error.localizedDescription)")
                    return nil
                }
                print(String(format: "%@ ready in %.2fs", candidate.name, seconds(clock.now - started)))
                contenders.append(Contender(
                    name: candidate.name,
                    label: "\(candidate.name) (\(streaming ? "streaming" : "batch"))",
                    kind: .engine { () -> any TranscriptionEngine in
                        streaming ? IncrementalParakeetEngine(models: models) : ParakeetEngine(models: models)
                    }
                ))
            case "command":
                guard let argv = candidate.command, !argv.isEmpty, argv.contains(where: { $0.contains("{audio}") }) else {
                    print("FAIL \(candidate.name): a command needs argv with an {audio} placeholder")
                    return nil
                }
                contenders.append(Contender(name: candidate.name, label: "\(candidate.name) (command, whole clip)", kind: .command(argv)))
            default:
                print("FAIL \(candidate.name): unknown kind \(candidate.kind)")
                return nil
            }
        }
        return contenders
    }

    /// One hold as the controller consumes it: stable text feeds the cleanup pipeline while
    /// audio arrives, and the final chunk is the transcript.
    private static func hold(
        _ engine: any TranscriptionEngine, chunks: [AudioChunk], paced: Bool, pipeline: CleanupPipeline?
    ) async throws -> Hold {
        let stream = try await engine.start()
        let consumer = Task { @MainActor in
            var final = ""
            for try await chunk in stream {
                if chunk.isFinal {
                    final = chunk.text
                } else if let stable = chunk.stable {
                    pipeline?.accept(stable: stable)
                }
            }
            return final
        }
        var hold = Hold()
        for chunk in chunks {
            await engine.feed(chunk)
            if paced {
                // Twice real time.
                let chunkSeconds = Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
                try? await Task.sleep(for: .seconds(chunkSeconds / 2))
            }
        }
        hold.releasedAt = clock.now
        await engine.finish()
        hold.text = try await consumer.value
        hold.heardSeconds = seconds(clock.now - hold.releasedAt)
        return hold
    }

    /// The controller's delivery steps: cleanup (through the pipeline when one ran), then
    /// the dictionary.
    private static func typed(_ heard: String, formatter: any TextFormatter, pipeline: CleanupPipeline?) async -> String {
        guard !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pipeline?.cancel()
            return ""
        }
        let cleaned: String
        if !Settings.shared.cleanupEnabled {
            cleaned = heard
        } else if let pipeline {
            cleaned = await pipeline.finish(transcript: heard) { await formatter.format(heard) }
        } else {
            cleaned = await formatter.format(heard)
        }
        return DictionaryStore.shared.corrector.apply(to: cleaned).text
    }

    private static func runCommand(_ argv: [String], audio: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv.map { $0.replacingOccurrences(of: "{audio}", with: audio) }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TranscriptionError.modelInstallFailed("command exited with \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Audio

    static let monoSixteenK = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// The recording in the format the engine asks capture for, in 100 ms chunks.
    private static func chunks(_ path: String, for engine: any TranscriptionEngine) async throws -> [AudioChunk] {
        guard let format = await engine.preferredInputFormat() else { throw TranscriptionError.noAudioFormat }
        return try load(path, as: format)
    }

    private static func load(_ path: String, as target: AVAudioFormat) throws -> [AudioChunk] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TranscriptionError.noAudioFormat
        }
        try file.read(into: source)
        let capacity = AVAudioFrameCount(Double(file.length) * target.sampleRate / file.processingFormat.sampleRate) + 1_024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw TranscriptionError.noAudioFormat }
        var consumed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if let conversionError { throw conversionError }

        let step = Int(target.sampleRate / 10)
        let total = Int(converted.frameLength)
        let channels = Int(target.channelCount)
        var chunks: [AudioChunk] = []
        var offset = 0
        while offset < total {
            let count = min(step, total - offset)
            guard let piece = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(count)) else { break }
            piece.frameLength = AVAudioFrameCount(count)
            if let from = converted.floatChannelData, let to = piece.floatChannelData {
                for channel in 0..<channels { to[channel].update(from: from[channel] + offset, count: count) }
            } else if let from = converted.int16ChannelData, let to = piece.int16ChannelData {
                for channel in 0..<channels { to[channel].update(from: from[channel] + offset, count: count) }
            } else {
                throw TranscriptionError.noAudioFormat
            }
            chunks.append(AudioChunk(buffer: piece))
            offset += count
        }
        return chunks
    }

    private static func writeWAV(_ chunks: [AudioChunk], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        for chunk in chunks { try file.write(from: chunk.buffer) }
    }

    private static func duration(_ chunks: [AudioChunk]) -> Double {
        chunks.reduce(0) { $0 + Double($1.buffer.frameLength) / $1.buffer.format.sampleRate }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: - Compile cache

    /// Core ML keeps compiled Neural Engine programs under `~/Library/Caches/<process>/`,
    /// which macOS may purge. Measured 2026-11-20: this test process can't use what the app
    /// compiled (Bark compiled again for 99 s with the app's cache linked), so the runner
    /// keeps its own cache in Application Support, away from the app's, the same way
    /// `CompileCacheGuard` keeps the app's.
    private static func linkCompileCache() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let identity = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let link = caches.appendingPathComponent(identity, isDirectory: true)
            .appendingPathComponent(CompileCacheGuard.cacheName, isDirectory: true)
        do {
            let safe = AppStorage.directory.appendingPathComponent("Benchmarks/ane-cache", isDirectory: true)
            let action = try CompileCacheGuard.ensure(link: link, safe: safe)
            print("compile cache (\(identity)): \(action.rawValue)")
        } catch {
            print("compile cache link failed, models may recompile: \(error.localizedDescription)")
        }
    }
}
