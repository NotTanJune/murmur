import React from 'react';
import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {Headline} from '../components/Headline';
import {color, ease, FPS, font, progress, SCENE_START, window} from '../theme';

const L = {
  left: 120,
  chipTop: 290,
  chipW: 440,
  chipH: 92,
  chipPitch: 112,
  cardX: 640,
  cardW: 1160,
  cardH: 428,
  passwordTop: 832,
};

const chips = ['General', 'Email', 'Message', 'Notes'] as const;

const SENTENCE = 'I think we should ship on Monday.';

/** Notes profile output from `Murmur --cleanup-check`, measured on 2026-11-06. */
const NOTES_ITEMS = ['Sunscreen', 'A first aid kit', 'Chargers for everything'];

const Check: React.FC = () => (
  <svg width={34} height={34} viewBox="0 0 34 34" fill="none">
    <path
      d="M6 18.5 L14 26 L28 9"
      stroke={color.ink}
      strokeWidth={3.6}
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </svg>
);

const cardText: React.CSSProperties = {
  fontFamily: font.serif,
  fontSize: 62,
  lineHeight: 1.3,
  color: color.ink,
  whiteSpace: 'nowrap',
};

export const FitScene: React.FC = () => {
  const frame = useCurrentFrame();
  const t = (frame + SCENE_START.fit) / FPS;

  // Which chip is selected, as a fractional index.
  const selected = interpolate(
    t,
    [22.25, 22.7, 23.4, 23.85, 24.55, 25.0],
    [0, 1, 1, 2, 2, 3],
    {
      extrapolateLeft: 'clamp',
      extrapolateRight: 'clamp',
      easing: ease.inOut,
    },
  );

  const layer = (inFrom: number, inTo: number, outFrom: number, outTo: number): React.CSSProperties => {
    const o = window(t, inFrom, inTo, outFrom, outTo);
    return {
      position: 'absolute',
      left: 72,
      right: 72,
      top: 0,
      bottom: 0,
      display: 'flex',
      flexDirection: 'column',
      justifyContent: 'center',
      opacity: o,
      translate: `0px ${(1 - progress(t, inFrom, inTo, ease.out)) * 14}px`,
    };
  };

  return (
    <AbsoluteFill style={{background: color.pane}}>
      <Headline
        lines={[[{text: 'Fits the place it '}, {text: 'lands.', italic: true}]]}
        size={128}
        left={L.left}
        top={92}
        time={t}
        inFrom={20.95}
        inTo={21.7}
      />

      {/* Chip surfaces */}
      {chips.map((name, i) => {
        const p = progress(t, 21.2 + i * 0.08, 21.7 + i * 0.08, ease.out);
        return (
          <div
            key={name}
            style={{
              position: 'absolute',
              left: L.left,
              top: L.chipTop + i * L.chipPitch,
              width: L.chipW,
              height: L.chipH,
              boxSizing: 'border-box',
              borderRadius: 22,
              background: color.card,
              border: `2px solid ${color.hairline}`,
              opacity: p,
              translate: `0px ${(1 - p) * 18}px`,
            }}
          />
        );
      })}

      {/* The selected state: cream fill, ink stroke, check glyph */}
      <div
        style={{
          position: 'absolute',
          left: L.left,
          top: L.chipTop + selected * L.chipPitch,
          width: L.chipW,
          height: L.chipH,
          boxSizing: 'border-box',
          borderRadius: 22,
          background: color.selected,
          border: `3px solid ${color.ink}`,
          opacity: progress(t, 21.5, 21.9, ease.out),
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'flex-end',
          paddingRight: 34,
        }}
      >
        <Check />
      </div>

      {/* Chip labels */}
      {chips.map((name, i) => {
        const p = progress(t, 21.2 + i * 0.08, 21.7 + i * 0.08, ease.out);
        return (
          <div
            key={name}
            style={{
              position: 'absolute',
              left: L.left + 40,
              top: L.chipTop + i * L.chipPitch,
              height: L.chipH,
              display: 'flex',
              alignItems: 'center',
              fontFamily: font.sans,
              fontSize: 38,
              fontWeight: 500,
              color: color.ink,
              opacity: p,
              translate: `0px ${(1 - p) * 18}px`,
            }}
          >
            {name}
          </div>
        );
      })}

      {/* The result card */}
      <div
        style={{
          position: 'absolute',
          left: L.cardX,
          top: L.chipTop,
          width: L.cardW,
          height: L.cardH,
          boxSizing: 'border-box',
          borderRadius: 28,
          background: color.card,
          border: `2px solid ${color.hairline}`,
          opacity: progress(t, 21.45, 21.95, ease.out),
        }}
      >
        <div style={layer(21.6, 22.0, 22.2, 22.45)}>
          <div style={cardText}>{SENTENCE}</div>
        </div>
        <div style={layer(22.4, 22.85, 23.35, 23.6)}>
          <div style={cardText}>Hi,</div>
          <div style={{...cardText, marginTop: 30}}>{SENTENCE}</div>
          <div style={{...cardText, marginTop: 30}}>Thanks,</div>
        </div>
        <div style={layer(23.55, 24.0, 24.6, 24.85)}>
          <div style={cardText}>I think we should ship on Monday</div>
        </div>
        <div style={layer(24.75, 25.15, 1e9, 1e9 + 1)}>
          <div style={{...cardText, fontSize: 54}}>For the trip we need to pack:</div>
          {NOTES_ITEMS.map((item, i) => (
            <div key={item} style={{...cardText, fontSize: 54, marginTop: i === 0 ? 14 : 4, paddingLeft: 48}}>
              {'- '}
              {item}
            </div>
          ))}
        </div>
      </div>

      {/* Cleanup lays out words you said; it does not add a greeting of its own. */}
      <div
        style={{
          position: 'absolute',
          left: L.left,
          top: L.passwordTop,
          height: 88,
          display: 'flex',
          alignItems: 'center',
          fontFamily: font.sans,
          fontSize: 44,
          fontWeight: 500,
          color: color.ink,
          whiteSpace: 'nowrap',
          opacity: progress(t, 22.5, 22.9, ease.out) * (1 - progress(t, 23.3, 23.55, ease.out)),
        }}
      >
        Your greeting and sign-off get their own lines.
      </div>

      {/* Notes turns three or more spoken items into a list. This text is S1-mini's own output. */}
      <div
        style={{
          position: 'absolute',
          left: L.left,
          top: L.passwordTop,
          height: 88,
          display: 'flex',
          alignItems: 'center',
          fontFamily: font.sans,
          fontSize: 44,
          fontWeight: 500,
          color: color.ink,
          whiteSpace: 'nowrap',
          opacity: progress(t, 24.95, 25.4, ease.out) * (1 - progress(t, 25.95, 26.2, ease.out)),
        }}
      >
        Say three or more items and Notes writes a list.
      </div>

      {/* Password fields */}
      <div
        style={{
          position: 'absolute',
          left: L.left,
          top: L.passwordTop,
          height: 88,
          display: 'flex',
          alignItems: 'center',
          gap: 44,
          opacity: progress(t, 26.25, 26.8, ease.out),
          translate: `0px ${(1 - progress(t, 26.25, 26.8, ease.out)) * 16}px`,
        }}
      >
        <div
          style={{
            width: 360,
            height: 88,
            boxSizing: 'border-box',
            borderRadius: 22,
            background: color.field,
            border: `2px solid ${color.hairline}`,
            display: 'flex',
            alignItems: 'center',
            gap: 18,
            paddingLeft: 34,
          }}
        >
          {Array.from({length: 8}, (_, i) => (
            <div
              key={i}
              style={{width: 20, height: 20, borderRadius: 10, background: color.ink}}
            />
          ))}
        </div>
        <div
          style={{
            fontFamily: font.sans,
            fontSize: 44,
            fontWeight: 500,
            color: color.ink,
            whiteSpace: 'nowrap',
          }}
        >
          Password fields stay untouched.
        </div>
      </div>
    </AbsoluteFill>
  );
};
