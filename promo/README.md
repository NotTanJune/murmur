# Murmur promo

Two 1920x1080, 30 fps promos for Murmur, built with Remotion: the Mac film (31 s,
`MurmurPromo`) and its iPhone keyboard companion (27.5 s, `MurmurPhonePromo`). They live in
their own folder and share nothing with the Swift package.

## Commands

Use yarn, not npm.

```console
yarn install
yarn dev        # Remotion Studio
yarn render     # out/murmur-promo.mp4
yarn phone      # out/murmur-iphone-promo.mp4, the iPhone keyboard film
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
scripts/master.sh out/murmur-promo.mp4 ../docs/media/murmur-promo.mp4
scripts/master.sh out/murmur-iphone-promo.mp4 ../docs/media/murmur-iphone-promo.mp4
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
- `src/PhonePromo.tsx` and `src/phone/` are the iPhone film: tap the key, talk, tap again,
  the text lands in a chat (`Phone.tsx`, `TalkKey.tsx`, drawn from
  `ios/Keyboard/KeyboardView.swift` and `DS.Keyboard`), then "On your iPhone", "Mac and
  iPhone" and the end card. `phone/timing.ts` holds its clock and the spoken sentence. It
  reuses the Mac film's bed, Mac key, done chime, ticks and end chord; `phone-tap.wav`,
  `send-swoosh.wav` and `sheet-whoosh.wav` were rendered by earshot 1.0.0 (`make`), which
  needs no credit. On 2026-11-22 `earshot critique` scored the mastered film "close", 20 of
  23 metrics in range; the one major note, "sparse", is the calm piano bed both films share
  (the Mac film scored "needs work", 15 of 23).