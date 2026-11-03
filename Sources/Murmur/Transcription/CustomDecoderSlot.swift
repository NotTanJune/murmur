import Foundation

/// What a training export's result declares about itself. Written by the notebook.
struct CustomDecoderManifest: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let path: String
        let size: Int
        let sha256: String
    }

    let trainedAt: String
    let clips: Int
    let heldOutWER: Double
    let replayWER: Double
    let baseRevision: String
    let files: [File]
}

/// Fine-tuned decoder and joint pairs installed beside the stock Bark Clean files.
///
/// Only those two components are ever swapped. The encoder is the low-bit, bit-exact
/// Core ML palette build and is reused from the stock folder, so a swap costs a 0.3 s reload
/// and never a Neural Engine recompile. A folder that ships an encoder is refused outright.
enum CustomDecoderSlot {
    static let requiredWeights = [
        "Decoder.mlmodelc/weights/weight.bin",
        "JointDecisionv3.mlmodelc/weights/weight.bin",
    ]
    static let forbidden = ["Encoder.mlmodelc", "Preprocessor.mlmodelc"]

    static var root: URL {
        BarkModelStore.modelsRoot.appendingPathComponent("bark-3.0-clean-custom", isDirectory: true)
    }

    static func installed(root: URL = root) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent("\($0)/manifest.json").path) }.sorted()
    }

    static func directory(for name: String, root: URL = root) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    static func readManifest(at folder: URL) throws -> CustomDecoderManifest {
        try JSONDecoder().decode(CustomDecoderManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    }

    @discardableResult
    static func verify(_ folder: URL, baseRevision: String) throws -> CustomDecoderManifest {
        let manifest = try readManifest(at: folder)
        guard manifest.baseRevision == baseRevision else {
            throw TranscriptionError.modelInstallFailed("trained against Bark revision \(manifest.baseRevision.prefix(8)), installed is \(baseRevision.prefix(8))")
        }
        for name in forbidden where FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            throw TranscriptionError.modelInstallFailed("\(name) must not be replaced; only the decoder and joint are fine-tuned")
        }
        let listed = Set(manifest.files.map(\.path))
        for required in requiredWeights where !listed.contains(required) {
            throw TranscriptionError.modelInstallFailed("manifest does not list \(required)")
        }
        for file in manifest.files {
            try BarkModelStore.verify(.init(file.path, file.size, file.sha256), at: folder.appendingPathComponent(file.path))
        }
        return manifest
    }

    /// Verifies `source` and copies it to `<root>/<trainedAt>/`, replacing a slot of the
    /// same date. Returns the slot name.
    static func importFolder(_ source: URL, baseRevision: String, root: URL = root) throws -> String {
        let manifest = try verify(source, baseRevision: baseRevision)
        let name = manifest.trainedAt
        guard !name.isEmpty, !name.contains("/") else {
            throw TranscriptionError.modelInstallFailed("manifest trainedAt is not a usable folder name")
        }
        let destination = directory(for: name, root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        try verify(destination, baseRevision: baseRevision)
        return name
    }

    static func remove(_ name: String, root: URL = root) {
        try? FileManager.default.removeItem(at: directory(for: name, root: root))
    }
}
