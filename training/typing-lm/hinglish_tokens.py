#!/usr/bin/env python3
"""How GPT-2's tokenizer splits the Hinglish words the keyboard's word list would gain.

    uv run --with tokenizers training/typing-lm/hinglish_tokens.py \
        --hinglish ~/Library/Caches/MurmurBuild/hinglish [--tokenizer ios/TypingLM] [--top 40]

Takes the same 8,000 words `Tools/build_typing_model.py --hinglish` adds (it imports that
function, so the selection cannot drift) and counts how many are one token, two, or three or
more once written with a leading space (" hai"), which is how the model sees a word after a
space. Counts are weighted by corpus frequency too, since a keyboard meets "hai" far more often
than a rare word. Prints numbers only; the word lists it reads derive from L3Cube-HingCorpus
(CC BY-NC-SA 4.0), so nothing it prints about individual words may be committed.
"""
import argparse
import importlib.util
import os
import sys

from tokenizers import Tokenizer, models, pre_tokenizers, decoders

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "..", "..", "Tools", "build_typing_model.py")


def load_builder():
    spec = importlib.util.spec_from_file_location("build_typing_model", BUILD)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--hinglish", required=True, help="folder with the two corpus count files")
    parser.add_argument("--tokenizer", default=os.path.join(HERE, "..", "..", "ios", "TypingLM"),
                        help="folder with GPT-2's vocab.json and merges.txt")
    parser.add_argument("--data-dir", default=os.path.expanduser("~/Library/Caches/MurmurBuild/typing-data"))
    parser.add_argument("--top", type=int, default=40, help="how many of the most frequent multi-token words to list")
    args = parser.parse_args()

    builder = load_builder()
    for name, (_, size, sha) in builder.SOURCES.items():
        builder.check_file(os.path.join(args.data_dir, name), size, sha)
    unigrams = builder.read_unigrams(os.path.join(args.data_dir, "frequency_dictionary_en_82_765.txt"))
    bigrams = builder.read_bigrams(os.path.join(args.data_dir, "frequency_bigramdictionary_en_243_342.txt"))
    for word, count in builder.read_extras(builder.DEFAULT_EXTRAS).items():
        unigrams[word] = max(unigrams.get(word, 0), count)
    added, _, report = builder.add_hinglish(unigrams, bigrams, args.hinglish)
    corpus = report["corpus"]

    vocab = os.path.join(args.tokenizer, "vocab.json")
    merges = os.path.join(args.tokenizer, "merges.txt")
    tokenizer = Tokenizer(models.BPE.from_file(vocab, merges))
    tokenizer.pre_tokenizer = pre_tokenizers.ByteLevel(add_prefix_space=False)
    tokenizer.decoder = decoders.ByteLevel()

    buckets = {1: [0, 0], 2: [0, 0], 3: [0, 0]}  # words, corpus count
    multi = []
    for word in added:
        pieces = tokenizer.encode(" " + word).tokens
        key = min(len(pieces), 3)
        buckets[key][0] += 1
        buckets[key][1] += corpus[word]
        if len(pieces) > 1:
            multi.append((corpus[word], word, pieces))
    words = sum(b[0] for b in buckets.values())
    mass = sum(b[1] for b in buckets.values())
    print(f"{words} selected words, {mass} corpus occurrences")
    for key, label in ((1, "one token"), (2, "two tokens"), (3, "three or more")):
        w, c = buckets[key]
        print(f"{label:>14}: {w:5d} words ({100 * w / words:5.1f}%), {100 * c / mass:5.1f}% of occurrences")
    multi.sort(reverse=True)
    for rank in (100, 500, 1000, 2000):
        covered = sum(c for c, _, _ in multi[:rank])
        print(f"top {rank} multi-token words hold {100 * covered / sum(c for c, _, _ in multi):.1f}% of multi-token occurrences")
    print(f"most frequent multi-token words (local only): "
          + ", ".join(f"{w}={'|'.join(p)}" for _, w, p in multi[:args.top]))


if __name__ == "__main__":
    sys.exit(main())
