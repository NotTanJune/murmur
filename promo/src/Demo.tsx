import React from 'react';
import {AbsoluteFill, OffthreadVideo, staticFile, useCurrentFrame, useVideoConfig} from 'remotion';
import {color, font} from './theme';

export const DEMO_WIDTH = 1920;
export const DEMO_HEIGHT = 1080;
export const DEMO_FPS = 30;
export const DEMO_SECONDS = 15.15;

/**
 * Moments in the capture, in seconds. The key press and release come from the hotkey
 * tool's timestamps; the landing frame was read from the capture (first frame with
 * text at the top of the window), and the gap between release and landing matches the
 * app's own log line for this hold: "release to delivery event 0.445s".
 */
const PRESS = 0.8;
const SPEECH_START = PRESS + 0.7;
const RELEASE = 10.9;
const SPEECH_END = RELEASE - 0.6;
const LANDED = 11.35;

const SENTENCE =
  'Hey, can we move the design review to Thursday afternoon? I want to walk through the new onboarding flow before it ships.';
const WORDS = SENTENCE.split(' ');

const Eyebrow: React.FC<{children: React.ReactNode}> = ({children}) => (
  <div
    style={{
      fontFamily: font.sans,
      fontSize: 22,
      fontWeight: 500,
      letterSpacing: '0.08em',
      textTransform: 'uppercase',
      color: color.secondaryOnDark,
    }}
  >
    {children}
  </div>
);

/** The capture with two overlays: the sentence as it is spoken, and a stopwatch from release to text. */
export const Demo: React.FC = () => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const t = frame / fps;

  const holding = t >= PRESS && t < RELEASE;
  const spokenCount =
    t < SPEECH_START
      ? 0
      : Math.min(
          WORDS.length,
          Math.floor(((t - SPEECH_START) / (SPEECH_END - SPEECH_START)) * WORDS.length) + 1,
        );
  const captionVisible = t >= SPEECH_START && t < RELEASE + 0.2;

  const timerRunning = t >= RELEASE;
  const elapsed = Math.min(t, LANDED) - RELEASE;
  const landed = t >= LANDED;

  return (
    <AbsoluteFill style={{background: color.hud}}>
      <OffthreadVideo src={staticFile('demo-capture.mp4')} muted style={{width: DEMO_WIDTH, height: DEMO_HEIGHT}} />

      {holding ? (
        <div
          style={{
            position: 'absolute',
            left: 48,
            top: 96,
            display: 'flex',
            alignItems: 'center',
            gap: 14,
            padding: '12px 22px',
            borderRadius: 999,
            background: color.record,
            color: color.onRecord,
            fontFamily: font.sans,
            fontSize: 26,
            fontWeight: 600,
          }}
        >
          <span style={{fontSize: 30, lineHeight: 1}}>⌘</span>
          Right ⌘ held
        </div>
      ) : null}

      {captionVisible ? (
        <div
          style={{
            position: 'absolute',
            left: 0,
            right: 0,
            top: 430,
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'center',
            gap: 18,
            padding: '0 240px',
            textAlign: 'center',
          }}
        >
          <Eyebrow>Saying</Eyebrow>
          <div
            style={{
              fontFamily: font.sans,
              fontSize: 48,
              fontWeight: 500,
              lineHeight: 1.3,
              color: color.inkOnDark,
              minHeight: 130,
            }}
          >
            {WORDS.slice(0, spokenCount).join(' ')}
          </div>
        </div>
      ) : null}

      {timerRunning ? (
        <div
          style={{
            position: 'absolute',
            right: 48,
            top: 96,
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'flex-end',
            gap: 10,
            padding: '18px 28px',
            borderRadius: 24,
            background: color.hud,
            border: `2px solid ${landed ? color.record : color.hairlineOnDark}`,
          }}
        >
          <Eyebrow>Release to text</Eyebrow>
          <div
            style={{
              fontFamily: '"SF Mono", Menlo, monospace',
              fontSize: 72,
              fontWeight: 600,
              lineHeight: 1,
              fontVariantNumeric: 'tabular-nums',
              color: landed ? color.record : color.inkOnDark,
            }}
          >
            {elapsed.toFixed(2)} s
          </div>
        </div>
      ) : null}
    </AbsoluteFill>
  );
};
