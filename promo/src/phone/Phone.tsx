import React from 'react';
import {color, ease, font, progress} from '../theme';
import {TalkKey} from './TalkKey';
import {MOMENT, PHONE_SENTENCE, phoneVoiceLevel} from './timing';

/**
 * An iPhone 15 Pro (393 x 852 pt) in a chat, with Murmur's keyboard up. Everything is laid
 * out in points; the caller scales the whole device. The keyboard follows
 * ios/Keyboard/KeyboardView.swift: the history key and the talk key, a punctuation row with
 * shift and delete, then 123, emoji, hide, space and return. Light appearance.
 */
export const SCREEN = {w: 393, h: 852, radius: 55} as const;
export const BEZEL = 7;

const KB = {
  ground: '#D3D5DB',
  letter: '#FFFFFF',
  fn: '#ABB0BD',
  shadow: '#888A8F',
  padding: 6,
  rowSpacing: 10,
  keySpacing: 6,
  talkHeight: 48,
  keyHeight: 44,
  radius: 8,
  fnWidth: 44,
  returnWidth: 92,
  historyWidth: 40,
  /** The system's strip under a custom keyboard: the globe and the home indicator. */
  strip: 46,
} as const;

const KB_HEIGHT = KB.padding * 2 + KB.talkHeight + KB.keyHeight * 2 + KB.rowSpacing * 2;
export const KB_TOP = SCREEN.h - KB.strip - KB_HEIGHT;
const INNER = SCREEN.w - KB.padding * 2;
const TALK_WIDTH = INNER - KB.historyWidth - KB.keySpacing;

/** Where the talk key's centre sits on the screen, for touches. */
export const TALK_CENTER = {
  x: KB.padding + KB.historyWidth + KB.keySpacing + TALK_WIDTH / 2,
  y: KB_TOP + KB.padding + KB.talkHeight / 2,
} as const;

const FIELD = {left: 52, right: 10, gapAbove: 8, oneLine: 36, twoLines: 58, send: 30} as const;

const ink = color.ink;

const Icon: React.FC<{children: React.ReactNode; size?: number}> = ({children, size = 20}) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    stroke={ink}
    strokeWidth={1.7}
    strokeLinecap="round"
    strokeLinejoin="round"
  >
    {children}
  </svg>
);

const icons = {
  history: (
    <Icon>
      <path d="M3.5 12a8.5 8.5 0 1 0 2.5-6" />
      <path d="M3 4.5v4h4" />
      <path d="M12 7.5V12l3 2" />
    </Icon>
  ),
  shift: (
    <Icon>
      <path d="M12 4 4 12.5h4.5V20h7v-7.5H20z" />
    </Icon>
  ),
  delete: (
    <Icon size={22}>
      <path d="M9 5h11a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H9l-6-7z" />
      <path d="m11.5 9.5 5 5m0-5-5 5" />
    </Icon>
  ),
  emoji: (
    <Icon>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M8.3 14.2a4.6 4.6 0 0 0 7.4 0" />
      <circle cx="9.2" cy="9.8" r="0.6" fill={ink} />
      <circle cx="14.8" cy="9.8" r="0.6" fill={ink} />
    </Icon>
  ),
  hide: (
    <Icon>
      <rect x="3" y="3.5" width="18" height="11" rx="2" />
      <path d="M7 7.5h.01M10.3 7.5h.01M13.7 7.5h.01M17 7.5h.01M8 11h8" />
      <path d="m9 18 3 2.5 3-2.5" />
    </Icon>
  ),
  globe: (
    <Icon size={24}>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M3.5 12h17M12 3.5c-3 3.4-3 13.6 0 17M12 3.5c3 3.4 3 13.6 0 17" />
    </Icon>
  ),
};

const Key: React.FC<{
  width?: number;
  fill?: string;
  children?: React.ReactNode;
  grow?: boolean;
}> = ({width, fill = KB.letter, children, grow}) => (
  <div
    style={{
      width,
      flex: grow ? 1 : undefined,
      height: KB.keyHeight,
      borderRadius: KB.radius,
      background: fill,
      boxShadow: `0 1px 0 ${KB.shadow}`,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      fontFamily: font.system,
      color: ink,
    }}
  >
    {children}
  </div>
);

const Row: React.FC<{children: React.ReactNode}> = ({children}) => (
  <div style={{display: 'flex', gap: KB.keySpacing, alignItems: 'center'}}>{children}</div>
);

const press = (t: number, at: number) =>
  progress(t, at - 0.04, at + 0.02, ease.out) * (1 - progress(t, at + 0.08, at + 0.2, ease.soft));

