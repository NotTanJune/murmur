/**
 * The dictated sentence, word by word. Times are seconds on the video clock.
 * `a` and `b` are when the word is spoken; the text lands a moment after (recognizer lag).
 */
export type Kind = 'keep' | 'filler' | 'false-start';

export type SpokenWord = {
  text: string;
  /** What the word reads as once cleaned. */
  final?: string;
  kind: Kind;
  line: number;
  a: number;
  b: number;
  /** Peak loudness 0..1. */
  amp: number;
  /** Syllables, for the pulse inside the word. */
  syllables: number;
};

export const RECOGNIZER_LAG = 0.14;

export const SPOKEN: SpokenWord[] = [
  {text: 'so', kind: 'filler', line: 0, a: 4.9, b: 5.12, amp: 0.6, syllables: 1},
  {text: 'um', kind: 'filler', line: 0, a: 5.28, b: 5.62, amp: 0.42, syllables: 1},
  {text: 'I', kind: 'keep', line: 0, a: 5.74, b: 5.85, amp: 0.7, syllables: 1},
  {text: 'think', kind: 'keep', line: 0, a: 5.87, b: 6.17, amp: 0.86, syllables: 1},
  {text: 'we', kind: 'keep', line: 0, a: 6.19, b: 6.32, amp: 0.74, syllables: 1},
  {text: 'should', kind: 'keep', line: 0, a: 6.34, b: 6.66, amp: 0.92, syllables: 1},
  {text: 'uh', kind: 'filler', line: 0, a: 6.86, b: 7.14, amp: 0.4, syllables: 1},
  {text: 'ship', kind: 'keep', line: 1, a: 7.26, b: 7.54, amp: 0.88, syllables: 1},
  {text: 'on', kind: 'keep', line: 1, a: 7.56, b: 7.66, amp: 0.62, syllables: 1},
  {text: 'friday', kind: 'false-start', line: 1, a: 7.7, b: 8.16, amp: 0.96, syllables: 2},
  {text: 'no', kind: 'false-start', line: 1, a: 8.4, b: 8.56, amp: 0.8, syllables: 1},
  {text: 'wait', kind: 'false-start', line: 1, a: 8.59, b: 8.9, amp: 0.9, syllables: 1},
  {text: 'monday', final: 'Monday.', kind: 'keep', line: 1, a: 9.1, b: 9.56, amp: 0.86, syllables: 2},
];

/** Final layout: which words stay and on which line. */
export const FINAL_LINES: number[][] = [
  [2, 3, 4, 5],
  [7, 8, 12],
];

/** Groups of struck words, struck in one stroke. Index into SPOKEN. */
export const STRIKES = [
  {words: [0, 1], from: 10.3, to: 10.7, fadeFrom: 11.75},
  {words: [6], from: 10.8, to: 11.05, fadeFrom: 11.82},
  {words: [9, 10, 11], from: 11.15, to: 11.65, fadeFrom: 11.9},
] as const;

const smooth = (edge0: number, edge1: number, x: number) => {
  const t = Math.min(1, Math.max(0, (x - edge0) / (edge1 - edge0)));
  return t * t * (3 - 2 * t);
};

/** Instantaneous loudness of the voice at time `t`, 0..1. */
const instant = (t: number) => {
  // Room tone, so the bars never sit perfectly still.
  let level = 0.045 + 0.02 * Math.sin(t * 2.3) * Math.sin(t * 5.1 + 1);
  for (const word of SPOKEN) {
    const length = word.b - word.a;
    const u = (t - word.a) / length;
    if (u < -0.05 || u > 1.6) continue;
    const attack = smooth(0, 0.14, u);
    const release = u <= 1 ? 1 : Math.exp(-((u - 1) * length) / 0.09);
    const clamped = Math.min(1, Math.max(0, u));
    const pulse = 0.7 + 0.3 * Math.abs(Math.sin(Math.PI * word.syllables * clamped));
    const body = 0.82 + 0.18 * Math.sin(Math.PI * clamped);
    level = Math.max(level, word.amp * attack * release * pulse * body);
  }
  // Fast fluctuation inside speech, like breath and consonants.
  const grain = 1 + 0.09 * Math.sin(t * 37) + 0.06 * Math.sin(t * 61 + 2);
  return Math.min(1, level * grain);
};

/** Level as a meter would show it: quick attack, slower fall. */
export const voiceLevel = (t: number) => {
  let level = 0;
  for (let step = 0; step < 6; step++) {
    level = Math.max(level, instant(t - step / 30) * Math.pow(0.74, step));
  }
  return level;
};

/** The three formatted outputs of the same sentence. */
export const SENTENCE = 'I think we should ship on Monday.';
