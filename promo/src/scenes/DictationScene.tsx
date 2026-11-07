import {measureText} from '@remotion/layout-utils';
import React, {useMemo} from 'react';
import {AbsoluteFill, interpolateColors, useCurrentFrame} from 'remotion';
import {Capsule} from '../components/Capsule';
import {Headline} from '../components/Headline';
import {KeyCap} from '../components/KeyCap';
import {FINAL_LINES, RECOGNIZER_LAG, SPOKEN, STRIKES, voiceLevel} from '../script';
import {color, ease, FPS, font, progress} from '../theme';

const L = {
  left: 128,
  doc: {x: 744, y: 150, w: 1048, h: 520},
  // Fraunces sets wider than the old serif: 66 px keeps the longest line inside the card.
  text: {size: 66, line: 96, padX: 96, padTop: 92},
  key: {x: 128, y: 662, scale: 1.25},
  capsule: {centerX: 1268, top: 744},
  headTop: 176,
  headSize: 152,
};

const measure = (text: string) =>
  measureText({
    text,
    fontFamily: font.serif,
    fontSize: L.text.size,
    fontWeight: 400,
    validateFontIsLoaded: true,
  }).width;

/** Left edge of each word when the words are set on one line separated by spaces. */
const offsets = (words: string[]) =>
  words.map((word, i) => (i === 0 ? 0 : measure(words.slice(0, i + 1).join(' ')) - measure(word)));

type Layout = {rawX: number[]; rawW: number[]; finalX: number[]; finalW: number[]; finalLine: number[]};

const buildLayout = (): Layout => {
  const rawX: number[] = [];
  const rawW = SPOKEN.map((w) => measure(w.text));
  for (const line of [0, 1]) {
    const idx = SPOKEN.map((w, i) => (w.line === line ? i : -1)).filter((i) => i >= 0);
    const xs = offsets(idx.map((i) => SPOKEN[i].text));
    idx.forEach((i, k) => (rawX[i] = xs[k]));
  }
  const finalX: number[] = SPOKEN.map(() => 0);
  const finalW: number[] = SPOKEN.map(() => 0);
  const finalLine: number[] = SPOKEN.map(() => 0);
  FINAL_LINES.forEach((indices, line) => {
    const texts = indices.map((i) => SPOKEN[i].final ?? SPOKEN[i].text);
    const xs = offsets(texts);
    indices.forEach((i, k) => {
      finalX[i] = xs[k];
      finalW[i] = measure(texts[k]);
      finalLine[i] = line;
    });
  });
  return {rawX, rawW, finalX, finalW, finalLine};
};

