#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Download a Hugging Face model repo for the benchmark, pinned and verified.

    uv run bench/fetch.py <owner/repo> <name> [--revision SHA] [--include PREFIX ...]
    uv run bench/fetch.py --remove <name>

Files go to ~/Library/Application Support/Murmur/Benchmarks/models/<name>/. The revision
is resolved to a commit hash once and recorded in model.json; every file is checked
against the repo's listing (SHA-256 for LFS files, the git blob hash otherwise) and the
folder only appears under its name once all of them match. Nothing in the app reads this
folder.
"""
import argparse
import hashlib
import json
import shutil
import sys
import urllib.parse
import urllib.request
from pathlib import Path

MODELS = Path.home() / "Library/Application Support/Murmur/Benchmarks/models"


def get_json(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "murmur-bench"})) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("repo", nargs="?")
    parser.add_argument("name")
    parser.add_argument("--revision", default="main")
    parser.add_argument("--include", nargs="*", default=[], help="only paths starting with these prefixes")
    parser.add_argument("--remove", action="store_true", help="delete models/<name> instead")
    args = parser.parse_args()

    target = MODELS / args.name
    if args.remove:
        if not target.exists():
            sys.exit(f"{target} does not exist")
        size = sum(f.stat().st_size for f in target.rglob("*") if f.is_file())
        shutil.rmtree(target)
        print(f"removed {target} ({size / 1e6:.0f} MB)")
        return
    if not args.repo:
        sys.exit("give a repo, e.g. FluidInference/parakeet-tdt-0.6b-v3-coreml")
    if target.exists():
        sys.exit(f"{target} already exists; remove it first with --remove {args.name}")

    repo = urllib.parse.quote(args.repo, safe="/")
    sha = get_json(f"https://huggingface.co/api/models/{repo}/revision/{urllib.parse.quote(args.revision)}")["sha"]
    listing = get_json(f"https://huggingface.co/api/models/{repo}/tree/{sha}?recursive=true")
    files = [e for e in listing if e["type"] == "file" and (not args.include or any(e["path"].startswith(p) for p in args.include))]
    total = sum(e.get("lfs", {}).get("size", e["size"]) for e in files)
    print(f"{args.repo}@{sha[:8]}: {len(files)} files, {total / 1e6:.0f} MB")

    partial = MODELS / f".{args.name}.partial"
    shutil.rmtree(partial, ignore_errors=True)
    for entry in files:
        path = partial / entry["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        url = f"https://huggingface.co/{repo}/resolve/{sha}/{urllib.parse.quote(entry['path'])}"
        lfs = entry.get("lfs")
        digest = hashlib.sha256() if lfs else hashlib.sha1(f"blob {entry['size']}\0".encode())
        size = 0
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "murmur-bench"})) as response, open(path, "wb") as out:
            while chunk := response.read(1 << 20):
                digest.update(chunk)
                out.write(chunk)
                size += len(chunk)
        expected_size = lfs["size"] if lfs else entry["size"]
        expected_hash = lfs["oid"] if lfs else entry["oid"]
        if size != expected_size or digest.hexdigest() != expected_hash:
            shutil.rmtree(partial, ignore_errors=True)
            sys.exit(f"MISMATCH {entry['path']}: {size} bytes {digest.hexdigest()}, expected {expected_size} {expected_hash}")
        print(f"  ok {entry['path']} ({size / 1e6:.1f} MB)")

    (partial / "model.json").write_text(json.dumps({"repo": args.repo, "revision": sha, "files": len(files), "bytes": total}, indent=1))
    target.parent.mkdir(parents=True, exist_ok=True)
    partial.rename(target)
    print(f"verified {len(files)} files → {target}")


if __name__ == "__main__":
    main()
