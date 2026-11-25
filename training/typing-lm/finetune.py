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
"""
import argparse
import bz2
import hashlib
import math
import os
import random
import re
import time
import urllib.request

import pyarrow.parquet as pq
import torch
from huggingface_hub import hf_hub_download
from transformers import AutoModelForCausalLM, AutoTokenizer

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
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    os.makedirs(args.data, exist_ok=True)
    rng = random.Random(args.seed)
    torch.manual_seed(args.seed)
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"device {device}: {torch.cuda.get_device_name(0) if device == 'cuda' else 'no GPU'}", flush=True)

    held_ids, held_texts = held_out(args.eval_sentences)
    texts = tatoeba(args.data, held_ids, held_texts) + soda(args.soda_turns, held_texts, rng)
    texts = [variant(text, rng) for text in texts]
    texts = [text for text in texts if text]
    rng.shuffle(texts)

    tokenizer = AutoTokenizer.from_pretrained(BASE, revision=BASE_REVISION)
    start = tokenizer.eos_token_id
    examples = []
    for at in range(0, len(texts), 50_000):
        for ids in tokenizer(texts[at:at + 50_000], add_special_tokens=False)["input_ids"]:
            examples.append([start] + ids[:args.max_tokens - 1])
    held_back, examples = examples[:5000], examples[5000:]
    print(f"{len(examples)} training examples, {sum(map(len, examples)) / len(examples):.1f} tokens each", flush=True)
    for text in texts[5000:5008]:
        print(f"  sample: {text}", flush=True)

    model = AutoModelForCausalLM.from_pretrained(BASE, revision=BASE_REVISION).to(device).train()
    plan = batches(examples, args.batch, rng)
    steps = len(plan)
    warmup = 500
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.rate, weight_decay=0.01)
    schedule = torch.optim.lr_scheduler.LambdaLR(
        optimizer,
        lambda step: (step + 1) / warmup if step < warmup
        else 0.5 * (1 + math.cos(math.pi * (step - warmup) / max(1, steps - warmup))))
    scaler = torch.amp.GradScaler("cuda", enabled=device == "cuda")
    saves = {steps // 4: "quarter", steps // 2: "half", steps: "full"}
    print(f"validation loss before: {validation_loss(model, held_back, start, device):.4f}", flush=True)

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
        if step % 200 == 0:
            rate = step / (time.time() - began)
            print(f"step {step}/{steps} loss {running / 200:.4f} {rate:.1f} steps/s, "
                  f"{(steps - step) / rate / 60:.1f} min left", flush=True)
            running = 0.0
        if step in saves:
            folder = os.path.join(args.out, saves[step])
            model.save_pretrained(folder)
            tokenizer.save_pretrained(folder)
            print(f"saved {folder} at step {step}: validation loss "
                  f"{validation_loss(model, held_back, start, device):.4f}", flush=True)
    print(f"DONE in {(time.time() - began) / 60:.1f} min", flush=True)


if __name__ == "__main__":
    main()
