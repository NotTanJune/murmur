/**
 * The iPhone film's clock. Seconds on the global timeline unless a name says frames.
 * Cuts at 12 s, 18 s and 23 s; each transition is centred on its cut, as in the Mac film.
 */
import {FPS} from '../theme';

export const CUT = {toIPhone: 12, toPair: 18, toEnd: 23, end: 27.5} as const;

export const PHONE_TRANSITION = {toIPhone: 16, toPair: 16, toEnd: 24} as const;

const f = (seconds: number) => Math.round(seconds * FPS);

/** Global start frame of each scene's local clock. */
export const PHONE_START = {
  keyboard: 0,
  iphone: f(CUT.toIPhone) - PHONE_TRANSITION.toIPhone / 2,
  pair: f(CUT.toPair) - PHONE_TRANSITION.toPair / 2,
  end: f(CUT.toEnd) - PHONE_TRANSITION.toEnd / 2,
} as const;

/** Scene lengths in frames, each including half of the transition on either side. */
export const PHONE_LENGTH = {
  keyboard: f(CUT.toIPhone) + PHONE_TRANSITION.toIPhone / 2,
  iphone: f(CUT.toPair) + PHONE_TRANSITION.toPair / 2 - PHONE_START.iphone,
  pair: f(CUT.toEnd) + PHONE_TRANSITION.toEnd / 2 - PHONE_START.pair,
  end: f(CUT.end) - PHONE_START.end,
} as const;

export const PHONE_TOTAL_FRAMES = f(CUT.end);

/** The keyboard scene's moments. */
export const MOMENT = {
  phoneIn: 0.15,
  firstTap: 2.2,
  /** The page hears: the flat grey bars turn red. */
  heard: 2.42,
  secondTap: 8.4,
  /** 0.19 s after the second tap, as measured on an iPhone 15 Pro (Bark warm). */
  textLands: 8.59,
  sendTap: 10.25,
} as const;

export type PhoneWord = {
  text: string;
  /** What the word reads as once cleaned; absent when it is unchanged. */
  final?: string;
  filler?: boolean;
  a: number;
  b: number;
  amp: number;
  syllables: number;
};

/** What is said into the key. Bark Clean drops the fillers; the rules write the number. */
export const PHONE_SPOKEN: PhoneWord[] = [
  {text: 'um', filler: true, a: 3.3, b: 3.6, amp: 0.45, syllables: 1},
  {text: 'yeah', final: 'Yeah,', a: 3.78, b: 4.08, amp: 0.82, syllables: 1},
  {text: "I'm", a: 4.2, b: 4.36, amp: 0.7, syllables: 1},
  {text: 'ten', final: '10', a: 4.4, b: 4.66, amp: 0.9, syllables: 1},
  {text: 'minutes', a: 4.7, b: 5.1, amp: 0.84, syllables: 2},
  {text: 'away', final: 'away.', a: 5.14, b: 5.52, amp: 0.8, syllables: 2},
  {text: 'uh', filler: true, a: 5.92, b: 6.22, amp: 0.4, syllables: 1},
  {text: 'order', final: 'Order', a: 6.46, b: 6.78, amp: 0.88, syllables: 2},
  {text: 'me', a: 6.8, b: 6.92, amp: 0.7, syllables: 1},
  {text: 'the', a: 6.94, b: 7.03, amp: 0.62, syllables: 1},
  {text: 'usual', final: 'usual.', a: 7.06, b: 7.52, amp: 0.86, syllables: 3},
];

export const PHONE_SENTENCE = "Yeah, I'm 10 minutes away. Order me the usual.";

const smooth = (edge0: number, edge1: number, x: number) => {
  const t = Math.min(1, Math.max(0, (x - edge0) / (edge1 - edge0)));
  return t * t * (3 - 2 * t);
};

const instant = (t: number) => {
  let level = 0.05 + 0.02 * Math.sin(t * 2.3) * Math.sin(t * 5.1 + 1);
  for (const word of PHONE_SPOKEN) {
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
  const grain = 1 + 0.09 * Math.sin(t * 37) + 0.06 * Math.sin(t * 61 + 2);
  return Math.min(1, level * grain);
};

/** Level as the key's meter shows it: quick attack, slower fall. */
export const phoneVoiceLevel = (t: number) => {
  let level = 0;
  for (let step = 0; step < 6; step++) {
    level = Math.max(level, instant(t - step / 30) * Math.pow(0.74, step));
  }
  return level;
};
