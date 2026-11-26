# The keyboard's next-word model

The iPhone keyboard's suggestion strip ranks words with a word-pair model
(`SuggestionEngine`, data in `en.mtm`). A pair model knows one word of context, so repeated taps
on the centre cell wrote "my dog breeds of the same time to the first to be a new window"
(the owner, 2026-11-25). This folder holds the spike that measured small pretrained language
models against it, and the scripts that convert the one that was kept. The app's side is
`Sources/MurmurTyping/Predict`, `ios/Keyboard/SmartPredictions.swift` and
`Tools/fetch_typing_lm.py`.

Nothing here ships in the app, and nothing here was uploaded anywhere. Downloads, the Python
environment and converted models live in `~/Library/Caches/MurmurBuild/typing-lm/`.

## What was chosen

`distilbert/distilgpt2`, Apache-2.0, 81.9 M parameters (6 layers, width 768, GPT-2's 50,257
token vocabulary), pinned to Hugging Face revision `2290a62682d06624634c1f46a6ad5be0f47f38aa`.
`model.safetensors` is 352,824,413 bytes, SHA-256
`e1ff18884359fe8beb795a5f414feb85a6ce3d929ad019c0d958c039d2b94a1b`; `Tools/fetch_typing_lm.py`
holds the size and hash of every file it downloads.

It runs through Core ML on the CPU with a fixed window of 32 tokens and no key-value cache. The
embedding table is a 4-bit palette and every other weight a 6-bit palette (`emb4rest6`), 51.5 MB.

## Files

| File | What it is |
|---|---|
| `make_eval.py` | builds `eval-sentences.tsv` from Murmur's replay sentences and a pinned Tatoeba export |
| `eval-sentences.tsv` | 519 entries, 579 sentences: 229 of Murmur's own, 290 from Tatoeba (CC BY 2.0 FR, ids in the file) |
| `cases.py` | turns the entries into cases: a text before the cursor and the word written next |
| `evaluate.py` | hit rates for a model on disk, in PyTorch or (`--coreml`) the converted model |
| `convert.py` | PyTorch to Core ML, and the weight formats |
| `measure.swift` | load time, latency and footprint of a compiled model in a fresh process |
| `bench_predict.swift` | the same for the keyboard's whole path (`NextWordPredictor.predict`), in a release build |
| `hinglish_tokens.py` | how GPT-2's tokenizer splits the Hinglish words the word list gains, and (`--emit`) the 2,000 words to add as tokens (see "Hinglish") |
| `added_tokens.py` | the shared code for whole-word added tokens: the word list, the reference tokenizer, the mean-initialised rows |
| `extend_model.py` | a model folder plus added tokens with no training, for `evaluate.py` and `convert.py` |
| `make_bpe_vectors.py` | writes `Tests/MurmurTypingTests/bpe-vectors.json` (and with `--added`, vectors for a tokenizer with added tokens) from the reference tokenizer |

The pair model's side of the evaluation is `Tests/MurmurTypingTests/TypingLMEvalTests.swift`,
which runs the real `SuggestionEngine` over the same cases.

## Commands

