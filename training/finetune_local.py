#!/usr/bin/env python3
"""Fine-tune Bark Clean's decoder and joint on this Mac, straight from Murmur's history.

The Colab notebook beside this file needs an export zip and a GPU. This does the same job on
the Mac's CPU, reading the run log and recordings in place (read-only; nothing is marked as
exported), in three stages that each save their result under --work:

  prepare   cut every recording into segments of at most 14 s at its quietest points, run the
            stock model over them once, keep the encoder output of each, and give every
            segment of a labelled recording the words of the correction that belong to it
  train     fine-tune the encoder projector, decoder and joint on those encoder outputs,
            scoring held-out recordings after every epoch
  export    write the best epoch as a Core ML decoder and joint pair Murmur can install

Setup (once):
  uv venv --python 3.12 ~/Library/Caches/MurmurBuild/train/env
  uv pip install --python ~/Library/Caches/MurmurBuild/train/env/bin/python \\
      "transformers>=5.19" torch coremltools "constriction>=0.5" soundfile soxr librosa huggingface_hub numpy

Why segments: the model takes 15 s of audio, Murmur feeds it windows of that size, and the
transducer loss needs a frames x tokens x vocabulary lattice, which for a 90 s recording is
about 11 GB. Why the encoder outputs are kept: the encoder is frozen, so it runs once per
segment instead of once per segment per epoch, and can be dropped from memory for training.
"""
import argparse, difflib, gc, hashlib, json, os, random, re, shutil, subprocess, sys, time
from pathlib import Path

import numpy as np

SUPPORT = Path.home() / "Library/Application Support/Murmur"
REPO = "ConwayResearch/Underdog-Bark-3.0-Clean"
PROCESSOR = "nvidia/parakeet-tdt-0.6b-v3"
RATE = 16_000
LEAD = 4_000  # 0.25 s of silence before the audio, the setting the model card evaluates


# ---------------------------------------------------------------- text

PAUSE_PERIOD = re.compile(r"(?<=[A-Za-z]{2})(?<!\betc)(?<!\bvs)\. (?=[a-z]{2}|a )")


def drop_pause_periods(text):
    """Same rule as TranscriptRepair.dropPausePeriods: a period before a lowercase word is
    one Bark wrote at a pause. Corrections were typed over Bark's text and still hold some."""
    return PAUSE_PERIOD.sub(" ", text)


def key(word):
    return re.sub(r"[^\w']", "", word.lower())


def loose(text):
    return [k for k in (key(w) for w in text.split()) if k]


def edits(reference, hypothesis):
    row = list(range(len(hypothesis) + 1))
    for i in range(1, len(reference) + 1):
        previous, row[0] = row[0], i
        for j in range(1, len(hypothesis) + 1):
            current = min(row[j] + 1, row[j - 1] + 1, previous + (reference[i - 1] != hypothesis[j - 1]))
            previous, row[j] = row[j], current
    return row[-1]


def error_rates(pairs):
    """(word error rate ignoring case and punctuation, the same counting them), in percent."""
    words = sum(len(loose(ref)) for ref, _ in pairs) or 1
    exact = sum(len(ref.split()) for ref, _ in pairs) or 1
    return (100 * sum(edits(loose(r), loose(h)) for r, h in pairs) / words,
            100 * sum(edits(r.split(), h.split()) for r, h in pairs) / exact)


# ---------------------------------------------------------------- audio

def read_audio(path):
    import soundfile as sf
    wave, rate = sf.read(str(path), dtype="float32", always_2d=True)
    wave = wave.mean(axis=1)
    if rate != RATE:
        import soxr
        wave = soxr.resample(wave, rate, RATE)
    return wave.astype(np.float32)


