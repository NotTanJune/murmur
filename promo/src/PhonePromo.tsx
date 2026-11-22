import {linearTiming, TransitionSeries} from '@remotion/transitions';
import {fade} from '@remotion/transitions/fade';
import {Audio} from '@remotion/media';
import React from 'react';
import {AbsoluteFill, Sequence, staticFile} from 'remotion';
import {FontGate} from './fonts';
import {IPhoneScene} from './phone/scenes/IPhoneScene';
import {KeyboardScene} from './phone/scenes/KeyboardScene';
import {PairScene} from './phone/scenes/PairScene';
import {PhoneEndCard} from './phone/scenes/PhoneEndCard';
import {MOMENT, PHONE_LENGTH, PHONE_TRANSITION} from './phone/timing';
import {sheet} from './sheet';
import {color, FPS} from './theme';

/**
 * The iPhone keyboard's film, the Mac film's companion: same paper, type, bed and end chord.
 * The bed, the Mac key, the done chime, the ticks and the end chord are the Mac film's
 * (CREDITS.md). The phone tap, the send swoosh and the end-card whoosh are new, rendered by
 * earshot 1.0.0 (`tap/fingertip` and `send/swoosh` at seed 4, `whoosh/airy` take 2 at seed 2),
 * free to use without credit.
 * `at` is when the sound should be heard; `lead` is the file's own time to its peak.
 */
const BED = {file: 'bed-soft-piano', volume: 0.8, fadeIn: 0.4, fadeOutFrom: 21.9, fadeOutTo: 23.3};

const CUES: {file: string; at: number; lead: number; volume: number}[] = [
  {file: 'phone-tap', at: MOMENT.firstTap, lead: 0.1, volume: 0.22},
  {file: 'phone-tap', at: MOMENT.secondTap, lead: 0.1, volume: 0.22},
  {file: 'done-chime', at: MOMENT.textLands, lead: 0, volume: 0.45},
  {file: 'send-swoosh', at: MOMENT.sendTap + 0.06, lead: 0.04, volume: 0.6},
  {file: 'tick', at: 12.45, lead: 0, volume: 0.45},
  {file: 'tick', at: 13.1, lead: 0, volume: 0.45},
  {file: 'tick', at: 13.75, lead: 0, volume: 0.45},
  {file: 'key-press', at: 18.95, lead: 0.07, volume: 0.8},
  {file: 'phone-tap', at: 19.95, lead: 0.1, volume: 0.22},
  {file: 'phone-tap', at: 21.05, lead: 0.1, volume: 0.22},
  {file: 'sheet-whoosh', at: 23.0, lead: 0.08, volume: 0.4},
  {file: 'end', at: 23.9, lead: 0, volume: 0.8},
];

const bedVolume = (frame: number): number => {
  const t = frame / FPS;
  const fadeIn = Math.min(1, t / BED.fadeIn);
  const fadeOut = 1 - Math.min(1, Math.max(0, (t - BED.fadeOutFrom) / (BED.fadeOutTo - BED.fadeOutFrom)));
  return BED.volume * fadeIn * fadeOut;
};

export const PhonePromo: React.FC = () => (
  <FontGate>
    <AbsoluteFill style={{background: color.chrome}}>
      <Sequence name="music bed" durationInFrames={Math.round(BED.fadeOutTo * FPS)}>
        <Audio src={staticFile(`sfx/${BED.file}.wav`)} volume={bedVolume} />
      </Sequence>
      {CUES.map((cue, i) => (
        <Sequence key={i} from={Math.round((cue.at - cue.lead) * FPS)} name={`sfx ${cue.file}`}>
          <Audio src={staticFile(`sfx/${cue.file}.wav`)} volume={cue.volume} />
        </Sequence>
      ))}
      <TransitionSeries>
        <TransitionSeries.Sequence name="Tap, talk, tap" durationInFrames={PHONE_LENGTH.keyboard}>
          <KeyboardScene />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition
          presentation={fade()}
          timing={linearTiming({durationInFrames: PHONE_TRANSITION.toIPhone})}
        />
        <TransitionSeries.Sequence name="On your iPhone" durationInFrames={PHONE_LENGTH.iphone}>
          <IPhoneScene />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition
          presentation={fade()}
          timing={linearTiming({durationInFrames: PHONE_TRANSITION.toPair})}
        />
        <TransitionSeries.Sequence name="Mac and iPhone" durationInFrames={PHONE_LENGTH.pair}>
          <PairScene />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition
          presentation={sheet()}
          timing={linearTiming({durationInFrames: PHONE_TRANSITION.toEnd})}
        />
        <TransitionSeries.Sequence name="End card" durationInFrames={PHONE_LENGTH.end}>
          <PhoneEndCard />
        </TransitionSeries.Sequence>
      </TransitionSeries>
    </AbsoluteFill>
  </FontGate>
);
