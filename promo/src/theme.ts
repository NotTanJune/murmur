import {Easing, interpolate} from 'remotion';

export const WIDTH = 1920;
export const HEIGHT = 1080;
export const FPS = 30;

/** Seconds to frames. */
export const sec = (seconds: number) => Math.round(seconds * FPS);

/**
 * Colours are the Murmur design tokens (Sources/Murmur/UI/DesignSystem.swift),
 * light values unless the name says otherwise.
 */
export const color = {
  chrome: '#EDE7DB',
  pane: '#F7F3EA',
  card: '#FFFDF8',
  field: '#EDE7DB',
  hairline: 'rgba(28, 25, 23, 0.12)',
  divider: 'rgba(28, 25, 23, 0.08)',
  ink: '#1C1917',
  inkSecondary: '#6B625A',
  inkTertiary: '#A89F94',
  selected: '#FBF1DD',
  stat: '#3F5D3A',
  /** Recording coral. Only the capsule bars and the pressed key use it. */
  record: '#FF6C4C',
  onRecord: '#FFFFFF',
  hud: '#1C1917',
  /** The solid underside of a keycap: the chrome colour pushed toward ink. */
  keyBody: '#D5CCBA',
  // Dark theme, for the end card.
  nearBlack: '#1A1715',
  inkOnDark: '#F0E8DA',
  secondaryOnDark: '#9A9087',
  tertiaryOnDark: '#574F48',
  hairlineOnDark: '#2E2925',
} as const;

export const font = {
  serif: '"Fraunces", Georgia, serif',
  sans: 'Figtree, "Helvetica Neue", Arial, sans-serif',
} as const;

/** Long, soft deceleration. Nothing bounces. */
export const ease = {
  out: Easing.bezier(0.16, 1, 0.3, 1),
  soft: Easing.bezier(0.22, 1, 0.36, 1),
  inOut: Easing.bezier(0.65, 0, 0.35, 1),
  in: Easing.bezier(0.5, 0, 0.75, 0),
  /** Spring with no overshoot, per the Remotion guidance. */
  spring: Easing.spring({damping: 200}),
} as const;

/**
 * Progress 0..1 between two moments, given in seconds on the clock the caller supplies.
 */
export const progress = (
  time: number,
  from: number,
  to: number,
  easing: (input: number) => number = ease.out,
) =>
  interpolate(time, [from, to], [0, 1], {
    easing,
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

/** Fade in at `inFrom..inTo`, hold, fade out at `outFrom..outTo`. */
export const window = (
  time: number,
  inFrom: number,
  inTo: number,
  outFrom: number,
  outTo: number,
) => progress(time, inFrom, inTo, ease.out) * (1 - progress(time, outFrom, outTo, ease.in));

/** Global start frame of each scene's local clock inside the final timeline. */
export const SCENE_START = {
  dictation: 0,
  mac: 442,
  fit: 622,
  end: 804,
} as const;

/** Scene lengths in frames, each including the half of the transition on either side. */
export const SCENE_LENGTH = {
  dictation: 458,
  mac: 196,
  fit: 206,
  end: 132,
} as const;

export const TRANSITION = {
  toMac: 16,
  toFit: 16,
  toEnd: 24,
} as const;

export const TOTAL_FRAMES =
  SCENE_LENGTH.dictation +
  SCENE_LENGTH.mac +
  SCENE_LENGTH.fit +
  SCENE_LENGTH.end -
  TRANSITION.toMac -
  TRANSITION.toFit -
  TRANSITION.toEnd;
