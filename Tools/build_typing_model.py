#!/usr/bin/env python3
"""Build the keyboard's word model, Sources/MurmurTyping/Resources/en.mtm.

Inputs, pinned to SymSpell commit 91fe939e9c1259813ee817e95239629c5badf8ec (MIT):
    SymSpell/frequency_dictionary_en_82_765.txt          word<space>count
    SymSpell/frequency_bigramdictionary_en_243_342.txt   word<space>word<space>count
plus Tools/typing-extra-words.tsv (contractions and chat words, counts written down there).

    uv run Tools/build_typing_model.py --fetch --out Sources/MurmurTyping/Resources/en.mtm
    uv run Tools/build_typing_model.py --out Sources/MurmurTyping/Resources/en.mtm

A normal run never touches the network. `--fetch` downloads the two files into the data
directory (default ~/Library/Caches/MurmurBuild/typing-data). Every run checks the files' size and
SHA-256 against the values below and exits 1 on a mismatch, so a changed upstream file can never
slip into the model. The file format is documented in Sources/MurmurTyping/Lexicon/MTMFormat.md;
the output is deterministic, byte for byte, for the same inputs.

Hinglish (local only, never committed): `--hinglish <folder>` adds Hindi words written in Roman
script from the counts `Tools/hinglish_words.py` wrote from L3Cube-HingCorpus (CC BY-NC-SA 4.0,
not GPL-compatible). The output then derives from that corpus, so it must go to a git-ignored
path (`ios/TypingLM/en.mtm`), never over the committed `en.mtm`. Without the flag the output is
byte for byte what it was, and English words keep the very same bytes with the flag, because the
probability scale is fixed by the English counts alone.

Standard library only.
"""
import argparse
import hashlib
import math
import os
import struct
import sys
import urllib.request

COMMIT = "91fe939e9c1259813ee817e95239629c5badf8ec"
BASE = f"https://raw.githubusercontent.com/wolfgarbe/SymSpell/{COMMIT}/SymSpell/"

# name on disk: (URL, byte size, SHA-256), all observed on the first fetch (2026-11-25).
SOURCES = {
    "frequency_dictionary_en_82_765.txt": (
        BASE + "frequency_dictionary_en_82_765.txt",
        1_332_881,
        "c604e1121e398ae7c7fbf777f11e0a0f2fa66eda932cb9fba1321466cf3acd7b",
    ),
    "frequency_bigramdictionary_en_243_342.txt": (
        BASE + "frequency_bigramdictionary_en_243_342.txt",
        5_137_213,
        "fd892a160184101dd7ae807ac5a302d01fcea1c47304181a8ed7ed9c94545bcd",
    ),
}

DEFAULT_DATA_DIR = os.path.expanduser("~/Library/Caches/MurmurBuild/typing-data")
DEFAULT_EXTRAS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "typing-extra-words.tsv")

# Hinglish words enter at this fraction of the count their corpus frequency would earn on the
# English list's scale. Below 1 so that a Hinglish word never outranks an English word of the same
# spelling-neighbourhood in the strip or in a swipe, and so that autocorrect still prefers a real
# English word when a typo is equally close to both. A first guess, not a measured value.
HINGLISH_DAMPING = 0.5
HINGLISH_WORDS = 8000        # how many corpus words are added
HINGLISH_MIN_COUNT = 200     # corpus count a word needs to be added
HINGLISH_SHARED_TOP = 200    # most frequent shared words that fix the scale
HINGLISH_GUARD = 50          # an English neighbour this many times as common blocks a word
HINGLISH_MIN_PAIR = 50       # corpus count a pair needs

SCALE = 25.0  # one step is 0.04 in log10, so 255 reaches 10^-10.2
FLAG_CONTRACTION = 0b10


def quantise(p):
    """-log10(p) * 25, rounded half up and clamped to a byte. p <= 0 gives 255."""
    if p <= 0:
        return 255
    q = math.floor(-math.log10(p) * SCALE + 0.5)
    return max(0, min(255, q))


