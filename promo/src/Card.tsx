import React from 'react';
import {AbsoluteFill} from 'remotion';
import {Capsule, CAPSULE_HEIGHT, CAPSULE_WIDTH} from './components/Capsule';
import {KeyCap} from './components/KeyCap';
import {BEZEL, Phone, SCREEN} from './phone/Phone';
import {color, font} from './theme';

export const CARD_WIDTH = 1600;
export const CARD_HEIGHT = 900;

const PHONE_SCALE = 1.22;
const PHONE_LEFT = 150;
const PHONE_BOTTOM = 870;
const KEY_SCALE = 0.62;
const CAPSULE_SCALE = 0.5;
const TEXT_LEFT = 820;

/**
 * A project card for the portfolio: the iPhone keyboard mid-dictation beside the wordmark,
 * the Mac's pressed key and its listening capsule. A still, so every value is fixed.
 */
export const Card: React.FC = () => {
  const phoneHeight = (SCREEN.h + BEZEL * 2) * PHONE_SCALE;
  return (
    <AbsoluteFill style={{background: color.pane, overflow: 'hidden'}}>
      <div
        style={{
          position: 'absolute',
          left: PHONE_LEFT,
          top: PHONE_BOTTOM - phoneHeight,
          transformOrigin: 'top left',
          scale: `${PHONE_SCALE}`,
        }}
      >
        {/* 5 s into the film: recording, with the bars following the voice. */}
        <Phone t={5.0} />
      </div>

      <div style={{position: 'absolute', left: TEXT_LEFT, top: 210, whiteSpace: 'nowrap'}}>
        <div
          style={{
            fontFamily: font.serif,
            fontSize: 176,
            lineHeight: 1,
            letterSpacing: '-0.02em',
            color: color.ink,
          }}
        >
          Murmur
        </div>
        <div
          style={{
            marginTop: 22,
            fontFamily: font.sans,
            fontSize: 44,
            lineHeight: 1.3,
            color: color.inkSecondary,
          }}
        >
          Push-to-talk dictation
          <br />
          for Mac and iPhone
        </div>
      </div>

      <KeyCap pressed={1} left={TEXT_LEFT} top={560} scale={KEY_SCALE} />
      <div
        style={{
          position: 'absolute',
          left: TEXT_LEFT + 240 * KEY_SCALE + 44,
          top: 560 + ((216 + 26) * KEY_SCALE) / 2 - (CAPSULE_HEIGHT * CAPSULE_SCALE) / 2,
          width: CAPSULE_WIDTH,
          height: CAPSULE_HEIGHT,
          scale: `${CAPSULE_SCALE}`,
          transformOrigin: '0% 0%',
        }}
      >
        <Capsule centerX={CAPSULE_WIDTH / 2} top={0} level={0.72} time={1.37} opacity={1} translateY={0} />
      </div>
    </AbsoluteFill>
  );
};
