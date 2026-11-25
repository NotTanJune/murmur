#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = [
#     "torch==2.7.1",
#     "transformers==4.53.2",
#     "coremltools==8.3.0",
#     "numpy==2.2.6",
#     "scikit-learn==1.9.1",
#     "safetensors==0.8.0",
# ]
# ///
"""Build the keyboard's language model into ios/TypingLM, which git ignores.

    uv run Tools/fetch_typing_lm.py --fetch     # download the source model, then build
    uv run Tools/fetch_typing_lm.py             # build from the files already downloaded
    uv run Tools/fetch_typing_lm.py --remove    # empty ios/TypingLM again

The model is distilbert/distilgpt2 (Apache-2.0) at the Hugging Face revision below. A normal
run never touches the network. `--fetch` downloads four files into the data directory (default
~/Library/Caches/MurmurBuild/typing-lm/source); every run checks their size and SHA-256
against the values below and exits 1 on a mismatch, so a changed upstream file can never slip
into a build.

The output is what Sources/MurmurTyping/Predict/NextWordPredictor.swift loads and what
ios/project.yml copies into the keyboard as a folder:

    ios/TypingLM/NextWord.mlmodelc   the Core ML model, compiled (needs Xcode's coremlcompiler)
    ios/TypingLM/vocab.json          the tokenizer's vocabulary, as downloaded
    ios/TypingLM/merges.txt          the tokenizer's merge list, as downloaded
    ios/TypingLM/model.json          what was built, from what

Conversion is training/typing-lm/convert.py: a window of 32 tokens, the embedding table as a
4-bit palette and every other weight as a 6-bit palette (51.5 MB; the choice and its
measurements are in training/typing-lm/README.md). The palettes come from k-means. Three builds
on one Mac on 2026-11-25 gave the same weight file (SHA-256 59d54459...784f0922), but that is
not checked, because another version of the libraries may cluster differently; the inputs are
what is pinned. Without the model the keyboard builds and runs on the word-pair model alone.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request

REPO = "distilbert/distilgpt2"
REVISION = "2290a62682d06624634c1f46a6ad5be0f47f38aa"
LICENCE = "Apache-2.0"
BASE = f"https://huggingface.co/{REPO}/resolve/{REVISION}/"

# name: (byte size, SHA-256), all observed on the first fetch (2026-11-25).
SOURCES = {
    "config.json": (762, "4ec5947c1d59fee6212cdf3b0ec1a53eac02092554c5ff0a733488cbd2c64f3a"),
    "model.safetensors": (352_824_413, "e1ff18884359fe8beb795a5f414feb85a6ce3d929ad019c0d958c039d2b94a1b"),
    "vocab.json": (1_042_301, "196139668be63f3b5d6574427317ae82f612a97c5d1cdaf36ed2256dbf636783"),
    "merges.txt": (456_318, "1ce1664773c50f3e0cc8842619a93edc4624525b728b188a9e0be33b7726adc5"),
}

CONTEXT = 32
WEIGHT_FORMAT = "emb4rest6"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_DATA_DIR = os.path.expanduser("~/Library/Caches/MurmurBuild/typing-lm/source")
DEFAULT_OUT = os.path.join(ROOT, "ios", "TypingLM")
OUTPUTS = ["NextWord.mlmodelc", "vocab.json", "merges.txt", "model.json"]


def die(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def check_file(path, size, sha):
    if not os.path.isfile(path):
        die(f"{path} is missing; run with --fetch")
    if os.path.getsize(path) != size:
        die(f"{path}: {os.path.getsize(path)} bytes, expected {size}")
    got = sha256(path)
    if got != sha:
        die(f"{path}: SHA-256 {got}, expected {sha}")


def fetch(data_dir):
    os.makedirs(data_dir, exist_ok=True)
    for name, (size, sha) in SOURCES.items():
        path = os.path.join(data_dir, name)
        if os.path.isfile(path) and os.path.getsize(path) == size and sha256(path) == sha:
            continue
        print(f"fetching {BASE}{name}")
        request = urllib.request.Request(BASE + name, headers={"User-Agent": "model-fetch/1.0"})
        tmp = path + ".part"
        with urllib.request.urlopen(request, timeout=120) as response, open(tmp, "wb") as handle:
            shutil.copyfileobj(response, handle, 1 << 20)
        os.replace(tmp, path)


def remove(out):
    for name in OUTPUTS:
        path = os.path.join(out, name)
        if os.path.isdir(path):
            shutil.rmtree(path)
        elif os.path.exists(path):
            os.remove(path)


def folder_size(path):
    return sum(os.path.getsize(os.path.join(root, name)) for root, _, names in os.walk(path) for name in names)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fetch", action="store_true", help="download the source model first")
    parser.add_argument("--remove", action="store_true", help="delete the built model from --out and stop")
    parser.add_argument("--data-dir", default=DEFAULT_DATA_DIR)
    parser.add_argument("--out", default=DEFAULT_OUT)
    args = parser.parse_args()

    if args.remove:
        remove(args.out)
        print(f"removed the model from {args.out}")
        return
    if args.fetch:
        fetch(args.data_dir)
    for name, (size, sha) in SOURCES.items():
        check_file(os.path.join(args.data_dir, name), size, sha)

    sys.dont_write_bytecode = True  # no __pycache__ beside the repo's scripts
    sys.path.insert(0, os.path.join(ROOT, "training", "typing-lm"))
    import convert  # noqa: E402  (after the checks, because it imports torch and coremltools)

    model = convert.compress(convert.convert(args.data_dir, CONTEXT), WEIGHT_FORMAT)
    with tempfile.TemporaryDirectory() as scratch:
        package = os.path.join(scratch, "NextWord.mlpackage")
        model.save(package)
        compiled = subprocess.run(
            ["xcrun", "coremlcompiler", "compile", package, scratch], capture_output=True, text=True)
        if compiled.returncode != 0:
            die(f"coremlcompiler failed: {compiled.stderr.strip() or compiled.stdout.strip()}")
        os.makedirs(args.out, exist_ok=True)
        remove(args.out)
        shutil.move(os.path.join(scratch, "NextWord.mlmodelc"), os.path.join(args.out, "NextWord.mlmodelc"))
    for name in ("vocab.json", "merges.txt"):
        shutil.copyfile(os.path.join(args.data_dir, name), os.path.join(args.out, name))
    size = folder_size(os.path.join(args.out, "NextWord.mlmodelc"))
    manifest = {
        "model": REPO, "revision": REVISION, "licence": LICENCE,
        "context": CONTEXT, "weights": WEIGHT_FORMAT, "modelBytes": size,
        "sources": {name: {"bytes": size_, "sha256": sha} for name, (size_, sha) in SOURCES.items()},
    }
    with open(os.path.join(args.out, "model.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    print(f"wrote {args.out}: NextWord.mlmodelc {size / 1e6:.1f} MB, vocab.json, merges.txt, model.json")


if __name__ == "__main__":
    main()
