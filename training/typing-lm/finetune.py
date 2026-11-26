#!/usr/bin/env python3
"""Fine-tune the keyboard's next-word model on short conversational English, on a GPU.

    python finetune.py --eval-sentences eval-sentences.tsv --out /content/ft

Meant for a Colab GPU session (`colab upload` this file and eval-sentences.tsv, then start it in
the background and read its log); it needs torch, transformers, pyarrow and huggingface_hub,
which Colab has. Nothing private goes up: the two corpora are public and the script downloads
them itself.

Why: distilgpt2 was trained on web pages, and its taste shows in the strip ("please enable
javascript to view the comments"). The keyboard's text is messages and notes, and the owner
types in lowercase. So the model is trained a little further on:

- Tatoeba's English sentences (CC BY 2.0 FR): short everyday sentences. Sentences that start
  with a name, or hold one of the corpus's stock names and places (`STOCK`), are dropped: a
  twelfth of its sentences say "Tom" and the first run, which dropped only the name-led ones,
  offered "tom" in the middle of a sentence ("please don't tell tom that").
- Utterances from SODA (allenai/soda, CC BY 4.0): single turns of casual dialogue.

Each example is one sentence or one turn with the start token in front, which is what the
keyboard gives the model. 40% are as written, 30% lowercased, and 30% lowercased with the
punctuation removed, so the model reads lowercase text as well as it reads cased text.

Nothing from the evaluation set is trained on: every Tatoeba sentence the set uses is dropped
by id, and any sentence or turn whose words equal an evaluation sentence's is dropped too.
Tatoeba's remaining sentences still resemble its evaluation half (it is a corpus of variations),
so that half flatters a model trained here. Murmur's own 229 replay sentences are the clean
measure; evaluate.py reports them separately.

It saves a checkpoint (a Hugging Face model folder) at a quarter, a half and the end of the
run, so the least-trained model that helps can be the one kept.

Hinglish (optional, `--hinglish <file>`): the owner mixes Hindi written in Roman script into his
English ("kya hai yaar"). The file is lines of Hinglish text, plain or gzipped, in the shape of
L3Cube-HingCorpus (roman), a Twitter corpus under CC BY-NC-SA 4.0. That licence is not
GPL-compatible, so the corpus, anything made from it and any model trained on it stay out of
the repository. A line is kept if it has 5 to 40 words, no URL, handle or tag, and mostly Roman
letters (`hinglish_ok`); duplicates are dropped. 2,000 kept lines are held out and never trained
on; `--hinglish-share` is the fraction of the final training sentences that are Hinglish (default
0.15; 0.3 adds about 0.43 Hinglish sentences per English one, the English part being unchanged). Held-out
Hinglish and English next-word hits are printed before training and at each checkpoint, so one
run shows both what Hinglish gains and what English loses.

Added tokens (optional, `--added-tokens <file>`, plan 004): the word list `hinglish_tokens.py
--emit` writes (each word with its leading space, one a line) becomes whole-word tokens, ids 50257
on. Their embedding rows start as the mean of the rows of the pieces the word was cut into
(`added_tokens.py`, which says why they are not Hugging Face `AddedToken`s). The tokenizer is built
before anything is tokenised, so the Hinglish training lines and the held-out measure see an added
word as one token; the list is saved next to each checkpoint as `added-tokens.txt`. Like the
corpus, the list derives from CC BY-NC-SA data and is never committed. `--hinglish-share` defaults
to 0.15; `--max-steps` stops early, for a smoke run on a CPU (with `--soda-turns 0` and
`--max-english` to keep the data small).
"""
import argparse
import bz2
import gzip
import hashlib
import math
import os
import random
import re
import shutil
import sys
import time
import urllib.request

import pyarrow.parquet as pq
import torch
from huggingface_hub import hf_hub_download
from transformers import AutoModelForCausalLM, AutoTokenizer

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import added_tokens  # noqa: E402

BASE = "distilbert/distilgpt2"
BASE_REVISION = "2290a62682d06624634c1f46a6ad5be0f47f38aa"
SODA = "allenai/soda"
SODA_REVISION = "fdc848ab0183208ea7808206c91c724414d0a071"
TATOEBA = "https://downloads.tatoeba.org/exports/per_language/eng/eng_sentences.tsv.bz2"