```bash
L=~/Library/Caches/MurmurBuild/typing-lm
uv venv --python 3.12 $L/venv
VIRTUAL_ENV=$L/venv uv pip install torch==2.7.1 transformers==4.53.2 coremltools==8.3.0 \
    "numpy<2.3" huggingface_hub scikit-learn

# Evaluation set (the Tatoeba export is checked by size and SHA-256; it changes weekly).
curl -o $L/tatoeba/eng_sentences.tsv.bz2 \
    https://downloads.tatoeba.org/exports/per_language/eng/eng_sentences.tsv.bz2
python3 training/typing-lm/make_eval.py --tatoeba $L/tatoeba/eng_sentences.tsv.bz2 \
    --out training/typing-lm/eval-sentences.tsv
python3 training/typing-lm/cases.py --eval training/typing-lm/eval-sentences.tsv --out $L/eval

# The pair model's answers, its word list and its centre-tap chains.
MURMUR_TYPING_LM_CASES=$L/eval/befores.json MURMUR_TYPING_LM_OUT=$L/eval/bigram.json \
MURMUR_TYPING_LM_WORDS=$L/eval/words.tsv \
    swift test --scratch-path ~/Library/Caches/MurmurBuild/scratch --filter TypingLMEvalTests

# A candidate (a Hugging Face model folder, fetched with huggingface_hub at a pinned revision).
$L/venv/bin/python training/typing-lm/evaluate.py --model $L/models/distilgpt2 --name distilgpt2 \
    --eval-dir $L/eval --context 32 --second 4 --fresh

# Convert, compress, and check the converted model's accuracy and cost.
$L/venv/bin/python training/typing-lm/convert.py --model $L/models/distilgpt2 --out $L/coreml \
    --context 32 --format fp16 --compile
$L/venv/bin/python training/typing-lm/convert.py --model $L/models/distilgpt2 --out $L/coreml \
    --context 32 --format emb4rest6 --from-package $L/coreml/distilgpt2-c32-fp16.mlpackage --compile
$L/venv/bin/python training/typing-lm/evaluate.py --model $L/models/distilgpt2 --name distilgpt2 \
    --eval-dir $L/eval --coreml $L/coreml/distilgpt2-c32-emb4rest6.mlpackage
swiftc -O training/typing-lm/measure.swift -o $L/measure
$L/measure $L/coreml/distilgpt2-c32-emb4rest6.mlmodelc cpu 32 200

# The build's copy, the whole Swift path timed on it, and the tokenizer's test vectors.
uv run Tools/fetch_typing_lm.py --fetch
swiftc -O -parse-as-library training/typing-lm/bench_predict.swift Sources/MurmurTyping/Predict/*.swift \
    Sources/MurmurTyping/Lexicon/TypingModel.swift -o $L/bench/bench_predict
$L/bench/bench_predict ios/TypingLM Sources/MurmurTyping/Resources/en.mtm training/typing-lm/eval-sentences.tsv
$L/venv/bin/python training/typing-lm/make_bpe_vectors.py --model $L/models/distilgpt2 \
    --eval training/typing-lm/eval-sentences.tsv --out Tests/MurmurTypingTests/bpe-vectors.json
```

## How it was measured

A case is the text before the cursor and the word that was written next, for every word of
every entry: 4,337 word positions. The text is the entry so far, so the second sentence of a
two-sentence entry has the first as context. There are two sets: `written` (Murmur's sentences,
which are lowercase with no punctuation, and Tatoeba's as written) and `lower` (everything
lowercased, the way the owner types). Words are compared folded to lowercase. Sentence-initial
names survive the filter ("Sami", "Mary"); no model can predict them.

- **Next word**: the three words the strip would show after the space. `@1` is the centre cell.
- **Completion** after 1, 2 and 3 typed letters, for words longer than what is typed. The strip
  has two completion cells, so `@2` is what it shows; `@3` is there for comparison.
- **Keys saved**: the word is tapped in the strip the first time it shows there (next word, or
  after 1, 2 or 3 letters), which costs one key and types the space; otherwise every letter and
  the space are typed.

Every system keeps the strip's rules: no single letters but "a" and "i", nothing from
`SuggestionEngine.neverVolunteered`, no pair of words written again, and a word already used
held back.

**From tokens to words.** One pass gives the distribution of the next token. A token that
starts a new word and is, lowercased, one of the keyboard's 82,842 words stands for that word;
case variants add up. 20,182 words are one token, and they cover 96.2% of the words written in
the evaluation set (99.2% are in the word list at all). Sixteen stems of contractions that are
no words ("didn") stand for the contraction.

## Results (2026-11-25, Apple M2, 8 GB)

### Candidates

PyTorch, 32-bit weights, a window of 32 tokens. Percent of 4,337 word positions; completion
columns are `@1 / @2 / @3`. `written` set first, `lower` set second.

| System | Next @1 | Next @3 | After 1 letter | After 2 letters | After 3 letters | Keys saved |
|---|---|---|---|---|---|---|
| Pair model (`SuggestionEngine`) | 12.84 | 22.87 | 34.01 / 44.65 / 52.18 | 48.87 / 60.83 / 67.54 | 66.28 / 77.34 / 82.43 | 39.33 |
| distilgpt2 (81.9 M) | 23.77 | 39.91 | 56.54 / 67.36 / 72.86 | 68.29 / 78.83 / 83.29 | 80.89 / 88.60 / 90.96 | 54.02 |
| distilgpt2, second step over 4 tokens | 23.82 | 40.00 | 56.64 / 67.33 / 72.98 | 68.35 / 79.01 / 83.65 | 81.32 / 89.16 / 91.56 | 54.24 |
| pythia-70m (70.4 M) | 22.60 | 36.43 | 52.23 / 63.36 / 70.09 | 65.58 / 76.18 / 82.05 | 78.88 / 87.28 / 89.72 | 51.79 |
| SmolLM2-135M (134.5 M) | 27.30 | 42.84 | 57.78 / 68.36 / 73.54 | 69.59 / 78.47 / 83.50 | 81.49 / 89.03 / 91.26 | 55.14 |

