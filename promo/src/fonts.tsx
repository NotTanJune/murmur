import {loadFont} from '@remotion/fonts';
import React, {useEffect, useState} from 'react';
import {staticFile, useDelayRender} from 'remotion';

let loading: Promise<unknown> | null = null;

const loadAll = () =>
  Promise.all([
    loadFont({
      family: 'Fraunces',
      url: staticFile('fonts/Fraunces[SOFT,WONK,opsz,wght].ttf'),
      weight: '400 800',
      style: 'normal',
    }),
    loadFont({
      family: 'Fraunces',
      url: staticFile('fonts/Fraunces-Italic[SOFT,WONK,opsz,wght].ttf'),
      weight: '400 800',
      style: 'italic',
    }),
    loadFont({
      family: 'Figtree',
      url: staticFile('fonts/Figtree[wght].ttf'),
      weight: '300 900',
      style: 'normal',
    }),
  ]).then(() => document.fonts.ready);

/**
 * Holds the render until both families are loaded, and renders nothing before that so
 * anything that measures text only ever sees the real faces.
 */
export const FontGate: React.FC<{children: React.ReactNode}> = ({children}) => {
  const {delayRender, continueRender, cancelRender} = useDelayRender();
  const [handle] = useState(() => delayRender('Loading Fraunces and Figtree'));
  const [ready, setReady] = useState(false);

  useEffect(() => {
    loading ??= loadAll();
    loading
      .then(() => {
        setReady(true);
        continueRender(handle);
      })
      .catch((error) => cancelRender(error));
  }, [handle, continueRender, cancelRender]);

  return ready ? <>{children}</> : null;
};
