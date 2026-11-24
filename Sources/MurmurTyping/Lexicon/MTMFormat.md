# The `.mtm` word model

`en.mtm` is the keyboard's English word list with unigram frequencies and word-pair
probabilities. `Tools/build_typing_model.py` writes it and `TypingModel` reads it in place from a
memory-mapped file: no section is ever copied into a Swift array, because mapped pages that are
only read cost the keyboard almost nothing against its memory limit.

All integers are little-endian. Readers load them unaligned. There is no section table: every
position follows from the three counts in the header, in the order below. Sections marked
"pad" are followed by zero bytes up to the next multiple of 4 from the start of the file.

| Section | Size in bytes | Content |
|---|---|---|
| header | 16 | `"MTM1"`, `u32 version` (1), `u32 wordCount` (N), `u32 pairCount` (P) |
| `offsets` | 4 (N + 1) | `u32` byte offsets into `blob`; word `i` is `blob[offsets[i] ..< offsets[i+1]]` |
| `unigram` | N | one `u8` per word, see below |
| `flags` | N | one `u8` per word; bit 1 (`0b10`) is set for a contraction (the word contains `'`); bit 0 is reserved and 0 |
| pad | 0 to 3 | |
| `firstLetterStart` | 4 × 27 | `u32` index of the first word starting with `a` to `z` (26 entries), then the end of the `z` words; a word whose first byte is outside `a` to `z` lies before entry 0 or after entry 26 |
| `startEndBucket` | 4 × 677 | `u32` ranges into `endIds`: bucket `first * 26 + last` (letters 0 to 25) is `startEndBucket[b] ..< startEndBucket[b+1]`; the last entry is the length of `endIds` |
| `endIds` | 4 × `startEndBucket[676]` | `u32` word ids grouped by (first letter, last letter), ascending within a bucket; words whose first or last byte is outside `a` to `z` are not listed |
| pad | 0 to 3 | |
| `pairIndex` | 4 (N + 1) | `u32` ranges into `pairs` by first word id: word `a` owns `pairIndex[a] ..< pairIndex[a+1]` |
| `pairs` | 5 P | packed records `(u32 secondId, u8 logp)`, second ids ascending within a first word |
| `blob` | `offsets[N]` | UTF-8 words with no separators |

The file ends with the blob. A reader checks that the file is exactly as long as these sizes add up
to and refuses it otherwise.

## Words and ids

Words are lowercase and sorted by their UTF-8 bytes; an id is a word's index in that order.
Binary search finds a word, and all words with a given prefix are one contiguous id range (that
range is the "trie node" the spatial decoder walks). A contraction is stored with a straight
apostrophe (`don't`); `'` (0x27) sorts before `a`, so `don't` comes before `done`.

## Unigram byte

`q = clamp(floor(-log10(p) * 25 + 0.5), 0, 255)` with `p = count / total`, where `total` is the sum
of every word's count after the extra words are merged. A reader recovers `log10 p = -q / 25`.
One step is 0.04 in log10 (about 9.6 percent in probability); 255 reaches 10^-10.2, below the
rarest word in the list (about 10^-7.6).

## Pair byte

`logp` is the conditional probability of the second word given the first, quantised the same way:
`q = clamp(floor(-log10(P(b | a)) * 25 + 0.5), 0, 255)`, with
`P(b | a) = count(a b) / max(count(a), sum of count(a x) over every stored pair of a)`. The
denominator is the larger of the word's own unigram count and the sum of its stored pairs, so a
word with few, rare pairs never reads as certain. A reader recovers `log10 P(b | a) = -q / 25`. A
pair that is absent has no value at all (`pairLogP` returns nil); callers back off to the unigram.

## Sources and counts

The word list is SymSpell's `frequency_dictionary_en_82_765.txt`, the pairs are its
`frequency_bigramdictionary_en_243_342.txt` (both at the commit pinned in the script, with their
SHA-256 checked on every build), and `Tools/typing-extra-words.tsv` adds contractions and chat
words. A word's count is the larger of its count in the list and in the tsv. Pairs whose words are
not both in the word list are dropped. Contractions have no pairs in v1: the bigram file has
none, since its tokens split at the apostrophe.