| System, `lower` set | Next @1 | Next @3 | After 1 letter | After 2 letters | After 3 letters | Keys saved |
|---|---|---|---|---|---|---|
| Pair model | 12.84 | 22.87 | 34.01 / 44.65 / 52.18 | 48.87 / 60.83 / 67.54 | 66.28 / 77.34 / 82.43 | 39.33 |
| distilgpt2 | 23.86 | 39.94 | 56.30 / 67.19 / 72.62 | 68.05 / 79.25 / 83.86 | 81.06 / 88.86 / 90.92 | 54.18 |
| distilgpt2, second step over 4 tokens | 23.89 | 40.05 | 56.37 / 67.19 / 72.69 | 68.17 / 79.43 / 84.16 | 81.32 / 89.25 / 91.39 | 54.37 |
| pythia-70m | 21.63 | 35.12 | 50.94 / 62.63 / 69.48 | 64.32 / 75.67 / 81.21 | 77.76 / 86.50 / 89.03 | 50.99 |
| SmolLM2-135M | 27.37 | 42.56 | 57.03 / 67.89 / 72.96 | 69.20 / 78.29 / 83.29 | 81.36 / 88.60 / 90.96 | 54.76 |

The pair model folds case, so its two rows are the same. Pinned revisions: pythia-70m
`a39f36b100fe8a5377810d56c3f4789b9c53ac42`, SmolLM2-135M
`93efa2f097d58c2a74874c7e644dbc9b0cee75a2`, both Apache-2.0.

- **The second step is not worth its passes.** Four more passes per word for the likeliest
  first tokens of two-token words moved next-word top three by 0.1 points. Contractions that
  need it ("I'm", "it's") stay with the pair model's completions.
- **Mid-word, the distribution from the word's start is enough.** The completion columns above
  use only that. The alternative measured, a new pass over the text with the typed letters in
  it and one more token to finish the word, reached 1.05 / 5.06 / 22.88% at `@1` after 1, 2 and
  3 letters, against 56.54 / 68.29 / 80.89%: typed letters are not how the tokenizer writes
  the word, so the model has never seen that path.
- **The window barely matters here.** 24 tokens gave the same numbers as 32 to the last digit,
  and 12 tokens 39.54% top three (written). The evaluation's entries are short; a long message
  is where a longer window would show, and it is not measured.
- **Why not SmolLM2.** It is the most accurate (42.84% top three), but 134.5 M parameters would
  be about 67 MB at 4 bits (not converted), over the 60 MB limit set for the build, and it has 30 layers to
  distilgpt2's 6. pythia-70m is smaller and faster and loses 3.5 points (4.8 lowercased).

Centre-tap chains, 15 taps from each start:

| System | Chains |
|---|---|
| Pair model | my dog breeds of the same time to the first to be a new window and the · i have been a new window and the same time to the first to be a · the same time to the first to be a new window and the following the same · please contact us to the same time to be a new window and the first to · can you are not be a new window and the same time to the first to be |
| distilgpt2 | my dog is a little bit more than a puppy and i love him so much and · i have a lot of fun with it and i love it so much i can · the world of the internet is a place where people can be free to do whatever · please enable javascript to view the comments powered by dis advertisement or other media in your · can you tell me what you think of the new game and how it will affect the |
| pythia-70m | my dog is a great friend of mine and i am a very lucky dog and a · i have a question about the size of the data i need to know how to · the first time i had this conversation with you on the phone and i thought i · please read the following below to the right of the page to see if the item · can you help me with this issue please let me know if you have any questions or |
| SmolLM2-135M | my dog is a cat and i am a human being and we are both animals and · i have a question about the following code snippet in the previous post on the topic · the world of the future is a place where people can live in peace and harmony · please read the following article and answer the questions below in your own words and in · can you use the word in a sentence with the meaning of the term in the dictionary |
| distilgpt2 as built (`emb4rest6`, through `SuggestionEngine`) | my dog is a great friend and I love him so much and he is a wonderful · i think that it is a good idea to have a lot of fun with it · the best way to get to the top of your game is to play with a · please enable javascript to view the comments powered by dis advertisement ads or other media you · can you help us make this happen by donating to our campaign and helping to keep this |

