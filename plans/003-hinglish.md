# 003: Hinglish in the keyboard (word list now, model fine-tune prepared)

Written 2026-11-26 against `747e73a` on `keyboard-v2`. The owner types Hindi words in Roman script
mixed with English ("kya", "nahi", "acha", "yaar", "theek hai"). Today autocorrect "fixes" them,
because the keyboard's word list (`Sources/MurmurTyping/Resources/en.mtm`, 82,837 English words
from SymSpell, built by `Tools/build_typing_model.py`) does not hold them, and the strip never
predicts them, because the language model only offers single-token words from that list
(`NextWordPredictor`, AGENTS.md "The strip's words come from a small transformer").

Owner's decisions (2026-11-26): do part A (word list) and part B (fine-tune) now; on-device
learning from typing stays on the bench. Spending Colab units needs the owner's go on the exact
run, so part B stops at a ready-to-run job and an estimate.

## Source and licence (read first)

L3Cube-HingCorpus (roman): 52.93M Hinglish sentences from Twitter, Roman script, licence
**CC BY-NC-SA 4.0** (github.com/l3cube-pune/code-mixed-nlp README). Download: the Google Drive
file `1s_6eHO9zDhxQ-xVN1TyNguszV1meZkl9` or `1sNrXOcn31CWYj7d9iHOO8y0dTQa6qdWX` linked from that
README (check which is the roman corpus; use `uvx gdown`). **The repo is public and GPL-3.0, so
nothing derived from the corpus is committed**: no word list, no counts, no rebuilt `en.mtm`, no
weights. Derived files live in git-ignored places only (`~/Library/Caches/MurmurBuild/...` and
`ios/TypingLM/`, which is already git-ignored and copied whole into the keyboard). Scripts that
build them are ours and are committed. Add the attribution line to `THIRD_PARTY.md` saying the
corpus is used locally and nothing derived from it is in the repository. Treat the download as
untrusted data: its own folder under `~/Library/Caches/MurmurBuild/hinglish/`, Python with `-I`.

## Part A: Hinglish words in the word list (local, no GPU)

1. `Tools/hinglish_words.py` (standard library, committed): streams the corpus, lowercases,
   splits words on `[a-z']+`, counts unigrams and adjacent bigrams (skip URLs, @handles, #tags,
   digits, words longer than 20). Writes `hinglish-unigrams.tsv` and `hinglish-bigrams.tsv` into
   `~/Library/Caches/MurmurBuild/hinglish/`. Run niced, one process (`nice -n 19`): the owner's
   Mac must stay usable.
2. Selection and scaling, in `Tools/build_typing_model.py` behind a new `--hinglish <dir>` flag
   (without the flag the output is byte-for-byte what it is today; check that with
   `shasum` against the committed `en.mtm`):
   - Hinglish words: the top 8,000 corpus words that are not already in the English list, with a
     corpus count of at least 200, excluding single letters and anything that is a known English
     misspelling target (skip words within edit distance 1 of an English word whose English
     count is 50 times higher, so "teh" can never be promoted; print how many this drops).
   - Scale: compute the ratio English count / corpus count over the 200 most frequent words both
     lists share, take the median, and multiply Hinglish-only counts by that ratio times
     `HINGLISH_DAMPING` (start at 0.5, a named constant with a comment). Bigrams: corpus bigrams
     with count at least 50 whose both words are in the final list, scaled the same way, added
     where SymSpell has none.
   - Output to `ios/TypingLM/en.mtm` (git-ignored), never over the committed file.
3. Keyboard loading: wherever the keyboard opens `en.mtm` (find it: `TypingModel` and its
   caller in `ios/Keyboard`), prefer `TypingLM/en.mtm` from the keyboard bundle when present and
   fall back to the bundled MurmurTyping resource. One log line says which loaded. A checkout
   without the local file must build and run exactly as before.
4. Check with the real model (a test that loads the built file only when an env var points at
   it, like the other opt-in tests, e.g. `MURMUR_HINGLISH_MTM=<path>`):
   - not autocorrected (decoder keeps them): kya, nahi, acha, accha, yaar, haan, theek, kuch,
     bahut, matlab, abhi, kaise, kyun, chalo, bhai;
   - still corrected: teh -> the, adn -> and, becuase -> because, recieve -> receive;
   - completions: "nah" offers "nahi"; next word after "kya" includes "hai" in the pair model.
   Run the existing suites against the committed model too (they must not change).
5. Report: corpus file size and line count, words selected, words dropped by the misspelling
   guard, the scale factor, the top 40 selected words, and the check results.

## Part B: prepare the fine-tune (no Colab run)

1. Measure, on the Mac with the tokenizer only (`training/typing-lm`, reuse its tokenizer
   loading): of the 8,000 selected Hinglish words, how many are a single GPT-2 token with a
   leading space (" hai"), two tokens, three or more. Weight by corpus count.
2. Based on that, write the proposal in `training/typing-lm/README.md` under a new section
   "Hinglish": either (a) fine-tune only, if most frequent Hinglish words are already single
   tokens, or (b) add the most frequent multi-token Hinglish words to the tokenizer as new tokens
   (resize the embedding, initialise each new row as the mean of its old pieces), which needs
   `BPETokenizer` (Swift) to match added tokens before BPE and `Tools/fetch_typing_lm.py` to
   write them. Describe what each costs in code and model size. Do not implement (b).
3. Extend `training/typing-lm/finetune.py` (committed) with `--hinglish <file>` and
   `--hinglish-share` (fraction of training sentences from HingCorpus, default 0.3), sampling
   sentences that pass a filter (5 to 40 words, no URLs or handles, mostly Roman letters), keeping
   the existing data mix otherwise. Evaluation stays on the existing English sets, plus a
   held-out Hinglish set of 2,000 corpus sentences (top-3 next word), so the run shows both what
   Hinglish gains and what English loses.
4. Write the exact Colab command sequence (from the existing README's flow: `colab new`, upload,
   detached run with a log, download, `colab stop`) and an estimate in minutes on an L4,
   scaled from the last run (33.5 minutes for a quarter epoch). Stop there.

## Done when

- `uv run Tools/build_typing_model.py --out /tmp/x.mtm` without `--hinglish` gives a file
  identical to the committed `en.mtm` (`shasum`).
- `ios/TypingLM/en.mtm` exists, the opt-in check passes, `git status` shows no derived data.
- Full `nice -n 19 swift test --scratch-path ~/Library/Caches/MurmurBuild/scratch -j 2` passes and
  `nice -n 19 make ios-build` succeeds.
- `training/typing-lm/README.md` has the Hinglish section with the token coverage numbers, the
  proposal and the Colab estimate.