def cut_points(wave, shortest=8.0, longest=13.5):
    """Sample offsets that split the recording into pieces no longer than `longest` seconds,
    each cut at the quietest 0.2 s between `shortest` and `longest` after the previous one."""
    hop = RATE // 100
    frames = len(wave) // hop
    energy = np.sqrt((wave[: frames * hop].reshape(frames, hop) ** 2).mean(axis=1) + 1e-12)
    smooth = np.convolve(energy, np.ones(20) / 20, mode="same")
    cuts, start = [], 0
    while len(wave) - start > 14.0 * RATE:
        low, high = start // hop + int(shortest * 100), start // hop + int(longest * 100)
        cut = (low + int(np.argmin(smooth[low:high]))) * hop
        cuts.append(cut)
        start = cut
    return cuts


# ---------------------------------------------------------------- model

def load_model(work):
    from huggingface_hub import snapshot_download
    folder = snapshot_download(REPO, allow_patterns=["model.bark", "bark_loader.py"], local_dir=str(work / "bark"))
    sys.path.insert(0, folder)
    import bark_loader, torch
    from transformers import AutoProcessor
    model = bark_loader.load_model(f"{folder}/model.bark", device="cpu", dtype=torch.float32)
    return model, AutoProcessor.from_pretrained(PROCESSOR)


class CachedEncoder:
    """Stands in for the model's encoder pass during generation and training, serving a
    stored encoder output and applying the (trainable) projector to it."""

    def __init__(self, model):
        self.model, self.real, self.captured, self.serve = model, model.get_audio_features, None, None
        model.get_audio_features = self

    def __call__(self, *args, **kwargs):
        import torch
        from transformers.models.parakeet.modeling_parakeet import ParakeetEncoderModelOutput
        if self.serve is None:
            self.captured = self.real(*args, **kwargs)
            return self.captured
        hidden = self.serve
        mask = torch.ones(hidden.shape[:2], dtype=torch.bool)
        return ParakeetEncoderModelOutput(
            last_hidden_state=hidden, pooler_output=self.model.encoder_projector(hidden), attention_mask=mask)


def decode(model, processor, cache, hidden):
    """Greedy text for one stored encoder output."""
    import torch
    cache.serve = hidden.unsqueeze(0).float()
    # The encoder pass is replaced, so only the batch size of this tensor is read.
    dummy = torch.zeros(1, 16, 128)
    with torch.inference_mode():
        out = model.generate(input_features=dummy)
    cache.serve = None
    return processor.batch_decode(out.sequences, skip_special_tokens=True)[0].strip()


# ---------------------------------------------------------------- prepare

