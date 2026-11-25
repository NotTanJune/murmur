#!/usr/bin/env python3
"""Measure a causal language model against the keyboard's pair model on next-word prediction
and mid-word completion.

    python training/typing-lm/evaluate.py --model <folder> --name <label> --eval-dir <dir> \
        [--context 32] [--second 4] [--fresh]

`<dir>` holds what cases.py and TypingLMEvalTests wrote: cases.json, befores.json, bigram.json
(the pair model's answers, in the order of befores.json) and words.tsv (the keyboard's word
list). `<folder>` is a Hugging Face model folder on disk; nothing is downloaded.

How subword logits become word suggestions, which is also what the keyboard does:

- One forward pass over the text before the cursor (trailing spaces dropped, a start token in
  front, the last `--context` tokens kept) gives the distribution of the next token.
- A token that starts a new word (it begins with the tokenizer's space mark, or at the start
  of the text with none) and is, folded to lowercase, a word of the keyboard's list stands
  for that word. Tokens that differ only in case add up. `STEMS` are first halves of
  contractions that are no words themselves ("didn"); their token stands for the contraction.
- `--second N` measures a second step: the N likeliest first tokens of two-token words
  ("I" + "'m") each get one more pass, the two-token word scores P(first) x P(second), and the
  plain word loses the share that goes on into a longer word.
- Mid-word, the candidates are the words with the typed prefix, ranked by the distribution
  already computed at the word's start (nothing runs per letter); the pair model's
  completions fill the slots it leaves. `--fresh` measures the alternative, a new pass over
  the text with the typed letters in it.

The rules the strip applies to any prediction are mirrored from SuggestionEngine: single
letters other than "a" and "i" and the never-volunteered words are skipped, a pair of words
already written in the sentence is not offered again, and a word already used keeps 5% of
its score unless it is a function word.
"""
import argparse
import json
import os
import time

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

NEVER = set("""sex sexy sexual porn porno xxx nude naked erotic adult escort fuck fucking shit bitch
pussy dick cock cum anal tits boobs milf hentai slut sluts whore rape incest bdsm fetish orgy
blowjob gay lesbian teen teens viagra cialis casino poker gratis""".split())
REPEATS_FREELY = set("""the a an to of and in is it i you that for on with as at be this are was or by
not have he we but they from""".split())
REPEAT_WINDOW = 12
REPEAT_DISCOUNT = 0.05
CONTRACTION_DISCOUNT = 0.1
STEMS = """ain aren couldn didn doesn don hadn hasn haven isn mustn needn shouldn wasn weren
wouldn""".split()
SPACE = "Ġ"
CHAIN_STARTS = ["my dog ", "i ", "the ", "please ", "can you "]


def fold(word):
    return word.lower().replace("’", "'")


def is_word_char(character):
    return character.isalpha() or character in "'’"


def suggestible(word):
    return len(word) >= 2 or word in ("a", "i")


def recent_words(text):
    """SuggestionEngine.recentWords: the sentence's last words, folded, oldest first."""
    words, word = [], ""
    for character in reversed(text):
        if is_word_char(character):
            word += character
            continue
        if word:
            words.append(fold(word[::-1]))
            word = ""
            if len(words) == REPEAT_WINDOW:
                break
        if character in "\n.!?":
            break
    if word and len(words) < REPEAT_WINDOW:
        words.append(fold(word[::-1]))
    return words[::-1]


def previous_word(text):
    """The word right before the cursor's gap, as SuggestionEngine.Context reads it."""
    head = text.rstrip()
    if not head or "\n" in text[len(head):] or head[-1] in ".!?" or not is_word_char(head[-1]):
        return None
    start = len(head)
    while start > 0 and is_word_char(head[start - 1]):
        start -= 1
    return fold(head[start:].lstrip("'’")) or None