export const DictationScene: React.FC = () => {
  const frame = useCurrentFrame();
  const t = frame / FPS;
  const layout = useMemo(buildLayout, []);

  // ---- Clock for the three beats ------------------------------------------------
  const arrive = (i: number) => SPOKEN[i].a + RECOGNIZER_LAG;
  const glide = progress(t, 12.1, 13.0, ease.inOut);
  const swap = progress(t, 13.1, 13.4, ease.inOut);
  const settle = progress(t, 11.8, 15.1, (x) => x);

  // ---- Key ------------------------------------------------------------------------
  const keyAppear = progress(t, 0.7, 1.5, ease.out);
  const pressed =
    progress(t, 2.4, 2.55, ease.out) * (1 - progress(t, 10.0, 10.42, ease.soft));

  // ---- Capsule --------------------------------------------------------------------
  const capsuleIn = progress(t, 4.15, 5.0, ease.spring);
  const capsuleOut = progress(t, 10.0, 10.5, ease.in);
  const capsuleOpacity = progress(t, 4.15, 4.55, ease.out) * (1 - capsuleOut);
  const capsuleShift = (1 - capsuleIn) * 190 + capsuleOut * 110;

  // ---- Document -------------------------------------------------------------------
  const docIn = progress(t, 0, 1.0, ease.out);

  // ---- Caret: follows the end of the newest word ---------------------------------
  const arrived = SPOKEN.map((_, i) => i).filter((i) => arrive(i) <= t);
  const last = arrived.length ? arrived[arrived.length - 1] : -1;
  const lastIndex = SPOKEN.length - 1;
  const xOf = (i: number) =>
    SPOKEN[i].kind === 'keep'
      ? layout.rawX[i] + (layout.finalX[i] - layout.rawX[i]) * glide
      : layout.rawX[i];
  const widthOf = (i: number) =>
    i === lastIndex
      ? layout.rawW[i] + (layout.finalW[i] - layout.rawW[i]) * swap
      : layout.rawW[i];
  const endOf = (i: number) => xOf(i) + widthOf(i) + 7;
  const entered = (i: number) => progress(t, arrive(i), arrive(i) + 0.22, ease.out);
  let caretX = 0;
  let caretLine = 0;
  if (last >= 0) {
    caretLine = SPOKEN[last].line;
    const previous = last > 0 && SPOKEN[last - 1].line === caretLine ? endOf(last - 1) : 0;
    caretX = previous + (endOf(last) - previous) * entered(last);
  }
  const blink = Math.min(1, Math.max(0, 1.7 * Math.cos((2 * Math.PI * frame) / 36) + 0.55));
  const caretShown = t > 0.55 ? blink : 0;

  const wordStyle = (i: number): React.CSSProperties => {
    const word = SPOKEN[i];
    const enter = progress(t, arrive(i), arrive(i) + 0.22, ease.out);
    const struck = STRIKES.find((s) => (s.words as readonly number[]).includes(i));
    const collapse = struck ? progress(t, struck.fadeFrom, struck.fadeFrom + 0.4, ease.inOut) : 0;
    const order = FINAL_LINES.flat().indexOf(i);
    const ink = progress(t, 12.9 + order * 0.045, 13.45 + order * 0.045, ease.inOut);
    return {
      position: 'absolute',
      left: xOf(i),
      top: word.line * L.text.line,
      fontFamily: font.serif,
      fontSize: L.text.size,
      lineHeight: `${L.text.line}px`,
      whiteSpace: 'pre',
      color: interpolateColors(ink, [0, 1], [color.inkSecondary, color.ink]),
      opacity: enter * (1 - collapse),
      translate: `0px ${(1 - enter) * 10}px`,
      scale: `${1 - collapse * 0.35}`,
      transformOrigin: '50% 60%',
    };
  };

  return (
    <AbsoluteFill style={{background: color.chrome}}>
     <AbsoluteFill style={{opacity: 1 - progress(t, 14.75, 15.1, ease.in)}}>
      {/* Headlines, one after the other, last word italic */}
      <Headline
        lines={[[{text: 'Hold a'}], [{text: 'key.', italic: true}]]}
        size={L.headSize}
        left={L.left}
        top={L.headTop}
        time={t}
        inFrom={0.35}
        inTo={1.15}
        outFrom={3.7}
        outTo={4.05}
      />
      <Headline
        lines={[[{text: 'Talk.', italic: true}]]}
        size={L.headSize}
        left={L.left}
        top={L.headTop}
        time={t}
        inFrom={4.1}
        inTo={4.85}
        outFrom={9.7}
        outTo={10.02}
      />
      <Headline
        lines={[[{text: 'Release.', italic: true}]]}
        size={L.headSize}
        left={L.left}
        top={L.headTop}
        time={t}
        inFrom={10.1}
        inTo={10.85}
      />

      {/* The document */}
      <div
        style={{
          position: 'absolute',
          left: L.doc.x,
          top: L.doc.y,
          width: L.doc.w,
          height: L.doc.h,
          boxSizing: 'border-box',
          borderRadius: 32,
          background: color.pane,
          border: `2px solid ${color.hairline}`,
          opacity: docIn,
          translate: `0px ${(1 - docIn) * 28}px`,
          scale: `${1 + settle * 0.025}`,
          transformOrigin: '50% 40%',
        }}
      >
        <div
          style={{
            position: 'absolute',
            left: L.text.padX - 2,
            top: L.text.padTop - 2,
          }}
        >
          {SPOKEN.map((word, i) => {
            const isLast = i === lastIndex;
            return (
              <React.Fragment key={i}>
                <div style={{...wordStyle(i), opacity: wordStyle(i).opacity as number * (isLast ? 1 - swap : 1)}}>
                  {word.text}
                </div>
                {isLast ? (
                  <div style={{...wordStyle(i), opacity: wordStyle(i).opacity as number * swap}}>
                    {word.final}
                  </div>
                ) : null}
              </React.Fragment>
            );
          })}

          {/* Strokes that strike out the fillers and the false start */}
          {STRIKES.map((strike, k) => {
            const first = strike.words[0];
            const lastWord = strike.words[strike.words.length - 1];
            const x0 = layout.rawX[first];
            const x1 = layout.rawX[lastWord] + layout.rawW[lastWord];
            const draw = progress(t, strike.from, strike.to, ease.inOut);
            const fade = progress(t, strike.fadeFrom, strike.fadeFrom + 0.4, ease.inOut);
            return (
              <div
                key={k}
                style={{
                  position: 'absolute',
                  left: x0 - 4,
                  top: SPOKEN[first].line * L.text.line + L.text.line * 0.56,
                  width: (x1 - x0 + 8) * draw,
                  height: 4,
                  borderRadius: 2,
                  background: color.ink,
                  opacity: 1 - fade,
                }}
              />
            );
          })}

          <div
            style={{
              position: 'absolute',
              left: caretX,
              top: caretLine * L.text.line + 14,
              width: 4,
              height: 80,
              borderRadius: 2,
              background: color.ink,
              opacity: caretShown,
            }}
          />
        </div>
      </div>

      {/* The key */}
      <KeyCap
        left={L.key.x}
        top={L.key.y}
        pressed={pressed}
        ripple={progress(t, 2.4, 3.1, ease.out)}
        scale={L.key.scale}
        opacity={keyAppear}
        translateY={(1 - keyAppear) * 26}
      />

      {/* The listening capsule */}
      <Capsule
        centerX={L.capsule.centerX}
        top={L.capsule.top}
        level={voiceLevel(t)}
        time={t}
        opacity={capsuleOpacity}
        translateY={capsuleShift}
      />
     </AbsoluteFill>
    </AbsoluteFill>
  );
};
