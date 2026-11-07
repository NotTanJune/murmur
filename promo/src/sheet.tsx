import type {
  TransitionPresentation,
  TransitionPresentationComponentProps,
} from '@remotion/transitions';
import React from 'react';
import {AbsoluteFill} from 'remotion';
import {ease} from './theme';

type SheetProps = Record<string, never>;

/**
 * The next scene rises over the current one like a page being laid on top; the current
 * scene drifts up a little as it is covered. The corners square off as it lands.
 */
const SheetPresentation: React.FC<TransitionPresentationComponentProps<SheetProps>> = ({
  children,
  presentationDirection,
  presentationProgress,
}) => {
  const eased = ease.inOut(presentationProgress);
  if (presentationDirection === 'entering') {
    return (
      <AbsoluteFill
        style={{
          translate: `0px ${(1 - eased) * 100}%`,
          borderRadius: `${(1 - eased) * 56}px ${(1 - eased) * 56}px 0 0`,
          overflow: 'hidden',
        }}
      >
        {children}
      </AbsoluteFill>
    );
  }
  return <AbsoluteFill style={{translate: `0px ${-eased * 140}px`}}>{children}</AbsoluteFill>;
};

export const sheet = (): TransitionPresentation<SheetProps> => ({
  component: SheetPresentation,
  props: {},
});
