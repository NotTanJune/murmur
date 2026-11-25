#!/usr/bin/env python3
"""The evaluation's cases: every word position of every entry of eval-sentences.tsv.

    python3 training/typing-lm/cases.py --eval training/typing-lm/eval-sentences.tsv --out <dir>

Writes <dir>/cases.json (every case) and <dir>/befores.json (the distinct texts before the
cursor, which Tests/MurmurTypingTests/TypingLMEvalTests.swift answers with the pair model).

A case is a text before the cursor and the word that was written next. `k` is how many of the
word's letters are already typed: 0 is a next-word prediction, 1 to 3 are completions, and a
completion case exists only while the word is longer than what is typed. There are two sets:
`written` (Murmur's sentences, which are lowercase, and Tatoeba's as written) and `lower` (all of
it lowercased, the way the owner types). Standard library only.
"""
import argparse
import json
import os
import re

WORD = re.compile(r"[A-Za-z']+")


def entries(path):
    out = []
    for line in open(path, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        source, text = line.rstrip("\n").split("\t", 1)
        out.append((source, text))
    return out


def fold(word):
    return word.lower().replace("’", "'")


def build(path):
    cases = []
    for index, (source, written) in enumerate(entries(path)):
        for variant, text in (("written", written), ("lower", written.lower())):
            for match in WORD.finditer(text):
                word = match.group().strip("'")
                if not word:
                    continue
                start = match.start() + (len(match.group()) - len(match.group().lstrip("'")))
                for k in range(4):
                    if k and k >= len(word):
                        break
                    cases.append({
                        "set": variant, "entry": index, "source": "replay" if source == "replay" else "tatoeba",
                        "k": k, "before": text[:start + k], "target": fold(word),
                    })
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--eval", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    cases = build(args.eval)
    befores = sorted({case["before"] for case in cases})
    json.dump(cases, open(os.path.join(args.out, "cases.json"), "w"))
    json.dump(befores, open(os.path.join(args.out, "befores.json"), "w"))
    words = sum(1 for case in cases if case["k"] == 0 and case["set"] == "written")
    print(f"{len(cases)} cases, {words} word positions per set, {len(befores)} distinct texts")


if __name__ == "__main__":
    main()
