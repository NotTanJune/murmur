import {linearTiming, TransitionSeries} from '@remotion/transitions';
import {fade} from '@remotion/transitions/fade';
import React from 'react';
import {AbsoluteFill, Sequence, staticFile} from 'remotion';
import {Audio} from '@remotion/media';
import {FontGate} from './fonts';
import {DictationScene} from './scenes/DictationScene';
import {EndCard} from './scenes/EndCard';
import {FitScene} from './scenes/FitScene';
import {MacScene} from './scenes/MacScene';
import {sheet} from './sheet';
import {color, FPS, SCENE_LENGTH, TRANSITION} from './theme';

/**
 * Cuts fall at 15 s, 21 s and 26 s. Each transition is centred on its cut, so a scene
 * runs half a transition past its nominal end and starts half a transition early.
 */
/**
 * Sound. A quiet piano bed runs from the first frame and fades out just before the end
 * chord, so the chord lands on a short silence. Seven cues sit on the global clock
 * (seconds). The bed, the key press and the done chime are Creative Commons recordings
 * found through Openverse and chosen with earshot; the rest are synthesized in
 * `scripts/make-sfx.py`. CREDITS.md lists every recording with its author and licence.
 */
const BED = {file: 'bed-soft-piano', volume: 0.8, fadeIn: 0.4, fadeOutFrom: 25.2, fadeOutTo: 26.6};

const CUES: {file: string; at: number; volume: number}[] = [
  {file: 'key-press', at: 2.4, volume: 0.8},
  {file: 'key-up', at: 10.0, volume: 0.7},
  {file: 'done-chime', at: 12.9, volume: 0.45},
  {file: 'tick', at: 22.25, volume: 0.45},
  {file: 'tick', at: 23.4, volume: 0.45},
  {file: 'tick', at: 24.55, volume: 0.45},
  {file: 'end', at: 26.9, volume: 0.8},
];

/** Bed level at a global frame. The recording is 25.3 s, so it is never looped. */
const bedVolume = (frame: number): number => {
  const t = frame / FPS;
  const fadeIn = Math.min(1, t / BED.fadeIn);
  const fadeOut = 1 - Math.min(1, Math.max(0, (t - BED.fadeOutFrom) / (BED.fadeOutTo - BED.fadeOutFrom)));
  return BED.volume * fadeIn * fadeOut;
};

export const MurmurPromo: React.FC = () => (
  <FontGate>
    <AbsoluteFill style={{background: color.chrome}}>
      <Sequence name="music bed" durationInFrames={Math.round(BED.fadeOutTo * FPS)}>
        <Audio src={staticFile(`sfx/${BED.file}.wav`)} volume={bedVolume} />
      </Sequence>
      {CUES.map((cue, i) => (
        <Sequence key={i} from={Math.round(cue.at * FPS)} name={`sfx ${cue.file}`}>
          <Audio src={staticFile(`sfx/${cue.file}.wav`)} volume={cue.volume} />
        </Sequence>
      ))}
      <TransitionSeries>
        <TransitionSeries.Sequence name="Hold, talk, release" durationInFrames={SCENE_LENGTH.dictation}>
          <DictationScene />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition
          presentation={fade()}
          timing={linearTiming({durationInFrames: TRANSITION.toMac})}
        />
        <TransitionSeries.Sequence name="On your Mac" durationInFrames={SCENE_LENGTH.mac}>
          <MacScene />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition
          presentation={fade()}
          timing={linearTiming({durationInFrames: TRANSITION.toFit})}
        />
        <TransitionSeries.Sequence name="Fits the place it lands" durationInFrames={SCENE_LENGTH.fit}>
          <FitScene />
        </TransitionSeries.Sequence>
        <TransitionSeries.Transition
          presentation={sheet()}
          timing={linearTiming({durationInFrames: TRANSITION.toEnd})}
        />
        <TransitionSeries.Sequence name="End card" durationInFrames={SCENE_LENGTH.end}>
          <EndCard />
        </TransitionSeries.Sequence>
      </TransitionSeries>
    </AbsoluteFill>
  </FontGate>
);
