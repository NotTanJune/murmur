#!/usr/bin/env python3
"""Write a Hugging Face model folder that is a model plus whole-word tokens (plan 004), with no
training: each new embedding row is the mean of the rows of the pieces the word was cut into.

    python training/typing-lm/extend_model.py --model <folder with config.json, model.safetensors,
        vocab.json, merges.txt> --added-tokens <word list> --out <folder>

The output has the model with its wider embedding, `tokenizer.json` for the extended tokenizer
(`added_tokens.py`) and a copy of the list. It is what `evaluate.py --model` reads, to measure
what the extra rows alone do to the English numbers, and what `convert.py` can convert. The list
derives from a corpus that is not GPL-compatible: write the output under ~/Library/Caches.
"""
import argparse
import os
import shutil
import sys

from transformers import AutoModelForCausalLM

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import added_tokens  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", required=True)
    parser.add_argument("--added-tokens", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    words = added_tokens.read_words(args.added_tokens)
    model = AutoModelForCausalLM.from_pretrained(args.model)
    added_tokens.extend_embeddings(model, args.model, words)
    os.makedirs(args.out, exist_ok=True)
    model.save_pretrained(args.out)
    added_tokens.build(args.model, words).save_pretrained(args.out)
    shutil.copyfile(args.added_tokens, os.path.join(args.out, "added-tokens.txt"))
    print(f"wrote {args.out}: {model.config.vocab_size} embedding rows ({len(words)} added)")


if __name__ == "__main__":
    main()
