import React from 'react';
import {AbsoluteFill} from 'remotion';
import {Capsule, CAPSULE_HEIGHT, CAPSULE_WIDTH} from './components/Capsule';
import {KeyCap} from './components/KeyCap';
import {color, font} from './theme';

export const BANNER_WIDTH = 1920;
export const BANNER_HEIGHT = 640;

const KEY_SCALE = 0.78;
const KEY_WIDTH = 240 * KEY_SCALE;
const KEY_HEIGHT = (216 + 26) * KEY_SCALE;
const CAPSULE_SCALE = 0.62;
const GAP = 56;
const TEXT_GAP = 112;
const WORDMARK_WIDTH = 600;

/**
 * The README banner: paper ground, the pressed key, the listening capsule and the
 * wordmark. A still, so every value is fixed.
 */
export const Banner: React.FC = () => {
  const groupWidth =
    KEY_WIDTH + GAP + CAPSULE_WIDTH * CAPSULE_SCALE + TEXT_GAP + WORDMARK_WIDTH;
  const left = (BANNER_WIDTH - groupWidth) / 2;
  const middle = BANNER_HEIGHT / 2;
  const keyLeft = left;
  const capsuleLeft = keyLeft + KEY_WIDTH + GAP;
  const textLeft = capsuleLeft + CAPSULE_WIDTH * CAPSULE_SCALE + TEXT_GAP;
  return (
    <AbsoluteFill style={{background: color.pane}}>
      <KeyCap pressed={1} left={keyLeft} top={middle - KEY_HEIGHT / 2} scale={KEY_SCALE} />
      <div
        style={{
          position: 'absolute',
          left: capsuleLeft,
          top: middle - (CAPSULE_HEIGHT * CAPSULE_SCALE) / 2,
          width: CAPSULE_WIDTH,
          height: CAPSULE_HEIGHT,
          scale: `${CAPSULE_SCALE}`,
          transformOrigin: '0% 0%',
        }}
      >
        <Capsule
          centerX={CAPSULE_WIDTH / 2}
          top={0}
          level={0.72}
          time={1.37}
          opacity={1}
          translateY={0}
        />
      </div>
      <div
        style={{
          position: 'absolute',
          left: textLeft,
          top: middle - 118,
          display: 'flex',
          flexDirection: 'column',
          gap: 14,
          whiteSpace: 'nowrap',
        }}
      >
        <div
          style={{
            fontFamily: font.serif,
            fontSize: 168,
            lineHeight: 1,
            letterSpacing: '-0.02em',
            color: color.ink,
          }}
        >
          Murmur
        </div>
        <div
          style={{
            fontFamily: font.sans,
            fontSize: 38,
            fontWeight: 400,
            color: color.inkSecondary,
          }}
        >
          Push-to-talk dictation for macOS
        </div>
      </div>
    </AbsoluteFill>
  );
};
