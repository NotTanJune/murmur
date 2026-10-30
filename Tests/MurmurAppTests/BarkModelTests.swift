import AVFoundation
import Foundation
import Testing
@testable import Murmur

struct BarkModelTests {
    @Test("Quotation-mark <unk> tokens are removed without leaving stray spacing")
    func unkStripping() {
        #expect(ParakeetEngine.cleanTranscript("He said <unk>ship it<unk> today.") == "He said ship it today.")
        #expect(ParakeetEngine.cleanTranscript("Call it <unk> , then stop.") == "Call it, then stop.")
        #expect(ParakeetEngine.cleanTranscript("  plain text  ") == "plain text")
    }

    @Test("The manifest pins one revision and covers every component FluidAudio needs")
    func manifest() {
        #expect(BarkModelStore.revision.count == 40)
        let paths = Set(BarkModelStore.files.map(\.path))
        #expect(paths.count == BarkModelStore.files.count)
        for component in ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"] {
            #expect(paths.contains("\(component).mlmodelc/weights/weight.bin"))
            #expect(paths.contains("\(component).mlmodelc/model.mil"))
            #expect(paths.contains("\(component).mlmodelc/coremldata.bin"))
        }
        #expect(paths.contains("parakeet_vocab.json"))
        #expect(!paths.contains { $0.hasPrefix("Encoder_lut3") })
        for file in BarkModelStore.files {
            #expect(file.sha256.count == 64)
            #expect(file.size > 0)
        }
        #expect(BarkModelStore.remoteURL(for: BarkModelStore.files[0]).absoluteString.contains(BarkModelStore.revision))
    }

    @Test("Verification rejects a wrong size or a wrong hash and accepts the exact bytes")
    func verification() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

        try BarkModelStore.verify(.init("x", 3, abc), at: url)
        #expect(throws: TranscriptionError.self) { try BarkModelStore.verify(.init("x", 4, abc), at: url) }
        #expect(throws: TranscriptionError.self) {
            try BarkModelStore.verify(.init("x", 3, String(repeating: "0", count: 64)), at: url)
        }
    }
}

/// Real download, checksum, Neural Engine load and transcription. Opt-in because it fetches
/// ~450 MB on first run and compiles for about a minute:
///
///     MURMUR_BARK_AUDIO=/path/to/16k-mono.f32 make test
///
/// The audio file is raw little-endian float32 at 16 kHz.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MURMUR_BARK_AUDIO"] != nil))
struct BarkIntegrationTests {
    @Test("Bark Clean downloads, verifies, loads and transcribes through ParakeetEngine")
    func endToEnd() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MURMUR_BARK_AUDIO"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let samples: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        let loadStarted = Date()
        _ = try await ParakeetModels.barkClean.manager()
        print("bark-integration load+warmup \(Date().timeIntervalSince(loadStarted))s")
        #expect(BarkModelStore.isDownloaded)

        let engine = ParakeetEngine(models: .barkClean)
        let format = try #require(await engine.preferredInputFormat())
        let stream = try await engine.start()
        // 100 ms buffers, the shape AudioCapture delivers.
        for start in stride(from: 0, to: samples.count, by: 1_600) {
            let count = min(1_600, samples.count - start)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress! + start, count: count)
            }
            await engine.feed(AudioChunk(buffer: buffer))
        }
        let finishStarted = Date()
        await engine.finish()
        print("bark-integration release-to-text \(Date().timeIntervalSince(finishStarted))s")

        var text = ""
        for try await chunk in stream { text = chunk.text }
        print("bark-integration text: \(text)")
        #expect(!text.isEmpty)
        #expect(!text.contains("<unk>"))
    }
}