# The names and places Tatoeba's contributors reuse, from a count of capitalised words inside its
# sentences on 2026-11-25 (Tom 166,794, Mary 119,529, Boston 18,500, Rima 14,827, ...). Languages,
# weekdays and other real proper nouns are kept.
STOCK = set("""Tom Mary John Rima Layla Skura Ziri Sami Yanni Linda Baya Alice Martha Walid Isabella
Jessica Sandra Amanda Amelia Anna Melissa Jackson Fadil Mennad Dania Dan Boston Australia Algeria
Algiers Algerian Berber Kabyle Kabylie Tatoeba Esperanto""".split())

URLISH = re.compile(r"https?:|www\.|[@#]\S|\.com\b", re.IGNORECASE)
HINGLISH_WORDS = (5, 40)
HINGLISH_ROMAN = 0.9  # share of non-space characters that must be A-Z, a-z or plain punctuation
HINGLISH_HELD_OUT = 2000

ALLOWED = re.compile(r"^[A-Za-z0-9' ,.?!;:()\"-]+$")
WORD = re.compile(r"[A-Za-z']+")
SENTENCE_END = re.compile(r"(?<=[.?!]) ")


def words_of(text):
    """The text as the evaluation compares it: lowercase words, nothing else."""
    return " ".join(WORD.findall(text.lower()))


def held_out(path):
    ids, texts = set(), set()
    for line in open(path, encoding="utf-8"):
        if line.startswith("#") or "\t" not in line:
            continue
        source, text = line.rstrip("\n").split("\t", 1)
        if source.isdigit():
            ids.add(int(source))
        texts.add(words_of(text))
        for sentence in SENTENCE_END.split(text):
            texts.add(words_of(sentence))
    return ids, texts


def tatoeba(folder, held_ids, held_texts):
    path = os.path.join(folder, "eng_sentences.tsv.bz2")
    if not os.path.exists(path):
        request = urllib.request.Request(TATOEBA, headers={"User-Agent": "corpus-fetch/1.0"})
        with urllib.request.urlopen(request, timeout=300) as response, open(path, "wb") as out:
            out.write(response.read())
    raw = open(path, "rb").read()
    print(f"tatoeba export: {len(raw)} bytes, SHA-256 {hashlib.sha256(raw).hexdigest()}", flush=True)
    rows = []
    for line in bz2.decompress(raw).decode("utf-8").splitlines():
        number, _, text = line.split("\t", 2)
        if int(number) in held_ids or not ALLOWED.match(text) or "  " in text:
            continue
        if not 3 <= len(WORD.findall(text)) <= 30:
            continue
        rows.append(text)
    # A first word that is seldom written in lowercase inside a sentence is a name.
    inside = {}
    for text in rows:
        for word in WORD.findall(text)[1:]:
            if word[0].islower():
                inside[word] = inside.get(word, 0) + 1
    kept, names, held = [], 0, 0
    for text in rows:
        words = WORD.findall(text)
        first = words[0]
        if any(word.removesuffix("'s") in STOCK for word in words):
            names += 1
        elif first != "I" and not first.startswith("I'") and inside.get(first.lower(), 0) < 20:
            names += 1
        elif words_of(text) in held_texts:
            held += 1
        else:
            kept.append(text)
    print(f"tatoeba: {len(kept)} kept, {names} start with a name or hold a stock one, "
          f"{held} equal an evaluation sentence", flush=True)
    return kept


def soda(count, held_texts, rng):
    path = hf_hub_download(SODA, "train.parquet", repo_type="dataset", revision=SODA_REVISION)
    turns, held = [], 0
    for dialogue in pq.read_table(path, columns=["dialogue"]).column("dialogue").to_pylist():
        for turn in dialogue:
            turn = " ".join(turn.split())
            if not ALLOWED.match(turn) or not 2 <= len(WORD.findall(turn)) <= 40:
                continue
            turns.append(turn)
    rng.shuffle(turns)
    kept = []
    for turn in turns:
        if len(kept) == count:
            break
        if words_of(turn) in held_texts:
            held += 1
            continue
        kept.append(turn)
    print(f"soda: {len(kept)} of {len(turns)} turns, {held} equal an evaluation sentence", flush=True)
    return kept


