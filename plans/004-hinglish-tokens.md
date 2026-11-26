# 004: Hinglish tokens for the strip's language model

Owner chose option (b) of `training/typing-lm/README.md` ("Hinglish", "Proposal") on 2026-11-26, at a
Hinglish share of 0.15. Read that section first; this plan only fixes the order and the checks.

## Constraints

- Corpus is CC BY-NC-SA 4.0 and the repo is public. The added-token list, any weights and any
  model built from them live in git-ignored places only (`ios/TypingLM`, `~/Library/Caches/MurmurBuild/`).
  Scripts are committed. A checkout without `added_tokens.json` must behave exactly as today.
- No Colab command in this plan's local part. Colab runs only after the owner approves the exact run.
- Niced builds and tests, few jobs. No simulator, no `make ios-install`.
- The fine-tuned English weights are gone from the cache. The installed model is backed up at
  `~/Library/Application Support/MurmurKeep/TypingLM-ft-quarter-2026-11-26`; never write there.

## Steps

1. **Token list.** `training/typing-lm/hinglish_tokens.py --emit <file>` writes the 2,000 most frequent
   multi-token Hinglish words, each with its leading space, to
   `~/Library/Caches/MurmurBuild/hinglish/added-tokens.txt`.
2. **finetune.py.** Before anything is tokenised: `--added-tokens <file>` adds them as `AddedToken(..., single_word=True, normalized=False)`
   (or whatever setting reproduces the leading-space behaviour exactly; record the choice), resizes the embedding,
   initialises each new row as the mean of its old pieces' rows, and makes the held-out Hinglish measure count
   added tokens as one token. Default share 0.15. Add `--max-steps` for a smoke run.
3. **Swift tokenizer.** `BPETokenizer` loads an optional `added_tokens.json` (word to id) and emits an added
   token's id for a matching pre-token before BPE, matching the reference tokenizer exactly.
   `make_bpe_vectors.py` gains Hinglish and mixed vectors with the table loaded; the Swift test checks both
   the plain table (existing 379 vectors unchanged) and the added one.
4. **NextWordPredictor and loading.** The token-to-word table includes added tokens. `SmartPredictions`
   passes `added_tokens.json` from the bundle when present. The logits width comes from the model, not a constant.
5. **Conversion.** `convert.py` and `Tools/fetch_typing_lm.py` take `--added-tokens`, set the vocabulary size,
   write `added_tokens.json` into the output folder and record its SHA-256 in `model.json`.
6. **Local proof, no training.** Build a model from stock distilgpt2 plus the added tokens with mean-initialised
   rows into a scratch folder (not `ios/TypingLM`), convert it, and run the Swift predictor on it on the Mac:
   it loads, an added token comes back as one word, and `evaluate.py` English numbers are recorded for stock with
   and without the added rows. Then a CPU smoke run of `finetune.py --max-steps 20` on a few thousand lines, niced.
7. **Checks.** Full `swift test`, `make ios-build`, and `git status` showing no corpus-derived file tracked.

## Done when

Steps 1 to 7 pass and the README's Colab section is updated to the exact run (share 0.15, `--added-tokens`,
the token file uploaded next to the sample). The Colab run itself, its evaluation and the install are the next
step, after the owner's go.

## Status and handoff (2026-11-27)

**Done and on the owner's phone.** The full checkpoint of a Kaggle run is installed as the strip's
language model. The owner is trying it for a few days and will say whether to retrain. Pick up from here.

### What ran

