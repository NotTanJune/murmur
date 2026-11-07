"""Synthesizes every sound cue in the promo into public/sfx/.

Sine waves and filtered noise only, so nothing is sampled or downloaded. Run with
`python3 scripts/make-sfx.py` from the promo folder; needs numpy.
"""
import os
import wave

import numpy as np

SR = 48000
OUT = os.path.join(os.path.dirname(__file__), "..", "public", "sfx")


def env(n, attack, decay, curve=3.0):
    t = np.linspace(0, 1, n)
    e = np.minimum(t / max(attack, 1e-6), 1.0) * np.exp(-curve * t / max(decay, 1e-6))
    return np.clip(e, 0, 1)


def tone(f, sec, amp=0.3, attack=0.004, decay=0.5, curve=4.0, harmonics=((1, 1.0), (2, 0.25), (3, 0.08))):
    n = int(SR * sec)
    t = np.arange(n) / SR
    y = np.zeros(n)
    for k, g in harmonics:
        y += g * np.sin(2 * np.pi * f * k * t)
    return y * env(n, attack, decay, curve) * amp


def click(sec=0.045, amp=0.5, lowpass=0.35, pitch=1800.0):
    n = int(SR * sec)
    noise = np.random.default_rng(3).standard_normal(n)
    body = np.zeros(n)
    acc = 0.0
    for i in range(n):
        acc = acc + lowpass * (noise[i] - acc)
        body[i] = acc
    t = np.arange(n) / SR
    thump = np.sin(2 * np.pi * pitch * t) * np.exp(-t * 220)
    return (0.6 * body / np.max(np.abs(body)) + 0.7 * thump) * env(n, 0.001, 0.25, 5.0) * amp


def write(name, y):
    y = np.concatenate([np.clip(y, -1, 1), np.zeros(int(SR * 0.02))])
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((y * 32767).astype("<i2").tobytes())
    print(name, f"{len(y) / SR:.3f}s peak {np.max(np.abs(y)):.2f}")


os.makedirs(OUT, exist_ok=True)
write("key-down.wav", click(0.05, 0.55, 0.32, 1500))
write("key-up.wav", click(0.04, 0.38, 0.45, 2300))

resolve = np.zeros(int(SR * 0.9))
low = tone(523.25, 0.9, 0.22, 0.01, 0.45, 4.5)
high = tone(783.99, 0.75, 0.17, 0.01, 0.45, 4.5)
resolve[: len(low)] += low
resolve[int(SR * 0.11) : int(SR * 0.11) + len(high)] += high
write("resolve.wav", resolve)

write("tick.wav", click(0.022, 0.22, 0.5, 3200))

end = np.zeros(int(SR * 2.8))
for f, g in ((130.81, 0.5), (196.0, 0.35), (261.63, 0.25), (392.0, 0.12)):
    end += tone(f, 2.8, g * 0.28, 0.35, 0.6, 2.2, harmonics=((1, 1.0), (2, 0.12)))
write("end.wav", end)