class Scorer:
    def __init__(self, folder, words, context):
        self.words = words
        self.context = context
        self.tokenizer = AutoTokenizer.from_pretrained(folder)
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.model = AutoModelForCausalLM.from_pretrained(folder, torch_dtype=torch.float32).eval().to(self.device)
        self.bos = self.tokenizer.bos_token_id
        if self.bos is None:
            self.bos = self.tokenizer.eos_token_id
        index = {word: i for i, word in enumerate(words)}
        self.index = index
        stems = {index[s]: index[s + "'t"] for s in STEMS if s in index and s + "'t" in index}
        vocabulary = self.tokenizer.convert_ids_to_tokens(list(range(len(self.tokenizer))))
        tables = {"space": ([], []), "bare": ([], [])}
        continues = torch.zeros(len(vocabulary), dtype=torch.bool)
        for token, text in enumerate(vocabulary):
            if text is None:
                continue
            kind, body = ("space", text[1:]) if text.startswith(SPACE) else ("bare", text)
            if kind == "bare" and body[:1] and (body[0].isascii() and body[0].isalpha() or body[0] == "'"):
                continues[token] = True
            word = index.get(fold(body))
            if word is not None and body.isascii():
                tables[kind][0].append(token)
                tables[kind][1].append(stems.get(word, word))
        self.tables = {k: (torch.tensor(t), torch.tensor(w)) for k, (t, w) in tables.items()}
        self.continues = continues
        self.token_word = {k: dict(zip(t, w)) for k, (t, w) in tables.items()}

        # Words of exactly two tokens, by their first token, for the second step.
        self.two = {"space": {}, "bare": {}}
        for kind, lead in (("space", " "), ("bare", "")):
            single = set(tables[kind][1])
            rest = [i for i in range(len(words)) if i not in single]
            for form in (lambda w: w, lambda w: w[:1].upper() + w[1:]):
                encoded = self.tokenizer([lead + form(words[i]) for i in rest], add_special_tokens=False)["input_ids"]
                for i, ids in zip(rest, encoded):
                    if len(ids) == 2:
                        self.two[kind].setdefault(ids[0], set()).add((ids[1], i))
        self.two_keys = {k: torch.tensor(sorted(v)) for k, v in self.two.items()}
        self.single_coverage = {k: len(set(w)) for k, (t, w) in tables.items()}
        self.prefixes = {}
        for i, word in enumerate(words):
            for n in (1, 2, 3):
                if len(word) > n:
                    self.prefixes.setdefault(word[:n], []).append(i)
        self.prefixes = {p: torch.tensor(v) for p, v in self.prefixes.items()}
        self.passes = 0
        self.seconds = 0.0

    def encode(self, text):
        """The model's input for the text before the cursor, and which table reads its answer."""
        head = text.rstrip(" ")
        kind = "bare" if not head or head.endswith("\n") else "space"
        ids = self.tokenizer(head, add_special_tokens=False)["input_ids"] if head else []
        return [self.bos] + ids[-(self.context - 1):], kind

    def distributions(self, id_lists):
        """log P(next token) after each list of token ids, right-padded into one batch."""
        out = []
        for start in range(0, len(id_lists), 16):
            chunk = id_lists[start:start + 16]
            longest = max(len(ids) for ids in chunk)
            batch = torch.zeros((len(chunk), longest), dtype=torch.long)
            mask = torch.zeros((len(chunk), longest), dtype=torch.long)
            for row, ids in enumerate(chunk):
                batch[row, :len(ids)] = torch.tensor(ids)
                mask[row, :len(ids)] = 1
            began = time.perf_counter()
            with torch.no_grad():
                logits = self.model(input_ids=batch.to(self.device), attention_mask=mask.to(self.device)).logits
                last = logits[torch.arange(len(chunk)), mask.sum(1) - 1].float().cpu()
            self.seconds += time.perf_counter() - began
            self.passes += len(chunk)
            out.append(torch.log_softmax(last, dim=-1))
        return torch.cat(out)

    def word_scores(self, ids, kind, logp, second):
        """P(word) for every word of the list: one pass, then `second` more for two-token words."""
        probabilities = logp.exp()
        tokens, word_ids = self.tables[kind]
        scores = torch.zeros(len(self.words)).index_add_(0, word_ids, probabilities[tokens])
        if not second:
            return scores, scores
        refined = scores.clone()
        keys = self.two_keys[kind]
        best = keys[torch.topk(probabilities[keys], min(second, len(keys))).indices].tolist()
        after = self.distributions([(ids + [token])[-self.context:] for token in best]).exp()
        for token, following in zip(best, after):
            first = probabilities[token].item()
            plain = self.token_word[kind].get(token)
            if plain is not None:
                refined[plain] -= first * following[self.continues].sum().item()
            for second_token, word in self.two[kind][token]:
                refined[word] += first * following[second_token].item()
        return scores, refined

    def rank_next(self, scores, text, count=3):
        recent = recent_words(text)
        previous = previous_word(text)
        pairs = set(zip(recent, recent[1:]))
        repeated = set(recent) - REPEATS_FREELY
        top = torch.topk(scores, 80)
        ranked = []
        for score, word_id in zip(top.values.tolist(), top.indices.tolist()):
            word = self.words[word_id]
            if not suggestible(word) or word in NEVER:
                continue
            if previous and (word == previous or (previous, word) in pairs):
                continue
            ranked.append((score * (REPEAT_DISCOUNT if word in repeated else 1), word))
        ranked.sort(key=lambda item: -item[0])
        return [word for _, word in ranked[:count]]

    def rank_completions(self, scores, typed, count=3):
        folded = fold(typed)
        ids = self.prefixes.get(folded)
        if ids is None:
            return []
        values = scores[ids].clone()
        top = torch.topk(values, min(40, len(ids)))
        ranked = []
        for score, position in zip(top.values.tolist(), top.indices.tolist()):
            word = self.words[ids[position]]
            if score <= 0 or word == folded or not suggestible(word):
                continue
            if "'" in word and len(folded) < word.index("'"):
                score *= CONTRACTION_DISCOUNT
            ranked.append((score, word))
        ranked.sort(key=lambda item: -item[0])
        return [word for _, word in ranked[:count]]

    def fresh_completions(self, boundary, typed, count=3):
        """A new pass with the typed letters in the text: one more token that completes a word."""
        ids, _ = self.encode(boundary + typed)
        probabilities = self.distributions([ids])[0].exp()
        top = torch.topk(probabilities, 200)
        vocabulary = self.tokenizer.convert_ids_to_tokens(top.indices.tolist())
        ranked = []
        for score, piece in zip(top.values.tolist(), vocabulary):
            if piece.startswith(SPACE) or not piece.isascii():
                continue
            word = fold(typed + piece)
            if word in self.index and suggestible(word) and word not in ranked:
                ranked.append(word)
        return ranked[:count]

    def chain(self, start, second, steps=15):
        text = start
        for _ in range(steps):
            ids, kind = self.encode(text)
            scores = self.word_scores(ids, kind, self.distributions([ids])[0], second)[1]
            words = self.rank_next(scores, text, 1)
            if not words:
                break
            text += words[0] + " "
        return text


