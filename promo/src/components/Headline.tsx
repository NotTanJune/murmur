import React from 'react';
import {color, font, progress, ease} from '../theme';

type Line = {text: string; italic?: boolean};

/**
 * A display line in Fraunces. The last word of every headline is italic.
 * Fades up in `inFrom..inTo` (seconds on the caller's clock), fades out `outFrom..outTo`.
 */
export const Headline: React.FC<{
  lines: Line[][];
  size: number;
  left: number;
  top: number;
  time: number;
  inFrom: number;
  inTo: number;
  outFrom?: number;
  outTo?: number;
  fill?: string;
  lineHeight?: number;
}> = ({
  lines,
  size,
  left,
  top,
  time,
  inFrom,
  inTo,
  outFrom = 1e9,
  outTo = 1e9 + 1,
  fill = color.ink,
  lineHeight = 1,
}) => {
  const enter = progress(time, inFrom, inTo, ease.out);
  const leave = progress(time, outFrom, outTo, ease.in);
  return (
    <div
      style={{
        position: 'absolute',
        left,
        top,
        fontFamily: font.serif,
        fontSize: size,
        fontWeight: 400,
        lineHeight,
        letterSpacing: '-0.012em',
        color: fill,
        whiteSpace: 'nowrap',
        opacity: enter * (1 - leave),
        translate: `0px ${(1 - enter) * 32 - leave * 20}px`,
      }}
    >
      {lines.map((line, row) => (
        <div key={row}>
          {line.map((part, i) => (
            <span key={i} style={{fontStyle: part.italic ? 'italic' : 'normal'}}>
              {part.text}
            </span>
          ))}
        </div>
      ))}
    </div>
  );
};
