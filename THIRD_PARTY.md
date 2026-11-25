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
EB Garamond Italic (by Georg Duffner and Octavio Pardo) draws the app icon's "m" and sets the
word "Murmur" on the iPhone keyboard's talk key. It sits in `Tools/Fonts/` under the same license,
with its license text. It ships in the iPhone keyboard extension (and its license text in the
iPhone app) and not in the Mac app.

## Model weights

No weights are stored in this repository. The app downloads them and keeps the upstream license and
notice files beside the weights where the source provides them.

| Model | Source | License |
|---|---|---|
| Underdog Bark 3.0 Clean, Core ML build | `FluidInference/bark-3.0-coreml`, from Conway Research, derived from NVIDIA Parakeet TDT 0.6B v3 and Moondream parakeet-ultra | CC-BY-4.0 |
| S1-mini by Superwhisper | `superwhisper/s1-mini`, converted to 4-bit on your Mac | Apache-2.0, with a term requiring the name "S1-mini" by "Superwhisper" |
| Parakeet TDT v3, Parakeet EOU and Nemotron | Fetched through FluidAudio | See each model card |
| DistilGPT2, the iPhone keyboard's next-word model | `distilbert/distilgpt2` at revision `2290a626`, by Hugging Face, distilled from OpenAI's GPT-2; converted to Core ML with 4-bit and 6-bit palettes by `Tools/fetch_typing_lm.py`, with its `vocab.json` and `merges.txt` | Apache-2.0 |

DistilGPT2 is the one model that ships inside a build and is not downloaded by the app: the script
writes it to `ios/TypingLM`, which git ignores, and the keyboard target copies that folder. A build
made without running the script has no model in it.

## Data

The iPhone keyboard's word model, `Sources/MurmurTyping/Resources/en.mtm`, is built by
`Tools/build_typing_model.py` from two word lists in the SymSpell repository, pinned to commit
`91fe939e9c1259813ee817e95239629c5badf8ec`, plus a short hand-written list of contractions and chat
words (`Tools/typing-extra-words.tsv`, Murmur's own). The lists are not stored in this repository;
the script downloads them and checks their SHA-256.

| Data | Source | License |
|---|---|---|
| `frequency_dictionary_en_82_765.txt` and `frequency_bigramdictionary_en_243_342.txt` | SymSpell by Wolf Garbe, `github.com/wolfgarbe/SymSpell` | MIT |
| Word frequencies behind both lists | Google Books Ngram data, http://books.google.com/ngrams | CC BY 3.0 Unported |
| English vocabulary the unigram list was filtered with | SCOWL (Spell Checker Oriented Word Lists), as the SymSpell README states, http://wordlist.aspell.net/ | Permissive, notice below |

`training/typing-lm/eval-sentences.tsv`, which only the model evaluation reads and no build
includes, holds 290 sentences from Tatoeba (https://tatoeba.org), licensed CC BY 2.0 FR. Each line
carries its Tatoeba sentence id, which names its author at `tatoeba.org/sentences/show/<id>`.

SCOWL's notice, from `scowl/Copyright` in `github.com/en-wl/wordlist` (which also credits further
contributors' lists under similar terms):

> Copyright 2000-2018 by Kevin Atkinson
>
> Permission to use, copy, modify, distribute and sell these word lists, the associated scripts,
> the output created from the scripts, and its documentation for any purpose is hereby granted
> without fee, provided that the above copyright notice appears in all copies and that both that
> copyright notice and this permission notice appear in supporting documentation. Kevin Atkinson
> makes no representations about the suitability of this array for any purpose. It is provided
> "as is" without express or implied warranty.
