#!/usr/bin/env python3
"""Generate assets/sounds/intro_laugh.wav - the J3NSONTOP intro sting.

Fully original and fully synthesized: no samples, no recordings, no
third-party audio. Every sound below is built from oscillators, filtered
noise and simple envelopes with numpy, and written with the standard
`wave` module. A fixed random seed makes the output deterministic (bit-exact
for a given numpy version).

Format: 22.05 kHz, mono, 16-bit PCM, 4.0 s (about 176 KB).

Timing comes from tool/sound/intro_cues.json, which is exported from the
Dart timeline (lib/features/intro/intro_timeline.dart) with
`dart run tool/sound/export_cues.dart`, so every sound lands on its frame:

  0.30-0.60  signal   - mains buzz + crackle gated by the same flicker
                        pattern as the red signal line
  0.60-1.20  reveal   - band-pass noise sweep following the scanline, a low
                        pad fading in; the eyes ignite with a "whoom" whose
                        tremolo follows the eye flicker
  1.20-2.70  laugh    - three "HA"s, each synced to a jaw pulse: breathy
                        onset, formant-filtered sawtooth voice (/a/ vowel,
                        falling pitch, growling sub-octave), amplitude shaped
                        like the jaw curve, and a bony teeth "clack" when the
                        jaw snaps shut; a synth sub drop underneath
  2.70-2.92  glitch   - FM "zap" chirp, bit-crushed and chopped with the
                        same 45 ms frames and envelope as the visual glitch
  2.92-3.82  title    - faint data ticks while "SYSTEM ONLINE" types, a two
                        tone "online" chime when it completes
  everything decays before the outro wipe; a small synthetic room reverb
  glues the parts together.

Usage (from the repository root):
  python3 tool/sound/generate_intro_sound.py
  python3 tool/sound/generate_intro_sound.py --spectrogram build/intro_sound.png
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import wave

import numpy as np

SR = 22050
DURATION = 4.0
SEED = 0x135C0
ROOT = pathlib.Path(__file__).resolve().parents[2]
CUES_PATH = ROOT / "tool" / "sound" / "intro_cues.json"
OUT_PATH = ROOT / "assets" / "sounds" / "intro_laugh.wav"

rng = np.random.default_rng(SEED)
N = int(SR * DURATION)
T = np.arange(N) / SR


# --------------------------------------------------------------- helpers --


def idx(t: float) -> int:
    return max(0, min(N, int(round(t * SR))))


def place(dst: np.ndarray, start: float, sig: np.ndarray, gain: float = 1.0) -> None:
    i = idx(start)
    j = min(N, i + len(sig))
    if j > i:
        dst[i:j] += gain * sig[: j - i]


def ease_out(x):
    x = np.clip(x, 0.0, 1.0)
    return 1 - (1 - x) ** 3


def ease_in(x):
    x = np.clip(x, 0.0, 1.0)
    return x**3


def fade(sig: np.ndarray, fin: float = 0.004, fout: float = 0.01) -> np.ndarray:
    out = sig.copy()
    a, b = int(fin * SR), int(fout * SR)
    if a:
        out[:a] *= np.linspace(0, 1, a)
    if b:
        out[-b:] *= np.linspace(1, 0, b)
    return out


def biquad(x: np.ndarray, b0, b1, b2, a1, a2) -> np.ndarray:
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for n in range(len(x)):
        xn = x[n]
        yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, xn, y1, yn
        y[n] = yn
    return y


def bandpass(x: np.ndarray, f0: float, bw: float) -> np.ndarray:
    """RBJ band-pass (0 dB peak gain)."""
    w0 = 2 * math.pi * f0 / SR
    q = f0 / bw
    alpha = math.sin(w0) / (2 * q)
    a0 = 1 + alpha
    return biquad(x, alpha / a0, 0.0, -alpha / a0, -2 * math.cos(w0) / a0, (1 - alpha) / a0)


def lowpass(x: np.ndarray, f0: float, q: float = 0.707) -> np.ndarray:
    w0 = 2 * math.pi * f0 / SR
    alpha = math.sin(w0) / (2 * q)
    c = math.cos(w0)
    a0 = 1 + alpha
    return biquad(x, (1 - c) / 2 / a0, (1 - c) / a0, (1 - c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0)


def highpass(x: np.ndarray, f0: float, q: float = 0.707) -> np.ndarray:
    w0 = 2 * math.pi * f0 / SR
    alpha = math.sin(w0) / (2 * q)
    c = math.cos(w0)
    a0 = 1 + alpha
    return biquad(x, (1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0)


def svf_bandpass(x: np.ndarray, fc: np.ndarray, q: float) -> np.ndarray:
    """Chamberlin state-variable band-pass with a per-sample cutoff."""
    y = np.zeros_like(x)
    low = band = 0.0
    damp = 1.0 / q
    for n in range(len(x)):
        f = 2 * math.sin(math.pi * min(fc[n], SR / 6) / SR)
        low += f * band
        high = x[n] - low - damp * band
        band += f * high
        y[n] = band
    return y


def saw(phase: np.ndarray, f0: np.ndarray, tilt: float = 1.0) -> np.ndarray:
    """Band-limited sawtooth by additive synthesis (no aliasing)."""
    out = np.zeros_like(phase)
    kmax = int(SR / 2 / max(float(np.min(f0)), 20.0))
    for k in range(1, kmax + 1):
        mask = (k * f0) < SR * 0.45
        out += mask * np.sin(k * phase) / (k**tilt)
    return out


def steps(keys, t_rel: np.ndarray) -> np.ndarray:
    """Step function: hold each (time, value) until the next key."""
    out = np.full_like(t_rel, keys[0][1], dtype=float)
    for at, v in keys:
        out[t_rel >= at] = v
    return out


def smooth_steps(values: np.ndarray, ms: float = 3.0) -> np.ndarray:
    """De-click a stepped envelope with a short moving average."""
    n = max(1, int(ms / 1000 * SR))
    kernel = np.ones(n) / n
    return np.convolve(values, kernel, mode="same")


# ----------------------------------------------------------------- parts --


def signal_buzz(c) -> np.ndarray:
    s0, s1 = c["signal"]
    if s1 <= s0:
        return np.zeros(0)
    n = idx(s1 - s0) + int(0.02 * SR)
    t = np.arange(n) / SR
    hum = np.sign(np.sin(2 * math.pi * 60 * t)) * 0.5 + 0.5 * np.sin(2 * math.pi * 120 * t)
    hum = lowpass(hum, 900)
    crackle = bandpass(rng.standard_normal(n), 3200, 1800) * (rng.random(n) < 0.08)
    keys = [(at - s0, v) for at, v in c["signalFlicker"]]
    gate = smooth_steps(steps(keys, t))
    return fade((0.55 * hum + 0.9 * crackle) * gate)


def reveal_sweep(c) -> np.ndarray:
    r0, r1 = c["reveal"]
    n = idx(r1 - r0) + int(0.15 * SR)
    t = np.arange(n) / SR
    p = np.clip(t / (r1 - r0), 0, 1)
    fc = 280 * (2800 / 280) ** p
    sweep = svf_bandpass(rng.standard_normal(n), fc, 6.0)
    env = np.sin(np.pi * p) ** 0.7 * (t < (r1 - r0) + 0.1)
    return fade(sweep * env * 0.5, 0.01, 0.08)


def eye_ignite(c) -> np.ndarray:
    dur = 0.5
    n = int(dur * SR)
    t = np.arange(n) / SR
    f = 70 + 170 * np.exp(-t / 0.07)
    phase = 2 * np.pi * np.cumsum(f) / SR
    body = np.sin(phase) + 0.3 * np.sin(2 * phase)
    env = (1 - np.exp(-t / 0.004)) * np.exp(-t / 0.18)
    flicker_keys = [(0.00, 0.95), (0.14, 0.10), (0.27, 1.00), (0.45, 0.30), (0.55, 0.90), (0.75, 0.72)]
    trem = smooth_steps(steps([(k * 0.22, v) for k, v in flicker_keys], t))
    click = highpass(rng.standard_normal(n), 2500) * np.exp(-t / 0.006)
    return fade((0.8 * body * env * trem + 0.25 * click), 0.001, 0.05)


def pad(c) -> np.ndarray:
    """Low detuned-saw chord: fades in with the reveal, ducks at the glitch."""
    start = c["reveal"][0]
    end = c["glitch"][0] + 0.5
    n = idx(end - start)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for f in (73.42, 87.31, 110.0, 146.83):
        for det in (-0.35, 0.35):
            ff = np.full(n, f + det)
            out += saw(2 * np.pi * ff * t + rng.random() * 6.28, ff, 1.3)
    out = lowpass(out, 520, 0.9)
    g0, g1 = c["glitch"]
    env = np.clip(t / 0.6, 0, 1) ** 2
    duck = np.where(t + start < g0, 1.0, np.exp(-(t + start - g0) / 0.12))
    return fade(out * env * duck * 0.06, 0.01, 0.1)


def sub_drop(c) -> np.ndarray:
    dur = 1.6
    n = int(dur * SR)
    t = np.arange(n) / SR
    f = 34 + (96 - 34) * np.exp(-t / 0.45)
    phase = 2 * np.pi * np.cumsum(f) / SR
    env = (1 - np.exp(-t / 0.012)) * np.exp(-t / 0.75)
    return fade(np.tanh(1.9 * np.sin(phase)) * env * 0.55, 0.002, 0.2)


VOICES = [
    # (f0 start Hz, f0 end Hz, vibrato depth)
    (122.0, 98.0, 0.015),
    (134.0, 108.0, 0.012),
    (108.0, 74.0, 0.03),
]
FORMANTS = [(640, 80, 1.0), (1000, 100, 0.55), (2350, 150, 0.28), (3300, 220, 0.12)]


def ha(pulse, voice) -> np.ndarray:
    """One "HA", shaped exactly like the jaw pulse it accompanies."""
    start, peak, hold_end, end = pulse["start"], pulse["peak"], pulse["holdEnd"], pulse["end"]
    amp = pulse["amplitude"]
    dur = end - start + 0.03
    n = int(dur * SR)
    t = np.arange(n) / SR
    tp, th, te = peak - start, hold_end - start, end - start

    # Jaw-shaped envelope: ease-out open, slight sag, ease-in close.
    env = np.where(
        t < tp,
        ease_out(t / tp),
        np.where(t < th, 1 - 0.08 * (t - tp) / max(th - tp, 1e-6), 0.92 * (1 - ease_in((t - th) / (te - th)))),
    )
    env = np.clip(env, 0, 1) * (t <= te)

    f_start, f_end, vib = voice
    f0 = f_start * (f_end / f_start) ** np.clip(t / te, 0, 1)
    jitter = lowpass(rng.standard_normal(n), 30) * 0.4
    f0 = f0 * (1 + vib * np.sin(2 * np.pi * 7.5 * t) + 0.015 * jitter)
    phase = 2 * np.pi * np.cumsum(f0) / SR
    # Glottal-like source (-12 dB/octave) plus a growling sub-octave.
    source = saw(phase, f0, 1.9) + 0.4 * saw(phase / 2, f0 / 2, 2.0)
    breath = rng.standard_normal(n)
    aspiration = np.clip(t / 0.012, 0, 1) * np.exp(-np.maximum(t - 0.012, 0) / 0.05)
    voiced = np.clip((t - 0.025) / 0.03, 0, 1)
    excitation = source * voiced * 0.5 + breath * (0.9 * aspiration + 0.025)
    shaped = sum(g * bandpass(excitation, f, bw) for f, bw, g in FORMANTS)
    shaped = lowpass(shaped + 0.15 * lowpass(source * voiced, 400), 4200)
    shaped /= np.max(np.abs(shaped))
    shaped = np.tanh(1.8 * shaped) / math.tanh(1.8)  # a little grit
    return fade(shaped * env * amp, 0.002, 0.012)


def clack() -> np.ndarray:
    """Teeth snapping shut: a short, bony double resonance."""
    n = int(0.05 * SR)
    t = np.arange(n) / SR
    burst = rng.standard_normal(n) * np.exp(-t / 0.0035)
    tone = bandpass(burst, 2100, 180) + 0.7 * bandpass(burst, 3400, 300) + 0.4 * bandpass(burst, 900, 120)
    return fade(tone * 3.0, 0.0005, 0.01)


def glitch_zap(c) -> np.ndarray:
    g0, g1 = c["glitch"]
    if g1 <= g0:
        return np.zeros(0)
    dur = g1 - g0
    n = int(dur * SR)
    t = np.arange(n) / SR
    p = t / dur
    fc = 2600 * (180 / 2600) ** p
    index = 6 * (1 - p) + 1
    mod = np.sin(2 * np.pi * np.cumsum(fc * 3.01) / SR)
    carrier = np.sin(2 * np.pi * np.cumsum(fc) / SR + index * mod)
    square = np.sign(carrier) * np.abs(carrier) ** 0.3
    # Sample-and-hold "bit crush", a different rate per 45 ms glitch frame.
    frame = (t / 0.045).astype(int)
    hold = np.array([3, 7, 4, 9, 5, 6])[frame % 6]
    crushed = np.empty(n)
    i = 0
    while i < n:
        h = int(hold[i])
        crushed[i : i + h] = np.round(square[i] * 6) / 6
        i += h
    chop = np.array([1.0, 0.55, 0.9, 0.35, 0.7])[np.minimum((p * 5).astype(int), 4)] * (1 - 0.6 * p)
    noise = highpass(rng.standard_normal(n), 1500) * np.exp(-t / 0.02)
    return fade((0.5 * crushed + 0.4 * noise) * smooth_steps(chop, 2), 0.001, 0.02)


def title_ticks(c) -> np.ndarray:
    t0 = c["title"][0]
    done = c["taglineDone"]
    typing_start = done - 0.42
    out = np.zeros(idx(c["outro"][0] - t0 + 0.3))
    tick = highpass(rng.standard_normal(int(0.006 * SR)), 4000) * np.exp(-np.arange(int(0.006 * SR)) / SR / 0.0012)
    chars = 23
    for i in range(chars):
        at = typing_start + i * 0.42 / chars - t0
        j = idx(at)
        out[j : j + len(tick)] += tick * (0.10 + 0.05 * (i % 3 == 0))
    # "Online" chime: two soft FM blips.
    for k, (f, delay) in enumerate(((880.0, 0.0), (1318.5, 0.075))):
        n = int(0.35 * SR)
        t = np.arange(n) / SR
        blip = np.sin(2 * np.pi * f * t + 0.8 * np.exp(-t / 0.05) * np.sin(2 * np.pi * f * 2 * t))
        env = (1 - np.exp(-t / 0.002)) * np.exp(-t / (0.09 + 0.05 * k))
        j = idx(done - t0 + delay)
        seg = (blip * env * 0.22)[: len(out) - j]
        out[j : j + len(seg)] += seg
    return out


def room(x: np.ndarray, rt60: float = 0.8, wet: float = 0.2) -> np.ndarray:
    """Synthetic room: FFT convolution with decaying, darkened noise."""
    n = int(rt60 * SR)
    t = np.arange(n) / SR
    ir = rng.standard_normal(n) * np.exp(-6.9 * t / rt60)
    ir = lowpass(ir, 3200)
    ir[: int(0.012 * SR)] = 0  # pre-delay
    ir /= np.sqrt(np.sum(ir**2))
    size = 1 << int(math.ceil(math.log2(len(x) + n)))
    wet_sig = np.fft.irfft(np.fft.rfft(x, size) * np.fft.rfft(ir, size), size)[: len(x)]
    return x + wet * wet_sig


# ------------------------------------------------------------------ main --


def render(cues) -> np.ndarray:
    dry = np.zeros(N)  # parts that get the room
    sub = np.zeros(N)  # kept dry
    # Levels: the laugh leads; everything else supports it.
    place(dry, cues["signal"][0], signal_buzz(cues), 0.22)
    place(dry, cues["reveal"][0], reveal_sweep(cues), 0.2)
    place(dry, cues["eyeIgnite"], eye_ignite(cues), 0.42)
    place(dry, cues["reveal"][0], pad(cues), 0.55)
    for pulse, voice in zip(cues["pulses"], VOICES):
        place(dry, pulse["start"] - 0.012, ha(pulse, voice), 0.9)
        place(dry, pulse["end"] - 0.004, clack(), 0.3)
    place(sub, cues["laugh"][0], sub_drop(cues), 0.62)
    place(dry, cues["glitch"][0], glitch_zap(cues), 0.5)
    place(dry, cues["title"][0], title_ticks(cues), 0.8)

    mix = room(dry) + sub
    mix = np.tanh(1.15 * mix) / math.tanh(1.15)
    peak = np.max(np.abs(mix))
    mix *= 0.89 / peak  # -1 dBFS
    mix[: int(0.004 * SR)] *= np.linspace(0, 1, int(0.004 * SR))
    tail = int(0.25 * SR)
    mix[-tail:] *= np.linspace(1, 0, tail) ** 2
    return mix


def write_wav(path: pathlib.Path, mix: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = np.clip(np.round(mix * 32767), -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def spectrogram(path: pathlib.Path, mix: np.ndarray, cues) -> None:
    """Debug view: log spectrogram with the cue times marked (needs Pillow)."""
    from PIL import Image, ImageDraw

    win, hop = 512, 64
    frames = 1 + (len(mix) - win) // hop
    window = np.hanning(win)
    spec = np.array([np.abs(np.fft.rfft(mix[i * hop : i * hop + win] * window)) for i in range(frames)]).T
    db = 20 * np.log10(spec + 1e-6)
    db = np.clip((db - db.max() + 70) / 70, 0, 1)
    img = (np.flipud(db) * 255).astype(np.uint8)
    wave_h = 120
    canvas = Image.new("RGB", (frames, img.shape[0] + wave_h), (5, 5, 7))
    canvas.paste(Image.fromarray(img).convert("RGB"), (0, wave_h))
    d = ImageDraw.Draw(canvas)
    env = np.array([np.max(np.abs(mix[i * hop : i * hop + win])) for i in range(frames)])
    for x, v in enumerate(env):
        d.line([(x, wave_h / 2 - v * wave_h / 2), (x, wave_h / 2 + v * wave_h / 2)], fill=(255, 22, 59))
    marks = [cues["signal"][0], cues["reveal"][0], cues["eyeIgnite"], cues["laugh"][0], cues["glitch"][0], cues["title"][0], cues["taglineDone"], cues["outro"][0]]
    marks += [p["peak"] for p in cues["pulses"]] + [p["end"] for p in cues["pulses"]]
    for m in marks:
        x = int(m * SR / hop)
        d.line([(x, 0), (x, canvas.height)], fill=(80, 200, 255))
    path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--out", type=pathlib.Path, default=OUT_PATH)
    parser.add_argument("--spectrogram", type=pathlib.Path, help="also write a debug spectrogram PNG")
    args = parser.parse_args()
    cues = json.loads(CUES_PATH.read_text())
    mix = render(cues)
    write_wav(args.out, mix)
    if args.spectrogram:
        spectrogram(args.spectrogram, mix, cues)
    size = args.out.stat().st_size
    rms = float(np.sqrt(np.mean(mix**2)))
    print(f"wrote {args.out.relative_to(ROOT)}: {len(mix) / SR:.2f} s, {SR} Hz mono 16-bit, {size} bytes, "
          f"peak {20 * math.log10(np.max(np.abs(mix))):.1f} dBFS, rms {20 * math.log10(rms):.1f} dBFS")


if __name__ == "__main__":
    main()
