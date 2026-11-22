import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {Headline} from '../../components/Headline';
import {KeyCap} from '../../components/KeyCap';
import {color, ease, FPS, font, progress} from '../../theme';
import {TalkKey} from '../TalkKey';
import {PHONE_START} from '../timing';

const KEY_SCALE = 1.7;
const TALK = {w: 335, h: 48} as const;
const L = {
  macCenter: 520,
  phoneCenter: 1340,
  keyTop: 360,
  labelTop: 680,
  rule: 800,
  noteTop: 850,
};

/** Seconds on the global clock. */
const MAC_PRESS = {down: 18.95, up: 19.75};
const PHONE_TAP = {on: 19.95, off: 21.05};

const rise = (t: number, from: number, to: number) => {
  const p = progress(t, from, to, ease.out);
  return {opacity: p, translate: `0px ${(1 - p) * 22}px`} as const;
};

/** A level that looks like a short phrase, for the phone key's bars. */
const phraseLevel = (t: number) => {
  const u = t - PHONE_TAP.on - 0.15;
  if (u < 0 || u > 0.85) return 0.06;
  return 0.35 + 0.45 * Math.abs(Math.sin(u * 7.5)) * Math.sin((Math.PI * u) / 0.85);
};

/** The Mac's key and the iPhone's key, side by side. */
export const PairScene: React.FC = () => {
  const frame = useCurrentFrame();
  const t = (frame + PHONE_START.pair) / FPS;

  const macPressed =
    progress(t, MAC_PRESS.down, MAC_PRESS.down + 0.12, ease.out) *
    (1 - progress(t, MAC_PRESS.up, MAC_PRESS.up + 0.14, ease.out));
  const tapPress = (at: number) =>
    progress(t, at - 0.04, at + 0.02, ease.out) * (1 - progress(t, at + 0.08, at + 0.2, ease.soft));
  const recording = t >= PHONE_TAP.on && t < PHONE_TAP.off;
  const keyIn = progress(t, 18.35, 18.95, ease.out);

  return (
    <AbsoluteFill style={{background: color.pane}}>
      <Headline
        lines={[[{text: 'Mac and '}, {text: 'iPhone.', italic: true}]]}
        size={128}
        left={120}
        top={92}
        time={t}
        inFrom={18.15}
        inTo={18.9}
      />

      <div style={{opacity: keyIn, translate: `0px ${(1 - keyIn) * 26}px`}}>
        <KeyCap
          pressed={macPressed}
          left={L.macCenter - 120}
          top={L.keyTop}
          ripple={progress(t, MAC_PRESS.down, MAC_PRESS.down + 0.7, ease.out)}
        />
        <div
          style={{
            position: 'absolute',
            left: L.phoneCenter - (TALK.w * KEY_SCALE) / 2,
            top: L.keyTop + 120 - (TALK.h * KEY_SCALE) / 2,
            transformOrigin: 'top left',
            scale: `${KEY_SCALE}`,
          }}
        >
          <TalkKey
            width={TALK.w}
            height={TALK.h}
            time={t}
            recording={recording}
            heard={t >= PHONE_TAP.on + 0.12}
            level={phraseLevel(t)}
            press={Math.max(tapPress(PHONE_TAP.on), tapPress(PHONE_TAP.off))}
          />
        </div>
      </div>

      {[
        {center: L.macCenter, text: 'Hold ⌥ on your Mac.', from: 18.75},
        {center: L.phoneCenter, text: 'Tap Murmur on your iPhone.', from: 19.0},
      ].map((label) => (
        <div
          key={label.text}
          style={{
            position: 'absolute',
            left: label.center - 400,
            width: 800,
            top: L.labelTop,
            textAlign: 'center',
            fontFamily: font.sans,
            fontSize: 42,
            fontWeight: 500,
            color: color.ink,
            ...rise(t, label.from, label.from + 0.6),
          }}
        >
          {label.text}
        </div>
      ))}

      <div
        style={{
          position: 'absolute',
          left: 120,
          top: L.rule,
          width: 1680 * progress(t, 20.7, 21.3, ease.inOut),
          height: 2,
          background: color.hairline,
        }}
      />
      <div
        style={{
          position: 'absolute',
          left: 120,
          top: L.noteTop,
          fontFamily: font.sans,
          fontSize: 36,
          lineHeight: 1.45,
          color: color.inkSecondary,
          ...rise(t, 21.0, 21.6),
        }}
      >
        Bark 3.0 Clean on both, on device.
        <br />
        Dictations from your iPhone import into your Mac's training.
      </div>
    </AbsoluteFill>
  );
};
