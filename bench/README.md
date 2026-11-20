# Model benchmark

Runs a candidate speech model against Murmur's current setup on your own recordings and
writes a report. None of it ships in the app.

```bash
uv run bench/fetch.py FluidVoice-Labs/fluid-speech-pro-coreml fluid-speech-pro --revision 3b9d38a9
make bench CANDIDATES="bench/candidates/fluid-speech-pro.json"
uv run bench/fetch.py --remove fluid-speech-pro
```

## The baseline

The baseline is whatever the installed app is set to when the run starts: engine, timing
(while speaking or on release), Bark decoder, cleanup engine and profile, and
`dictionary.txt`. The runner reads the app's Settings and builds the engine through the
app's own `engine(for:)`, so switching the app to a new model makes that model the next
baseline. Two things come from different places:

- Engine, windowing, cleanup pipeline, transcript repair and dictionary code are compiled
  from this repo, uncommitted changes included.
- S1-mini cleanup runs in the installed app's helper (`/Applications/Murmur.app`), because
  SwiftPM can't build MLX's GPU kernels. Run `make install` first if cleanup changed.

The streaming models (Parakeet EOU, Nemotron) can't be checked as on disk, so they can't be
the baseline: the runner never downloads.

## Candidates

One JSON file per model in `bench/candidates/`. A candidate replaces the current engine;
cleanup and dictionary stay as they are.

A Parakeet v3-layout Core ML folder (preprocessor, encoder, decoder, joint, vocabulary)
runs through the same streaming or batch engine as a hold, so its latency is comparable:

```json
{"name": "fluid-speech-pro", "kind": "parakeet-coreml",
 "folder": "~/Library/Application Support/Murmur/Benchmarks/models/fluid-speech-pro",
 "joint": "JointDecision.mlmodelc"}
```

Any other model is a command that prints the transcript of a 16 kHz mono WAV. It is
scored on accuracy only; its timing is the command's wall time on the whole clip.

```json
{"name": "some-whisper", "kind": "command",
 "command": ["uv", "run", "/path/to/transcribe.py", "{audio}"]}
```

An audio filter (denoise, dereverb) is a `preprocess` command that writes `{output}` from
`{audio}`, the recording as stored. The current engine, cleanup and dictionary then run on
its output. If the command prints a number, that is its processing time in seconds,
reported on its own row and not added to the release wait; otherwise its wall time counts.

```json
{"name": "clear-studio", "kind": "preprocess",
 "command": ["/path/to/clear-cli", "clear-studio", "{audio}", "{output}"]}
```

## What runs

`bench.py` picks the recordings the run log kept audio for, writes a job file and runs the
`MurmurBench` target (`bench/runner/`) through `swift test`, which skips it when no job is
given. Three passes, `PASSES=clean,paced,noisy` by default:

| Pass | Recordings | What it shows |
|---|---|---|
| clean | all, unpaced | what each engine heard and typed, terms, fillers, empty results |
| paced | corrected, fed at twice real time | release-to-typed wait |
| noisy | corrected, under babble from 6 other recordings plus pink noise at 5 dB | robustness |

Scores are word errors against your history corrections. Those are edits of whatever
engine you used at the time (Bark Clean so far), so they favour it. Results, including
`report.md` and each pass's raw JSON, go to
`~/Library/Application Support/Murmur/Benchmarks/runs/<stamp>-<names>/`. The noisy audio
is deleted after its pass.

The first run builds the package in release (minutes, CPU-heavy) and compiles each model
for the Neural Engine, Bark about 100 s. Core ML won't reuse the app's compiled models in
another process, so the runner keeps its own cache in
`~/Library/Application Support/Murmur/Benchmarks/ane-cache`; later runs load in seconds.
