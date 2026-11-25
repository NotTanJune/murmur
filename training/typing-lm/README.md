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
| `make_bpe_vectors.py` | writes `Tests/MurmurTypingTests/bpe-vectors.json` from the reference tokenizer |

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
