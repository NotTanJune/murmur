#!/usr/bin/env python3
"""Build eval-sentences.tsv, the evaluation set for the keyboard's next-word model.

    python3 training/typing-lm/make_eval.py --tatoeba <eng_sentences.tsv.bz2> \
        --out training/typing-lm/eval-sentences.tsv

Inputs: Tests/MurmurTypingTests/replay-sentences.txt (Murmur's own) and Tatoeba's English
export, https://downloads.tatoeba.org/exports/per_language/eng/eng_sentences.tsv.bz2
(CC BY 2.0 FR). The export changes weekly, so its size and SHA-256 are checked against the
copy the checked-in file was built from. Never downloads. Standard library only.

A Tatoeba entry is kept when it is plain ASCII prose of one or two sentences, each 4 to 14
words, with no digits and no capitalised word inside a sentence other than "I" (names cannot
be predicted by any model and Tatoeba is full of "Tom" and "Mary"). The sample is drawn with a
fixed seed: 230 one-sentence entries and 60 two-sentence entries, so the second sentence of an
entry has a real previous sentence as context.
"""
import argparse
import bz2
import hashlib
import os
import random
import re
import sys

SIZE = 24_954_390
SHA256 = "0c4d3b18152bd6507bbf77ab690532b25de1e60da950f68705b3c88935c01fb4"
SEED = 20261125
SINGLES, DOUBLES = 230, 60

HERE = os.path.dirname(os.path.abspath(__file__))
REPLAY = os.path.join(HERE, "..", "..", "Tests", "MurmurTypingTests", "replay-sentences.txt")
ALLOWED = re.compile(r"^[A-Za-z' ,.?!]+$")
SENTENCE_END = re.compile(r"(?<=[.?!]) ")
WORD = re.compile(r"[A-Za-z']+")


def sentences(text):
    return SENTENCE_END.split(text)


def acceptable(sentence):
    words = WORD.findall(sentence)
    if not 4 <= len(words) <= 14 or not sentence[0].isupper() or sentence[-1] not in ".?!":
        return False
    for word in words[1:]:
        if word[0].isupper() and word != "I" and not word.startswith("I'"):
            return False
    return not any(len(w) > 1 and w.isupper() for w in words)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tatoeba", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    raw = open(args.tatoeba, "rb").read()
    if len(raw) != SIZE or hashlib.sha256(raw).hexdigest() != SHA256:
        sys.exit(f"{args.tatoeba}: not the export this set was built from (size or SHA-256 differs)")

    singles, doubles = [], []
    for line in bz2.decompress(raw).decode("utf-8").splitlines():
        number, _, text = line.split("\t", 2)
        if not ALLOWED.match(text) or "  " in text:
            continue
        parts = sentences(text)
        if not all(acceptable(part) for part in parts):
            continue
        if len(parts) == 1:
            singles.append((int(number), text))
        elif len(parts) == 2:
            doubles.append((int(number), text))
    rng = random.Random(SEED)
    chosen = rng.sample(sorted(singles), SINGLES) + rng.sample(sorted(doubles), DOUBLES)

    replay = [line.strip() for line in open(REPLAY, encoding="utf-8") if line.strip()]
    with open(args.out, "w", encoding="utf-8") as out:
        out.write("# Evaluation sentences for the keyboard's next-word model. Built by make_eval.py.\n")
        out.write("# Lines marked replay are Murmur's own (Tests/MurmurTypingTests/replay-sentences.txt).\n")
        out.write("# Numbered lines are sentences from Tatoeba (https://tatoeba.org), licensed\n")
        out.write("# CC BY 2.0 FR (https://creativecommons.org/licenses/by/2.0/fr/); the number is the\n")
        out.write("# sentence's id, so https://tatoeba.org/sentences/show/<id> names its author.\n")
        for text in replay:
            out.write(f"replay\t{text}\n")
        for number, text in chosen:
            out.write(f"{number}\t{text}\n")
    print(f"{len(singles)} one-sentence and {len(doubles)} two-sentence entries passed the filter")
    print(f"wrote {len(replay)} replay + {len(chosen)} Tatoeba entries to {args.out}")


if __name__ == "__main__":
    main()
