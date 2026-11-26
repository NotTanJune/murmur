#!/usr/bin/env python3
"""Count unigrams and adjacent bigrams in L3Cube-HingCorpus (roman), for the keyboard's word list.

    nice -n 19 python3 -I Tools/hinglish_words.py \
        --corpus ~/Library/Caches/MurmurBuild/hinglish/raw/hingcorpus.download \
        --out ~/Library/Caches/MurmurBuild/hinglish

The corpus (52.93M Hinglish tweets, CC BY-NC-SA 4.0) is a gzipped tar with two text files, one
sentence per line: `concatenated_train_final_shuffled.txt` and `concatenated_validation.txt`.
Both are read as a stream and nothing is ever extracted to disk or executed: only file members
are read, and only as text. The corpus is untrusted data, so run this with `python3 -I`.

Nothing this writes may enter the repository: the corpus's licence is not GPL-compatible. The
outputs are `hinglish-unigrams.tsv` (word<TAB>count) and `hinglish-bigrams.tsv`
(word<TAB>word<TAB>count), both sorted by count, in the output folder (a cache folder, never the
repo), and `Tools/build_typing_model.py --hinglish <folder>` reads them.

Rules: text is lowercased; a word is `[a-z]+` with inner apostrophes, at most 20 letters. URLs,
@handles, #tags and any token holding a digit are dropped and break a bigram, as do `. ! ?`.
Two passes, one process, standard library only. Pass 1 counts unigrams. Pass 2 counts bigrams
only between words that passed 1 with at least MIN_VOCAB_COUNT, which keeps the table small enough
for an 8 GB Mac; both passes prune counts of 1 now and then, so a rare word's or pair's count can
be short by the few occurrences a prune removed, which is nothing next to the thresholds used.
"""
import argparse
import codecs
import collections
import os
import re
import sys
import tarfile
import time

MAX_WORD = 20
MIN_VOCAB_COUNT = 200   # a bigram's two words both need this many unigram counts
MIN_UNIGRAM_WRITTEN = 5
MIN_BIGRAM_WRITTEN = 20
PRUNE_EVERY = 4_000_000  # lines

# One pattern for everything that is not a word and must not join two words: URLs, handles, tags,
# any token with a digit, and sentence ends.
BREAK = re.compile(r"https?\S*|www\.\S*|[@#]\S*|\S*\d\S*|[.!?]+(?=\s|$)")
WORD = re.compile(r"[a-z]+(?:'[a-z]+)*")


def lines(path):
    """Yield every text line of every file member, without extracting anything."""
    with tarfile.open(path, mode="r|gz") as archive:
        for member in archive:
            if not member.isfile():
                continue
            stream = archive.extractfile(member)
            print(f"reading {member.name} ({member.size} bytes)", file=sys.stderr, flush=True)
            # The tar stream cannot seek, so lines are cut from 1 MiB reads by hand.
            decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
            rest = ""
            while True:
                chunk = stream.read(1 << 20)
                if not chunk:
                    break
                parts = (rest + decoder.decode(chunk)).split("\n")
                rest = parts.pop()
                yield from parts
            rest += decoder.decode(b"", final=True)
            if rest:
                yield rest


def segments(line):
    """Runs of words with no URL, handle, tag, number or sentence end between them."""
    for piece in BREAK.split(line.lower()):
        words = [w for w in WORD.findall(piece) if len(w) <= MAX_WORD]
        if words:
            yield words


def prune(counter):
    for key in [key for key, count in counter.items() if count == 1]:
        del counter[key]


def write_tsv(path, rows):
    with open(path + ".part", "w", encoding="utf-8") as out:
        for key, count in rows:
            out.write(("\t".join(key) if isinstance(key, tuple) else key) + f"\t{count}\n")
    os.replace(path + ".part", path)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--corpus", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--limit", type=int, default=0, help="stop each pass after this many lines (a trial run)")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    began = time.time()

    unigrams = collections.Counter()
    total = 0
    for total, line in enumerate(lines(args.corpus), 1):
        for words in segments(line):
            unigrams.update(words)
        if total % PRUNE_EVERY == 0:
            prune(unigrams)
            print(f"pass 1: {total} lines, {len(unigrams)} words, {time.time() - began:.0f} s",
                  file=sys.stderr, flush=True)
        if args.limit and total >= args.limit:
            break
    print(f"pass 1 done: {total} lines, {len(unigrams)} distinct words kept", file=sys.stderr, flush=True)
    write_tsv(os.path.join(args.out, "hinglish-unigrams.tsv"),
              sorted(((w, c) for w, c in unigrams.items() if c >= MIN_UNIGRAM_WRITTEN),
                     key=lambda item: (-item[1], item[0])))

    vocab = frozenset(w for w, c in unigrams.items() if c >= MIN_VOCAB_COUNT)
    del unigrams
    print(f"pass 2 vocabulary: {len(vocab)} words", file=sys.stderr, flush=True)
    bigrams = collections.Counter()
    for total, line in enumerate(lines(args.corpus), 1):
        for words in segments(line):
            if len(words) > 1:
                bigrams.update(pair for pair in zip(words, words[1:]) if pair[0] in vocab and pair[1] in vocab)
        if total % PRUNE_EVERY == 0:
            prune(bigrams)
            print(f"pass 2: {total} lines, {len(bigrams)} pairs, {time.time() - began:.0f} s",
                  file=sys.stderr, flush=True)
        if args.limit and total >= args.limit:
            break
    write_tsv(os.path.join(args.out, "hinglish-bigrams.tsv"),
              sorted(((p, c) for p, c in bigrams.items() if c >= MIN_BIGRAM_WRITTEN),
                     key=lambda item: (-item[1], item[0])))
    print(f"done: {total} lines in {time.time() - began:.0f} s", file=sys.stderr)


if __name__ == "__main__":
    main()