def variant(text, rng):
    """As written, lowercased, or lowercased with no punctuation but apostrophes."""
    draw = rng.random()
    if draw < 0.4:
        return text
    lower = text.lower()
    if draw < 0.7:
        return lower
    return " ".join(re.sub(r"[^a-z0-9' ]", " ", lower).split())


def hinglish_ok(line):
    """A Hinglish line the model may train on: 5 to 40 words, no link, handle or tag, mostly Roman."""
    words = line.split()
    if not HINGLISH_WORDS[0] <= len(words) <= HINGLISH_WORDS[1] or URLISH.search(line):
        return False
    letters = [c for c in line if not c.isspace()]
    plain = sum(1 for c in letters if c.isascii() and (c.isalpha() or c in "',.?!;:()\"-"))
    return plain / len(letters) >= HINGLISH_ROMAN and not any(c.isdigit() for c in line)


def hinglish(path, count, held_texts, rng):
    """(training lines, held-out lines) from the corpus file: filtered, deduplicated, shuffled."""
    opener = gzip.open if path.endswith(".gz") else open
    seen, lines, read = set(), [], 0
    with opener(path, "rt", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            read += 1
            line = " ".join(line.split())
            if not hinglish_ok(line):
                continue
            key = words_of(line)
            if key in seen or key in held_texts:
                continue
            seen.add(key)
            lines.append(line)
    rng.shuffle(lines)
    held, train = lines[:HINGLISH_HELD_OUT], lines[HINGLISH_HELD_OUT:]
    # A tweet and its retweet differ only by a handle or tag, which the filter has removed.
    if len(train) < count:
        print(f"WARNING: only {len(train)} Hinglish lines for the {count} asked", flush=True)
    print(f"hinglish: {read} lines read, {len(lines)} pass the filter, {len(held)} held out, "
          f"{min(count, len(train))} used", flush=True)
    return train[:count], held


def next_word_hits(model, tokenizer, sentences, device, max_tokens=48):
    """Top-three next-word hits at every word boundary of lowercased sentences.

    A proxy for the keyboard (which also filters to its word list and applies its own rules): the
    target counts as a hit when it is one token (" hai") and among the three likeliest tokens;
    a word that takes several tokens is a miss, as it is for the keyboard today. Returns
    (hits over every word, hits over one-token words, one-token share).
    """
    start = tokenizer.eos_token_id
    rows = []
    for text in sentences:
        words = words_of(text).split()
        ids, marks = [start], []
        for at, word in enumerate(words):
            pieces = tokenizer(word if at == 0 else " " + word, add_special_tokens=False)["input_ids"]
            if len(ids) + len(pieces) > max_tokens:
                break
            if at > 0:
                marks.append((len(ids) - 1, pieces[0] if len(pieces) == 1 else None))
            ids += pieces
        if marks:
            rows.append((ids, marks))
    model.eval()
    positions = singles = hits = 0
    with torch.no_grad():
        for first in range(0, len(rows), 64):
            chunk = rows[first:first + 64]
            longest = max(len(ids) for ids, _ in chunk)
            batch = torch.full((len(chunk), longest), start, dtype=torch.long)
            mask = torch.zeros((len(chunk), longest), dtype=torch.long)
            for row, (ids, _) in enumerate(chunk):
                batch[row, :len(ids)] = torch.tensor(ids)
                mask[row, :len(ids)] = 1
            with torch.autocast("cuda", dtype=torch.float16, enabled=device == "cuda"):
                logits = model(input_ids=batch.to(device), attention_mask=mask.to(device)).logits
            top3 = logits.topk(3, dim=-1).indices.cpu()
            for row, (_, marks) in enumerate(chunk):
                for position, target in marks:
                    positions += 1
                    if target is not None:
                        singles += 1
                        hits += int(target in top3[row, position].tolist())
    model.train()
    return hits / max(1, positions), hits / max(1, singles), singles / max(1, positions)


def report_hits(label, model, tokenizer, english, held, device):
    parts = []
    for name, sentences in (("english", english), ("hinglish", held)):
        if sentences:
            top3, top3_single, share = next_word_hits(model, tokenizer, sentences, device)
            parts.append(f"{name} top-3 {100 * top3:.2f}% (one-token words {100 * top3_single:.2f}%, "
                         f"{100 * share:.1f}% of words are one token)")
    print(f"{label}: " + "; ".join(parts), flush=True)


def eval_sentences(path):
    """The evaluation file's sentences, one per sentence of each entry."""
    out = []
    for line in open(path, encoding="utf-8"):
        if line.startswith("#") or "\t" not in line:
            continue
        out += [sentence for sentence in SENTENCE_END.split(line.rstrip("\n").split("\t", 1)[1]) if sentence]
    return out


def batches(examples, size, rng):
    """Batches of similar length, in random order: sorted inside chunks of fifty batches."""
    order = list(range(len(examples)))
    rng.shuffle(order)
    out = []
    for start in range(0, len(order), size * 50):
        chunk = sorted(order[start:start + size * 50], key=lambda index: len(examples[index]))
        out += [chunk[at:at + size] for at in range(0, len(chunk), size)]
    rng.shuffle(out)
    return out


def tensors(examples, indices, pad, device):
    longest = max(len(examples[index]) for index in indices)
    ids = torch.full((len(indices), longest), pad, dtype=torch.long)
    mask = torch.zeros((len(indices), longest), dtype=torch.long)
    for row, index in enumerate(indices):
        ids[row, :len(examples[index])] = torch.tensor(examples[index])
        mask[row, :len(examples[index])] = 1
    labels = ids.masked_fill(mask == 0, -100)
    return ids.to(device), mask.to(device), labels.to(device)


def validation_loss(model, examples, pad, device):
    model.eval()
    total, count = 0.0, 0
    with torch.no_grad():
        for start in range(0, len(examples), 512):
            indices = list(range(start, min(start + 512, len(examples))))
            ids, mask, labels = tensors(examples, indices, pad, device)
            with torch.autocast("cuda", dtype=torch.float16, enabled=device == "cuda"):
                loss = model(input_ids=ids, attention_mask=mask, labels=labels).loss
            tokens = int((labels != -100).sum()) - len(indices)
            total += loss.item() * tokens
            count += tokens
    model.train()
    return total / count


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--eval-sentences", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--data", default="/content/data")
    parser.add_argument("--soda-turns", type=int, default=1_500_000)
    parser.add_argument("--batch", type=int, default=256)
    parser.add_argument("--max-tokens", type=int, default=48)
    parser.add_argument("--rate", type=float, default=5e-5)
    parser.add_argument("--seed", type=int, default=20261125)
    parser.add_argument("--hinglish", help="Hinglish corpus lines, plain or .gz (see the docstring)")
    parser.add_argument("--hinglish-share", type=float, default=0.15,
                        help="fraction of the final training sentences that are Hinglish")
    parser.add_argument("--added-tokens", help="word list (a space and a word a line) to add as whole-word tokens")
    parser.add_argument("--max-steps", type=int, help="stop after this many steps (a smoke run)")
    parser.add_argument("--max-english", type=int,
                        help="use at most this many Tatoeba sentences (a smoke run); with --soda-turns 0 no SODA")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    os.makedirs(args.data, exist_ok=True)
    rng = random.Random(args.seed)
    torch.manual_seed(args.seed)
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"device {device}: {torch.cuda.get_device_name(0) if device == 'cuda' else 'no GPU'}", flush=True)

    held_ids, held_texts = held_out(args.eval_sentences)
    english = tatoeba(args.data, held_ids, held_texts)
    if args.max_english:
        rng.shuffle(english)
        english = english[:args.max_english]
    texts = english + (soda(args.soda_turns, held_texts, rng) if args.soda_turns else [])
    held_hinglish = []
    if args.hinglish:
        if not 0 < args.hinglish_share < 1:
            parser.error("--hinglish-share must be between 0 and 1")
        wanted = round(len(texts) * args.hinglish_share / (1 - args.hinglish_share))
        added, held_hinglish = hinglish(args.hinglish, wanted, held_texts, rng)
        texts += added
        with open(os.path.join(args.out, "hinglish-heldout.txt"), "w", encoding="utf-8") as handle:
            handle.write("\n".join(held_hinglish) + "\n")
    texts = [variant(text, rng) for text in texts]
    texts = [text for text in texts if text]
    rng.shuffle(texts)

    words = added_tokens.read_words(args.added_tokens) if args.added_tokens else []
    if words:
        source = os.path.dirname(hf_hub_download(BASE, "vocab.json", revision=BASE_REVISION))
        hf_hub_download(BASE, "merges.txt", revision=BASE_REVISION)
        tokenizer = added_tokens.build(source, words)
        print(f"added tokens: {len(words)} words, ids {added_tokens.STOCK_VOCABULARY} to "
              f"{added_tokens.STOCK_VOCABULARY + len(words) - 1}", flush=True)
    else:
        source = None
        tokenizer = AutoTokenizer.from_pretrained(BASE, revision=BASE_REVISION)
    start = tokenizer.eos_token_id
    examples = []
    for at in range(0, len(texts), 50_000):
        for ids in tokenizer(texts[at:at + 50_000], add_special_tokens=False)["input_ids"]:
            examples.append([start] + ids[:args.max_tokens - 1])
    held_back = min(5000, len(examples) // 10)
    held_back, examples = examples[:held_back], examples[held_back:]
    print(f"{len(examples)} training examples, {sum(map(len, examples)) / len(examples):.1f} tokens each", flush=True)
    for text in texts[-8:]:
        print(f"  sample: {text}", flush=True)

    model = AutoModelForCausalLM.from_pretrained(BASE, revision=BASE_REVISION)
    if words:
        added_tokens.extend_embeddings(model, source, words)
    model = model.to(device).train()
    plan = batches(examples, args.batch, rng)
    if args.max_steps:
        plan = plan[:args.max_steps]
    steps = len(plan)
    warmup = min(500, max(1, steps // 10))
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.rate, weight_decay=0.01)
    schedule = torch.optim.lr_scheduler.LambdaLR(
        optimizer,
        lambda step: (step + 1) / warmup if step < warmup
        else 0.5 * (1 + math.cos(math.pi * (step - warmup) / max(1, steps - warmup))))
    scaler = torch.amp.GradScaler("cuda", enabled=device == "cuda")
    saves = {steps // 4: "quarter", steps // 2: "half", steps: "full"}
    print(f"validation loss before: {validation_loss(model, held_back, start, device):.4f}", flush=True)
    english_eval = eval_sentences(args.eval_sentences)
    report_hits("before", model, tokenizer, english_eval, held_hinglish, device)

    began, running = time.time(), 0.0
    for step, indices in enumerate(plan, 1):
        ids, mask, labels = tensors(examples, indices, start, device)
        with torch.autocast("cuda", dtype=torch.float16, enabled=device == "cuda"):
            loss = model(input_ids=ids, attention_mask=mask, labels=labels).loss
        optimizer.zero_grad(set_to_none=True)
        scaler.scale(loss).backward()
        scaler.unscale_(optimizer)
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        scaler.step(optimizer)
        scaler.update()
        schedule.step()
        running += loss.item()
        if step % 200 == 0 or step == steps:
            every = 200 if step % 200 == 0 else step % 200
            rate = step / (time.time() - began)
            print(f"step {step}/{steps} loss {running / every:.4f} {rate:.1f} steps/s, "
                  f"{(steps - step) / rate / 60:.1f} min left", flush=True)
            running = 0.0
        if step in saves:
            folder = os.path.join(args.out, saves[step])
            model.save_pretrained(folder)
            tokenizer.save_pretrained(folder)
            if args.added_tokens:
                shutil.copyfile(args.added_tokens, os.path.join(folder, "added-tokens.txt"))
            print(f"saved {folder} at step {step}: validation loss "
                  f"{validation_loss(model, held_back, start, device):.4f}", flush=True)
            report_hits(saves[step], model, tokenizer, english_eval, held_hinglish, device)
    print(f"DONE in {(time.time() - began) / 60:.1f} min", flush=True)


if __name__ == "__main__":
    main()