"dis" is "Disqus": the model's first token of it is a word of the keyboard's list, and one pass
cannot tell that the model meant to go on.

### Weight formats (distilgpt2, 32 tokens, Core ML on the CPU)

Accuracy is next word `@1 / @3`, `written` then `lower`. Cold is a first load with Core ML's
compile cache removed, warm a later load; both in a fresh process (`measure.swift`, 200
predictions on random tokens). Footprint is the process's `phys_footprint` gained, at its peak.

| Format | File | Accuracy written | Accuracy lower | Cold load | Cold footprint | Warm load | Warm footprint | p50 / p95 | Compile cache |
|---|---|---|---|---|---|---|---|---|---|
| `fp16` | 162.5 MB | 23.75 / 39.68 | 23.68 / 39.68 | 551 ms | +10.4 MB | 5 ms | +2.8 MB | 3.5 / 3.8 ms | 155 MiB |
| `int8` | 81.6 MB | 24.16 / 39.77 | 24.30 / 39.73 | 366 ms | +17.4 MB | 5 ms | +2.8 MB | 3.5 / 3.9 ms | 155 MiB |
| `pal6` | 61.2 MB | 24.26 / 39.84 | 23.89 / 39.91 | 292 ms | +18.8 MB | 5 ms | +2.8 MB | 3.5 / 3.8 ms | 183 MiB |
| `pal4` | 40.9 MB | 22.46 / 37.88 | 21.77 / 37.42 | 297 ms | +11.0 MB | 5 ms | +2.9 MB | 3.3 / 3.6 ms | 113 MiB |
| `pal4s` | 43.3 MB | 0.00 / 0.00 | 0.00 / 0.00 | not measured | | | | | |
| `emb6rest4` | 50.5 MB | 23.29 / 38.39 | 22.60 / 38.21 | not measured | | | | | |
| `emb4rest8` | 62.2 MB | 23.54 / 39.45 | 23.26 / 39.27 | not measured | | | | | |
| **`emb4rest6`** | **51.5 MB** | **23.54 / 39.24** | **23.06 / 39.04** | 282 ms | +17.7 MB | 5 ms | +2.9 MB | 3.5 / 3.8 ms | 174 MiB |

- The footprint is small in every format because Core ML compiles the model once into a BNNS
  program in the process's cache folder (`com.apple.e5rt.e5bundlecache`, the last column) and
  maps the weights from that file; mapped pages that are only read do not count. The cost
  moves to disk: 174 MiB for the format that was kept, rebuilt whenever the system clears the
  cache.
- `pal4s` (a 4-bit palette with a scale per channel) converts and loads, and predicts nonsense
  on the CPU.
- A 24-token window in `fp16` measured 3.8 / 4.8 ms, no faster than 32, so 32 was kept.

**The Neural Engine** (`cpuAndNeuralEngine`), same tool:

| Format | Cold load | Cold footprint | Warm load | Warm footprint | p50 / p95 |
|---|---|---|---|---|---|
| `emb4rest6` | 3,921 ms | +239.8 MB | 22 ms | +7.3 MB | 1.5 / 1.6 ms |
| `pal4` | 3,869 ms | +238.6 MB | 25 ms | +8.2 MB | 1.3 / 1.5 ms |
| `fp16` | 1,767 ms | +16.9 MB | 25 ms | +7.4 MB | 3.6 / 5.8 ms |

Two milliseconds faster when warm, and a first load that puts 240 MB into the process, which
is more than the 177 MB at which an iPhone 15 Pro kills the keyboard. The keyboard asks for
the CPU.

**The whole path in Swift** (`bench_predict.swift`, release build: tokenizer, Core ML pass,
tokens to words, over 505 word boundaries of the evaluation set):

| | Load | Footprint after all | First prediction | p50 | p95 |
|---|---|---|---|---|---|
| Cold | 550 ms | +25.4 MB | 9.6 ms | 3.60 ms | 4.32 ms |
| Warm | 285 ms | +13.6 MB | 9.6 ms | 3.49 ms | 3.63 ms |

The tokenizer's two files and the word tables are 11 MB of that footprint and 0.28 s of the
load.

### The gate

| Requirement | Limit | Measured |
|---|---|---|
| Next-word top three against the pair model | at least 1.3 times (29.73%) | 39.24% written, 39.04% lowercased: 1.72 and 1.71 times |
| Model file | at most 60 MB | 51.5 MB |
| Added footprint on the Mac | at most 80 MB | 25.4 MB at a first load, 13.6 MB after |
| p95 prediction on the Mac's CPU | at most 40 ms | 4.3 ms |

