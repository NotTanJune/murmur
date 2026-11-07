# Murmur promo

A 30 second, 1920x1080, 30 fps promo for Murmur, built with Remotion. It lives in its own
folder and shares nothing with the Swift package.

## Commands

Use yarn, not npm.

```console
yarn install
yarn dev        # Remotion Studio
yarn render     # out/murmur-promo.mp4
yarn poster     # out/murmur-poster.png, frame 880 of the end card
yarn banner     # out/murmur-banner.png, the README banner (src/Banner.tsx)
yarn demo       # out/murmur-demo.mp4, the README demo: public/demo-capture.mp4 with overlays (src/Demo.tsx)
```

Renders are CPU heavy. `remotion.config.ts` caps concurrency at 2; run them niced too:

```console
nice -n 19 yarn render
```

After `yarn render`, run the two-pass -16 LUFS master:

```console
scripts/master.sh out/murmur-promo.mp4 docs/media/murmur-promo.mp4
```

## Layout

- `src/MurmurPromo.tsx` joins the four scenes. Cuts fall at 15 s, 21 s and 26 s.
- `src/scenes/` holds one file per scene. The first covers "Hold a key", "Talk" and
  "Release" as one continuous take.
- `src/script.ts` is the dictated sentence, its timings and the voice envelope that drives
  the capsule bars.
- `src/theme.ts` has the colours (Murmur's design tokens), easing and the scene clock.
- `public/fonts/` is Fraunces and Figtree, each with its OFL
  licence.

- `public/sfx/` holds the sound: a soft piano bed that fades out before the end chord,
  and the cues (key press and release, the done chime, the profile ticks and the end
  chord). The bed, key press and chime are Creative Commons recordings from Freesound, found
  through the Openverse API and ranked with [earshot](https://github.com/Leonxlnx/earshot);
  `CREDITS.md` names each author and licence. `scripts/make-sfx.py` synthesizes the rest
  (needs numpy). `src/MurmurPromo.tsx` places everything on the global clock.