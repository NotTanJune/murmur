import Foundation
import Testing
@testable import Murmur

struct CustomDecoderSlotTests {
    private let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private func makeFolder(baseRevision: String, extra: [String] = []) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for path in ["Decoder.mlmodelc/weights/weight.bin", "JointDecisionv3.mlmodelc/weights/weight.bin"] + extra {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("abc".utf8).write(to: url)
        }
        let manifest = CustomDecoderManifest(
            trainedAt: "2026-11-03", clips: 120, heldOutWER: 4.1, replayWER: 5.0, baseRevision: baseRevision,
            files: [
                .init(path: "Decoder.mlmodelc/weights/weight.bin", size: 3, sha256: abc),
                .init(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 3, sha256: abc),
            ]
        )
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        return folder
    }

    @Test("A matching folder verifies; wrong base revision, wrong bytes, or an encoder are refused")
    func verification() throws {
        let good = try makeFolder(baseRevision: "rev1")
        defer { try? FileManager.default.removeItem(at: good) }
        #expect(try CustomDecoderSlot.verify(good, baseRevision: "rev1").clips == 120)
        #expect(throws: (any Error).self) { try CustomDecoderSlot.verify(good, baseRevision: "rev2") }

        try Data("abd".utf8).write(to: good.appendingPathComponent("Decoder.mlmodelc/weights/weight.bin"))
        #expect(throws: (any Error).self) { try CustomDecoderSlot.verify(good, baseRevision: "rev1") }

        let withEncoder = try makeFolder(baseRevision: "rev1", extra: ["Encoder.mlmodelc/weights/weight.bin"])
        defer { try? FileManager.default.removeItem(at: withEncoder) }
        #expect(throws: (any Error).self) { try CustomDecoderSlot.verify(withEncoder, baseRevision: "rev1") }
    }

    @Test("Import copies a verified folder under its training date and remove deletes it")
    func importAndRemove() throws {
        let source = try makeFolder(baseRevision: "rev1")
        defer { try? FileManager.default.removeItem(at: source) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = try CustomDecoderSlot.importFolder(source, baseRevision: "rev1", root: root)
        #expect(name == "2026-11-03")
        #expect(CustomDecoderSlot.installed(root: root) == ["2026-11-03"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("2026-11-03/manifest.json").path))
        CustomDecoderSlot.remove("2026-11-03", root: root)
        #expect(CustomDecoderSlot.installed(root: root).isEmpty)
    }
}
