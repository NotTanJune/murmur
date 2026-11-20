#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["jiwer==3.1.0", "whisper-normalizer==0.1.12", "numpy", "soundfile", "scipy"]
# ///
"""Benchmark candidate speech models against Murmur's current setup.

    uv run bench/bench.py bench/candidates/<name>.json [more.json ...]
        [--passes clean,paced,noisy] [--snr 5] [--limit N] [--exclude ID8 ...]

The current setup is whatever the installed app's Settings select (engine, timing, Bark
decoder, cleanup engine and profile) plus the dictionary, read at run time. A candidate runs
in place of the current engine with everything else the same.

Passes, each over the recordings the run log kept audio for:
  clean   unpaced, every recording: what each engine heard and would have typed
  paced   the corrected recordings fed at twice real time: release-to-typed latency
  noisy   the corrected recordings under babble (6 of your other recordings) plus pink
          noise at --snr dB, unpaced

Scores are against your history corrections, which are edits of whatever engine you used
when you made them (Bark Clean so far), so they lean toward that engine. Results go to
~/Library/Application Support/Murmur/Benchmarks/runs/<stamp>-<names>/ with report.md.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
APP = Path.home() / "Library/Application Support/Murmur"
RUNS_DIR = APP / "Benchmarks/runs"
SCRATCH = Path.home() / "Library/Caches/MurmurBuild/scratch"
ANE_CACHE = APP / "Benchmarks/ane-cache"
# Release, as the app is built: in debug FluidAudio's decode loop runs several times slower.
# -enable-testing lets the runner import the app's internal types.
SWIFT_FLAGS = ["-c", "release", "-Xswiftc", "-enable-testing", "-j", "3", "--scratch-path", str(SCRATCH)]
HELPER = Path("/Applications/Murmur.app/Contents/MacOS/Murmur")
FILLERS = re.compile(r"\b(um+|uh+|uhm|er|ah|hmm+|mm+)\b", re.I)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("candidates", nargs="+", type=Path)
    parser.add_argument("--passes", default="clean,paced,noisy")
    parser.add_argument("--snr", type=float, default=5.0)
    parser.add_argument("--limit", type=int, help="only the newest N recordings in each pass (a quick check)")
    parser.add_argument("--exclude", nargs="*", default=[], help="recording id prefixes to leave out of scores")
    args = parser.parse_args()

    candidates = [json.loads(p.read_text()) for p in args.candidates]
    for c in candidates:
        if "folder" in c:
            c["folder"] = str(Path(os.path.expanduser(c["folder"])))
    passes = [p.strip() for p in args.passes.split(",") if p.strip()]
    if unknown := set(passes) - {"clean", "paced", "noisy"}:
        sys.exit(f"unknown pass {', '.join(unknown)}")
    if not HELPER.exists():
        sys.exit(f"{HELPER} not found: S1-mini cleanup runs in the installed app's helper (make install)")

    runs = load_runs()
    with_audio = [r for r in runs.values() if r.get("hasAudio") and recording(r["id"]).exists()]
    with_audio.sort(key=lambda r: r["date"], reverse=True)
    labelled = [r for r in with_audio if r.get("label")]
    print(f"{len(with_audio)} recordings with audio, {len(labelled)} corrected")
    pool = with_audio
    if args.limit:
        with_audio, labelled = with_audio[: args.limit], labelled[: args.limit]

    stamp = dt.datetime.now().strftime("%Y-%m-%d-%H%M")
    out = RUNS_DIR / f"{stamp}-{'-'.join(c['name'] for c in candidates)}"
    out.mkdir(parents=True, exist_ok=True)

    build()
    results = {}
    for name in passes:
        if name == "clean":
            items = [{"id": r["id"], "path": str(recording(r["id"]))} for r in with_audio]
            results[name] = run_pass(out, name, items, candidates, paced=False)
        elif name == "paced":
            items = [{"id": r["id"], "path": str(recording(r["id"]))} for r in labelled]
            results[name] = run_pass(out, name, items, candidates, paced=True)
        elif name == "noisy":
            noisy = out / "noisy-audio"
            items = mix_noise(labelled, pool, noisy, args.snr)
            try:
                results[name] = run_pass(out, name, items, candidates, paced=False)
            finally:
                # Your voice; nothing needs it once the pass has run.
                shutil.rmtree(noisy, ignore_errors=True)

    report = score(results, runs, set(args.exclude), args.snr)
    (out / "report.md").write_text(report)
    print("\n" + report)
    print(f"\nwritten to {out}")


def load_runs():
    runs = {}
    for line in (APP / "runs.jsonl").read_text().splitlines():
        if line.strip():
            run = json.loads(line)
            runs[run["id"]] = run  # a later line for the same id replaces the earlier one
    return runs


def recording(run_id):
    return APP / "Recordings" / f"{run_id}.flac"


def run_pass(out, name, items, candidates, paced):
    job = out / f"job-{name}.json"
    result = out / f"{name}.json"
    job.write_text(json.dumps({"items": items, "candidates": candidates, "paced": paced, "output": str(result)}, indent=1))
    print(f"\n== {name}: {len(items)} recordings{' at 2× real time' if paced else ''}")
    env = dict(os.environ, MURMUR_BENCH_JOB=str(job), MURMUR_S1_HELPER=str(HELPER),
               MURMUR_SETTINGS_DOMAIN="ai.pivotstudio.murmur.bench")
    command = ["nice", "-n", "10", "swift", "test", "--skip-build", *SWIFT_FLAGS, "--filter", "MurmurBench"]
    code = subprocess.run(command, cwd=REPO, env=env).returncode
    if code != 0 or not result.exists():
        sys.exit(f"{name} pass failed (exit {code}); partial results, if any, are in {result}")
    return json.loads(result.read_text())


def build():
    """Builds the runner, and empties its Core ML cache when the binary changed.

    Core ML ties a compiled model to the binary that compiled it (2026-11-20: an unchanged
    runner loaded Bark in 0.6 s; after a rebuild Bark compiled again for 100 s and the old
    entries stayed behind), so a new binary makes the whole cache dead weight.
    """
    print("building the runner (release)")
    if subprocess.run(["nice", "-n", "10", "swift", "build", "--build-tests", *SWIFT_FLAGS], cwd=REPO).returncode != 0:
        sys.exit("build failed")
    bin_path = subprocess.run(["swift", "build", *SWIFT_FLAGS, "--show-bin-path"], cwd=REPO,
                              capture_output=True, text=True, check=True).stdout.strip()
    binary = Path(bin_path) / "MurmurBench.xctest/Contents/MacOS/MurmurBench"
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    # Beside the cache, not in it: Core ML removed a file left inside.
    marker = ANE_CACHE.parent / "ane-cache.built-from"
    ANE_CACHE.mkdir(parents=True, exist_ok=True)
    if not marker.exists() or marker.read_text().strip() != digest:
        stale = list(ANE_CACHE.iterdir())
        for p in stale:
            shutil.rmtree(p) if p.is_dir() and not p.is_symlink() else p.unlink()
        if stale:
            print("new runner binary: cleared its Neural Engine cache; models compile once this run")
        marker.write_text(digest + "\n")


def mix_noise(labelled, pool_runs, folder, snr):
    """Babble (6 other recordings overlapped) plus pink noise under each corrected recording."""
    import numpy as np
    import soundfile as sf
    from scipy.signal import resample_poly

    folder.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(7)
    labelled_ids = {r["id"] for r in labelled}
    pool = [str(recording(r["id"])) for r in pool_runs if r["id"] not in labelled_ids]
    if len(pool) < 6:
        sys.exit("noisy pass needs at least 6 uncorrected recordings for babble")

    def load(path):
        x, rate = sf.read(path, dtype="float32", always_2d=True)
        x = x.mean(1)
        return resample_poly(x, 16000, rate).astype("float32") if rate != 16000 else x

    def rms(x):
        return float(np.sqrt(np.mean(x**2) + 1e-12))

    items = []
    for run in labelled:
        speech = load(str(recording(run["id"])))
        n = len(speech)
        babble = np.zeros(n, "float32")
        for path in rng.choice(pool, 6, replace=False):
            b = load(path)
            babble += np.tile(b, int(np.ceil(n / len(b))))[:n] / rms(b)
        spectrum = np.fft.rfft(rng.standard_normal(n))
        spectrum[1:] /= np.sqrt(np.arange(1, len(spectrum)))
        pink = np.fft.irfft(spectrum, n).astype("float32")
        noise = babble / rms(babble) + 0.5 * pink / rms(pink)
        noise *= rms(speech) / rms(noise) / (10 ** (snr / 20))
        mixed = speech + noise
        mixed /= max(1.0, float(np.abs(mixed).max()) / 0.99)
        path = folder / f"{run['id']}.wav"
        sf.write(path, mixed, 16000, subtype="PCM_16")
        items.append({"id": run["id"], "path": str(path)})
    print(f"mixed {len(items)} recordings at {snr:g} dB SNR")
    return items


# ---------------------------------------------------------------------------- scoring

def normaliser():
    from whisper_normalizer.english import EnglishTextNormalizer

    english = EnglishTextNormalizer()

    def norm(text):
        words, out, letters = english(text or "").split(), [], []
        # Join runs of single letters ("m c p" -> "mcp") so spelled acronyms match either way.
        for w in words + [""]:
            if len(w) == 1 and w.isalpha():
                letters.append(w)
                continue
            if letters:
                out.append("".join(letters))
                letters = []
            if w:
                out.append(w)
        return " ".join(out)

    return norm


def score(results, runs, exclude, snr):
    import jiwer

    norm = normaliser()

    def wer(refs, hyps):
        pairs = [(norm(r), norm(h) or "<empty>") for r, h in zip(refs, hyps)]
        pairs = [p for p in pairs if p[0]]
        if not pairs:
            return float("nan")
        m = jiwer.process_words([p[0] for p in pairs], [p[1] for p in pairs])
        return 100 * (m.substitutions + m.deletions + m.insertions) / sum(len(p[0].split()) for p in pairs)

    def median_ms(xs):
        xs = [x for x in xs if x is not None]
        return f"{statistics.median(xs) * 1000:.0f} ms" if xs else "n/a"

    def pct(x):
        return "n/a" if x != x else f"{x:.2f}%"

    terms = dictionary_terms()
    first = next(iter(results.values()))
    meta = first["meta"]
    names = ["current"] + sorted(n for n in meta["contenders"] if n != "current")
    lines = [
        f"# Benchmark {dt.date.today().isoformat()}",
        "",
        f"Current setup: **{meta['baseline']}**, cleanup {meta['cleanup']}.",
        "Candidates: " + ", ".join(f"**{n}** ({meta['contenders'][n]})" for n in names[1:]) + ".",
        "",
        "Word errors are against your history corrections, normalised, fillers ignored by the",
        "normaliser. The corrections are edits of the engine you used when you made them, so",
        "they lean toward it. Lower is better.",
        "",
    ]

    def rows_of(name):
        rows = results[name]["rows"]
        return [r for r in rows if r["id"][:8] not in exclude]

    def labelled(rows):
        return [r for r in rows if runs.get(r["id"], {}).get("label")]

    head = ["| | " + " | ".join(names) + " |", "|---|" + "---|" * len(names)]
    table = []
    for name in results:
        rows = labelled(rows_of(name))
        refs = [runs[r["id"]]["label"] for r in rows]
        tag = {"clean": "clean", "paced": "paced", "noisy": f"{snr:g} dB noise"}[name]
        if name == "clean":
            table.append(f"| Heard, {tag} | " + " | ".join(pct(wer(refs, [r["results"][n]["heard"] for r in rows])) for n in names) + " |")
        table.append(f"| Typed, {tag} | " + " | ".join(pct(wer(refs, [r["results"][n]["typed"] for r in rows])) for n in names) + " |")
    if "paced" in results:
        rows = rows_of("paced")
        table.append("| Release to typed, median | " + " | ".join(median_ms([r["results"][n].get("tailSeconds") for r in rows]) for n in names) + " |")
    if "clean" in results:
        rows = rows_of("clean")
        expected = []
        for r in labelled(rows):
            label = norm(runs[r["id"]]["label"]).replace(" ", "")
            expected += [(r, t) for t in terms if len(t) >= 3 and norm(t).replace(" ", "") and norm(t).replace(" ", "") in label]
        table.append(f"| Dictionary terms heard right (of {len(expected)}) | "
                     + " | ".join(str(sum(1 for r, t in expected if t in r["results"][n]["heard"])) for n in names) + " |")
        table.append(f"| Empty result (of {len(rows)}) | " + " | ".join(str(sum(1 for r in rows if not r["results"][n]["heard"].strip())) for n in names) + " |")
        table.append("| Fillers heard / typed | " + " | ".join(
            f"{sum(len(FILLERS.findall(r['results'][n]['heard'])) for r in rows)} / {sum(len(FILLERS.findall(r['results'][n]['typed'])) for r in rows)}"
            for n in names) + " |")
        table.append("| Decode, engine alone, median | " + " | ".join(median_ms([r["results"][n]["decodeSeconds"] for r in rows]) for n in names) + " |")
        if any(r["results"][n].get("preprocessSeconds") is not None for r in rows for n in names):
            table.append("| Preprocess, whole clip, median | " + " | ".join(
                median_ms([r["results"][n].get("preprocessSeconds") for r in rows]) for n in names) + " |")
        table.append("| Errors | " + " | ".join(str(sum(1 for r in rows if r["results"][n].get("error"))) for n in names) + " |")
    lines += head + table

    if "clean" in results:
        rows = [r for r in rows_of("clean") if not runs.get(r["id"], {}).get("label")]
        lines += ["", f"## Against the current setup, {len(rows)} uncorrected recordings", ""]
        for n in names[1:]:
            same = sum(1 for r in rows if norm(r["results"][n]["typed"]) == norm(r["results"]["current"]["typed"]))
            diff = wer([r["results"]["current"]["typed"] for r in rows], [r["results"][n]["typed"] for r in rows])
            lines.append(f"- **{n}**: typed text differs by {pct(diff)} of words; {same} of {len(rows)} recordings identical.")
        empties = [(r["id"][:8], runs[r["id"]]["text"]) for r in rows_of("clean")
                   if any(not r["results"][n]["heard"].strip() for n in names[1:]) and r["results"]["current"]["heard"].strip()]
        if empties:
            lines.append("- Empty where the current setup heard words: " + "; ".join(f"`{i}` \"{t[:40]}\"" for i, t in empties[:10]))
    return "\n".join(lines) + "\n"


def dictionary_terms():
    path = APP / "dictionary.txt"
    if not path.exists():
        return []
    terms = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            terms.append(line.split("->")[-1].strip())
    return terms


if __name__ == "__main__":
    main()