def die(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def check_file(path, size, sha):
    if not os.path.isfile(path):
        die(f"{path} is missing; run with --fetch")
    data = open(path, "rb").read()
    if len(data) != size:
        die(f"{path}: {len(data)} bytes, expected {size}")
    got = hashlib.sha256(data).hexdigest()
    if got != sha:
        die(f"{path}: SHA-256 {got}, expected {sha}")


def fetch(data_dir):
    os.makedirs(data_dir, exist_ok=True)
    for name, (url, size, sha) in SOURCES.items():
        path = os.path.join(data_dir, name)
        print(f"fetching {url}")
        request = urllib.request.Request(url, headers={"User-Agent": "murmur-typing-model-builder"})
        with urllib.request.urlopen(request, timeout=60) as response:
            body = response.read()
        tmp = path + ".part"
        with open(tmp, "wb") as handle:
            handle.write(body)
        os.replace(tmp, path)


def read_unigrams(path):
    counts = {}
    # utf-8-sig: the unigram file starts with a byte order mark.
    with open(path, encoding="utf-8-sig") as handle:
        for number, line in enumerate(handle, 1):
            parts = line.split()
            if not parts:
                continue
            if len(parts) != 2:
                die(f"{path}:{number}: expected 'word count'")
            word = parts[0].lower().replace("’", "'")
            counts[word] = counts.get(word, 0) + int(parts[1])
    return counts


def read_bigrams(path):
    pairs = {}
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            parts = line.split()
            if not parts:
                continue
            if len(parts) != 3:
                die(f"{path}:{number}: expected 'word word count'")
            key = (parts[0].lower(), parts[1].lower())
            pairs[key] = pairs.get(key, 0) + int(parts[2])
    return pairs


def read_extras(path):
    extras = {}
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            word, tab, count = line.partition("\t")
            if not tab or not count.strip().isdigit():
                die(f"{path}:{number}: expected 'word<TAB>count'")
            extras[word] = int(count)
    return extras


def read_tsv(path, columns):
    rows = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            parts = line.rstrip("\n").split("\t")
            if len(parts) != columns + 1 or not parts[-1].isdigit():
                die(f"{path}:{number}: expected {columns} words and a count")
            rows.append((tuple(parts[:-1]), int(parts[-1])))
    return rows


def edits1(word):
    """Every string one deletion, transposition, replacement or insertion from the word."""
    letters = "abcdefghijklmnopqrstuvwxyz'"
    splits = [(word[:i], word[i:]) for i in range(len(word) + 1)]
    found = {a + b[1:] for a, b in splits if b}
    found |= {a + b[1] + b[0] + b[2:] for a, b in splits if len(b) > 1}
    found |= {a + c + b[1:] for a, b in splits if b for c in letters}
    found |= {a + c + b for a, b in splits for c in letters}
    found.discard(word)
    return found


def add_hinglish(unigrams, bigrams, folder):
    """Add the corpus's Hinglish words and pairs. Returns the added words, the added pairs and a report."""
    corpus = {key[0]: count for key, count in read_tsv(os.path.join(folder, "hinglish-unigrams.tsv"), 1)}
    pair_rows = read_tsv(os.path.join(folder, "hinglish-bigrams.tsv"), 2)

    # The scale: median of English count / corpus count over the most frequent words both share.
    shared = [w for w, _ in sorted(corpus.items(), key=lambda item: (-item[1], item[0])) if w in unigrams]
    ratios = sorted(unigrams[w] / corpus[w] for w in shared[:HINGLISH_SHARED_TOP])
    if len(ratios) < HINGLISH_SHARED_TOP:
        die(f"only {len(ratios)} shared words in the corpus, expected {HINGLISH_SHARED_TOP}")
    middle = len(ratios) // 2
    ratio = (ratios[middle - 1] + ratios[middle]) / 2 if len(ratios) % 2 == 0 else ratios[middle]

    added, dropped = {}, []
    for word, count in sorted(corpus.items(), key=lambda item: (-item[1], item[0])):
        if len(added) == HINGLISH_WORDS or count < HINGLISH_MIN_COUNT:
            break
        if word in unigrams or len(word) < 2:
            continue
        # A common misspelling of an English word ("teh") must never be promoted to a word.
        scaled = count * ratio
        if any(unigrams.get(near, 0) > HINGLISH_GUARD * scaled for near in edits1(word)):
            dropped.append(word)
            continue
        added[word] = max(1, round(scaled * HINGLISH_DAMPING))

    known = set(unigrams) | set(added)
    pairs = {}
    for (a, b), count in pair_rows:
        if count >= HINGLISH_MIN_PAIR and a in known and b in known and (a, b) not in bigrams:
            pairs[(a, b)] = max(1, round(count * ratio * HINGLISH_DAMPING))
    report = {"ratio": ratio, "dropped": dropped, "corpus": corpus}
    return added, pairs, report


def pad4(buffer):
    while len(buffer) % 4:
        buffer.append(0)


def build(data_dir, extras_path, hinglish_dir=None):
    for name, (_, size, sha) in SOURCES.items():
        check_file(os.path.join(data_dir, name), size, sha)

    unigrams = read_unigrams(os.path.join(data_dir, "frequency_dictionary_en_82_765.txt"))
    bigrams = read_bigrams(os.path.join(data_dir, "frequency_bigramdictionary_en_243_342.txt"))
    for word, count in read_extras(extras_path).items():
        unigrams[word] = max(unigrams.get(word, 0), count)
    total = sum(unigrams.values())  # English only, so every English word keeps its byte

    hinglish, added_pairs, report = {}, {}, None
    if hinglish_dir:
        hinglish, added_pairs, report = add_hinglish(unigrams, bigrams, hinglish_dir)
        unigrams.update(hinglish)
        bigrams = {**bigrams, **added_pairs}

    # Ids are positions in byte-sorted order, which is also what the reader binary-searches.
    words = sorted(unigrams, key=lambda w: w.encode("utf-8"))
    ids = {word: index for index, word in enumerate(words)}
    n = len(words)

    # Pairs whose words are both known, grouped by first word, second ids ascending.
    by_first = [[] for _ in range(n)]
    added_sum = [0] * n
    for (a, b), count in bigrams.items():
        if a in ids and b in ids:
            by_first[ids[a]].append((ids[b], count))
            if (a, b) in added_pairs:
                added_sum[ids[a]] += count
    pair_count = 0
    for entries in by_first:
        entries.sort()
        pair_count += len(entries)

    out = bytearray()
    out += b"MTM1" + struct.pack("<III", 1, n, pair_count)

    blob = bytearray()
    offsets = []
    for word in words:
        offsets.append(len(blob))
        blob += word.encode("utf-8")
    offsets.append(len(blob))
    out += struct.pack(f"<{n + 1}I", *offsets)

    out += bytes(quantise(unigrams[w] / total) for w in words)
    out += bytes(FLAG_CONTRACTION if "'" in w else 0 for w in words)
    pad4(out)

    # a..z start indices, then the end of z. Words starting outside a..z lie before the first
    # entry or after the last, and belong to no bucket.
    def letter_index(word):
        c = ord(word[0]) - 97 if word else -1
        return c if 0 <= c < 26 else -1

    starts = [0] * 27
    letters = [letter_index(w) for w in words]
    for letter in range(26):
        starts[letter] = next((i for i, l in enumerate(letters) if l == letter), None)
    # A letter with no words takes the start of the next one; the last takes the end of z.
    last_z = max((i for i, l in enumerate(letters) if l >= 0), default=-1) + 1
    starts[26] = last_z
    for letter in range(25, -1, -1):
        if starts[letter] is None:
            starts[letter] = starts[letter + 1]
    out += struct.pack("<27I", *starts)

    # (first, last) buckets: ids of words whose first and last characters are both a..z.
    buckets = [[] for _ in range(26 * 26)]
    for index, word in enumerate(words):
        f, l = ord(word[0]) - 97, ord(word[-1]) - 97
        if 0 <= f < 26 and 0 <= l < 26:
            buckets[f * 26 + l].append(index)
    bucket_starts = []
    end_ids = []
    for bucket in buckets:
        bucket_starts.append(len(end_ids))
        end_ids += bucket
    bucket_starts.append(len(end_ids))
    out += struct.pack(f"<{len(bucket_starts)}I", *bucket_starts)
    out += struct.pack(f"<{len(end_ids)}I", *end_ids)
    pad4(out)

    pair_index = []
    pair_bytes = bytearray()
    running = 0
    for first, entries in enumerate(by_first):
        pair_index.append(running)
        running += len(entries)
        # P(b | a) is the pair's count over the larger of a's own count and the sum of a's pair
        # counts, so a word with a few rare pairs never reads as certain.
        # An English word's denominator ignores the Hinglish pairs, so its pairs keep their bytes.
        extra = 0 if words[first] in hinglish else added_sum[first]
        denominator = max(unigrams[words[first]], sum(c for _, c in entries) - extra)
        for second, count in entries:
            pair_bytes += struct.pack("<IB", second, quantise(count / denominator))
    pair_index.append(running)
    out += struct.pack(f"<{n + 1}I", *pair_index)
    out += pair_bytes
    out += blob
    if report is not None:
        report.update(added=hinglish, added_pairs=added_pairs)
    return bytes(out), n, pair_count, report


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--out", required=True, help="path of the .mtm file to write")
    parser.add_argument("--fetch", action="store_true", help="download the pinned inputs first")
    parser.add_argument("--data-dir", default=DEFAULT_DATA_DIR)
    parser.add_argument("--extras", default=DEFAULT_EXTRAS)
    parser.add_argument("--hinglish", help="folder with hinglish-unigrams.tsv and hinglish-bigrams.tsv "
                        "(local only: the output derives from a non-GPL corpus)")
    args = parser.parse_args()

    if args.fetch:
        fetch(args.data_dir)
    if args.hinglish and os.path.realpath(args.out) == os.path.realpath(
            os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources/MurmurTyping/Resources/en.mtm")):
        die("a Hinglish model must never replace the committed en.mtm")
    model, words, pairs, report = build(args.data_dir, args.extras, args.hinglish)
    tmp = args.out + ".part"
    with open(tmp, "wb") as handle:
        handle.write(model)
    os.replace(tmp, args.out)
    print(f"words: {words}")
    print(f"pairs: {pairs}")
    print(f"bytes: {len(model)}")
    print(f"sha256: {hashlib.sha256(model).hexdigest()}")
    if report:
        added = report["added"]
        print(f"hinglish words added: {len(added)}")
        print(f"hinglish words dropped by the misspelling guard: {len(report['dropped'])}")
        print(f"hinglish pairs added: {len(report['added_pairs'])}")
        print(f"scale (English count / corpus count, median of top {HINGLISH_SHARED_TOP} shared): {report['ratio']:.1f}")
        print(f"damping: {HINGLISH_DAMPING}")
        top = sorted(added, key=lambda w: (-report["corpus"][w], w))[:40]
        print("top 40 added: " + " ".join(top))


if __name__ == "__main__":
    main()