Passed, on a Mac.

## Fine-tune (2026-11-26, Colab L4)

The stock model's taste is the web's, and the owner types lowercase messages and notes.
`finetune.py` trains it a little further on Tatoeba's English sentences and single turns from
SODA (2.9 M examples: 40% as written, 30% lowercased, 30% lowercased without punctuation), one
epoch, with checkpoints at a quarter, a half and the end. Nothing from the evaluation set is
trained on. A first run kept Tatoeba's stock names and offered "tom" mid-sentence, so the second
drops every sentence that holds one. The second run took 33.5 minutes; validation loss 3.94
before, 2.78, 2.70 and 2.67 at the three checkpoints.

PyTorch fp32, 32-token window, next word @1 / @3 and keystrokes saved. `replay` is Murmur's own
229 sentences, lowercased, and the clean measure; Tatoeba's half is flattered by training on its
other sentences.

| Model | written | lower | replay | tatoeba |
|---|---|---|---|---|
| Pair model | 12.84 / 22.87 · 39.33% | same | 15.37 / 27.98 · 44.85% | 10.70 / 18.54 · 34.94% |
| Run 2, quarter | 29.65 / 47.77 · 59.13% | 29.19 / 47.64 · 59.08% | 32.14 / 54.50 · 65.45% | 26.68 / 41.82 · 54.02% |
| Run 2, half | 29.63 / 47.04 · 59.24% | 29.19 / 46.60 · 59.01% | 32.30 / 52.29 · 64.94% | 26.56 / 41.77 · 54.30% |
| Run 2, full | 30.02 / 47.48 · 59.37% | 29.93 / 47.15 · 59.17% | 32.70 / 52.79 · 65.23% | 27.58 / 42.37 · 54.35% |

