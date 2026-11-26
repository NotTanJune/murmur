#!/usr/bin/env python3
"""Convert a causal language model on disk to the Core ML model the keyboard runs.

    python training/typing-lm/convert.py --model <folder> --out <dir> [--context 32] \
        [--format fp16|int8|pal6|pal4|pal4s|emb4rest6|...] [--compile] [--added-tokens <word list>]

The Core ML model takes `input_ids` (1 x context, Int32, right-padded with anything) and
`last` (the index of the last real token) and returns `logp`, the log probabilities of the
next token after that position, for the whole vocabulary. A causal model never looks right,
so padding after `last` cannot change the answer, and one fixed shape serves every length
without a key-value cache.

Weight formats: `fp16` as converted; `int8` 8-bit linear, per channel; `pal6` and `pal4`
k-means palettes of 64 and 16 values per tensor; `pal4s` the 4-bit palette with a scale per
output channel; `emb<A>rest<B>` gives the embedding table A bits and every other weight B bits
(8 is linear, 6 and 4 are palettes). `--compile` also writes the `.mlmodelc` folder
(needs Xcode's `coremlcompiler`).

`--added-tokens <word list>` (plan 004, `added_tokens.py`) builds a model with whole-word tokens
added: the vocabulary, and so the width of `logp`, is 50,257 plus the list's length. A model folder
with the stock 50,257 rows gets the new rows as the mean of the rows of each word's old pieces
(the tokenizer's `vocab.json` and `merges.txt` are read from `--tokenizer-files`, by default the
model folder); a fine-tune that already has them (finetune.py --added-tokens) is checked for the
right size and used as it is. `added_tokens.json` (word to id) is written into `--out`.
"""
import argparse
import os
import shutil
import subprocess

import sys

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch
from transformers import AutoModelForCausalLM


class NextToken(torch.nn.Module):
    def __init__(self, lm):
        super().__init__()
        self.body = lm.base_model
        self.head = lm.get_output_embeddings()

    def forward(self, input_ids, last):
        hidden = self.body(input_ids=input_ids, use_cache=False, return_dict=False)[0]
        picked = hidden[0].index_select(0, last)
        return torch.log_softmax(self.head(picked), dim=-1)


def convert(folder, context, words=None, tokenizer_files=None):
    lm = AutoModelForCausalLM.from_pretrained(folder, torch_dtype=torch.float32, attn_implementation="eager").eval()
    if words:
        import added_tokens

        wanted = added_tokens.STOCK_VOCABULARY + len(words)
        if lm.config.vocab_size == added_tokens.STOCK_VOCABULARY:
            added_tokens.extend_embeddings(lm, tokenizer_files or folder, words)
        elif lm.config.vocab_size != wanted:
            raise SystemExit(f"the model has {lm.config.vocab_size} embedding rows; "
                             f"{len(words)} added tokens need {wanted}")
        lm.eval()
    wrapper = NextToken(lm).eval()
    ids = torch.zeros((1, context), dtype=torch.int32)
    last = torch.tensor([context - 1], dtype=torch.int32)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (ids, last), strict=False)
    return ct.convert(
        traced,
        inputs=[
            ct.TensorType("input_ids", shape=(1, context), dtype=np.int32),
            ct.TensorType("last", shape=(1,), dtype=np.int32),
        ],
        # Float32 out, whatever the model computes in: Swift has no Float16 on every Mac.
        outputs=[ct.TensorType("logp", dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
    )


EMBEDDING_ELEMENTS = 20_000_000  # only a vocabulary-sized table has this many weights


def reduce(model, bits, threshold=None):
    """One pass over the weights still stored as plain constants: 8 is linear, less is a palette."""
    extra = {"weight_threshold": threshold} if threshold else {}
    if bits == 8:
        config = cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel", **extra)
        return cto.linear_quantize_weights(model, cto.OptimizationConfig(global_config=config))
    config = cto.OpPalettizerConfig(mode="kmeans", nbits=bits, **extra)
    return cto.palettize_weights(model, cto.OptimizationConfig(global_config=config))


def compress(model, weight_format):
    if weight_format == "fp16":
        return model
    if weight_format == "int8":
        return reduce(model, 8)
    if weight_format in ("pal6", "pal4"):
        return reduce(model, int(weight_format[-1]))
    if weight_format == "pal4s":
        config = cto.OpPalettizerConfig(mode="kmeans", nbits=4, enable_per_channel_scale=True)
        return cto.palettize_weights(model, cto.OptimizationConfig(global_config=config))
    if weight_format.startswith("emb") and "rest" in weight_format:
        # The embedding table first; the second pass sees only what is still a plain constant.
        embedding, rest = weight_format[3:].split("rest")
        return reduce(reduce(model, int(embedding), EMBEDDING_ELEMENTS), int(rest))
    raise SystemExit(f"unknown format {weight_format}")


def folder_size(path):
    return sum(os.path.getsize(os.path.join(root, name)) for root, _, names in os.walk(path) for name in names)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--context", type=int, default=32)
    parser.add_argument("--format", default="fp16")
    parser.add_argument("--from-package", help="compress this fp16 .mlpackage instead of converting again")
    parser.add_argument("--compile", action="store_true")
    parser.add_argument("--added-tokens", help="word list of whole-word tokens to add (see the docstring)")
    parser.add_argument("--tokenizer-files", help="folder with GPT-2's vocab.json and merges.txt (default: --model)")
    args = parser.parse_args()
    sys.dont_write_bytecode = True
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    words = None
    if args.added_tokens:
        import added_tokens

        words = added_tokens.read_words(args.added_tokens)

    os.makedirs(args.out, exist_ok=True)
    name = f"{os.path.basename(os.path.normpath(args.model))}-c{args.context}-{args.format}"
    package = os.path.join(args.out, name + ".mlpackage")
    if args.from_package:
        model = ct.models.MLModel(args.from_package, skip_model_load=True)
    else:
        model = convert(args.model, args.context, words, args.tokenizer_files)
    model = compress(model, args.format)
    shutil.rmtree(package, ignore_errors=True)
    model.save(package)
    if words:
        added_tokens.write_table(words, os.path.join(args.out, "added_tokens.json"))
    print(f"{package}: {folder_size(package) / 1e6:.1f} MB")
    if args.compile:
        compiled = os.path.join(args.out, name + ".mlmodelc")
        shutil.rmtree(compiled, ignore_errors=True)
        subprocess.run(["xcrun", "coremlcompiler", "compile", package, args.out], check=True, capture_output=True)
        print(f"{compiled}: {folder_size(compiled) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
