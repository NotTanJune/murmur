"""Whole-word tokens added to GPT-2's vocabulary, for the keyboard's language model (plan 004).

A word list file has one word a line, each with its leading space (" kya"), in the order the ids
are given: the first is 50257, the next 50258, and so on. Nothing here knows which words they are;
the list for Hinglish derives from a corpus whose licence is not GPL-compatible and stays out of
the repository (`hinglish_tokens.py --emit` writes it under ~/Library/Caches/MurmurBuild).

How an added token is recognised, and why it is not a Hugging Face `AddedToken`
-------------------------------------------------------------------------------
GPT-2 first cuts text into pieces (a word with the space before it, a run of digits, ...) and
then merges bytes inside each piece. An added token should be what a *whole piece* turns into
when it is one of the listed words: " kya" is one token, " kyaa" and " nahin" are not touched.
`AddedToken` cannot say that. Measured with tokenizers in transformers 4.53.2:

- `AddedToken(" kya", single_word=False)` matches inside longer pieces: " kyaa" becomes the
  token for " kya" and a stray "a", " nahin" becomes " nahi" and "n".
- `AddedToken(" kya", single_word=True)` checks that the character before the match is not a word
  character, and that character is the one before the space, so it rejects " kya" after any
  word ("dog kya" is cut to " ky" and "a"), and keeps it only after a second space.
- With no leading space and `lstrip=True` the space and any line break before the word are
  swallowed and lost.

So the token is put in the BPE vocabulary itself, under its byte-level spelling ("Ġkya"), and the
model is built with `ignore_merges=True`: a piece found whole in the vocabulary is that token, and
any other piece is merged as before. That is what `BPETokenizer.swift` does with
`added_tokens.json`. `ignore_merges` also applies to GPT-2's own whole-word tokens; for a word
that is a token, merging gives the same token (checked on every one of the 50,257 in
`check_ignore_merges`), so stock text is tokenised as before.
"""
import json
import os
import re

STOCK_VOCABULARY = 50257  # GPT-2's ids run 0 to 50256; the first added token is this one
WORD = re.compile(r" [a-z]+")


def read_words(path):
    """The word list, validated: a space and lowercase letters only, no repeats."""
    words = []
    for number, line in enumerate(open(path, encoding="utf-8"), 1):
        word = line.rstrip("\n")
        if not WORD.fullmatch(word):
            raise SystemExit(f"{path}:{number}: {word!r} is not a space and letters a to z (one GPT-2 piece)")
        words.append(word)
    if len(set(words)) != len(words):
        raise SystemExit(f"{path}: repeated words")
    return words


def table(words):
    """Word to id, in file order."""
    return {word: STOCK_VOCABULARY + index for index, word in enumerate(words)}


def write_table(words, path):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(table(words), handle, ensure_ascii=True, indent=0)
        handle.write("\n")


def byte_level(word):
    """The word as the vocabulary spells it: each byte as a printable character, a space as 'Ġ'."""
    from transformers.models.gpt2.tokenization_gpt2 import bytes_to_unicode

    mapping = bytes_to_unicode()
    return "".join(mapping[byte] for byte in word.encode("utf-8"))


def read_merges(path):
    lines = open(path, encoding="utf-8").read().split("\n")
    return [tuple(line.split(" ")) for line in lines if line and not line.startswith("#version")]


def build(folder, words=None, ignore_merges=None):
    """GPT-2's tokenizer from `folder`'s vocab.json and merges.txt as a fast tokenizer, with `words`
    added as whole-piece tokens. With none it is the stock tokenizer, merging as always."""
    from tokenizers import Tokenizer, decoders, models, pre_tokenizers
    from transformers import PreTrainedTokenizerFast

    vocab = json.load(open(os.path.join(folder, "vocab.json"), encoding="utf-8"))
    for word, token in table(words or []).items():
        vocab[byte_level(word)] = token
    if ignore_merges is None:
        ignore_merges = bool(words)
    model = models.BPE(vocab, read_merges(os.path.join(folder, "merges.txt")), ignore_merges=ignore_merges)
    tokenizer = Tokenizer(model)
    tokenizer.pre_tokenizer = pre_tokenizers.ByteLevel(add_prefix_space=False)
    tokenizer.decoder = decoders.ByteLevel()
    return PreTrainedTokenizerFast(
        tokenizer_object=tokenizer, bos_token="<|endoftext|>", eos_token="<|endoftext|>", unk_token="<|endoftext|>")


def check_ignore_merges(folder):
    """Every stock token spelled out as text: does merging give that one token without the shortcut?
    Returns the tokens it does not (GPT-2's pre-tokenizer can also cut a token's text into more
    than one piece, and those never reach the shortcut)."""
    from transformers.models.gpt2.tokenization_gpt2 import bytes_to_unicode

    plain = build(folder, None, False)
    unmap = {character: byte for byte, character in bytes_to_unicode().items()}
    vocab = json.load(open(os.path.join(folder, "vocab.json"), encoding="utf-8"))
    differing = []
    for text, token in vocab.items():
        try:
            raw = bytes(unmap[character] for character in text).decode("utf-8")
        except (KeyError, UnicodeDecodeError):
            continue  # a token that is not text by itself
        pieces = plain.backend_tokenizer.pre_tokenizer.pre_tokenize_str(raw)
        if len(pieces) != 1:
            continue  # never a whole piece, so the shortcut never sees it
        if plain(raw, add_special_tokens=False)["input_ids"] != [token]:
            differing.append(text)
    return differing


def extend_embeddings(model, folder, words):
    """Resizes the model's embedding to the new vocabulary and sets each new row to the mean of the
    rows of the pieces the stock tokenizer cuts the word into, so the model starts where it was."""
    import torch

    stock = build(folder, None)
    if model.config.vocab_size != STOCK_VOCABULARY:
        raise SystemExit(f"the model has {model.config.vocab_size} embedding rows, expected {STOCK_VOCABULARY}")
    model.resize_token_embeddings(STOCK_VOCABULARY + len(words))
    embedding = model.get_input_embeddings().weight
    with torch.no_grad():
        for word, token in table(words).items():
            pieces = stock(word, add_special_tokens=False)["input_ids"]
            embedding[token] = embedding[pieces].mean(dim=0)
    # The output layer is tied to the embedding in GPT-2, so it has the same rows.
    if model.get_output_embeddings().weight.data_ptr() != embedding.data_ptr():
        raise SystemExit("the output layer is not tied to the embedding; the new rows would be unset")
    return model
