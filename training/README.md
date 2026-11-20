# Fine-tuning Bark Clean's decoder on your dictation

1. In Murmur, Settings → Training → Export. A zip lands in
   `~/Library/Application Support/Murmur/Training/`.
2. Open `bark_decoder_finetune.ipynb` in Google Colab (free T4 is enough). Upload the zip
   when the first cell asks.
3. Run all cells. The notebook stops without exporting if the fine-tune is not better than
   stock on your held-out clips or drifts on replay clips; the tables tell you why.
4. Download `bark-decoder-<date>.zip`, unzip, and in Murmur choose Install fine-tuned
   decoder… and pick the folder. Switch Decoder to it. Revert with Stock any time.

Only the decoder and joint (35 MB) are trained. The encoder stays the stock low-bit build,
so acoustics do not change; what improves is which words the model writes for sounds it
already hears correctly.

## Verify the Core ML export on the first real run

Cells 7 and 8 were written against the stock package's documented contract and have not
been run. Check them once:

- Decoder: inputs `targets` Int32 [1,1], `target_length` Int32 [1], `h_in` and `c_in`
  Float32 [2,1,640]; outputs `decoder` Float32 [1,640,1], `h_out`, `c_out` Float32 [2,1,640].
- JointDecisionv3: inputs `encoder_step` Float32 [1,1024,1], `decoder_step` Float32
  [1,640,1]; outputs `token_id`, `duration` Int32 [1,1,1], `token_prob` Float32 [1,1,1]
  (the softmax probability of the chosen token; the stock `model.mil` has a `softmax` and a
  `gather_along_axis` for it), `top_k_ids` Int32 [1,1,1,64], `top_k_logits` Float32
  [1,1,1,64].
- Cell 7 gives the Decoder model the embedding and the two-layer LSTM only, and the joint
  model both projections plus the head. That matches the stock package: its
  `Decoder.mlmodelc/model.mil` holds `module_prediction_embed_weight` [8193, 640] and the
  LSTM weights and nothing else, and `JointDecisionv3.mlmodelc/model.mil` holds
  `joint_module_enc_weight` [640, 1024], `joint_module_pred_weight` [640, 640] and
  `joint_module_joint_net_2_weight` [8198, 640] (8193 tokens plus 5 durations). Cell 7's
  parity assertion checks the split against the Hugging Face model's own joint.

Then compile and run `Murmur --decoder-check <folder> <audio>` on the Mac. A load failure
there means an output name or dtype differs from the stock package's `metadata.json`.

## On the Mac, without Colab

`finetune_local.py` does the same job on the Mac's CPU, reading the run log and the
recordings in place. It marks nothing as exported, so a later Colab export still sees every
run.

```bash
uv venv --python 3.12 ~/Library/Caches/MurmurBuild/train/env
uv pip install --python ~/Library/Caches/MurmurBuild/train/env/bin/python \
    "transformers>=5.19" torch coremltools "constriction>=0.5" soundfile soxr librosa huggingface_hub numpy
PY=~/Library/Caches/MurmurBuild/train/env/bin/python
nice -n 19 $PY training/finetune_local.py prepare   # segments, stock text, encoder outputs
nice -n 19 $PY training/finetune_local.py train     # scores held-out recordings every epoch
nice -n 19 $PY training/finetune_local.py export    # Core ML decoder and joint pair
```

`train` keeps an epoch only when it is no worse than stock on either held-out count, better
on at least one, and within a point of stock on unlabelled speech. When no epoch qualifies
it says so and `export` has nothing to write. `export --stock` converts the untouched
checkpoint instead, to test the conversion: `Murmur --decoder-check` on that folder must
print the same text twice (it did, 0 words differing on three recordings of 36 to 92 s,
2026-11-13). The check installs the folder as a slot named `stock-parity`; delete it from
`Models/bark-3.0-clean-custom/` afterwards.

It differs from the notebook in three ways, each for a reason found on real recordings:

- Recordings are cut into segments of at most 14 s at their quietest points. The model takes
  15 s, Murmur feeds it windows of that size, and the transducer loss on a whole 90 s
  recording needs about 11 GB.
- A correction is split across its recording's segments by aligning it with the stock
  model's text for each one. A segment whose share of a changed stretch is ambiguous is left
  out. Each segment's target opens and closes the way the stock text does (first capital,
  closing period), so training changes what is written inside a clip and not how one is
  opened or closed.
- Replay segments are trained against the stock model's own text for that segment, not the
  `rawText` in the run log, which until 2026-11-13 carried the streaming engine's seam
  errors ("act.tions"). Periods before a lowercase word are dropped from corrections, the
  same rule as `TranscriptRepair.dropPausePeriods`.

Held-out recordings are scored twice: word error ignoring case and punctuation, and the
same counting them. Most corrections change punctuation and case, which the first number
cannot see.

### First run, 2026-11-13

78 recordings (27 min), 27 of them corrected, became 175 segments; 38 segments carried a
correction, nearly all acronyms ("m. c. p." to "MCP") and names (Kelpie, Ericsson,
Excalidraw). 134 segments trained, 19 corrected and 16 replay segments were held out.

| run | held-out word error | counting case and punctuation | replay drift | training corrections reproduced |
|---|---|---|---|---|
| stock | 1.96% | 2.61% | 0.00% | 0 of 32 |
| lr 1e-5, best of 6 epochs | 1.74% | 2.61% | 0.00% | not measured |
| lr 5e-5, epoch 2 | 1.74% | 3.05% | 0.80% | 4 of 32 |
| lr 5e-5, epoch 8 | 2.40% | 4.14% | 2.41% | 21 of 32 |

Nothing was exported. The gentle run moved one held-out word. The stronger run memorised
two thirds of the corrections it was shown while getting worse on recordings it was not
shown: 38 corrected segments are too few to generalise from. The held-out set is also too
small to trust in either direction (1.96% is nine words). More corrected recordings are
what changes this, and a correction teaches most when it fixes a word the model will meet
again.

