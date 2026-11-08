#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 KC2RGW Chris
#
# Makes the soundboard's built-in sounds in packaging/sounds:
#   - synthesizes the drums, the air horn, the sirens and the sad trombone (ours,
#     GPL-3.0-or-later like the rest of PatchPrimeMac), and
#   - trims and converts the recordings from Wikimedia Commons listed in
#     packaging/sounds/SOURCES.md, given the folder they were downloaded to.
# Then every sound is levelled to the same loudness: its loudest moment (momentary
# loudness, 400 ms) at -16 LUFS, with the true peak no higher than -2 dBTP. Written as
# 48 kHz 16-bit WAV with no metadata.
#
#   scripts/make-sounds.py <folder of the downloaded originals>
#
# Needs ffmpeg (brew install ffmpeg). Plain Python otherwise; the noise is seeded, so
# the synthesized sounds come out the same every time.

import math
import os
import random
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import wave

RATE = 48000
TARGET_MOMENTARY = -16.0  # LUFS, the loudest 400 ms
PEAK_CEILING = -2.0       # dBTP

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "packaging", "sounds")

# --- synthesis -----------------------------------------------------------------


def silence(seconds):
    return [0.0] * int(seconds * RATE)


def mix(into, sound, at, gain=1.0):
    start = int(at * RATE)
    if len(into) < start + len(sound):
        into.extend([0.0] * (start + len(sound) - len(into)))
    for i, v in enumerate(sound):
        into[start + i] += v * gain
    return into


def env_exp(n, decay):
    """Exponential decay: down 60 dB after `decay` seconds."""
    k = math.log(1000) / (decay * RATE)
    return [math.exp(-k * i) for i in range(n)]


def noise(seconds, rng):
    return [rng.uniform(-1, 1) for _ in range(int(seconds * RATE))]


def biquad(x, kind, freq, q=0.707):
    w = 2 * math.pi * freq / RATE
    a = math.sin(w) / (2 * q)
    c = math.cos(w)
    if kind == "low":
        b0, b1, b2 = (1 - c) / 2, 1 - c, (1 - c) / 2
    elif kind == "high":
        b0, b1, b2 = (1 + c) / 2, -(1 + c), (1 + c) / 2
    else:  # band
        b0, b1, b2 = a, 0.0, -a
    a0, a1, a2 = 1 + a, -2 * c, 1 - a
    b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
    y = []
    x1 = x2 = y1 = y2 = 0.0
    for v in x:
        out = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, v, y1, out
        y.append(out)
    return y


def sweep_sine(seconds, f_of_t, shape=lambda p: math.sin(p)):
    out, phase = [], 0.0
    for i in range(int(seconds * RATE)):
        phase += 2 * math.pi * f_of_t(i / RATE) / RATE
        out.append(shape(phase))
    return out


def saw(phase):
    return 2 * ((phase / (2 * math.pi)) % 1.0) - 1


def fade(x, fade_in=0.003, fade_out=0.01):
    n_in, n_out = int(fade_in * RATE), int(fade_out * RATE)
    for i in range(min(n_in, len(x))):
        x[i] *= i / n_in
    for i in range(min(n_out, len(x))):
        x[-1 - i] *= i / n_out
    return x


def kick(rng):
    n = int(0.5 * RATE)
    body = sweep_sine(0.5, lambda t: 50 + 110 * math.exp(-t * 28))
    e = env_exp(n, 0.45)
    click = biquad(noise(0.004, rng), "high", 2000)
    out = [body[i] * e[i] for i in range(n)]
    return mix(out, click, 0, 0.4)


def snare(rng, length=0.3):
    n = int(length * RATE)
    tone = sweep_sine(length, lambda t: 185 + 40 * math.exp(-t * 40))
    te = env_exp(n, 0.12)
    rattle = biquad(biquad(noise(length, rng), "high", 1200), "low", 9000)
    ne = env_exp(n, 0.22)
    return [0.45 * tone[i] * te[i] + 0.8 * rattle[i] * ne[i] for i in range(n)]


def tom(rng, freq=120):
    n = int(0.6 * RATE)
    body = sweep_sine(0.6, lambda t: freq + freq * 0.5 * math.exp(-t * 20))
    e = env_exp(n, 0.5)
    return [body[i] * e[i] for i in range(n)]


