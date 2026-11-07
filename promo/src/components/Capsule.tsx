import React from 'react';
import {color} from '../theme';

/**
 * The listening capsule, at 4.2x the app's 148 x 40 pt HUD. Bar maths follow
 * `Waveform` in Sources/Murmur/UI/HUDView.swift: a fixed phase per bar, a bell-shaped
 * envelope across the bars, and the wave riding on the level.
 */
const SCALE = 4.2;
export const CAPSULE_WIDTH = 148 * SCALE;
export const CAPSULE_HEIGHT = 40 * SCALE;

const BAR_COUNT = 16;
const BAR_WIDTH = 3 * SCALE;
const BAR_GAP = 3 * SCALE;
const FLOOR = 2 * SCALE;
const AMPLITUDE = 22 * SCALE;
const PHASES = Array.from({length: BAR_COUNT}, (_, i) => (i * 0.618) % 1);

const barHeight = (index: number, time: number, level: number) => {
  const phase = PHASES[index];
  const wave =
    0.65 * Math.sin(time * 9 + phase * Math.PI * 2) +
    0.35 * Math.sin(time * 15.5 + phase * Math.PI * 5);
  const envelope = 0.35 + 0.65 * Math.sin(((index + 1) / (BAR_COUNT + 1)) * Math.PI);
  const amplitude = Math.max(0.04, Math.min(level, 1));
  const scaled = amplitude * (0.55 + 0.45 * wave) * envelope;
  return FLOOR + Math.max(0, scaled) * AMPLITUDE;
};

export const Capsule: React.FC<{
  centerX: number;
  top: number;
  level: number;
  time: number;
  opacity: number;
  translateY: number;
}> = ({centerX, top, level, time, opacity, translateY}) => (
  <div
    style={{
      position: 'absolute',
      left: centerX - CAPSULE_WIDTH / 2,
      top,
      width: CAPSULE_WIDTH,
      height: CAPSULE_HEIGHT,
      borderRadius: CAPSULE_HEIGHT / 2,
      background: color.hud,
      // A floating surface: the one place a shadow is allowed.
      boxShadow: '0 8px 24px rgba(0, 0, 0, 0.16)',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      gap: BAR_GAP,
      opacity,
      translate: `0px ${translateY}px`,
    }}
  >
    {Array.from({length: BAR_COUNT}, (_, index) => (
      <div
        key={index}
        style={{
          width: BAR_WIDTH,
          height: barHeight(index, time, level),
          borderRadius: BAR_WIDTH / 2,
          background: color.record,
        }}
      />
    ))}
  </div>
);
