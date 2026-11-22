# Murmur on the Mac

## Install

Apple silicon, macOS 26 or later, Xcode with Swift 6.2. There is no prebuilt download yet.

```bash
make install
```

That builds a signed release bundle, copies it to `/Applications` and launches it. Grant three
permissions, then restart Murmur after the Accessibility one.

| Permission | Used for |
|---|---|
| Accessibility | The hotkey and inserting text |
| Microphone | Capture |
| Input Monitoring | Spotting a key-up that another event tap swallowed |

Hold **Right ⌥** and talk. Settings > Push to talk can switch it to fn or Right ⌘. Give each
dictation app on the Mac its own key, or two of them record and both type.

If an Accessibility grant gets stuck, reset that one entry. Without the bundle ID, `tccutil`
resets every app:

```bash
tccutil reset Accessibility ai.pivotstudio.murmur
```

## Engines

Pick a speech engine in Settings > Model or from the menu bar. Apple needs no setup. The rest
run on the Neural Engine through [FluidAudio](https://github.com/FluidInference/FluidAudio) and
download once.

| Engine | Notes |
|---|---|
| Apple (streaming) | Default, no download |
| Parakeet | 470 MB |
| Bark 3.0 Clean | 450 MB, drops fillers and false starts. One Neural Engine compile on first load |
| Parakeet EOU, Nemotron | Streaming, English |

Recording never starts a download. Bark and Parakeet load at launch when they are on disk.
If you press the key before they finish, Apple's transcriber handles that hold.

## Cleanup

Cleanup runs after transcription, with one of three engines:

- basic rules, which are instant
- S1-mini by Superwhisper, through MLX in a helper process. It downloads 1.5 GB once and
  converts it to a 331 MB 4-bit build on your Mac. It takes a profile: General, Email,
  Message or Notes.
- Apple Intelligence

Your dictionary applies last, so cleanup cannot undo a replacement. It is the file
`~/Library/Application Support/Murmur/dictionary.txt`.

## Privacy

Murmur's own code makes one kind of network request: model downloads from Hugging Face.

- By default the mic stays open between holds and keeps the last 0.3 s in memory, so a hold
  includes the audio from just before the key press. Murmur stores nothing outside a hold.
  Settings > Microphone turns this off.
- Every hold saves its audio as FLAC in `~/Library/Application Support/Murmur/Recordings/`
  beside its history entry. Murmur deletes runs older than 30 days unless you saved or
  labelled them.
- Murmur types nothing into a password field. The paste fallback marks its clipboard entry
  transient and concealed, so clipboard managers skip it.

## Training

Your corrections can train a decoder on your own vocabulary. Murmur exports nothing until you
press the button in Settings > Training, and the zip stays on your Mac until you upload it to
Colab. See [training/README.md](../training/README.md).