def hat(rng, decay=0.06):
    length = decay * 1.5 + 0.02
    n = int(length * RATE)
    partials = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0]  # inharmonic, like an 808
    sq = [0.0] * n
    for f in partials:
        for i in range(n):
            sq[i] += 1.0 if math.sin(2 * math.pi * f * 3.2 * i / RATE) > 0 else -1.0
    hiss = noise(length, rng)
    raw = [0.25 * sq[i] / len(partials) + 0.75 * hiss[i] for i in range(n)]
    out = biquad(biquad(raw, "high", 7000), "high", 7000)
    e = env_exp(n, decay)
    return [out[i] * e[i] for i in range(n)]


def crash(rng, decay=2.2):
    length = decay + 0.3
    n = int(length * RATE)
    partials = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0]
    sq = [0.0] * n
    for f in partials:
        for i in range(n):
            sq[i] += 1.0 if math.sin(2 * math.pi * f * 2.1 * i / RATE) > 0 else -1.0
    hiss = noise(length, rng)
    raw = [0.35 * sq[i] / len(partials) + 0.65 * hiss[i] for i in range(n)]
    out = biquad(biquad(raw, "high", 3500), "low", 14000)
    e = env_exp(n, decay)
    return [out[i] * e[i] for i in range(n)]


def clap(rng):
    out = silence(0.4)
    for k, at in enumerate([0.0, 0.011, 0.022]):  # three hands, a moment apart
        burst = biquad(noise(0.012, rng), "band", 1100, 1.2)
        mix(out, [v * (1 - i / len(burst)) for i, v in enumerate(burst)], at, 1.0)
    tail = biquad(noise(0.35, rng), "band", 1100, 1.0)
    e = env_exp(len(tail), 0.18)
    return mix(out, [tail[i] * e[i] for i in range(len(tail))], 0.033, 0.8)


def ba_dum_tss(rng):
    out = silence(2.6)
    mix(out, snare(rng, 0.25), 0.0, 0.8)
    mix(out, tom(rng, 110), 0.22, 0.9)
    mix(out, kick(rng), 0.44, 0.6)
    mix(out, crash(rng, 1.8), 0.44, 0.7)
    return out


def drum_roll(rng):
    out = silence(3.8)
    t, n = 0.0, 0
    while t < 2.4:  # a press roll, getting louder
        mix(out, snare(rng, 0.12), t, 0.25 + 0.6 * t / 2.4)
        t += 0.045 + rng.uniform(-0.004, 0.004)
        n += 1
    mix(out, kick(rng), 2.45, 0.9)
    mix(out, crash(rng, 2.0), 2.45, 0.9)
    return out


def air_horn(rng, blasts=3):
    out = []
    t = 0.0
    for b in range(blasts):
        length = 0.35 if b < blasts - 1 else 1.3
        tones = []
        for f in (466.2, 554.4, 698.5):  # a stadium horn's sour chord
            tones.append(sweep_sine(length, lambda tt, f=f: f * (1 + 0.004 * math.sin(2 * math.pi * 6 * tt)), saw))
        n = len(tones[0])
        raw = [sum(tn[i] for tn in tones) / 3 for i in range(n)]
        raw = [math.tanh(2.2 * v) for v in raw]  # brassy
        raw = biquad(raw, "low", 3200)
        mix(out, fade(raw, 0.02, 0.06), t, 1.0)
        t += length + 0.08
    return out


def siren_wail():
    def f(t):
        cycle = (t % 3.0) / 3.0
        rise = cycle * 2 if cycle < 0.5 else 2 - cycle * 2
        return 650 + 750 * (rise ** 0.8)
    s = sweep_sine(6.0, f, lambda p: math.tanh(2.5 * math.sin(p)))
    return fade(biquad(s, "low", 4500), 0.15, 0.4)


def siren_yelp():
    def f(t):
        cycle = (t % 0.32) / 0.32
        rise = cycle * 2 if cycle < 0.5 else 2 - cycle * 2
        return 700 + 800 * rise
    s = sweep_sine(4.0, f, lambda p: math.tanh(2.5 * math.sin(p)))
    return fade(biquad(s, "low", 4500), 0.05, 0.3)


