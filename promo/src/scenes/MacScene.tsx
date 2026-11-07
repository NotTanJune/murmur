import React from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {Headline} from '../components/Headline';
import {color, ease, FPS, font, progress, SCENE_START} from '../theme';

const L = {
  left: 120,
  right: 1800,
  lineY: 340,
  colWidth: 520,
  colPitch: 560,
  dot: 28,
  rule: 622,
  statTop: 664,
};

const stops = [
  {eyebrow: 'Speech', title: 'Bark 3.0 Clean', detail: 'on the Neural Engine'},
  {eyebrow: 'Cleanup', title: 'S1-mini by Superwhisper', detail: 'on the GPU'},
  {eyebrow: undefined, title: 'Your text field', detail: undefined},
] as const;

/** When the drawn line reaches each stop. */
const LINE_FROM = 15.45;
const LINE_TO = 16.75;
const reach = [LINE_FROM, (LINE_FROM + LINE_TO) / 2, LINE_TO];

const FIELD_WORDS = ['I', 'think', 'we', 'should', 'ship', 'on', 'Monday.'];

const rise = (t: number, from: number, to: number) => {
  const p = progress(t, from, to, ease.out);
  return {opacity: p, translate: `0px ${(1 - p) * 22}px`} as const;
};

export const MacScene: React.FC = () => {
  const frame = useCurrentFrame();
  const t = (frame + SCENE_START.mac) / FPS;

  const line = progress(t, LINE_FROM, LINE_TO, ease.inOut);
  const lineStart = L.left + L.dot / 2;
  const lineEnd = L.left + 2 * L.colPitch + L.dot / 2;

  return (
    <AbsoluteFill style={{background: color.pane}}>
     <AbsoluteFill style={{opacity: 1 - progress(t, 20.3, 20.72, ease.in)}}>
      <Headline
        lines={[[{text: 'On your '}, {text: 'Mac.', italic: true}]]}
        size={128}
        left={L.left}
        top={92}
        time={t}
        inFrom={15.15}
        inTo={15.9}
      />

      {/* The path */}
      <div
        style={{
          position: 'absolute',
          left: lineStart,
          top: L.lineY - 1.5,
          width: (lineEnd - lineStart) * line,
          height: 3,
          borderRadius: 2,
          background: color.ink,
        }}
      />
      {stops.map((stop, i) => {
        const x = L.left + i * L.colPitch;
        const arrive = reach[i];
        const dot = progress(t, arrive - 0.05, arrive + 0.3, ease.out);
        return (
          <React.Fragment key={stop.title}>
            <div
              style={{
                position: 'absolute',
                left: x,
                top: L.lineY - L.dot / 2,
                width: L.dot,
                height: L.dot,
                borderRadius: L.dot / 2,
                background: color.ink,
                opacity: dot,
                scale: `${0.4 + 0.6 * dot}`,
              }}
            />
            <div
              style={{
                position: 'absolute',
                left: x,
                top: 392,
                width: L.colWidth,
                fontFamily: font.sans,
                ...rise(t, arrive + 0.05, arrive + 0.65),
              }}
            >
              {stop.eyebrow ? (
                <div style={{fontSize: 30, fontWeight: 500, color: color.inkSecondary, height: 44}}>
                  {stop.eyebrow}
                </div>
              ) : (
                <div style={{height: 44}} />
              )}
              <div
                style={{
                  fontSize: 42,
                  fontWeight: 600,
                  color: color.ink,
                  height: 58,
                  whiteSpace: 'nowrap',
                }}
              >
                {stop.title}
              </div>
              {stop.detail ? (
                <div style={{fontSize: 32, fontWeight: 400, color: color.inkSecondary, marginTop: 6}}>
                  {stop.detail}
                </div>
              ) : null}
            </div>
          </React.Fragment>
        );
      })}

      {/* The field the text lands in */}
      <div
        style={{
          position: 'absolute',
          left: L.left + 2 * L.colPitch,
          top: 508,
          width: L.colWidth,
          height: 92,
          boxSizing: 'border-box',
          borderRadius: 20,
          background: color.card,
          border: `2px solid ${color.hairline}`,
          display: 'flex',
          alignItems: 'center',
          paddingLeft: 28,
          fontFamily: font.serif,
          fontSize: 30,
          color: color.ink,
          whiteSpace: 'pre',
          opacity: progress(t, 16.95, 17.35, ease.out),
        }}
      >
        {FIELD_WORDS.map((word, i) => {
          const p = progress(t, 17.1 + i * 0.08, 17.35 + i * 0.08, ease.out);
          return (
            <span key={i} style={{opacity: p}}>
              {word}
              {i < FIELD_WORDS.length - 1 ? ' ' : ''}
            </span>
          );
        })}
      </div>

      {/* Divider */}
      <div
        style={{
          position: 'absolute',
          left: L.left,
          top: L.rule,
          width: (L.right - L.left) * progress(t, 17.35, 17.95, ease.inOut),
          height: 2,
          background: color.hairline,
        }}
      />

      {/* Stats */}
      {[
        {x: L.left, value: '0.17', unit: 's', caption: 'speech release tail, 50 s of audio', from: 17.7},
        {x: 1000, value: '0.2', unit: 's', caption: 'to clean a 19-word sentence', from: 18.4},
      ].map((stat) => (
        <div
          key={stat.value}
          style={{
            position: 'absolute',
            left: stat.x,
            top: L.statTop,
            width: 800,
            ...rise(t, stat.from, stat.from + 0.7),
          }}
        >
          <div
            style={{
              fontFamily: font.serif,
              fontSize: 156,
              lineHeight: 1,
              letterSpacing: '-0.015em',
              color: color.stat,
            }}
          >
            {stat.value}
            <span style={{marginLeft: '0.16em'}}>{stat.unit}</span>
          </div>
          <div
            style={{
              marginTop: 14,
              fontFamily: font.sans,
              fontSize: 36,
              fontWeight: 400,
              color: color.ink,
              whiteSpace: 'nowrap',
            }}
          >
            {stat.caption}
          </div>
        </div>
      ))}

      <div
        style={{
          position: 'absolute',
          left: L.left,
          top: 918,
          fontFamily: font.sans,
          fontSize: 24,
          fontWeight: 400,
          color: color.inkSecondary,
          opacity: progress(t, 19.1, 19.6, ease.out),
        }}
      >
        Measured on an M2
      </div>
     </AbsoluteFill>
    </AbsoluteFill>
  );
};
