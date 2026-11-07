import React from 'react';
import {Composition, Folder} from 'remotion';
import {FontGate} from './fonts';
import {MurmurPromo} from './MurmurPromo';
import {DictationScene} from './scenes/DictationScene';
import {Banner, BANNER_HEIGHT, BANNER_WIDTH} from './Banner';
import {EndCard} from './scenes/EndCard';
import {FitScene} from './scenes/FitScene';
import {MacScene} from './scenes/MacScene';
import {FPS, HEIGHT, SCENE_LENGTH, TOTAL_FRAMES, WIDTH} from './theme';

// Scene previews. They read the global clock, so a scene opened alone starts at the
// moment it has in the full video's timeline minus its lead-in.
const gated = (Scene: React.FC): React.FC => {
  const Gated: React.FC = () => (
    <FontGate>
      <Scene />
    </FontGate>
  );
  return Gated;
};

const DictationPreview = gated(DictationScene);
const MacPreview = gated(MacScene);
const FitPreview = gated(FitScene);
const EndPreview = gated(EndCard);
const BannerStill = gated(Banner);

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="MurmurPromo"
        component={MurmurPromo}
        width={WIDTH}
        height={HEIGHT}
        fps={FPS}
        durationInFrames={TOTAL_FRAMES}
      />
      <Composition
        id="Banner"
        component={BannerStill}
        width={BANNER_WIDTH}
        height={BANNER_HEIGHT}
        fps={FPS}
        durationInFrames={1}
      />
      <Folder name="Scenes">
        <Composition
          id="Dictation"
          component={DictationPreview}
          width={WIDTH}
          height={HEIGHT}
          fps={FPS}
          durationInFrames={SCENE_LENGTH.dictation}
        />
        <Composition
          id="OnYourMac"
          component={MacPreview}
          width={WIDTH}
          height={HEIGHT}
          fps={FPS}
          durationInFrames={SCENE_LENGTH.mac}
        />
        <Composition
          id="FitsThePlace"
          component={FitPreview}
          width={WIDTH}
          height={HEIGHT}
          fps={FPS}
          durationInFrames={SCENE_LENGTH.fit}
        />
        <Composition
          id="EndCard"
          component={EndPreview}
          width={WIDTH}
          height={HEIGHT}
          fps={FPS}
          durationInFrames={SCENE_LENGTH.end}
        />
      </Folder>
    </>
  );
};
