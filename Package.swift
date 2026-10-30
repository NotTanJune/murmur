// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Parakeet TDT as CoreML on the Neural Engine. Optional at runtime — Apple's
        // SpeechTranscriber remains the default and needs no dependency at all.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
        // S1-mini transcript cleanup on the GPU. Called through MLXLMCommon directly rather
        // than the FoundationModels adapter, which can't keep a per-profile prompt cache, so
        // that adapter's trait is off. The GPU kernels need xcodebuild; see the Makefile.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3", traits: []),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.3.0")),
    ],
    targets: [
        // The dictionary is its own target so it can be tested directly, and because its
        // behaviour is a cross-platform contract: the Windows app reimplements this logic in
        // C#, and both sides run the same vectors in shared/dictionary-test-vectors.json.
        .target(
            name: "MurmurDictionary",
            path: "Sources/MurmurDictionary",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: [
                "MurmurDictionary",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/Murmur",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MurmurDictionaryTests",
            dependencies: ["MurmurDictionary"],
            path: "Tests/MurmurDictionaryTests",
            resources: [.copy("dictionary-test-vectors.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

if #available(macOS 26, *) {
    package.targets.append(
        .testTarget(
            name: "MurmurAppTests",
            dependencies: ["Murmur", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Tests/MurmurAppTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    )
}
