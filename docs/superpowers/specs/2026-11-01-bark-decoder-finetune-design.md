# Bark Clean personal fine-tune: design

Date: 2026-11-01. Status: approved in discussion, awaiting spec review.

## Goal

Make Bark 3.0 Clean recognise the user's own terms and phrasing in the first decode, so
fewer dictionary rewrites are needed. Latency is unchanged by design; the gain is accuracy.
Learning happens by fine-tuning the model's decoder and joint on the user's own recordings,
in a Colab notebook the user runs by hand, and installing the result in Murmur with one tap
and one-tap revert.

## Decisions taken

- Labels come from two sources: dictionary corrections that fired on a run, and edits the user
  makes to a transcript in Murmur's history. No observation of other apps.
- Audio is retained for every non-compare hold for 30 days; only runs with a label keep it
  longer, until exported. About 1 MB per dictated minute on disk (FLAC). Runtime RAM unchanged.
- Training runs on Colab, triggered by hand. Murmur exports a bundle; the user downloads a
  result and imports it. Nothing uploads automatically.
- Only the decoder (prediction network, 23 MB) and joint (12 MB) are trained. The encoder is
  frozen so its low-bit, bit-exact Core ML palettes are reused untouched. This rules out
  learning new acoustics but makes the swap safe, small and recompile-free.
- No automation of the three-day cadence; the Training card shows how many labelled runs have
  accumulated since the last export.

## Facts the design rests on (verified 2026-11-01)

- `ConwayResearch/Underdog-Bark-3.0-Clean` ships `model.bark` (180 MB) and `bark_loader.py`,
  which unpacks it bit-exactly into `transformers.ParakeetForTDT` (`transformers>=5.19`) and
  asserts a strict weight match.
- `ParakeetForTDT.forward(labels:)` returns the TDT loss, so the stock class trains.
- Bark's encoder linears hold five values per output row; `FluidInference/bark-3.0-coreml`
  stores them as Core ML palettes, bit-exact. Training the encoder would force an fp16 or
  int8 re-export (1.2 GB, minutes of Neural Engine recompile per swap).
- The installed `Decoder.mlmodelc` and `JointDecisionv3.mlmodelc` are fp16 `mlprogram`s whose
  contract is readable in `model.mil`: decoder inputs `targets [1,1] int32`,
  `target_length [1] int32`, `h_in [2,1,640] fp32`, `c_in [2,1,640] fp32`; joint inputs
  `encoder_step [1,1024,1] fp32`, `decoder_step [1,640,1] fp32`. The vocabulary is 8193 tokens
  with a leading-space word marker.
- `FluidInference/mobius`, `models/stt/parakeet-tdt-v3-0.6b/coreml/convert-parakeet.py`, is
  the reference export of these two components.
- FluidAudio's `AsrModels` takes the four `MLModel`s separately (`loadBarkClean` in
  `ParakeetEngine.swift` already constructs it by hand), so swapping two of them is local.

## Part 1: Murmur (macOS)

### Capture

`Utterance.feedTask` already receives every `AudioChunk` in order. For non-compare holds it
now retains them (16 kHz mono float32, about 3.8 MB per minute in memory, released at
delivery). At delivery `RunLog.record` receives the samples and writes
`~/Library/Application Support/Murmur/Recordings/<run-id>.flac` on its serial queue, using
`AVAudioFile` with the FLAC settings. A run whose text was discarded (password field, empty)
writes nothing.

`DictationRun` gains:

- `rawText: String?`: the engine's final transcript before cleanup and dictionary.
- `label: String?`: the user's edit from history. Nil until edited.
- `hasAudio: Bool`: whether the FLAC exists. Lines written before these fields decode as
  nil / false.

Pruning (`RunLog.retention`, 30 days) deletes the FLAC with the run. A run with `label` set,
or with at least one dictionary correction, keeps both until it has been included in an
export; after export it follows the normal rule. `isSaved` runs keep audio as long as the
run exists.

Settings → Training: toggle "Keep recordings for training" (default on). Off deletes the
Recordings folder and stops writing. The note shows the folder's current size.

### Labels

A run's training label, in priority:

1. `label` (history edit), only if the run's cleanup was the rule pass or none. Edits of
   S1-mini or Apple Intelligence output are rewrites, not transcripts; the edit field is
   hidden on those rows.
2. `rawText` with the dictionary corrector applied, when at least one correction fired.
   Applies to every cleanup engine, since it is computed from `rawText`.

Otherwise the run is unlabelled and can serve only as replay data.

History row: a pencil button opens an inline text field pre-filled with the transcript; blur
or Return saves `label` through `RunLog`; a "Labelled" chip appears, styled like the Save
chip. A labelled run is exempt from pruning like a saved one.

### Export

Settings → Training card shows "N labelled runs since last export · M minutes" and an Export
button. Export writes
`~/Library/Application Support/Murmur/Training/export-<yyyy-MM-dd>/` containing:

- `manifest.jsonl`: one object per labelled run with audio:
  `{"audio_filepath": "clips/<id>.flac", "duration": s, "text": label, "raw": rawText,
  "source": "edit" | "dictionary", "date": iso8601}`.
