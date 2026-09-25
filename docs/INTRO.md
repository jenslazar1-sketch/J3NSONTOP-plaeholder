# Laughing-skull intro

The first launch opens with a ~4.2 s sequence: darkness, a red signal
flicker, a scanline that decodes the original ASCII skull while its eyes
ignite, three "HA" laugh pulses, a short glitch, the product name with
"J3NSONTOP SYSTEM ONLINE", and a wipe into the dashboard. It is purely
presentational: the app is fully initialised before and while it plays,
skipping lands on the dashboard instantly, and it never loops or replays on
its own (`/intro?replay=1` replays it on request).

## Files

| File | Role |
| --- | --- |
| `lib/features/intro/intro_timeline.dart` | Pure-Dart choreography: phase windows and `jawOpen/jawTilt/headBob/eyeGlow/glitch/signal/reveal/title...(t)`, laugh pulses, cue-sheet export. No Flutter imports. |
| `lib/features/intro/skull_art.dart` | The original skull (cranium + jaw layers on one 41-column grid), eye centres, jaw hinge, mouth span, mini skull. |
| `lib/features/intro/skull_rig.dart` | `SkullRig`: renders a skull in a `SkullPose`; `SkullMetrics` (measured cell size); `skullTextStyle`, `skullStrut`, `skullGlyphGlow`. |
| `lib/features/intro/laughing_skull.dart` | `LaughingSkull` + `LaughingSkullController`: reusable skull (full/mini) that laughs on demand. |
| `lib/features/intro/intro_screen.dart` | `IntroScreen({required onFinished, bool replay})`, controls, sound, reduced-motion variant. |
| `lib/features/intro/intro_title.dart` | Title block (per-line `FittedBox`), wipe reveal, typed tagline. |
| `lib/features/intro/intro_fx.dart` | Painters and clippers: signal line, scan beam, haze, outro wipe, glitch slices. |
| `lib/features/intro/intro_sound.dart` | `IntroSound` interface, `audioplayers` implementation, `introSoundProvider`. |
| `assets/sounds/intro_laugh.wav` | Generated sting (see *Sound*). |
| `tool/sound/export_cues.dart`, `tool/sound/intro_cues.json` | Timeline cues handed to the sound generator. |
| `tool/sound/generate_intro_sound.py` | Deterministic synthesizer for the sting. |

## Choreography (intensity > 0)

| Phase | Window (s) | What happens |
| --- | --- | --- |
| darkness | 0.00-0.30 | Black cover over the app backdrop; SKIP and the toggle are already visible. |
| signal | 0.30-0.60 | A thin red line grows from the centre and flickers (stepped pattern) with a `SIGNAL` label. |
| reveal | 0.60-1.20 | A glowing scanline sweeps top to bottom; rows above it are revealed, the rows just decoded glow hot. The eyes ignite with a flicker when the beam crosses them (0.888 s). The cover starts easing away. |
| laugh | 1.20-2.70 | Three pulses (below). The head lifts and tilts back slightly with each one, eyes flare with the jaw. |
| glitch | 2.70-2.92 | RGB split (cyan/magenta ghosts) plus 2-3 horizontal slice offsets that change every 45 ms, choppy decaying envelope. |
| title | 2.92-3.82 | `J3NSONTOP` / `BIGGEST` / `MULTITOOL MADE` wipe in (staggered 0/100/180 ms, 280 ms each) with a hot edge; `J3NSONTOP SYSTEM ONLINE` types in mono (3.28-3.70) with scrambled leading glyphs and a blinking block cursor. |
| outro | 3.82-4.22 | Everything fades (ease-in) while a red wipe line sweeps down, clearing the scene to the backdrop; then `onFinished()` (exactly once). |

Low-effects mode (`EffectsConfig.intensity == 0`) removes the signal and the
glitch phases (3.70 s total), the beam glow, bloom and hot-edge tint; the
reveal, the laugh and the title stay. Glow off removes all radial glows and
text shadows (eyes become flat embers).

### Laugh pulses

Times are relative to the laugh start; amplitudes in line heights. The jaw
opens with an ease-out cubic, sags 8% while held (so each pulse has a single
distinct peak) and snaps shut with an ease-in cubic; it is fully closed
between pulses.

| Pulse | Start | Open | Hold | Close | Peak drop | Jaw roll |
| --- | --- | --- | --- | --- | --- | --- |
| HA | 0.05 | 0.14 | 0.06 | 0.17 | 1.00 | +2.2° |
| ha | 0.52 | 0.12 | 0.05 | 0.15 | 0.92 | -1.8° |
| HA! | 0.95 | 0.16 | 0.10 | 0.24 | 1.08 | +2.8° |

The head follows 30 ms behind the jaw: it lifts by up to 0.10 line heights
and tilts back (perspective X rotation about the neck) by up to 3°.

## Skull rendering rules

* Cranium and jaw are two `Text` layers (`SkullLayerText`) with the same
  self-contained style (`J3Type.ascii` with `inherit: false`, JetBrains Mono,
  `J3Type.asciiFeatures` so `|_|`/`|-|` never become ligatures), a forced
  strut, `softWrap: false`, `TextScaler.noScaling`, every row padded to the
  grid width.
* `SkullMetrics.measure` lays out the same style once with a `TextPainter` to
  get the real advance and row height; layers are placed in a `Stack` with
  explicit sizes (grid = columns x (cranium + jaw rows), plus 1.58 rows of
  headroom for the dropped jaw). The composition is scaled with `FittedBox`
  - text never reflows. Metrics are re-measured when system fonts change.
* Coordinates: eye centres are *cell* coordinates (cell centre at `+0.5`),
  the jaw hinge is a *grid* point relative to the jaw layer (see the header
  of `skull_art.dart`).
