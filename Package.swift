// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "MurmurKit", targets: ["MurmurKit"]),
        .library(name: "MurmurDictionary", targets: ["MurmurDictionary"]),
        .library(name: "MurmurDesign", targets: ["MurmurDesign"]),
    ],
    dependencies: [
        // Core ML speech models on the Neural Engine. Apple's transcriber is the default
        // engine and does not use this package.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
        // S1-mini transcript cleanup on the GPU. Called through MLXLMCommon directly rather
        // than the FoundationModels adapter, which can't keep a per-profile prompt cache, so
        // that adapter's trait is off. The GPU kernels need xcodebuild; see the Makefile.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3", traits: []),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.3.0")),
    ],
    targets: [
        // A separate target so CI can run the correction vectors without building the app.
        .target(
            name: "MurmurDictionary",
            path: "Sources/MurmurDictionary",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The platform-neutral text pipeline, shared by the Mac app and the iOS keyboard.
        .target(
            name: "MurmurKit",
            dependencies: [
                "MurmurDictionary",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/MurmurKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The ink-on-paper design tokens and shared views, used by the Mac app and the iOS targets.
        .target(
            name: "MurmurDesign",
            path: "Sources/MurmurDesign",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Murmur",
            dependencies: [
                "MurmurDictionary",
                "MurmurKit",
                "MurmurDesign",
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
            name: "MurmurKitTests",
            dependencies: ["MurmurKit", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Tests/MurmurKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
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
            dependencies: ["Murmur", "MurmurKit", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Tests/MurmurAppTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    )
    // The model benchmark, not a test: it imports the app's code the way the tests do and
    // runs only when `bench/bench.py` hands it a job. See bench/README.md.
    package.targets.append(
        .testTarget(
            name: "MurmurBench",
            dependencies: ["Murmur", "MurmurKit", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "bench/runner",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    )
}