def overlay(raw, label, hypotheses):
    """The stock model's text for each segment with the user's changes laid over it.

    A correction is Bark's text as the app heard it (`raw`) edited by hand (`label`). The
    words the user left alone are not evidence of anything: they are whatever the streaming
    engine wrote that day, seam errors included, and the stock model often writes them
    differently ("workflow" for "work flow"). So only the stretches the user changed are
    taken from the correction; everything else stays as the stock model wrote it for the
    segment. Returns (words per segment, segments where a change cannot be placed).
    """
    raw_words, label_words = raw.split(), label.split()
    heard = [(w, index) for index, text in enumerate(hypotheses) for w in text.split()]
    to_label, to_heard = {}, {}
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, raw_words, label_words, autojunk=False).get_opcodes():
        if tag == "equal":
            to_label.update({i1 + k: j1 + k for k in range(i2 - i1)})
    matcher = difflib.SequenceMatcher(None, [key(w) for w in raw_words], [key(w) for w, _ in heard], autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            to_heard.update({i1 + k: j1 + k for k in range(i2 - i1)})

    # Words the user kept and the stock model also wrote: fixed points on all three texts.
    anchors = [(-1, -1, -1)] + [(i, to_label[i], to_heard[i]) for i in range(len(raw_words))
                                if i in to_label and i in to_heard] + [(len(raw_words), len(label_words), len(heard))]
    parts = [[] for _ in hypotheses]
    unsure = set()
    last = len(hypotheses) - 1
    for (r0, l0, h0), (r1, l1, h1) in zip(anchors, anchors[1:]):
        between = heard[h0 + 1:h1]
        if raw_words[r0 + 1:r1] == label_words[l0 + 1:l1]:
            for word, segment in between:
                parts[segment].append(word)
        else:
            changed = label_words[l0 + 1:l1]
            inside = {segment for _, segment in between}
            before = heard[h0][1] if h0 >= 0 else 0
            after = heard[h1][1] if h1 < len(heard) else last
            if len(inside) == 1:
                parts[between[0][1]].extend(changed)
            elif len(inside) > 1 and len(changed) == len(between):
                for word, (_, segment) in zip(changed, between):
                    parts[segment].append(word)
            else:
                # Words added where the stock model wrote nothing, or a rewrite across a cut:
                # which segment holds them is a guess unless both neighbours share one.
                parts[before].extend(changed)
                if inside or before != after:
                    unsure |= inside | {before, after}
        if h1 < len(heard):
            parts[heard[h1][1]].append(heard[h1][0])
    return parts, unsure


def edge_style(target, heard):
    """A segment cut out of a sentence starts and ends the way Bark starts and ends any
    clip. Copying the stock text's first capital and closing mark keeps that habit as it is,
    so training changes what is written inside a clip and not how a clip is opened or closed."""
    if not target or not heard:
        return target
    if heard[0].isupper():
        target = target[0].upper() + target[1:]
    if heard[-1] in ".?!" and target[-1] not in ".?!":
        target = target.rstrip(",;:") + heard[-1]
    return target


def prepare(args):
    import torch
    work = Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    runs = [json.loads(line) for line in open(SUPPORT / "runs.jsonl") if line.strip()]
    clips = [r for r in runs if r.get("hasAudio") and (SUPPORT / "Recordings" / f"{r['id']}.flac").exists()]
    print(f"{len(clips)} recordings, {sum(r['audioSeconds'] for r in clips) / 60:.1f} min; "
          f"{sum(1 for r in clips if (r.get('label') or '').strip())} labelled")

    model, processor = load_model(work)
    cache = CachedEncoder(model)
    records, features = [], []
    started = time.time()
    for number, run in enumerate(clips):
        wave = read_audio(SUPPORT / "Recordings" / f"{run['id']}.flac")
        bounds = [0, *cut_points(wave), len(wave)]
        heard = []
        for start, end in zip(bounds, bounds[1:]):
            padded = np.concatenate([np.zeros(LEAD, np.float32), wave[start:end]])
            inputs = processor(padded, sampling_rate=RATE, return_tensors="pt")
            with torch.inference_mode():
                out = model.generate(**inputs)
            heard.append(processor.batch_decode(out.sequences, skip_special_tokens=True)[0].strip())
            features.append(cache.captured.last_hidden_state[0].clone().half())
        for index, text in enumerate(heard):
            records.append({"clip": run["id"], "segment": index, "start": bounds[index] / RATE,
                            "end": bounds[index + 1] / RATE, "heard": text})
        print(f"  {number + 1}/{len(clips)} {run['id'][:8]} {len(wave) / RATE:5.1f}s {len(heard)} segment(s) "
              f"[{time.time() - started:.0f}s]", flush=True)
    torch.save(features, work / "features.pt")
    with open(work / "segments.jsonl", "w") as out:
        for record in records:
            out.write(json.dumps(record, ensure_ascii=False) + "\n")
    set_targets(records)


def set_targets(records):
    """Gives every segment its training text. A segment of an uncorrected recording is
    trained against the stock model's own text for it (replay), which anchors the fine-tune
    to current behaviour; the run log's `rawText` is not used for that, because until
    2026-11-13 it carried the streaming engine's seam errors."""
    runs = {r["id"]: r for r in (json.loads(line) for line in open(SUPPORT / "runs.jsonl") if line.strip())}
    by_clip = {}
    for record in records:
        by_clip.setdefault(record["clip"], []).append(record)
    for clip, rows in by_clip.items():
        rows.sort(key=lambda r: r["segment"])
        run = runs.get(clip, {})
        label, raw = (run.get("label") or "").strip(), (run.get("rawText") or "").strip()
        heard = [r["heard"] for r in rows]
        parts, unsure = overlay(raw, label, heard) if label and raw else ([h.split() for h in heard], set())
        for row, words in zip(rows, parts):
            row["kind"] = "labelled" if label and raw else "replay"
            row["target"] = edge_style(drop_pause_periods(" ".join(words)), row["heard"])
            row["unsure"] = row["segment"] in unsure
    labelled = [r for r in records if r["kind"] == "labelled"]
    corrected = [r for r in labelled if not r["unsure"] and r["target"] != r["heard"]]
    print(f"{len(records)} segments: {len(labelled)} from corrected recordings, {len(records) - len(labelled)} replay; "
          f"{len(corrected)} carry a correction, {sum(r['unsure'] for r in labelled)} left out because a change cannot be placed; "
          f"{sum(1 for r in records if r['kind'] == 'replay' and r['target'] != r['heard'])} replay segments lose a pause period")
    loose_rate, exact_rate = error_rates([(r["target"], r["heard"]) for r in labelled if not r["unsure"] and r["target"]])
    print(f"stock model against the training text of corrected recordings: {loose_rate:.2f}% word error, "
          f"{exact_rate:.2f}% counting case and punctuation")


# ---------------------------------------------------------------- train

def load_prepared(work):
    import torch
    records = [json.loads(line) for line in open(work / "segments.jsonl") if line.strip()]
    features = torch.load(work / "features.pt")
    assert len(records) == len(features), "segments.jsonl and features.pt are from different runs"
    for record, feature in zip(records, features):
        record["feature"] = feature
    set_targets(records)
    return records


def split(records, seed=0):
    """Whole recordings are held out, never single segments: neighbouring segments of one
    recording share its vocabulary and would flatter the score."""
    def clips(kind):
        ids = sorted({r["clip"] for r in records if r["kind"] == kind})
        random.Random(seed).shuffle(ids)
        return ids
    labelled, replay = clips("labelled"), clips("replay")
    held = set(labelled[: max(4, len(labelled) // 5)]) | set(replay[: max(4, len(replay) // 5)])
    usable = [r for r in records if r["target"] and not r["unsure"]]
    return ([r for r in usable if r["clip"] not in held],
            [r for r in usable if r["clip"] in held and r["kind"] == "labelled"],
            [r for r in usable if r["clip"] in held and r["kind"] == "replay"])


def train(args):
    import torch
    from transformers.models.parakeet.modeling_parakeet import ParakeetEncoderModelOutput
    work = Path(args.work)
    records = load_prepared(work)
    training, held_out, replay = split(records)
    print(f"{len(training)} training segments "
          f"({sum(r['kind'] == 'labelled' for r in training)} labelled, {sum(r['kind'] == 'replay' for r in training)} replay); "
          f"held out: {len(held_out)} labelled segments, {len(replay)} replay segments")

    model, processor = load_model(work)
    cache = CachedEncoder(model)
    # The encoder never runs again: its outputs are on disk. Generation still asks it for the
    # name of its input and how many frames it will produce, so a module that answers both
    # from the stored output stands where its 2.3 GB of weights were.
    class NoEncoder(torch.nn.Module):
        main_input_name = "input_features"

        def _get_subsampling_output_length(self, input_lengths):
            return torch.tensor([cache.serve.shape[1]], dtype=torch.int)
    model.encoder = NoEncoder()
    gc.collect()
    trainable = [p for name, p in model.named_parameters() if not name.startswith("encoder.")]
    for parameter in trainable:
        parameter.requires_grad = True
    print(f"trainable parameters: {sum(p.numel() for p in trainable):,}")

    def score(rows):
        model.eval()
        return error_rates([(r["target"], decode(model, processor, cache, r["feature"])) for r in rows])

    # The stored encoder outputs must reproduce what the full model wrote in `prepare`.
    for row in (held_out + replay)[:5]:
        again = decode(model, processor, cache, row["feature"])
        assert again == row["heard"], f"cached decode differs:\n  {again}\n  {row['heard']}"

    stock = (score(held_out), score(replay))
    print(f"stock      held-out {stock[0][0]:5.2f}% ({stock[0][1]:5.2f}% with case and punctuation)   "
          f"replay drift {stock[1][0]:5.2f}%")

    corrected = [r for r in training if r["kind"] == "labelled" and r["target"] != r["heard"]]
    optimizer = torch.optim.AdamW(trainable, lr=args.lr, weight_decay=0.01)
    silence = np.zeros(RATE // 10, np.float32)
    history, best = [], None
    for epoch in range(1, args.epochs + 1):
        model.train()
        order = training[:]
        random.Random(epoch).shuffle(order)
        total, started = 0.0, time.time()
        for index, row in enumerate(order, start=1):
            # One segment at a time: the loss lattice is frames x tokens x 8,198 floats, about
            # 400 MB for a full segment before its gradient, and this Mac has 8 GB. Gradients
            # are summed over four segments per step instead.
            # The processor builds labels and decoder inputs; its audio half is not used.
            text = processor(audio=[silence], text=[row["target"]], sampling_rate=RATE, return_tensors="pt")
            hidden = row["feature"].float().unsqueeze(0)
            encoded = ParakeetEncoderModelOutput(
                last_hidden_state=hidden, pooler_output=model.encoder_projector(hidden),
                attention_mask=torch.ones(hidden.shape[:2], dtype=torch.bool))
            loss = model(encoder_outputs=encoded, labels=text["labels"], decoder_input_ids=text["decoder_input_ids"]).loss
            (loss / 4).backward()
            total += loss.item()
            if index % 4 == 0 or index == len(order):
                torch.nn.utils.clip_grad_norm_(trainable, 1.0)
                optimizer.step()
                optimizer.zero_grad()
        held, drift = score(held_out), score(replay)
        # How much of what it was shown it now writes: the corrected training segments it gets
        # exactly right. Low here with no held-out gain means it has not learned yet; high
        # here with no held-out gain means it memorised.
        learned = sum(decode(model, processor, cache, r["feature"]) == r["target"] for r in corrected)
        history.append({"epoch": epoch, "loss": total / len(order), "heldOut": held[0], "heldOutExact": held[1],
                        "replay": drift[0], "replayExact": drift[1], "trainingCorrectionsRight": learned})
        print(f"epoch {epoch}: loss {total / len(order):.4f}  held-out {held[0]:5.2f}% ({held[1]:5.2f}%)   "
              f"replay drift {drift[0]:5.2f}%   corrected training segments right {learned}/{len(corrected)}   "
              f"[{time.time() - started:.0f}s]", flush=True)
        # Worth keeping: no worse than stock on either held-out count, better on at least one,
        # better than any epoch kept so far, and within a point of stock on unlabelled speech.
        reference = (best["heldOutExact"], best["heldOut"]) if best else (stock[0][1], stock[0][0])
        better = (held[1], held[0]) < reference and held[1] <= stock[0][1] and held[0] <= stock[0][0]
        if better and drift[0] <= stock[1][0] + 1.0:
            best = dict(history[-1])
            torch.save({k: v for k, v in model.state_dict().items() if not k.startswith("encoder.")}, work / "best.pt")

    report = {"stock": {"heldOut": stock[0][0], "heldOutExact": stock[0][1], "replay": stock[1][0]},
              "epochs": history, "best": best, "trainingSegments": len(training),
              "labelledClips": len({r["clip"] for r in training if r["kind"] == "labelled"}),
              "heldOutSegments": len(held_out), "lr": args.lr}
    json.dump(report, open(work / "report.json", "w"), indent=2)
    if best is None:
        print("no epoch beat the stock model on the held-out recordings; nothing to export")
        return
    print(f"best: epoch {best['epoch']}, held-out {best['heldOut']:.2f}% ({best['heldOutExact']:.2f}%) "
          f"against stock {stock[0][0]:.2f}% ({stock[0][1]:.2f}%)")
    model.eval()
    model.load_state_dict(torch.load(work / "best.pt"), strict=False)
    print("held-out segments the best epoch changed:")
    for row in held_out:
        now = decode(model, processor, cache, row["feature"])
        if now != row["heard"]:
            print(f"  stock : {row['heard']}\n  tuned : {now}\n  label : {row['target']}\n")


# ---------------------------------------------------------------- export

def export(args):
    """Writes the decoder and joint as the two Core ML models of the stock package. Their
    inputs, outputs and split were read from the stock package's model.mil: the decoder model
    is the embedding and the two-layer LSTM; the joint model owns both projections, the head,
    and returns the softmax probability of the token it picked."""
    import coremltools as ct, torch
    work = Path(args.work)
    model, _ = load_model(work)
    if args.stock:
        # The untouched checkpoint through the same conversion: `--decoder-check` on the
        # result must print the stock text twice. Proves the export without a fine-tune.
        report = {"best": {"heldOut": 0.0, "replay": 0.0}, "labelledClips": 0}
    else:
        report = json.load(open(work / "report.json"))
        assert report["best"], "train found nothing better than stock; nothing to export"
        model.load_state_dict(torch.load(work / "best.pt"), strict=False)
    model.eval()
    vocabulary = model.config.vocab_size

    class Decoder(torch.nn.Module):
        def __init__(self, decoder):
            super().__init__()
            self.decoder = decoder

        def forward(self, targets, target_length, h_in, c_in):
            output, (h, c) = self.decoder.lstm(self.decoder.embedding(targets.long()), (h_in, c_in))
            return output.transpose(1, 2), h, c

    class Joint(torch.nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model

        def forward(self, encoder_step, decoder_step):
            encoder = self.model.encoder_projector(encoder_step.transpose(1, 2))
            decoder = self.model.decoder.decoder_projector(decoder_step.transpose(1, 2))
            logits = self.model.joint.head(self.model.joint.activation(encoder.unsqueeze(2) + decoder.unsqueeze(1)))
            tokens, durations = logits[..., :vocabulary], logits[..., vocabulary:]
            token = tokens.argmax(-1)
            probability = torch.softmax(tokens, -1).gather(-1, token.unsqueeze(-1)).squeeze(-1)
            top_logits, top_ids = torch.topk(tokens, 64, dim=-1)
            return (token.to(torch.int32), probability, durations.argmax(-1).to(torch.int32),
                    top_ids.to(torch.int32), top_logits)

    decoder, joint = Decoder(model.decoder).eval(), Joint(model).eval()
    with torch.no_grad():
        # The pair must reproduce the model's own joint for one step.
        step, token = torch.randn(1, 1024, 1), torch.tensor([[5]], dtype=torch.int32)
        raw, _, _ = decoder(token, torch.ones(1, dtype=torch.int32), torch.zeros(2, 1, 640), torch.zeros(2, 1, 640))
        reference = model.joint(
            decoder_hidden_states=model.decoder.decoder_projector(raw.transpose(1, 2))[:, None, :, :],
            encoder_hidden_states=model.encoder_projector(step.transpose(1, 2))[:, :, None, :])
        picked, _, duration, _, _ = joint(step, raw)
        assert int(picked) == int(reference[..., :vocabulary].argmax()), "joint wrapper disagrees with the model"
        assert int(duration) == int(reference[..., vocabulary:].argmax()), "duration head disagrees with the model"

    f32, i32 = np.float32, np.int32
    decoder_example = (torch.zeros(1, 1, dtype=torch.int32), torch.ones(1, dtype=torch.int32),
                       torch.zeros(2, 1, 640), torch.zeros(2, 1, 640))
    converted = {
        "Decoder": ct.convert(
            torch.jit.trace(decoder, decoder_example), convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS14,
            inputs=[ct.TensorType(name="targets", shape=(1, 1), dtype=i32),
                    ct.TensorType(name="target_length", shape=(1,), dtype=i32),
                    ct.TensorType(name="h_in", shape=(2, 1, 640), dtype=f32),
                    ct.TensorType(name="c_in", shape=(2, 1, 640), dtype=f32)],
            outputs=[ct.TensorType(name="decoder", dtype=f32), ct.TensorType(name="h_out", dtype=f32),
                     ct.TensorType(name="c_out", dtype=f32)]),
        "JointDecisionv3": ct.convert(
            torch.jit.trace(joint, (torch.zeros(1, 1024, 1), torch.zeros(1, 640, 1))), convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS14,
            inputs=[ct.TensorType(name="encoder_step", shape=(1, 1024, 1), dtype=f32),
                    ct.TensorType(name="decoder_step", shape=(1, 640, 1), dtype=f32)],
            outputs=[ct.TensorType(name="token_id", dtype=i32), ct.TensorType(name="token_prob", dtype=f32),
                     ct.TensorType(name="duration", dtype=i32), ct.TensorType(name="top_k_ids", dtype=i32),
                     ct.TensorType(name="top_k_logits", dtype=f32)]),
    }

    stock = max((SUPPORT / "Models/bark-3.0-clean").iterdir(), key=lambda p: p.stat().st_mtime)
    day = "stock-parity" if args.stock else time.strftime("%Y-%m-%d")
    out = work / f"bark-decoder-{day}"
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir()
    for name, mlmodel in converted.items():
        package = work / f"{name}.mlpackage"
        shutil.rmtree(package, ignore_errors=True)
        mlmodel.save(str(package))
        # Xcode's compiler, not coremltools': it writes the metadata.json the stock package
        # has, which the contract check below reads.
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(out)], check=True, capture_output=True)
        # Same names, types and shapes as the stock model, or Murmur's engine cannot run it.
        def contract(folder):
            meta = json.load(open(folder / f"{name}.mlmodelc/metadata.json"))[0]
            return {side: sorted((f["name"], f["dataType"], f["shape"]) for f in meta[side])
                    for side in ("inputSchema", "outputSchema")}
        assert contract(out) == contract(stock), f"{name}: contract differs from stock\n{contract(out)}\n{contract(stock)}"

    def sha256(path):
        digest = hashlib.sha256()
        with open(path, "rb") as handle:
            for block in iter(lambda: handle.read(1 << 22), b""):
                digest.update(block)
        return digest.hexdigest()

    files = [{"path": str(path.relative_to(out)), "size": path.stat().st_size, "sha256": sha256(path)}
             for path in sorted(out.rglob("*")) if path.is_file()]
    manifest = {"trainedAt": day, "clips": report["labelledClips"], "heldOutWER": round(report["best"]["heldOut"], 2),
                "replayWER": round(report["best"]["replay"], 2), "baseRevision": stock.name, "files": files}
    json.dump(manifest, open(out / "manifest.json", "w"), indent=2)
    print(f"wrote {out}\ncheck it on a recording, then install it from Settings, Training:\n"
          f"  /Applications/Murmur.app/Contents/MacOS/Murmur --decoder-check {out} <recording.flac>")




if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("stage", choices=["prepare", "train", "export"])
    parser.add_argument("--work", default=str(Path.home() / "Library/Caches/MurmurBuild/train"))
    parser.add_argument("--epochs", type=int, default=6)
    parser.add_argument("--lr", type=float, default=1e-5)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--stock", action="store_true", help="export: convert the untouched checkpoint, to test the conversion")
    args = parser.parse_args()
    import torch
    torch.set_num_threads(args.threads)
    {"prepare": prepare, "train": train, "export": export}[args.stage](args)