- **Where:** Kaggle, "GPU T4 x2", free quota, both private to the owner's account. Colab could not
  allocate an L4 or A100 for hours, and a single T4 ran out of memory in the validation pass (the full
  vocabulary's logits for a 512-line batch need about 5 GB). `finetune.py` now takes `--eval-batch`
  (128 on Kaggle) and wraps the model in `DataParallel` when it sees more than one GPU.
- **Job files:** `training/typing-lm/kaggle/finetune/` (job `<kaggle-user>/murmur-hinglish-finetune`,
  dataset `<kaggle-user>/murmur-hinglish-inputs`) and `training/typing-lm/kaggle/compare/` (job
  `<kaggle-user>/murmur-lm-compare`, dataset `<kaggle-user>/murmur-typing-eval`). The datasets hold the
  scripts, the eval files, the 2,000-word token list and the 8% HingCorpus sample, so they are
  CC BY-NC-SA derived and stay private; only the job scripts and metadata are in git. Push a job with
  `kaggle kernels push -p <folder>`, watch it with `kaggle kernels status <id>`, fetch with
  `kaggle kernels output <id> -p <dir>`. Kaggle unpacks an uploaded `.gz`, so the job looks for
  `hinglish-sample.txt.gz` or `hinglish-sample.txt`. A kernel cannot share its slug with a dataset
  (409 Conflict), which is why the compare job is `murmur-lm-compare`.
- **Run:** share 0.15, `--added-tokens`, transformers 4.53.2 pinned in the job, 3,185,636 examples
  (16.0 tokens each), 12,444 steps at 4.2 steps a second, 49.9 minutes. Validation loss 4.75 before,
  then 3.48, 3.39 and 3.35 at the quarter, half and full checkpoints. Training loss ended about 3.43,
  level with validation, so it converged without overfitting; more steps on the same data would gain
  little.

### Results (PyTorch fp32, 32 tokens, `--second 0`, top-1 / top-3 · keystrokes saved)

| Set | Stock | Phone before (run 2 quarter) | Installed (Hinglish full) |
|---|---|---|---|
| written | 23.77 / 39.91 · 54.02% | 29.65 / 47.77 · 59.13% | 30.44 / 47.57 · 59.29% |
| lower | 23.86 / 39.94 · 54.18% | 29.19 / 47.64 · 59.08% | 30.04 / 47.24 · 59.08% |
| replay | 26.57 / 45.05 · 59.79% | 32.14 / 54.50 · 65.45% | 33.20 / 53.09 · 65.34% |
| tatoeba | 21.57 / 35.59 · 49.73% | 26.68 / 41.82 · 54.02% | 27.37 / 42.28 · 54.11% |
| Hinglish held out, top-3 | 5.6% (with untrained rows) | most words not offerable | 16.6% |

The stock row was rerun on Kaggle (transformers 5.20.2) and matched the Mac's numbers to the digit, so
the run-2 row, taken from the README's table, compares like for like. Run 2's PyTorch weights were in
`~/Library/Caches` and are gone; its built model is the backup below. Replay top-3 fell 1.4 points
(the bar set beforehand was "not lower"); run 2's own full checkpoint scored 52.79 there, so 54.50 looks
like a lucky checkpoint. The owner accepted the trade for Hinglish.

### Where things are (none of it in git)

- Installed model: `ios/TypingLM` (`NextWord.mlmodelc` 52.3 MB, `added_tokens.json`, `model.json` with
  `fineTuned.sha256` `e0aed293...` and `addedTokens.count` 2000, plus the Hinglish `en.mtm` from plan 003).
- Checkpoints: `~/Library/Application Support/MurmurKeep/hinglish-ft-kaggle/ft/{quarter,half,full}`,
  with the run's `ft.log` and `hinglish-heldout.txt`.
- Previous phone model (rollback): `~/Library/Application Support/MurmurKeep/TypingLM-ft-quarter-2026-11-26`.
  To roll back, replace `ios/TypingLM`'s `NextWord.mlmodelc`, `vocab.json`, `merges.txt` and `model.json`
  with that folder's, delete `ios/TypingLM/added_tokens.json`, keep `en.mtm`, and `make ios-install`.
- Comparison log: `~/Library/Application Support/MurmurKeep/kaggle-eval/out/murmur-lm-compare.log`.

### If the owner asks for more

1. **Stronger Hinglish:** rerun the finetune job with `--hinglish-share 0.3` (edit `run.py`), compare
   with the compare job (add the new folder), install only if English holds. Expect Hinglish up and
   English slightly down.
2. **Spelling variants** ("nahi", "nhi", "nahin") split probability; folding them in the training text or
   the word list is untried.
3. **Rebuild the model** from a checkpoint: `uv run Tools/fetch_typing_lm.py --weights <folder>
   --added-tokens <folder>/added-tokens.txt` (35 s niced), then `make ios-install`.
4. The swipe network and personal learning (owner's order: swipe network, then recording and instant
   learning, then nightly fine-tune) come after the owner's verdict on this model.

**Owner's constraints:** do not run training or evaluation on the Mac (it needs the CPU and memory);
use Kaggle. A Core ML conversion is fine. Ask before spending paid GPU units.

Job and dataset ids are written as `<kaggle-user>/...`; put the owner's Kaggle username in the four
`*-metadata.json` files before pushing (`kaggle config view` shows it).