* The jaw layer translates down by `jawOpen * 1.08` rows and rolls about the
  hinge; its key (`IntroKeys.jaw`) sits on the translated, un-rotated box so
  tests can measure the drop with `getTopLeft`. The mouth gap is filled with
  darkness and a faint red ellipse that follows the rolled jaw edge.
* Eyes: a wide bloom + hot core (radial gradients, scaled by
  `EffectsConfig.glowBlur`) behind each socket and an ember pupil.

## Controls and settings

* **SKIP >>** (top right, from the first frame; tooltip "Skip intro (Esc)"),
  **Esc** anywhere, **Enter/Space** when no other control has focus: calls
  `onFinished` immediately and stops the animation and the sound.
* **Skip intro on launch** (bottom): persists `AppSettings.skipIntro`.
* **Sound**: plays only when `settings.sound` is on (default off) and the
  platform supports audio, at `settings.volume`. The `AudioPlayer` is created
  lazily at that moment, never otherwise. **Mute** (speaker icon, tooltip
  "Mute", visible from the first frame when sound is on) stops playback
  instantly and persists `sound = false`. Failures are caught and logged
  with `debugPrint`; they never block the intro. In low-effects mode the clip
  starts 0.30 s in so the "HA"s stay on the jaw.
* **Reduced motion**: a static composition (closed jaw, statically lit eyes,
  title and tagline, no ticker at all) with a **Continue** button; it
  continues automatically after 1.2 s. No sound.
* **Replay** (`replay: true`): same sequence, a small `REPLAY` label; the
  toggle works the same.

## LaughingSkull

```dart
final laughs = LaughingSkullController();
SizedBox(width: 120, height: 120, child: LaughingSkull(mini: true, controller: laughs));
laughs.laugh(); // or change `laughTrigger`, or `laughOnMount: true`
```

Same pulses and jaw mechanics as the intro, scaled to its constraints. With
reduced motion a laugh only brightens the eyes briefly; nothing moves. The
ticker runs only while a laugh plays.

## Sound

`assets/sounds/intro_laugh.wav`: 4.00 s, 22.05 kHz, mono, 16-bit PCM,
176,444 bytes, peaks at -1 dBFS.

It is fully original and fully synthesized by
`tool/sound/generate_intro_sound.py` (numpy + the standard `wave` module, fixed
seed, deterministic; no samples or third-party audio):

* signal: 60 Hz buzz + crackle gated by the signal flicker pattern;
* reveal: band-pass noise sweep (280 Hz -> 2.8 kHz) and a low detuned-saw
  pad; an eye-ignition "whoom" (pitch drop) whose tremolo follows the eye
  flicker;
* laugh: three "HA"s, each shaped exactly like its jaw pulse - breathy onset,
  a band-limited sawtooth voice with a growling sub-octave through /a/
  formant resonators (640/1000/2350/3300 Hz), falling pitch
  (122->98, 134->108, 108->74 Hz), and a bony teeth "clack" when the jaw
  snaps shut; a saturated sine sub drop (96 -> 34 Hz) under the laugh;
* glitch: FM zap chirp, sample-and-hold bit crush per 45 ms glitch frame,
  chopped with the visual glitch envelope;
* title: faint data ticks while the tagline types and a two-tone "online"
  chime when it completes;
* a small synthetic room reverb, soft limiter, fades.

Regenerate after changing the timeline:

```sh
dart run tool/sound/export_cues.dart            # timeline -> tool/sound/intro_cues.json
python3 tool/sound/generate_intro_sound.py      # -> assets/sounds/intro_laugh.wav
python3 tool/sound/generate_intro_sound.py --spectrogram build/intro_sound.png  # optional debug view
```

`test/features/intro/intro_timeline_test.dart` fails if the cue sheet is
stale; `intro_sound_asset_test.dart` checks the WAV format, length and size.

## Tests

`test/features/intro/`:

* `intro_timeline_test.dart` - three local maxima of `jawOpen`, closed
  before/after/between pulses, easing, 3-5 s total, ordered phases, eyes,
  glitch, low-effects timeline, sound offset, cue sheet in sync.
* `intro_screen_test.dart` - SKIP on the first frame and exactly-once
  finishing, Esc/Enter/Space, focused toggle keeps Space, toggle persistence
  (read back from disk), replay, jaw drop >= 0.8 line heights at every peak
  with the cranium moving <= 0.3, completion with no pending timers or
  tickers, low-effects (no glitch/flicker, laugh remains), reduced motion
  (static, Continue, auto-continue), 320x568 at 2x text, landscape, sound
  on/off/mute/skip with a fake `IntroSound` (no audio plugin is touched).
* `laughing_skull_test.dart` - art/grid invariants (teeth columns aligned,
  metrics equal rendered layers with and without app fonts), controller,
  trigger, mini art, reduced motion, disposal.
* `intro_frames_test.dart` - renders key frames with the bundled fonts to
  `build/intro_frames/*.png` for visual review:

```sh
flutter test test/features/intro/intro_frames_test.dart && ls build/intro_frames
```

## Known limitations

* Audio/visual sync is best effort: the clip is prepared asynchronously and,
  if preparation is slow, seeks to the intro's current position before it
  starts; platform output latency (typically 20-100 ms) is not compensated.
* The laugh is synthesized, not a recorded voice; it is designed to read as
  "HA-HA-HA" on phone speakers but is deliberately short and stylised.
* `LaughingSkull` lives in the intro feature. Other features that want it
  (About, Home, terminal easter eggs) should either import it like the shell
  imports `skull_art.dart`, or it should move to `core/widgets`.