def sad_trombone():
    out = []
    notes = [(293.7, 0.45), (277.2, 0.45), (261.6, 0.45), (246.9, 1.5)]  # D, C#, C, B: wah wah wah waaah
    t = 0.0
    for k, (f, length) in enumerate(notes):
        last = k == len(notes) - 1
        tone = sweep_sine(length, lambda tt, f=f, last=last: f * (1 + (0.025 * math.sin(2 * math.pi * 5.5 * tt) if last and tt > 0.3 else 0)), saw)
        n = len(tone)
        # The mute opening and closing: a low-pass that rises and falls with each note.
        y, lp = [], 0.0
        for i in range(n):
            p = i / n
            open_ = math.sin(math.pi * min(1.0, p * (1.6 if not last else 1.0))) if not last else min(1.0, p * 6) * (1 - 0.6 * p)
            cutoff = 300 + 1700 * max(0.0, open_)
            a = 1 - math.exp(-2 * math.pi * cutoff / RATE)
            lp += a * (tone[i] - lp)
            y.append(lp)
        mix(out, fade(y, 0.02, 0.08), t, 1.0)
        t += length + 0.05
    return out


SYNTH = {
    "Kick": kick, "Snare": snare, "Clap": clap, "Hi-Hat": hat, "Crash": crash,
    "Ba-Dum-Tss": ba_dum_tss, "Drum Roll": drum_roll, "Air Horn": air_horn,
    "Siren Wail": lambda rng: siren_wail(), "Siren Yelp": lambda rng: siren_yelp(),
    "Sad Trombone": lambda rng: sad_trombone(),
}

# --- recordings ---------------------------------------------------------------
# (pad name, Commons file, start, length in seconds or None for all)
RECORDED = [
    ("Applause", "277021 sandermotions applause-2.wav", 0, None),
    ("Applause (Small)", "Applause ii.ogg", 0, None),
    ("Cheer", "Clapping hurray (cropped).oga", 0, None),
    ("Hurray", "Hurray.ogg", 0, None),
    ("Ooh Ahh", "Ohhh ahhh.ogg", 0, None),
    ("Laughter", "72843 lonemonk approx-800-laughter-only-1.wav", 0, None),
    ("Toy Siren", "Toy siren alarm.ogg", 0, 8.5),
    ("Train Horn", "AirChime K5LA.ogg", 0.3, 4.5),
]

# --- levelling ------------------------------------------------------------------


def run(args):
    return subprocess.run(args, capture_output=True, text=True, check=True)


def loudness(path):
    """(loudest momentary loudness in LUFS, true peak in dBTP). Measured with half a
    second of silence after it, so a hit shorter than the 400 ms window still counts."""
    log = subprocess.run(["ffmpeg", "-nostats", "-v", "verbose", "-i", path, "-af",
                          "apad=pad_dur=0.5,ebur128=peak=true:framelog=verbose", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    moments = [float(m) for m in re.findall(r"M:\s*(-?[\d.]+)", log)]
    peak = float(re.findall(r"Peak:\s*(-?[\d.]+|-inf)", log)[-1])
    return max(moments), peak


def level(src, dest):
    m, peak = loudness(src)
    gain = min(TARGET_MOMENTARY - m, PEAK_CEILING - peak)
    run(["ffmpeg", "-y", "-v", "error", "-i", src, "-af", f"volume={gain:.2f}dB", "-ar", str(RATE),
         "-c:a", "pcm_s16le", "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact", dest])
    return m, peak, gain


def write_wav(path, samples):
    peak = max(1e-9, max(abs(v) for v in samples))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(32767 * 0.5 * v / peak)) for v in samples))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__ or "make-sounds.py <folder of the downloaded originals>")
    originals = sys.argv[1]
    if shutil.which("ffmpeg") is None:
        sys.exit("needs ffmpeg")
    os.makedirs(OUT, exist_ok=True)
    work = tempfile.mkdtemp()
    for name, make in SYNTH.items():
        rng = random.Random(name)  # the same every time
        raw = os.path.join(work, name + ".wav")
        write_wav(raw, make(rng))
        print(f"{name:18} synthesized   M {loudness(raw)[0]:6.1f} -> ", end="")
        m, peak, gain = level(raw, os.path.join(OUT, name + ".wav"))
        print(f"{gain:+.1f} dB")
    for name, file, start, length in RECORDED:
        src = os.path.join(originals, file)
        cut = os.path.join(work, name + ".wav")
        args = ["ffmpeg", "-y", "-v", "error", "-i", src, "-ss", str(start)]
        if length:
            args += ["-t", str(length), "-af", f"afade=t=out:st={max(0, length - 0.4)}:d=0.4"]
        run(args + ["-ar", str(RATE), cut])
        m, peak, gain = level(cut, os.path.join(OUT, name + ".wav"))
        print(f"{name:18} {file[:28]:28} M {m:6.1f}  peak {peak:5.1f} -> {gain:+.1f} dB")
    shutil.rmtree(work)


if __name__ == "__main__":
    main()
