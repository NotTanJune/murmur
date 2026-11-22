import React from 'react';
import {color, font} from '../theme';

/**
 * Murmur's talk key on the iPhone, in points (the caller scales it). Idle it carries the
 * wordmark in EB Garamond Italic, soft orange; recording it is the Mac's HUD: bars that are
 * flat and grey until the microphone hears, then red and following the level. Colours are
 * `DS.Keyboard` in Sources/MurmurDesign/DesignSystem.swift.
 */
export const TALK = {
  wordmark: '#F2A57E',
  /** `talkGlassTint` in light: the HUD brown at 0.88 over the keyboard. */
  glass: 'rgba(28, 25, 23, 0.9)',
  flatBar: 'rgba(240, 232, 218, 0.5)',
} as const;

const BAR_COUNT = 16;
const BAR_WIDTH = 3;
const BAR_GAP = 3;
const FLOOR = 2.5;
const PHASES = Array.from({length: BAR_COUNT}, (_, i) => (i * 0.618) % 1);

const barHeight = (index: number, time: number, level: number, amplitude: number) => {
  const phase = PHASES[index];
  const wave =
    0.65 * Math.sin(time * 9 + phase * Math.PI * 2) +
    0.35 * Math.sin(time * 15.5 + phase * Math.PI * 5);
  const envelope = 0.35 + 0.65 * Math.sin(((index + 1) / (BAR_COUNT + 1)) * Math.PI);
  const clamped = Math.max(0.04, Math.min(level, 1));
  return FLOOR + Math.max(0, clamped * (0.55 + 0.45 * wave) * envelope) * amplitude;
};

export const TalkKey: React.FC<{
  width: number;
  height: number;
  /** Seconds, for the bar motion. */
  time: number;
  recording: boolean;
  heard: boolean;
  level: number;
  /** 0..1, how far the key is pushed in. */
  press?: number;
}> = ({width, height, time, recording, heard, level, press = 0}) => (
  <div
    style={{
      width,
      height,
      borderRadius: height / 2,
      background: TALK.glass,
      // Liquid Glass reads as a lit rim and a soft lift off the keyboard.
      boxShadow:
        'inset 0 0.8px 0 rgba(255, 255, 255, 0.22), inset 0 -0.6px 0 rgba(255, 255, 255, 0.06), 0 2px 6px rgba(0, 0, 0, 0.18)',
      border: '0.5px solid rgba(255, 255, 255, 0.16)',
      boxSizing: 'border-box',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      scale: `${1 - 0.035 * press}`,
    }}
  >
    {recording ? (
      <div style={{display: 'flex', alignItems: 'center', gap: BAR_GAP}}>
        {Array.from({length: BAR_COUNT}, (_, index) => (
          <div
            key={index}
            style={{
              width: BAR_WIDTH,
              height: heard ? barHeight(index, time, level, height * 0.62) : FLOOR,
              borderRadius: BAR_WIDTH / 2,
              background: heard ? color.record : TALK.flatBar,
            }}
          />
        ))}
      </div>
    ) : (
      <div
        style={{
          fontFamily: font.wordmark,
          fontStyle: 'italic',
          fontWeight: 500,
          fontSize: height * 0.5,
          lineHeight: 1,
          color: TALK.wordmark,
          // EB Garamond sits low in its box; lift it to the optical centre.
          translate: `0px ${-height * 0.03}px`,
        }}
      >
        Murmur
      </div>
    )}
  </div>
);
