import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {color, ease, FPS, font, progress, SCENE_START} from '../theme';

const rise = (t: number, from: number, to: number, distance = 26) => {
  const p = progress(t, from, to, ease.out);
  return {opacity: p, translate: `0px ${(1 - p) * distance}px`} as const;
};

export const EndCard: React.FC = () => {
  const frame = useCurrentFrame();
  const t = (frame + SCENE_START.end) / FPS;

  return (
    <AbsoluteFill
      style={{
        background: color.nearBlack,
        alignItems: 'center',
        justifyContent: 'center',
        flexDirection: 'column',
        textAlign: 'center',
      }}
    >
     <AbsoluteFill
      style={{
        alignItems: 'center',
        justifyContent: 'center',
        flexDirection: 'column',
        // A slow drift keeps the held card alive without drawing the eye.
        scale: `${1 + 0.014 * progress(t, 27.2, 31.2, (x) => x)}`,
      }}
     >
      <div
        style={{
          fontFamily: font.serif,
          fontSize: 304,
          lineHeight: 1,
          letterSpacing: '-0.02em',
          color: color.inkOnDark,
          ...rise(t, 27.25, 28.15, 36),
        }}
      >
        Murmur
      </div>
      <div
        style={{
          marginTop: 28,
          fontFamily: font.sans,
          fontSize: 54,
          fontWeight: 400,
          color: color.inkOnDark,
          ...rise(t, 27.9, 28.6),
        }}
      >
        Push-to-talk dictation for macOS
      </div>
      <div
        style={{
          marginTop: 64,
          width: 132 * progress(t, 28.3, 28.9, ease.inOut),
          height: 2,
          background: color.tertiaryOnDark,
        }}
      />
      <div
        style={{
          marginTop: 48,
          fontFamily: font.sans,
          fontSize: 40,
          fontWeight: 400,
          color: color.secondaryOnDark,
          ...rise(t, 28.6, 29.2, 20),
        }}
      >
        On-device. Open source. GPL-3.0.
      </div>
      <div
        style={{
          marginTop: 22,
          fontFamily: font.sans,
          fontSize: 44,
          fontWeight: 500,
          color: color.inkOnDark,
          ...rise(t, 29.0, 29.6, 20),
        }}
      >
        github.com/NotTanJune/murmur
      </div>
     </AbsoluteFill>
    </AbsoluteFill>
  );
};
