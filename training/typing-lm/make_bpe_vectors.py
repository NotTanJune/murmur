#!/usr/bin/env python3
"""Write Tests/MurmurTypingTests/bpe-vectors.json: texts and the token ids the reference
tokenizer (Hugging Face `tokenizers`, from the model's own files) gives them. The Swift
tokenizer (Sources/MurmurTyping/Predict/BPETokenizer.swift) must give the same ids.

    python training/typing-lm/make_bpe_vectors.py --model <folder> \
        --eval training/typing-lm/eval-sentences.tsv --out Tests/MurmurTypingTests/bpe-vectors.json

The texts are 200 evaluation entries (as written and lowercased, every second one cut at a
word boundary with its trailing space, the way the keyboard sees text) and the hand-written
cases below: apostrophes, capitals, emoji, digits, leading and repeated spaces, line breaks,
punctuation runs, accents and other scripts. No start or end token is added.

`--added <word list>` builds the tokenizer with whole-word tokens added (`added_tokens.py`, the
file `hinglish_tokens.py --emit` writes, or the hand-written
Tests/MurmurTypingTests/added-tokens-test.txt) and adds texts built around those words: alone, after
words, before punctuation, as the start of a longer piece (" kyaa"), capitalised, with a line break
before them. The texts above stay in, so the same vectors show nothing else changed. A real list
derives from a corpus that is not GPL-compatible: write its vectors under ~/Library/Caches, not in
the repository.
"""
import argparse
import json
import os
import random
import sys

from transformers import AutoTokenizer

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import added_tokens  # noqa: E402

EDGE = [
    "", " ", "  ", "   ", "\n", "\n\n", " \n", "\n ", "\t", "a", " a", "a ", " a ", "I", " I", "i",
    "my dog ", "my dog", " my dog", "My Dog", "MY DOG", "my  dog", "my   dog", "my dog  ", "my\ndog",
    "my\n\ndog", "my \n dog", "my\tdog", "line one\nline two\n", "\n\nstart", "end\n\n",
    "don't", "Don't", "DON'T", "i'm", "I'm", "I'll", "you're", "we've", "he'd", "it's", "that's",
    "can't won't shouldn't", "'tis", "'s", " 's", "rock 'n' roll", "the dogs' bowls", "'quoted'",
    "it’s", "don’t", "“curly” quotes", "‘single’", "'", "''", " '", "' ", "o'clock", "y'all",
    "!'s", "what?!", "wait...", "wait…", "well, yes.", "(maybe)", "[1]", "{a}", "a-b", "a - b",
    "a–b", "a — b", "#tag", "@name", "50%", "$5", "$5.00", "£10", "€20", "1,000", "3.14", "1st",
    "2026-11-25", "10:30", "10:30am", "iPhone 15 Pro", "A17", "x86_64", "v2.0.1", "100km", "007",
    "one 2 three", " 42", "42 ", "4 2", "١٢٣", "½", "x²",
    "https://example.com/a?b=c&d=1", "name@example.com", "a/b/c", "C:\\path", "snake_case",
    "camelCase", "HTTPServer", "e.g. this", "U.S.A.", "Mr. Smith", "ok!!", "???", "!!!", "---",
    "___", "***", "a&b", "a+b=c", "<tag>", "</tag>", "\"double\"", "say \"hi\"", "`code`",
    "😀", "hi 😀", "😀😀", "👍🏽", "👨‍👩‍👧", "🇸🇬", "I ❤️ you", "ok 👍", "☕️ time", "😂 lol",
    "café", "naïve", "résumé", "jalapeño", "über", "Zürich", "São Paulo", "façade", "smörgåsbord",
    "日本語", "你好", "こんにちは", "안녕하세요", "Привет", "γειά", "שלום", "مرحبا", "नमस्ते",
    "mixed 日本 text", "e\u0301", "a\u00a0b", "a\u200bb", "tab\there", "x\r\ny",
    "The quick brown fox jumps over the lazy dog.", "the quick brown fox jumps over the lazy dog",
    "supercalifragilisticexpialidocious", "antidisestablishmentarianism", "aaaaaaaaaaaaaaaa",
    "zzz", "qwertyuiop", "lol omg btw idk", "gonna wanna gotta", "hmm", "uh huh", "okay okay",
    "I", "I ", "I am", "i am", "Hello", "hello", " Hello", " hello", "HELLO", "hELLO",
    "New York", "new york", "Monday", "monday", "January 1st", "Tom's", "Mary's car",
]