def fill(first, rest, count):
    """`first`, then what `rest` adds, without repeats, cut to `count`."""
    out = list(first)
    for word in rest:
        if word not in out:
            out.append(word)
    return out[:count]


class Tally:
    """Hit counts per (set, system, k, cutoff), and the keys each system needs for a word."""

    def __init__(self):
        self.hits = {}
        self.cases = {}
        self.shown = {}

    def add(self, group, system, k, ranked, target, word_key):
        key = (group, system, k)
        self.cases[key] = self.cases.get(key, 0) + 1
        for cutoff in (1, 2, 3):
            if target in ranked[:cutoff]:
                self.hits[key + (cutoff,)] = self.hits.get(key + (cutoff,), 0) + 1
        # The strip has three cells after a space and two completions mid-word.
        if target in ranked[:3 if k == 0 else 2]:
            first = self.shown.setdefault((group, system), {})
            first[word_key] = min(first.get(word_key, 99), k)

    def rate(self, group, system, k, cutoff):
        return 100 * self.hits.get((group, system, k, cutoff), 0) / max(1, self.cases.get((group, system, k), 0))

    def savings(self, group, system, lengths):
        """Keys saved when the word is tapped in the strip as soon as it shows (a tap is one key
        and types the space too), against typing every letter and the space."""
        full = sum(length + 1 for length in lengths.values())
        used = sum(min(self.shown.get((group, system), {}).get(key, 99), length) + 1 for key, length in lengths.items())
        return 100 * (1 - used / full)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--eval-dir", required=True)
    parser.add_argument("--context", type=int, default=32)
    parser.add_argument("--second", type=int, default=4)
    parser.add_argument("--fresh", action="store_true")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--coreml", help="run this .mlpackage or .mlmodelc (made by convert.py) on the CPU in place of PyTorch")
    args = parser.parse_args()
    torch.set_num_threads(args.threads)

    directory = args.eval_dir
    cases = json.load(open(os.path.join(directory, "cases.json")))
    befores = json.load(open(os.path.join(directory, "befores.json")))
    answers = dict(zip(befores, json.load(open(os.path.join(directory, "bigram.json")))))
    words = [line.split("\t")[0] for line in open(os.path.join(directory, "words.tsv"), encoding="utf-8") if line.strip()]
    scorer = Scorer(args.model, words, args.context)
    if args.coreml:
        import coremltools as ct
        import numpy as np

        if args.coreml.rstrip("/").endswith(".mlmodelc"):
            converted = ct.models.CompiledMLModel(args.coreml, compute_units=ct.ComputeUnit.CPU_ONLY)
        else:
            converted = ct.models.MLModel(args.coreml, compute_units=ct.ComputeUnit.CPU_ONLY)

        def distributions(id_lists):
            out = []
            for ids in id_lists:
                padded = np.zeros((1, args.context), dtype=np.int32)
                padded[0, :len(ids)] = ids
                began = time.perf_counter()
                answer = converted.predict({"input_ids": padded, "last": np.array([len(ids) - 1], dtype=np.int32)})
                scorer.seconds += time.perf_counter() - began
                scorer.passes += 1
                out.append(torch.from_numpy(answer["logp"].astype(np.float32).reshape(-1)))
            return torch.stack(out)

        scorer.distributions = distributions
        args.second = 0
        args.name += "-" + os.path.splitext(os.path.basename(args.coreml.rstrip("/")))[0]

    # A word position is the text at its start plus the word; its cases are k = 0...3.
    positions = {}
    for case in cases:
        boundary = case["before"][:len(case["before"]) - case["k"]]
        positions.setdefault((boundary, case["target"]), []).append(case)
    boundaries = sorted({boundary for boundary, _ in positions})
    by_boundary = {}
    for (boundary, target), group in positions.items():
        by_boundary.setdefault(boundary, []).append((target, group))

    tally = Tally()
    lengths = {}
    coverage = {"single": 0, "list": 0, "all": 0}
    for start in range(0, len(boundaries), 16):
        chunk = boundaries[start:start + 16]
        encoded = [scorer.encode(text) for text in chunk]
        logps = scorer.distributions([ids for ids, _ in encoded])
        for boundary, (ids, kind), logp in zip(chunk, encoded, logps):
            one, two = scorer.word_scores(ids, kind, logp, args.second)
            for target, group in by_boundary[boundary]:
                sets = sorted({case["set"] for case in group})
                target_id = scorer.index.get(target)
                for name in sets:
                    coverage["all"] += 1
                    coverage["list"] += target_id is not None
                    coverage["single"] += target_id is not None and one[target_id].item() > 0
                for case in group:
                    k, before = case["k"], case["before"]
                    pair = [fold(text) for kind_, text in answers[before] if kind_ != "typed"]
                    typed = before[len(boundary):]
                    if k == 0:
                        systems = {"pair": pair, "lm": scorer.rank_next(one, boundary)}
                        if args.second:
                            systems["lm+second"] = scorer.rank_next(two, boundary)
                    else:
                        systems = {"pair": pair, "lm": fill(scorer.rank_completions(one, typed), pair, 3)}
                        if args.second:
                            systems["lm+second"] = fill(scorer.rank_completions(two, typed), pair, 3)
                        if args.fresh:
                            systems["fresh"] = fill(scorer.fresh_completions(boundary, typed), pair, 3)
                    word_key = (case["set"], case["entry"], boundary, target)
                    # The lowercased set is also counted by where the entry came from: Murmur's
                    # own replay sentences, and Tatoeba's. A model trained on Tatoeba's other
                    # sentences is flattered by the second, so the first is the clean measure.
                    groups = [case["set"]] + ([case["source"]] if case["set"] == "lower" else [])
                    for group in groups:
                        lengths.setdefault(group, {})[word_key] = len(target)
                        for system, ranked in systems.items():
                            tally.add(group, system, k, ranked, target, word_key)
        if start % 800 == 0:
            print(f"  {start}/{len(boundaries)} word starts", flush=True)

    systems = ["pair", "lm"] + (["lm+second"] if args.second else []) + (["fresh"] if args.fresh else [])
    report = {"model": args.name, "context": args.context, "second": args.second, "rows": [], "chains": {}}
    print(f"\n{args.name}, context {args.context} tokens, second step over {args.second} tokens")
    print(f"single-token words: {scorer.single_coverage['space']} of {len(words)}; "
          f"targets in the word list {100 * coverage['list'] / coverage['all']:.1f}%, "
          f"reachable in one token {100 * coverage['single'] / coverage['all']:.1f}%")
    engine = "Core ML through Python, CPU" if args.coreml else "PyTorch (batched)"
    print(f"{scorer.passes} passes, {1000 * scorer.seconds / max(1, scorer.passes):.2f} ms each in {engine}")
    header = "set      system      next@1 next@3 | 1 letter @1 @2 @3 | 2 letters @1 @2 @3 | 3 letters @1 @2 @3 | keys saved"
    print(header)
    for group in ("written", "lower", "replay", "tatoeba"):
        for system in systems:
            if system == "fresh":
                cells = ["   -  ", "   -  "]
            else:
                cells = [f"{tally.rate(group, system, 0, 1):6.2f}", f"{tally.rate(group, system, 0, 3):6.2f}"]
            row = {"set": group, "system": system}
            for k in (1, 2, 3):
                cells.append("|")
                cells += [f"{tally.rate(group, system, k, cutoff):6.2f}" for cutoff in (1, 2, 3)]
            saved = tally.savings(group, system, lengths[group]) if system != "fresh" else float("nan")
            print(f"{group:8} {system:11} " + " ".join(cells) + f" | {saved:5.2f}%")
            row.update({
                "next": [tally.rate(group, system, 0, c) for c in (1, 3)],
                "completion": {k: [tally.rate(group, system, k, c) for c in (1, 2, 3)] for k in (1, 2, 3)},
                "keysSaved": saved, "words": tally.cases.get((group, system, 0), 0),
            })
            report["rows"].append(row)
    print("\ncentre-tap chains")
    for start in CHAIN_STARTS:
        for label, second in (("lm", 0), ("lm+second", args.second)):
            if label == "lm+second" and not args.second:
                continue
            text = scorer.chain(start, second)
            report["chains"].setdefault(label, []).append(text)
            print(f"  {label:10} {text}")
    json.dump(report, open(os.path.join(directory, f"result-{args.name}-c{args.context}-s{args.second}.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