The stock model on the same sets is in the candidates table above (23.77 / 39.91 written). The
three checkpoints are level, so the quarter one is kept: it moved least from the stock weights
and has the best replay @3. Its `model.safetensors` is 327,657,928 bytes, SHA-256
`952ef2d83ae862f68783b5c0cb86e1654f6fa5d16bef9829a9bb717f7c275194`; it is in no repository
(`~/Library/Caches/MurmurBuild/typing-lm-ft/quarter` on the owner's Mac) and is built into
`ios/TypingLM` with `uv run Tools/fetch_typing_lm.py --fetch --weights <folder>`. Centre taps
through the Swift engine with the converted model: "my dog is very shy and I don't know if he
likes me or not he just wants to be with you", "please don't worry about it I know you will do
great in your new job". The converted file's accuracy was not measured again after conversion.

Colab's proxy token lasts an hour, and `colab exec` after that fails with a 404 and drops the
session from `~/.config/colab-cli/sessions.json` while the VM keeps running and billing. The
assignment list still gives a fresh token for it; restore the entry from that, then stop it.

## Hinglish

The owner mixes Hindi written in Roman script into English ("kya hai yaar"). The word list side is
done: `Tools/hinglish_words.py` counts L3Cube-HingCorpus (roman; 52,933,356 sentences, a 2.49 GB
download that unpacks to a 4.88 GB training file and a 0.51 GB validation file), and
`Tools/build_typing_model.py --hinglish <folder>` writes a word list with 8,000 more words to
`ios/TypingLM/en.mtm`, which the keyboard prefers over the bundled one. The corpus is CC BY-NC-SA
4.0, so none of that output, and no model trained on it, may enter the repository (`THIRD_PARTY.md`).
This section is about the language model, which only offers words that are one token.

### Token coverage (measured 2026-11-26, `hinglish_tokens.py`)

The 8,000 added words, each written with its leading space (" hai") as the model sees a word after a
space, against GPT-2's 50,257 tokens, weighted by corpus occurrences:

| Tokens per word | Words | Share of words | Share of corpus occurrences |
|---|---|---|---|
| 1 | 190 | 2.4% | 22.2% |
| 2 | 4,067 | 50.8% | 62.2% |
| 3 or more | 3,743 | 46.8% | 15.6% |

Fine-tuning cannot fix this: the strip takes a prediction only for a word that is one token
(`NextWordPredictor`), so 77.8% of the Hinglish a user types would still never be offered as a
next word, however well the model learned to expect it. The most frequent ones are the worst
cases (the words that matter most are split in two). The multi-token occurrences are
concentrated, which is what makes option (b) cheap: the 100 most frequent multi-token words hold
49.4% of multi-token occurrences, the top 500 hold 73.7%, the top 1,000 82.8% and the top 2,000
90.1%. Giving the top 2,000 their own tokens would make 92.3% of Hinglish occurrences one token
(500: 79.5%, 1,000: 86.6%).

### Proposal

Do (b), not (a) alone. The code for (b) is in (plan 004, 2026-11-26, owner's choice at a Hinglish share
of 0.15); the training run is not done. "What plan 004 built" below says what is in and what was
measured; the bullets here are the proposal as written.

- **(a) Fine-tune only.** Cost: `finetune.py --hinglish` below and nothing else in code. Gain: the
  model learns Hinglish word order, but it can be offered only for the 22.2% of occurrences that are
  already one token, and the other words get their first piece predicted and then nothing. It would
  mostly help the English words in mixed sentences.
- **(b) Add the 2,000 most frequent multi-token Hinglish words as new tokens, then fine-tune.**
  - Model: resize the embedding from 50,257 to 52,257 rows (the output layer is tied to it), each new
    row the mean of the rows of the word's old pieces, so the model starts where it was. +1.5 M
    parameters; in the 4-bit embedding palette about +0.8 MB on the 51.5 MB file, and the
    output logits are 4% wider (a small cost per pass, unmeasured). The 2,000 words are chosen from
    the corpus, so the list is a local file, never committed.
  - `BPETokenizer` (Swift): before byte-pair merging, a pre-token (the regex's " hai" piece) found in
    an added-token table is emitted as its id; any other pre-token goes through BPE as now. About a
    dozen lines plus a loader for `added_tokens.json`, and new test vectors from the reference
    tokenizer with the same table added (`make_bpe_vectors.py`).
  - `NextWordPredictor`: the token-to-word table must include the added tokens (a word that is in
    the word list and is now one token). The word list already holds them when built with
    `--hinglish`; a model built with added tokens and a word list without them would simply never
    surface them.
  - `Tools/fetch_typing_lm.py` and `convert.py`: take `--added-tokens <file>` and the fine-tuned
    weights, set the vocabulary size in the Core ML model, write `added_tokens.json` into
    `ios/TypingLM`, and record the table's SHA-256 in `model.json`.
  - `finetune.py`: load the tokenizer with the added tokens (`tokenizer.add_tokens`, then
    `model.resize_token_embeddings` and the mean initialisation) before tokenising anything, so
    that the held-out Hinglish line shows the gain. Its current Hinglish numbers count a multi-token
    word as a miss, which is the keyboard's behaviour today.
  - Risks: the added words are only the ones seen in tweets; the English evaluation must not drop
    (it is in the same log); and the 1.5 M new rows learn from the first fine-tune only.

### What plan 004 built (2026-11-26; no model is trained yet)

- **The words.** `hinglish_tokens.py --emit <file>` writes the 2,000 most frequent multi-token
  words that are a space and letters a to z (apostrophe words such as "today's" are cut at the
  apostrophe by GPT-2's pattern and can never be one piece), most frequent first. They take 70.1%
  of all Hinglish occurrences, so with them 92.3% are one token (22.2% before). The file is local:
  `~/Library/Caches/MurmurBuild/hinglish/added-tokens.txt`.
- **Not `AddedToken`.** Measured with transformers 4.53.2 on " kya": `single_word=False` matches inside
  longer pieces (" kyaa" is " kya" and "a", " nahin" is " nahi" and "n"); `single_word=True` looks at
  the character before the match, which is the end of the previous word, so " kya" after a word is
  refused and is cut as " ky" and "a"; a bare word with `lstrip=True` drops the line break before
  it. What is wanted is "a whole pre-token that is on the list is its token", so the words go
  into the BPE vocabulary under their byte-level spelling ("Ġkya") and the model is built with
  `ignore_merges=True` (`added_tokens.py`). Every one of GPT-2's 50,257 tokens, written out as text,
  still tokenises to itself without the shortcut, so stock text is tokenised as before.
- **Swift.** `BPETokenizer(vocabulary:merges:addedTokens:)` reads `added_tokens.json` (text to id) and
  returns an added id for a whole piece equal to one of its words, before merging. The committed
  test is `addedTokensEncodeLikeTheReference`: 597 reference vectors (the 379 plain ones plus texts
  around three hand-written words, `Tests/MurmurTypingTests/added-tokens-test.txt`) must match. The same
  check runs against the real list when `MURMUR_ADDED_TOKENS_JSON` and `MURMUR_ADDED_VECTORS` name the
  built table and the vectors `make_bpe_vectors.py --added <list> --words 2000` wrote under
  `~/Library/Caches/MurmurBuild/typing-lm-004/` (597 vectors, 0 wrong). `NextWordPredictor` takes the table
  from the model folder, builds its token-to-word tables with the added tokens in them, and
  refuses a model whose `logp` is narrower than the tokenizer's ids.
- **Build.** `uv run Tools/fetch_typing_lm.py --added-tokens <list> [--weights <fine-tune>] --out <folder>`
  writes the model with `added_tokens.json` beside it and the SHA-256 of the list and the table in
  `model.json`. With the pinned weights the new rows are the mean of each word's pieces; a fine-tune
  made with `finetune.py --added-tokens <list>` already has them. 52.3 MB against 51.5 MB.
- **Proof without training** (stock distilgpt2 plus mean-initialised rows, built into
  `~/Library/Caches/MurmurBuild/typing-lm-004/`, not into `ios/TypingLM`). `evaluate.py` English numbers,
  `--second 0`, PyTorch: stock and stock-plus-rows are identical to the digit on every row (replay,
  lowercased next@3 `lm` 45.05 and 39.94, keys saved 59.79% and 54.18%). That is what the
  proxy can show: it ranks only the word list's English tokens, and extra output columns never
  change the order among the others; what the rows do change is the share of probability they take, which it
  does not see. In the Swift predictor, with the Hinglish word model, 400 added words (the first 400 alphabetically, all in the word model) each had a
  probability above zero at a word boundary (they were two tokens and had none), and the predictor had
  2,330 more predictable words than with the English word model. A 20-step CPU run of `finetune.py` with
  the list (3,000 Tatoeba sentences, 529 Hinglish lines, batch 32) trained, wrote its checkpoints, and
  `fetch_typing_lm.py --weights` built a model from one; the held-out Hinglish measure counted
  87.4% of words as one token.

### What `finetune.py --hinglish` does

Training sentences are the existing English mix plus Hinglish lines, so that `--hinglish-share`
(default 0.15; 0.3 adds about 1.24 M to the English part's 2.9 M examples, 0.15 about 0.51 M). The English part is unchanged. A Hinglish line is kept if it has 5 to 40 words, no URL,
handle, tag or digit, and at least 90% of its characters are Roman letters or plain punctuation;
duplicates by lowercased words are dropped. 2,000 kept lines are held out, written to
`<out>/hinglish-heldout.txt`, and never trained on. The three variants (as written, lowercased,
lowercased without punctuation) apply to Hinglish lines too. Before training and at each
checkpoint the log prints the top-three next-word hit rate for the English evaluation sentences
and for the held-out Hinglish lines (a token-level proxy: a one-token word among the three
likeliest tokens, anything else a miss; the keyboard's own measure is still `evaluate.py`).

### Colab run (not started; needs the owner's go on the exact run)

The exact run: share 0.15, the 2,000 added tokens, one L4. The corpus is public research data and no
private text goes up (the token list is derived from it and goes up with the sample). First the token
list and a sample of the corpus, on the Mac (8% of the training file, about 3.9 M lines, 150 MB or so
gzipped, far more than the 0.51 M kept lines share 0.15 needs; nothing is written but the sample, and
the corpus is read as a stream):

```bash
uv run --with tokenizers python -I training/typing-lm/hinglish_tokens.py \
    --hinglish ~/Library/Caches/MurmurBuild/hinglish \
    --emit ~/Library/Caches/MurmurBuild/hinglish/added-tokens.txt
```

```bash
H=~/Library/Caches/MurmurBuild/hinglish
tar -xzOf $H/raw/hingcorpus.download R11_final_data/concatenated_train_final_shuffled.txt \
  | awk 'BEGIN{srand(20261126)} rand()<0.08' | gzip > $H/hinglish-sample.txt.gz
```

Then the session, from the repository's root. Upload the pinned scripts and data, start the job
detached (a `colab exec` times out after 30 s), read the log, download, stop:

```bash
S=hinglish
colab new -s $S --gpu L4
colab exec -s $S -c "import os; os.makedirs('/content/in', exist_ok=True)"   # retry once if the first exec drops
colab upload -s $S training/typing-lm/finetune.py /content/in/finetune.py 2>&1 | grep -v -i token
colab upload -s $S training/typing-lm/added_tokens.py /content/in/added_tokens.py 2>&1 | grep -v -i token
colab upload -s $S $H/added-tokens.txt /content/in/added-tokens.txt 2>&1 | grep -v -i token
colab upload -s $S training/typing-lm/eval-sentences.tsv /content/in/eval-sentences.tsv 2>&1 | grep -v -i token
colab upload -s $S $H/hinglish-sample.txt.gz /content/in/hinglish-sample.txt.gz 2>&1 | grep -v -i token
cat > /tmp/launch.py <<'PY'
import subprocess
subprocess.Popen(
    "cd /content/in && pip install -q transformers==4.53.2 && python finetune.py --eval-sentences eval-sentences.tsv --out /content/ft "
    "--hinglish hinglish-sample.txt.gz --hinglish-share 0.15 --added-tokens added-tokens.txt "
    "> /content/ft.log 2>&1",
    shell=True, start_new_session=True)
PY
colab exec -s $S -f /tmp/launch.py
# every few minutes (the proxy token lasts an hour; see the note under "Fine-tune" above):
colab exec -s $S -c "print(open('/content/ft.log').read()[-1500:])"
# when the log says DONE (the checkpoints are Hugging Face folders; zip them to download one file):
colab exec -s $S -c "import shutil; shutil.make_archive('/content/ft', 'zip', '/content/ft')"
mkdir -p ~/Library/Application\ Support/MurmurKeep/typing-lm-ft   # not Caches: macOS purged the last run there
colab download -s $S /content/ft.zip ~/Library/Application\ Support/MurmurKeep/typing-lm-ft/hinglish.zip
colab stop -s $S
```

`-c` for a one-line command is assumed from the CLI's help and the whole flow is unrun here; if
`colab exec` has no `-c`, put the line in a file and use `-f`. Then evaluate each checkpoint with
`evaluate.py` as above (it reads the checkpoint's own `tokenizer.json`) and build the keyboard's copy
with `uv run Tools/fetch_typing_lm.py --weights <folder> --added-tokens <folder>/added-tokens.txt`
(into the git-ignored `ios/TypingLM`; the checkpoint carries a copy of the list, which must be the
one the run used, since the ids follow its order).

**Estimate, L4.** The last English run took 33.5 minutes for its 2.9 M examples (all three
checkpoints came out of that one run; the quarter checkpoint was at about 8 minutes). A
Hinglish tweet is longer in tokens than an English sentence (two tokens a word, up to the 48-token
cap), so time follows tokens and not examples. At share 0.3, 1.43 times the examples and roughly
2 to 2.5 times the tokens: about 65 to 85 minutes of training, plus about 10 for setup, the
Tatoeba and SODA downloads, tokenising and the held-out measurement; plan 90 minutes of L4 time.
Quarter-epoch checkpoint at about 20 minutes. A cheaper trial: `--hinglish-share 0.15` (about 45 to
55 minutes). Scaled, not measured; the L4's steps-per-second line in the first minutes of the log
is the real number, and the run can be stopped there.

**Estimate for the exact run above** (share 0.15, added tokens). Share 0.15 is 1.18 times the English
examples. With the added tokens a Hinglish line of the 20-step run's sample averages 22 tokens, 27
without them (5,000 lines, up to 47 tokens), and the English part is about 10 tokens an example
for Tatoeba (measured in that run) and more for SODA turns, so say 10 to 15 on average; that puts the
Hinglish part at 26 to 39% more tokens than the English run had. Training: 33.5 min times 1.26 to 1.39,
about 42 to 47 minutes, a little more for the 4% wider output layer. Setup, downloads, tokenising
and the three checkpoint measurements: about 10 minutes. About 55 to 60 minutes of L4 time in all, the
quarter checkpoint at about 12 to 15 minutes. Scaled from the numbers above, not measured: the run's
own steps-per-second line is the real figure.

## What it does not say

- Nothing was measured on a phone: not memory, not latency, not load time, not whether Core ML
  keeps the weights mapped from disk inside a keyboard extension the way it does in a Mac
  process. `KeyboardStatus` carries the model's state, load time, last latency and added
  footprint to the Setup tab for that.
- The evaluation text is short sentences. Chat fragments, names, slang and the owner's own
  vocabulary are not in it.
- GPT-2 was trained on web text. The chains show it: after "please" it writes "enable
  javascript". The strip's never-volunteered list still applies, but the model's taste is the
  web's.