FORMS = [
    "{w}", "{b}", "{w} ", " {w} ", "{w}\n", "\n{w}", "{w}.", "{w}!", "{w}?", "{w},", "({w})", "\"{w}\"", "{w}'s", "{w}'t",
    "{w}{w}", "{w} {w}", "{w}2", "{w}_x", "{w}-{b}", "{w}\u00e9", "dog{w}", "dog {w}", "dog  {w}", "dog\n{w}",
    "dog {w} hai", "my dog {w} ", "{b} dog", "{c}", "{u}", "{w}a", "{w}n", "{w}ing", "x{w}", "a {w}b",
    "so {w} yaar", "{w} \U0001f600", "1 {w}", "{w} 1", "hi.{w}", "hi, {w}", "e.g.{w}",
]


# Ordinary Hinglish and mixed sentences, written by hand. They hold no corpus output; words the added
# list lacks go through BPE as they always did.
MIXED = [
    "kya hai yaar", " kya hai yaar", "yaar kya kar raha hai", "tum nahi samjhe yaar", "i said nahi yaar kya",
    "Nahi yaar, kya hua?", "kya kya kya", "nahi nahi nahi", "so kya do you want to go", "meeting kal hai nahi",
    "bhai tu kya bol raha hai", "haan yaar, theek hai", "this is a test of kya and nahi", "kya\nnahi\nyaar",
    "yaar. nahi. kya?", "(yaar) [nahi] {kya}", "yaar's nahi's kya's", "yaaar kyaaa nahiii", "kyaa nahin yaarr",
]


def forms(words, rng, limit):
    """Texts around each word (a sample of `limit` words when the list is long): see FORMS."""
    chosen = words if len(words) <= limit else rng.sample(words, limit)
    texts = list(MIXED)
    for word in chosen:
        bare = word.strip()
        for form in FORMS:
            texts.append(form.format(w=word, b=bare, c=word.capitalize(), u=word.upper()))
    return texts


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", required=True)
    parser.add_argument("--eval", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--added", help="word list of whole-word tokens to add (see the docstring)")
    parser.add_argument("--words", type=int, default=300, help="with --added: how many of its words get texts")
    args = parser.parse_args()

    words = added_tokens.read_words(args.added) if args.added else []
    tokenizer = added_tokens.build(args.model, words) if words else AutoTokenizer.from_pretrained(args.model)
    entries = [line.rstrip("\n").split("\t", 1)[1] for line in open(args.eval, encoding="utf-8") if "\t" in line and not line.startswith("#")]
    rng = random.Random(20261125)
    texts = list(EDGE)
    for index, text in enumerate(rng.sample(entries, 200)):
        if index % 2:
            words = text.split(" ")
            text = " ".join(words[:rng.randint(1, len(words))]) + " "
        texts.append(text if index % 4 < 2 else text.lower())
    texts += forms(words, rng, args.words)
    seen, vectors = set(), []
    for text in texts:
        if text in seen:
            continue
        seen.add(text)
        vectors.append({"text": text, "ids": tokenizer(text, add_special_tokens=False)["input_ids"]})
    with open(args.out, "w", encoding="utf-8") as out:
        out.write("[\n" + ",\n".join(json.dumps(v, ensure_ascii=False, separators=(",", ":")) for v in vectors) + "\n]\n")
    print(f"wrote {len(vectors)} vectors to {args.out}")


if __name__ == "__main__":
    main()
