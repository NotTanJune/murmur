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
