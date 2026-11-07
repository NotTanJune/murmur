import React from 'react';
import {color} from '../theme';

const SIZE = 240;
const FACE = 216;
const DEPTH = 26;
const TRAVEL = 22;
const RADIUS = 44;

/** The option key symbol, drawn so it does not depend on a fallback font. */
const OptionGlyph: React.FC<{stroke: string}> = ({stroke}) => (
  <svg width={112} height={112} viewBox="0 0 100 100" fill="none">
    <path
      d="M8 30 H32 L62 74 H92"
      stroke={stroke}
      strokeWidth={9}
      strokeLinecap="butt"
      strokeLinejoin="miter"
    />
    <path d="M60 30 H92" stroke={stroke} strokeWidth={9} strokeLinecap="butt" />
  </svg>
);

/**
 * A flat keycap: a solid underside and a face that travels down onto it.
 * `pressed` runs 0 (up) to 1 (down); the face turns record coral as it goes.
 */
export const KeyCap: React.FC<{
  pressed: number;
  left: number;
  top: number;
  opacity?: number;
  translateY?: number;
  scale?: number;
  /** 0..1 over the life of a single expanding ring that marks the press. */
  ripple?: number;
}> = ({pressed, left, top, opacity = 1, translateY = 0, scale = 1, ripple = 0}) => {
  const faceTop = TRAVEL * pressed;
  const coral = pressed > 0.5;
  return (
    <div
      style={{
        position: 'absolute',
        left,
        top,
        width: SIZE,
        height: FACE + DEPTH,
        opacity,
        translate: `0px ${translateY}px`,
        scale: `${scale}`,
        transformOrigin: '0% 0%',
      }}
    >
      {ripple > 0 && ripple < 1 ? (
        <div
          style={{
            position: 'absolute',
            left: 0,
            top: TRAVEL,
            width: SIZE,
            height: FACE,
            boxSizing: 'border-box',
            borderRadius: RADIUS,
            border: `3px solid ${color.record}`,
            opacity: 0.55 * (1 - ripple),
            scale: `${1 + 0.3 * ripple}`,
          }}
        />
      ) : null}
      <div
        style={{
          position: 'absolute',
          left: 0,
          top: DEPTH,
          width: SIZE,
          height: FACE,
          borderRadius: RADIUS,
          background: color.keyBody,
        }}
      />
      <div
        style={{
          position: 'absolute',
          left: 0,
          top: faceTop,
          width: SIZE,
          height: FACE,
          boxSizing: 'border-box',
          borderRadius: RADIUS,
          background: coral ? color.record : color.card,
          border: `3px solid ${coral ? color.record : color.hairline}`,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
        }}
      >
        <OptionGlyph stroke={coral ? color.onRecord : color.ink} />
      </div>
    </div>
  );
};
