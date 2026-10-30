import CryptoKit
import Foundation

/// Underdog Bark 3.0 Clean on disk: a Parakeet TDT 0.6B v3 fine-tune that drops fillers,
/// false starts and repeated words itself, so its raw output is already dictation text.
///
/// The weights come from `FluidInference/bark-3.0-coreml`, which ships the model in
/// FluidAudio's v3 component layout. Only the Neural Engine encoder is fetched. The repo's
/// `Encoder_lut3` GPU build measured about 2× slower per utterance on an M2 and pays roughly
/// 8 s on its first inference after every launch; the ANE build pays a one-time compile
/// (about 80 s) that Core ML then caches across launches.
///
/// Every file is pinned to one repo revision and checked against its size and SHA-256
/// before the folder is published. A partial or tampered download never becomes visible
/// at `directory`, so `isDownloaded` can stay a cheap existence check.
enum BarkModelStore {
    static let repo = "FluidInference/bark-3.0-coreml"
    static let revision = "ca21bed2ccd9c3fbcd104a6014b9a5638a764bc8"
    static let folder = "bark-3.0-clean"

    struct File: Sendable {
        let path: String
        let size: Int
        let sha256: String

        init(_ path: String, _ size: Int, _ sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    static let files: [File] = [
        .init("Decoder.mlmodelc/analytics/coremldata.bin", 243, "d00e8baa4b1d7fc164d7cbbb96ed294d531ba6fb684a1aa79f66d4e4fbdbd5da"),
        .init("Decoder.mlmodelc/coremldata.bin", 569, "b33a57a008e7b138574bac1219037aadd7054caebfc42d0fa4adc97050f6a836"),
        .init("Decoder.mlmodelc/metadata.json", 3433, "de3e22da7619f1ba9ae8ab3676ece49a999b93b3ca2a6653687c54b0e69419fc"),
        .init("Decoder.mlmodelc/model.mil", 13110, "34bd2cc0a00dd7a485f0aa90f58d6b516c94ee8f4842de92aad7b581849df289"),
        .init("Decoder.mlmodelc/weights/weight.bin", 23604992, "6220cd08cb7eaacf5106da134c40f57e13783342c09f1be250dd31cc1b8b8a94"),
        .init("Encoder.mlmodelc/analytics/coremldata.bin", 243, "8f6763508e0d6caad8152bcc72cf8be1647f568c3cdc5c5ff9732c1c69e2734c"),
        .init("Encoder.mlmodelc/coremldata.bin", 557, "e08f511d23e5642bc45f6ecc0bc930e00f8f105d6a6c33fe03f83c8da9253070"),
        .init("Encoder.mlmodelc/model.mil", 1012893, "0442825ac24b17cd861db7a8bda7cda16c3372c8228331e640196965f190583d"),
        .init("Encoder.mlmodelc/weights/weight.bin", 409451136, "4216107d2214bd058aec94c2e0f9a7e8114f5274cf0c6a28ffb8f21ea56337eb"),
        .init("JointDecisionv3.mlmodelc/analytics/coremldata.bin", 243, "a55f011ca119fc7913ffc905ef48079572c4f54b6e5ed34a033f69c5422be0b6"),
        .init("JointDecisionv3.mlmodelc/coremldata.bin", 601, "2f5d97969689b6397b8f2e8ba31a1d4684a41ec373ecf56d4ee751efb2ca5073"),
        .init("JointDecisionv3.mlmodelc/metadata.json", 3577, "989223d0134de212bb206b7311b9f7038d26f86d0d43a88b17deee895d0a931e"),
        .init("JointDecisionv3.mlmodelc/model.mil", 11777, "167357ff6d558349e745047c6e3f610010d047ec21ab6f56df2dbb041f096baa"),
        .init("JointDecisionv3.mlmodelc/weights/weight.bin", 12642764, "4575e6ec06917259358cf17307fe7aa38d364b736e4b6c9b6e3d49169c760eee"),
        .init("NOTICE", 615, "4e627d41fa10efedd84a7dbb915711b0b73c904af1fee8bacdd4a2387bcc5a10"),
        .init("parakeet_vocab.json", 151122, "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        .init("Preprocessor.mlmodelc/analytics/coremldata.bin", 243, "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
        .init("Preprocessor.mlmodelc/coremldata.bin", 486, "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
        .init("Preprocessor.mlmodelc/metadata.json", 2841, "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
        .init("Preprocessor.mlmodelc/model.mil", 28181, "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
        .init("Preprocessor.mlmodelc/weights/weight.bin", 491072, "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
    ]

    static var totalBytes: Int { files.reduce(0) { $0 + $1.size } }

    /// Outside the iCloud-synced repo and keyed by revision, so a future pin lands beside
    /// this one instead of being mixed into it.
    static var modelsRoot: URL {
        AppStorage.directory.appendingPathComponent("Models", isDirectory: true)
    }

    static var directory: URL {
        modelsRoot.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }

    /// Filesystem-based for the same reason as `ParakeetModels.isDownloaded`: the menu asks
    /// synchronously, and an in-memory flag would be wrong on every fresh launch.
    nonisolated static var isDownloaded: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.path).path) }
    }

    /// Downloads and verifies every file into a staging folder, then moves it into place.
    /// Returns immediately when the pinned revision is already installed.
    static func ensureDownloaded() async throws -> URL {
        if isDownloaded { return directory }

        let fm = FileManager.default
        let staging = modelsRoot.appendingPathComponent(".\(folder)-\(revision)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        excludeFromBackup(modelsRoot)

        let megabytes = Double(totalBytes) / 1_000_000
        Log.speech.info("Bark: downloading \(megabytes, format: .fixed(precision: 0)) MB from \(repo, privacy: .public)@\(revision.prefix(8), privacy: .public)")
        let started = Date()

        for file in files {
            try Task.checkCancellation()
            let destination = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

            let (temporary, response) = try await URLSession.shared.download(from: remoteURL(for: file))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                try? fm.removeItem(at: temporary)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw TranscriptionError.modelInstallFailed("\(file.path): HTTP \(status)")
            }
            try fm.moveItem(at: temporary, to: destination)
            try verify(file, at: destination)
        }

        try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: directory.path) {
            // A leftover from an interrupted install of the same revision. Everything in it
            // is unverified, so replace it rather than merge.
            try fm.removeItem(at: directory)
        }
        try fm.moveItem(at: staging, to: directory)

        Log.speech.info("Bark: download verified in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
        return directory
    }

    static func remoteURL(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(folder)/\(file.path)")!
    }

    /// Size first, so a truncated download fails without hashing 400 MB.
    static func verify(_ file: File, at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
        guard size == file.size else {
            throw TranscriptionError.modelInstallFailed("\(file.path): expected \(file.size) bytes, got \(size)")
        }
        let digest = try sha256(of: url)
        guard digest == file.sha256 else {
            throw TranscriptionError.modelInstallFailed("\(file.path): checksum mismatch")
        }
    }

    /// Streams the file in 4 MB reads so hashing the encoder doesn't map 400 MB at once.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