const Keyboard: React.FC<{t: number}> = ({t}) => {
  const recording = t >= MOMENT.firstTap && t < MOMENT.secondTap;
  const keyPress = Math.max(press(t, MOMENT.firstTap), press(t, MOMENT.secondTap));
  const chars = ['@', '.', ',', '?', '!', "'"];
  return (
    <div
      style={{
        position: 'absolute',
        left: 0,
        top: KB_TOP,
        width: SCREEN.w,
        height: KB_HEIGHT + KB.strip,
        background: KB.ground,
        padding: KB.padding,
        boxSizing: 'border-box',
        display: 'flex',
        flexDirection: 'column',
        gap: KB.rowSpacing,
      }}
    >
      <Row>
        <div
          style={{
            width: KB.historyWidth,
            height: KB.talkHeight,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          {icons.history}
        </div>
        <TalkKey
          width={TALK_WIDTH}
          height={KB.talkHeight}
          time={t}
          recording={recording}
          heard={t >= MOMENT.heard}
          level={phoneVoiceLevel(t)}
          press={keyPress}
        />
      </Row>
      <Row>
        <Key width={KB.fnWidth} fill={KB.fn}>
          {icons.shift}
        </Key>
        {chars.map((c) => (
          <Key key={c} grow>
            <span style={{fontSize: 22, lineHeight: 1}}>{c}</span>
          </Key>
        ))}
        <Key width={KB.fnWidth} fill={KB.fn}>
          {icons.delete}
        </Key>
      </Row>
      <Row>
        <Key width={KB.fnWidth} fill={KB.fn}>
          <span style={{fontSize: 16}}>123</span>
        </Key>
        <Key width={KB.fnWidth} fill={KB.fn}>
          {icons.emoji}
        </Key>
        <Key width={KB.fnWidth} fill={KB.fn}>
          {icons.hide}
        </Key>
        <Key grow />
        <Key width={KB.returnWidth} fill={KB.fn}>
          <span style={{fontSize: 16}}>return</span>
        </Key>
      </Row>
      <div style={{position: 'absolute', left: 22, top: KB_HEIGHT + 4}}>{icons.globe}</div>
    </div>
  );
};

type Bubble = {text: string; mine: boolean};

const THREAD: Bubble[] = [
  {text: 'Dinner at 8 still on?', mine: false},
  {text: 'Yes! Leaving work now.', mine: true},
  {text: "Are you close? We're about to order.", mine: false},
];

const BUBBLE = {font: 17, line: 22, padX: 13, padY: 8, maxWidth: 300, radius: 19} as const;
/** The sent sentence wraps to two lines at the bubble's width. */
const SENT_HEIGHT = BUBBLE.line * 2 + BUBBLE.padY * 2;

const BubbleView: React.FC<Bubble> = ({text, mine}) => (
  <div style={{display: 'flex', justifyContent: mine ? 'flex-end' : 'flex-start'}}>
    <div
      style={{
        maxWidth: BUBBLE.maxWidth,
        padding: `${BUBBLE.padY}px ${BUBBLE.padX}px`,
        borderRadius: BUBBLE.radius,
        background: mine ? color.hud : '#E9E9EB',
        color: mine ? color.inkOnDark : ink,
        fontFamily: font.system,
        fontSize: BUBBLE.font,
        lineHeight: `${BUBBLE.line}px`,
        letterSpacing: '-0.01em',
      }}
    >
      {text}
    </div>
  </div>
);

export const Phone: React.FC<{t: number}> = ({t}) => {
  const landed = t >= MOMENT.textLands && t < MOMENT.sendTap + 0.05;
  const grow =
    progress(t, MOMENT.textLands, MOMENT.textLands + 0.12, ease.out) *
    (1 - progress(t, MOMENT.sendTap + 0.05, MOMENT.sendTap + 0.2, ease.out));
  const fieldHeight = FIELD.oneLine + (FIELD.twoLines - FIELD.oneLine) * grow;
  const fieldBottom = KB_TOP - FIELD.gapAbove;
  const fieldTop = fieldBottom - fieldHeight;
  const sent = progress(t, MOMENT.sendTap + 0.05, MOMENT.sendTap + 0.45, ease.out);
  const textIn = progress(t, MOMENT.textLands, MOMENT.textLands + 0.08, ease.out);

  return (
    <div
      style={{
        position: 'relative',
        width: SCREEN.w + BEZEL * 2,
        height: SCREEN.h + BEZEL * 2,
        borderRadius: SCREEN.radius + BEZEL,
        background: '#1B1A19',
        boxShadow: '0 0 0 1.5px #3A3734, 0 30px 60px rgba(28, 25, 23, 0.22)',
      }}
    >
      <div
        style={{
          position: 'absolute',
          left: BEZEL,
          top: BEZEL,
          width: SCREEN.w,
          height: SCREEN.h,
          borderRadius: SCREEN.radius,
          overflow: 'hidden',
          background: '#FFFFFF',
        }}
      >
        {/* Header */}
        <div
          style={{
            position: 'absolute',
            left: 0,
            top: 0,
            width: SCREEN.w,
            height: 120,
            display: 'flex',
            flexDirection: 'column',
            alignItems: 'center',
            justifyContent: 'flex-end',
            paddingBottom: 10,
            boxSizing: 'border-box',
            borderBottom: `0.5px solid ${color.hairline}`,
            fontFamily: font.system,
          }}
        >
          <div
            style={{
              width: 46,
              height: 46,
              borderRadius: 23,
              background: color.stat,
              color: '#FFFFFF',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: 20,
              fontWeight: 600,
            }}
          >
            S
          </div>
          <div style={{marginTop: 4, fontSize: 12, color: ink}}>Sam</div>
        </div>

        {/* Thread */}
        <div
          style={{
            position: 'absolute',
            left: 14,
            right: 14,
            bottom: SCREEN.h - fieldTop + 14,
            display: 'flex',
            flexDirection: 'column',
            gap: 6,
          }}
        >
          <div
            style={{
              textAlign: 'center',
              fontFamily: font.system,
              fontSize: 12,
              color: color.inkTertiary,
              marginBottom: 8,
            }}
          >
            Today 7:42 PM
          </div>
          {THREAD.map((b, i) => (
            <BubbleView key={i} {...b} />
          ))}
          <div
            style={{
              height: (SENT_HEIGHT + 0) * sent,
              opacity: sent,
              translate: `0px ${(1 - sent) * 18}px`,
              overflow: 'visible',
            }}
          >
            <BubbleView text={PHONE_SENTENCE} mine />
          </div>
        </div>

        {/* Input bar */}
        <div
          style={{
            position: 'absolute',
            left: 10,
            top: fieldBottom - FIELD.oneLine + 2,
            width: 32,
            height: 32,
            borderRadius: 16,
            background: '#E9E9EB',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
          }}
        >
          <Icon size={18}>
            <path d="M12 6v12M6 12h12" />
          </Icon>
        </div>
        <div
          style={{
            position: 'absolute',
            left: FIELD.left,
            top: fieldTop,
            width: SCREEN.w - FIELD.left - FIELD.right,
            height: fieldHeight,
            boxSizing: 'border-box',
            borderRadius: 18,
            border: `1px solid ${color.hairline}`,
            padding: `6px ${FIELD.send + 10}px 6px 14px`,
            fontFamily: font.system,
            fontSize: BUBBLE.font,
            lineHeight: `${BUBBLE.line}px`,
            letterSpacing: '-0.01em',
            color: landed ? ink : color.inkTertiary,
            overflow: 'hidden',
          }}
        >
          {landed ? <span style={{opacity: textIn}}>{PHONE_SENTENCE}</span> : 'Message'}
          <div
            style={{
              position: 'absolute',
              right: 4,
              bottom: 3,
              width: FIELD.send,
              height: FIELD.send,
              borderRadius: FIELD.send / 2,
              background: color.hud,
              opacity: landed ? textIn : 0,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              scale: `${1 - 0.12 * press(t, MOMENT.sendTap)}`,
            }}
          >
            <svg width={16} height={16} viewBox="0 0 24 24" fill="none">
              <path
                d="M12 19V5M6 11l6-6 6 6"
                stroke="#FFFFFF"
                strokeWidth={2.6}
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
          </div>
        </div>

        <Keyboard t={t} />

        {/* Home indicator */}
        <div
          style={{
            position: 'absolute',
            left: (SCREEN.w - 134) / 2,
            top: SCREEN.h - 9,
            width: 134,
            height: 5,
            borderRadius: 3,
            background: ink,
          }}
        />

        <Touch t={t} at={MOMENT.firstTap} x={TALK_CENTER.x} y={TALK_CENTER.y} />
        <Touch t={t} at={MOMENT.secondTap} x={TALK_CENTER.x} y={TALK_CENTER.y} />
        <Touch
          t={t}
          at={MOMENT.sendTap}
          x={SCREEN.w - FIELD.right - 4 - FIELD.send / 2}
          y={fieldBottom - 3 - FIELD.send / 2}
        />
      </div>
    </div>
  );
};

/** A fingertip: a soft disc that lands on the moment and lifts away. */
const Touch: React.FC<{t: number; at: number; x: number; y: number}> = ({t, at, x, y}) => {
  const down = progress(t, at - 0.12, at, ease.out);
  const up = progress(t, at + 0.1, at + 0.38, ease.soft);
  const opacity = down * (1 - up);
  if (opacity <= 0) return null;
  const size = 44;
  return (
    <div
      style={{
        position: 'absolute',
        left: x - size / 2,
        top: y - size / 2,
        width: size,
        height: size,
        borderRadius: size / 2,
        background: 'rgba(255, 255, 255, 0.4)',
        border: '1.5px solid rgba(28, 25, 23, 0.35)',
        boxSizing: 'border-box',
        opacity,
        scale: `${1.25 - 0.25 * down + 0.3 * up}`,
      }}
    />
  );
};
