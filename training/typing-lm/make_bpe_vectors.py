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
"""
import argparse
import json
import random

from transformers import AutoTokenizer

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


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", required=True)
    parser.add_argument("--eval", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    tokenizer = AutoTokenizer.from_pretrained(args.model)
    entries = [line.rstrip("\n").split("\t", 1)[1] for line in open(args.eval, encoding="utf-8") if "\t" in line and not line.startswith("#")]
    rng = random.Random(20261125)
    texts = list(EDGE)
    for index, text in enumerate(rng.sample(entries, 200)):
        if index % 2:
            words = text.split(" ")
            text = " ".join(words[:rng.randint(1, len(words))]) + " "
        texts.append(text if index % 4 < 2 else text.lower())
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
