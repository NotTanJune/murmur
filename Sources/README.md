# Developing Murmur

```bash
make test                 # dictionary vectors and macOS 26 app regression tests
make build CONFIG=debug   # SwiftPM compile only
make app                  # signed bundle in ~/Library/Caches/MurmurBuild
make install              # that bundle, copied to /Applications and launched
```

Always build with `make`, which keeps build output out of the repo.
`Tests/MurmurDictionaryTests/dictionary-test-vectors.json` defines correction behaviour, so
change the vectors first. [AGENTS.md](../AGENTS.md) records the traps in this codebase.

The installed binary has checks that need no microphone unless an audio file is named:

```bash
M=/Applications/Murmur.app/Contents/MacOS/Murmur
$M --cleanup-check                     # S1-mini end to end
$M --incremental-check <audio-file>    # streaming against batch
$M --residency-check <file>            # model memory and load times
$M --decoder-check <slot> <audio>      # a fine-tuned decoder against stock
```

## Layout

```
Sources/Murmur/
├── Core/            hotkey, capture, routing, injection, DictationController
├── Transcription/   Mac-only engines (streaming, Wispr reader)
├── Formatting/      S1-mini and its helper
├── Support/         Mac storage and settings extensions, permissions, check commands
└── UI/              components, main window, settings, HUD
Sources/MurmurKit/          text pipeline, engines, settings and run log shared with the iPhone
Sources/MurmurDictionary/   corrector, no app dependencies
Sources/MurmurDesign/       design system shared with the iPhone
ios/                        iPhone app and dictation keyboard (ios/README.md)
bench/                      model benchmark against your own recordings (bench/README.md)
training/                   Colab fine-tuning notebook (training/README.md)
promo/                      Remotion source for the promo videos and banner (promo/README.md)
docs/diagrams/              Excalidraw sources for the README diagrams
```
