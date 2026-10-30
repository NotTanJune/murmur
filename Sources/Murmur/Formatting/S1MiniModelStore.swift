import Foundation

/// S1-mini by Superwhisper on disk, as the 4-bit MLX build Murmur actually runs.
///
/// Superwhisper publishes only BF16 safetensors (1.5 GB). Murmur downloads that once, checks
/// every file against a pinned size and SHA-256, quantizes it to 4-bit on this Mac (affine,
/// group 64, the same layout `mlx_lm.convert -q` writes; measured bit-identical), keeps the
/// 331 MB result and deletes the original. 4-bit measured about 2× faster than BF16 on an M2
/// with the same output on the test transcripts.
///
/// The repo has no release tag despite its card mentioning `v1`, so the pin is a commit.
/// The converted folder only appears once conversion finished, so `isInstalled` can stay a
/// cheap existence check, like `BarkModelStore.isDownloaded`.
enum S1MiniModelStore {
    static let repo = "superwhisper/s1-mini"
    static let revision = "88f6b15896c73bbb13a3b596e0afe8ea0d5150b4"
    static let folder = "s1-mini-4bit"

    static let sourceFiles: [BarkModelStore.File] = [
        .init("config.json", 726, "660db3b73d788119c04535e48cf9be5f55bc3100841a718637ae695b442f27dd"),
        .init("generation_config.json", 181, "6ca52b0bcb818c9e52db8ea18413494110c5f2def581b769f621dda951a7863b"),
        .init("chat_template.jinja", 4168, "a55ee1b1660128b7098723e0abcd92caa0788061051c62d51cbe87d9cf1974d8"),
        .init("merges.txt", 1671853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        .init("tokenizer.json", 11422654, "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
        .init("tokenizer_config.json", 9732, "d5d09f07b48c3086c508b30d1c9114bd1189145b74e982a265350c923acd8101"),
        .init("vocab.json", 2776833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
        .init("LICENSE", 12033, "f715982df6ce767ae64864d74b95644e5d658aab54717dbceeb252eb3cbcb421"),
        .init("NOTICE", 470, "4feae786f1766dc58e807bcae1e7bdd06bf3610a03a23d0621b6c6c4d05f2980"),
        .init("model.safetensors", 1503300328, "69d2057077ab4dc738aaaab75d2a8ffa141e3a09fb9d956198cfce46f381131a"),
    ]

    /// Copied unchanged next to the converted weights. LICENSE and NOTICE travel with the
    /// model because Apache 2.0 requires them wherever it's redistributed or embedded.
    static let carriedFiles = [
        "generation_config.json", "chat_template.jinja", "merges.txt", "tokenizer.json",
        "tokenizer_config.json", "vocab.json", "LICENSE", "NOTICE",
    ]

    static var directory: URL {
        BarkModelStore.modelsRoot.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }

    nonisolated static var isInstalled: Bool {
        let fm = FileManager.default
        return ["config.json", "model.safetensors", "tokenizer.json"].allSatisfy {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    enum Phase: Sendable {
        case downloading
        case converting
    }

    /// Downloads, verifies and converts, then publishes the converted folder. Returns at once
    /// when it's already installed. `convert` writes the 4-bit build from the verified source
    /// folder into an empty destination folder.
    static func ensureInstalled(
        phase: @Sendable (Phase) -> Void,
        convert: @Sendable (_ source: URL, _ destination: URL) async throws -> Void
    ) async throws -> URL {
        if isInstalled { return directory }

        let fm = FileManager.default
        let root = BarkModelStore.modelsRoot
        let token = UUID().uuidString
        let source = root.appendingPathComponent(".\(folder)-source-\(token)", isDirectory: true)
        let converted = root.appendingPathComponent(".\(folder)-\(token)", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: converted, withIntermediateDirectories: true)
        // The 1.5 GB original is never kept, whether conversion succeeds or not.
        defer {
            try? fm.removeItem(at: source)
            try? fm.removeItem(at: converted)
        }
        excludeFromBackup(root)

        phase(.downloading)
        let started = Date()
        Log.speech.info("S1-mini: downloading \(repo, privacy: .public)@\(revision.prefix(8), privacy: .public)")
        for file in sourceFiles {
            try Task.checkCancellation()
            let destination = source.appendingPathComponent(file.path)
            let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
            let (temporary, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                try? fm.removeItem(at: temporary)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw TranscriptionError.modelInstallFailed("\(file.path): HTTP \(status)")
            }
            try fm.moveItem(at: temporary, to: destination)
            try BarkModelStore.verify(file, at: destination)
        }
        Log.speech.info("S1-mini: download verified in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")

        phase(.converting)
        try await convert(source, converted)
        for name in carriedFiles {
            try fm.copyItem(at: source.appendingPathComponent(name), to: converted.appendingPathComponent(name))
        }

        try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: directory.path) {
            try fm.removeItem(at: directory)
        }
        try fm.moveItem(at: converted, to: directory)
        Log.speech.info("S1-mini: installed in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
        return directory
    }

    /// Adds the 4-bit block to the source config so MLX quantizes the layers on load.
    static func quantizedConfig(from data: Data) throws -> Data {
        guard var config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.modelInstallFailed("config.json is not an object")
        }
        config["quantization"] = ["group_size": 64, "bits": 4, "mode": "affine"]
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }

    private static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
