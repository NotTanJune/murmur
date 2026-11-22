import {measureText} from '@remotion/layout-utils';
import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {Headline} from '../../components/Headline';
import {color, ease, FPS, font, progress} from '../../theme';
import {BEZEL, Phone, SCREEN} from '../Phone';
import {MOMENT, PHONE_SPOKEN, PHONE_START} from '../timing';

const SCALE = 1.6;
const L = {
  left: 120,
  headTop: 176,
  headSize: 148,
  said: {top: 440, size: 62, width: 900, line: 1.3},
  stat: {top: 820},
  phone: {left: 1150, bottom: 1052},
};

const PHONE_HEIGHT = (SCREEN.h + BEZEL * 2) * SCALE;

/**
 * Tap the key, talk, tap again: the text lands in the message field. Left of the phone, the
 * words as they are said, cleaned once the text lands; on the key, only the waveform.
 */
export const KeyboardScene: React.FC = () => {
  const frame = useCurrentFrame();
  const t = (frame + PHONE_START.keyboard) / FPS;

  const phoneIn = progress(t, MOMENT.phoneIn, MOMENT.phoneIn + 0.9, ease.out);
  const cleaned = t >= MOMENT.textLands + 0.15;
  const swap = progress(t, MOMENT.textLands + 0.05, MOMENT.textLands + 0.3, ease.out);
  const collapse = progress(t, MOMENT.textLands + 0.35, MOMENT.textLands + 0.75, ease.inOut);

  return (
    <AbsoluteFill style={{background: color.chrome}}>
      <Headline
        lines={[[{text: 'Tap '}, {text: 'Murmur.', italic: true}]]}
        size={L.headSize}
        left={L.left}
        top={L.headTop}
        time={t}
        inFrom={0.45}
        inTo={1.25}
        outFrom={2.5}
        outTo={2.8}
      />
      <Headline
        lines={[[{text: 'Talk.', italic: true}]]}
        size={L.headSize}
        left={L.left}
        top={L.headTop}
        time={t}
        inFrom={2.8}
        inTo={3.4}
        outFrom={7.6}
        outTo={7.9}
      />
      <Headline
        lines={[[{text: 'Tap '}, {text: 'again.', italic: true}]]}
        size={L.headSize}
        left={L.left}
        top={L.headTop}
        time={t}
        inFrom={7.9}
        inTo={8.45}
      />

      {/* What was said, cleaned once the text lands */}
      <div
        style={{
          position: 'absolute',
          left: L.left,
          top: L.said.top,
          width: L.said.width,
          fontFamily: font.serif,
          fontSize: L.said.size,
          lineHeight: L.said.line,
          letterSpacing: '-0.01em',
          color: color.inkSecondary,
        }}
      >
        {PHONE_SPOKEN.map((word, i) => {
          const appear = progress(t, word.a + 0.04, word.a + 0.22, ease.out);
          if (word.filler) {
            const full = measureText({
              text: `${word.text} `,
              fontFamily: font.serif,
              fontSize: L.said.size,
              letterSpacing: '-0.01em',
            }).width;
            return (
              <span
                key={i}
                style={{
                  display: 'inline-block',
                  position: 'relative',
                  whiteSpace: 'pre',
                  overflow: 'hidden',
                  verticalAlign: 'bottom',
                  width: full * (1 - collapse),
                  opacity: appear * (1 - progress(t, MOMENT.textLands + 0.25, MOMENT.textLands + 0.6, ease.in)),
                  color: color.inkTertiary,
                }}
              >
                {`${word.text} `}
                <span
                  style={{
                    position: 'absolute',
                    left: 0,
                    top: '54%',
                    height: 4,
                    width: (full - 16) * swap,
                    background: color.inkSecondary,
                  }}
                />
              </span>
            );
          }
          const text = cleaned && word.final ? word.final : word.text;
          const dip = word.final ? 1 - 0.7 * Math.sin(Math.PI * swap) : 1;
          return (
            <span
              key={i}
              style={{
                opacity: appear * dip,
                color: cleaned ? color.ink : color.inkSecondary,
              }}
            >
              {text}
              {i < PHONE_SPOKEN.length - 1 ? ' ' : ''}
            </span>
          );
        })}
      </div>

      {/* Tap to text */}
      <div
        style={{
          position: 'absolute',
          left: L.left,
          top: L.stat.top,
          display: 'flex',
          alignItems: 'baseline',
          gap: 22,
          opacity: progress(t, MOMENT.textLands + 0.3, MOMENT.textLands + 0.9, ease.out),
          translate: `0px ${(1 - progress(t, MOMENT.textLands + 0.3, MOMENT.textLands + 0.9, ease.out)) * 20}px`,
        }}
      >
        <span style={{fontFamily: font.serif, fontSize: 96, lineHeight: 1, color: color.stat}}>0.19 s</span>
        <span style={{fontFamily: font.sans, fontSize: 38, color: color.ink}}>from the second tap to text</span>
      </div>

      <div
        style={{
          position: 'absolute',
          left: L.phone.left,
          top: L.phone.bottom - PHONE_HEIGHT,
          transformOrigin: 'top left',
          scale: `${SCALE}`,
          opacity: phoneIn,
          translate: `0px ${(1 - phoneIn) * 120}px`,
        }}
      >
        <Phone t={t} />
      </div>
    </AbsoluteFill>
  );
};
