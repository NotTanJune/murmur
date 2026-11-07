# Third-party components

Murmur's own source is GPL-3.0-only. It links or downloads the components below, each under its own
license.

## Swift packages

Versions are the ones pinned in `Package.resolved`.

| Package | Version | License |
|---|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | 0.15.6 | Apache-2.0 |
| [mlx-swift](https://github.com/ml-explore/mlx-swift) | 0.32.3 | MIT |
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | 3.32.3 | MIT |
| [swift-transformers](https://github.com/huggingface/swift-transformers) | 1.3.5 | Apache-2.0 |
| [swift-huggingface](https://github.com/huggingface/swift-huggingface) | 1.0.0 | Apache-2.0 |
| [swift-jinja](https://github.com/huggingface/swift-jinja) | 2.5.2 | Apache-2.0 |
| [EventSource](https://github.com/mattt/EventSource) | 1.5.1 | MIT |
| [swift-asn1](https://github.com/apple/swift-asn1) | 1.7.3 | Apache-2.0 |
| [swift-collections](https://github.com/apple/swift-collections) | 1.7.5 | Apache-2.0 |
| [swift-crypto](https://github.com/apple/swift-crypto) | 4.5.2 | Apache-2.0 |
| [swift-numerics](https://github.com/apple/swift-numerics) | 1.1.1 | Apache-2.0 |
| [swift-syntax](https://github.com/swiftlang/swift-syntax) | 603.0.2 | Apache-2.0 |
| [yyjson](https://github.com/ibireme/yyjson) | 0.12.0 | MIT |

## Fonts

Fraunces (by Undercase Type, Phaedra Charles and Flavia Zimbardi) and Figtree ship in
`Resources/Fonts/` under the SIL Open Font License 1.1. Their license texts sit beside them.

## Model weights

No weights are stored in this repository. The app downloads them and keeps the upstream license and
notice files beside the weights where the source provides them.

| Model | Source | License |
|---|---|---|
| Underdog Bark 3.0 Clean, Core ML build | `FluidInference/bark-3.0-coreml`, from Conway Research, derived from NVIDIA Parakeet TDT 0.6B v3 and Moondream parakeet-ultra | CC-BY-4.0 |
| S1-mini by Superwhisper | `superwhisper/s1-mini`, converted to 4-bit on your Mac | Apache-2.0, with a term requiring the name "S1-mini" by "Superwhisper" |
| Parakeet TDT v3, Parakeet EOU and Nemotron | Fetched through FluidAudio | See each model card |