- `replay.jsonl`: up to three times as many unlabelled runs with audio, newest first, with
  `text` = `rawText` (Bark's own output, to anchor the fine-tune to current behaviour).
- `clips/`: the FLAC files referenced.
- `export.json`: Murmur version, Bark revision (`BarkModelStore.revision`), counts.

The folder is zipped to `export-<date>.zip` beside it and revealed in Finder. The runs it
contained are marked exported (`exportedAt` on the run), which releases their audio to the
normal retention rule.

### Import and model slot

`BarkModelStore` keeps the pinned stock revision. It gains a custom slot at
`~/Library/Application Support/Murmur/Models/bark-3.0-clean-custom/<training-date>/` holding
`Decoder.mlmodelc`, `JointDecisionv3.mlmodelc` and `manifest.json`
(`{"trainedAt", "clips", "heldOutWER", "replayWER", "baseRevision", "files": [{path, size,
sha256}]}`). Import copies a chosen folder in, verifies every file against the manifest with
the existing `verify`, and refuses on mismatch or a `baseRevision` other than the installed
stock revision.

`Settings.barkDecoder: .stock | .custom(date)`. `loadBarkClean` loads the stock preprocessor
and encoder always, and the decoder and joint from the selected slot. Switching unloads and
reloads Bark (0.3 to 0.5 s; the encoder file is unchanged so no Neural Engine recompile).
The Training card shows a ChoiceKeys "Decoder: Stock / Fine-tuned <date>" with the manifest's
WER figures as the note, and a Remove button for the custom slot.

Compare mode adds a "Bark 3.0 Clean (fine-tuned)" row when the custom slot is installed,
sharing the encoder output path with the stock row (two `AsrModels` instances over the same
encoder `MLModel`).

### Memory

Runtime RAM unchanged: audio is in memory only during a hold; the custom decoder pair is the
same 35 MB as stock. Disk: about 1 MB per retained minute plus 35 MB per installed slot.

## Part 2: training (Colab)

`training/bark_decoder_finetune.ipynb` in the repo, with a `training/README.md`. Free-tier T4
is sufficient.

1. Install `transformers>=5.19`, `torch`, `torchaudio`, `constriction`, `coremltools`,
   `soundfile`, `soxr`, `jiwer`. Download the Bark Clean repo files (`model.bark`,
   `bark_loader.py`, `mlx/` tokenizer files) at the revision Murmur records in `export.json`.
2. Unpack into `ParakeetForTDT` with `bark_loader.load_model`; its strict assert guarantees
   bit-exact weights. Freeze all `encoder.*` parameters. Trainable: `decoder.*` and `joint.*`.
3. Load `manifest.jsonl` and `replay.jsonl`; hold out 10% of labelled clips (at least 10) as a
   test set. Resample to 16 kHz, prepend 0.25 s of silence as the model card specifies, run the
   processor, tokenise labels with the model tokenizer.
4. Train: AdamW, lr 1e-5, weight decay 0.01, batch 8, 3 epochs, labelled and replay clips
   mixed in each batch. Loss is the TDT loss returned by `forward(labels:)`. Evaluate each
   epoch on held-out WER (jiwer); keep the best epoch.
5. Gate: held-out WER must be lower than the frozen stock model's on the same clips, and
   replay WER (model vs its own prior output) must not rise more than 0.5 points. On failure
   print both tables and stop; nothing is exported.
6. Export: wrap decoder and joint in the same modules `convert-parakeet.py` uses, trace with
   the exact shapes above, `ct.convert(convert_to="mlprogram", compute_precision=FLOAT16,
   minimum_deployment_target=macOS15)`, compile with `xcrun coremlcompiler` equivalent
   (`coremltools.models.utils.compile_model`), and check the compiled models' input names and
   shapes against the contract. Write `manifest.json` with SHA-256s and the WER figures. Zip.
7. Smoke test in the notebook: decode three held-out clips with the Core ML pair through a
   Python greedy TDT loop ported from FluidAudio's decoder and compare with the PyTorch output.

## Verification

- `Murmur --decoder-check <slot-folder> <audio-file>`: loads stock and custom pairs over one
  encoder, transcribes the file with both, prints texts, timings and a word diff.
- Unit tests: manifest verification (size, hash, base revision), slot selection and revert,
  retention rules for labelled, saved, exported and plain runs, label priority, export manifest
  shape with a fake run store, `DictationRun` decoding of old lines.
- Compare mode on live holds for A/B by ear.

## Out of scope

Encoder training (approach B), decode-time vocabulary biasing (approach C), scheduled Colab
runs, observing edits in other apps, Windows.

## Risks

- Too few labels: at the current dictionary-hit rate, a useful first fine-tune is weeks away.
  The card's count makes this visible rather than hidden.
- Export contract drift: FluidAudio's expected tensor names are read from the installed
  `model.mil`; the notebook asserts them after compile.
- Over-fitting a 35 MB decoder on hundreds of clips: replay mix plus the WER gate; revert is
  one tap.
