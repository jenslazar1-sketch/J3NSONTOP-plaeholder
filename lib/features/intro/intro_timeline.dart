/// Choreography of the laughing-skull intro as pure functions of time.
///
/// Everything here is deterministic and free of Flutter imports, so the
/// timing is unit-tested (test/features/intro/intro_timeline_test.dart) and
/// exported as a cue sheet for the sound generator
/// (`tool/sound/intro_cues.json`, checked by a test so audio and animation
/// cannot drift apart).
///
/// Times are in seconds from the first frame of the intro.
library;

import 'dart:math' as math;

/// The ordered phases of the intro.
enum IntroPhase {
  /// Black screen; only the controls are visible.
  darkness,

  /// A thin red signal line flickers on (decorative; skipped in low-effects mode).
  signal,

  /// A scanline sweeps top to bottom revealing the skull; the eyes ignite.
  reveal,

  /// Three "HA" pulses: the jaw drops and snaps shut, the head bobs.
  laugh,

  /// Short RGB-split / slice-offset burst (decorative; skipped in low-effects mode).
  glitch,

  /// The product name and "J3NSONTOP SYSTEM ONLINE" are revealed.
  title,

  /// Fade plus scanline wipe into the dashboard.
  outro,
}

/// A phase's time window `[start, end)`.
class PhaseWindow {
  const PhaseWindow(this.phase, this.start, this.end);

  final IntroPhase phase;
  final double start;
  final double end;

  double get duration => end - start;
  bool get isEmpty => duration <= 0;
  bool contains(double t) => t >= start && t < end;

  /// Linear progress through the window, clamped to 0..1. An empty window
  /// reports 1 as soon as it has been reached.
  double progress(double t) {
    if (duration <= 0) return t >= start ? 1 : 0;
    return ((t - start) / duration).clamp(0.0, 1.0);
  }

  @override
  String toString() => '${phase.name}[${start.toStringAsFixed(3)}, ${end.toStringAsFixed(3)})';
}

/// One "HA" of the laugh. The jaw drops with an ease-out curve, sags a little
/// while it is held open (so every pulse has a single, distinct peak) and
/// snaps shut with an ease-in curve. Times are relative to the laugh start.
class LaughPulse {
  const LaughPulse({
    required this.start,
    required this.open,
    required this.hold,
    required this.close,
    required this.amplitude,
    required this.tilt,
  });

  final double start;
  final double open;
  final double hold;
  final double close;

  /// Peak opening, 0..1 (1 = [kJawMaxDropLines]).
  final double amplitude;

  /// Jaw roll at the peak in degrees; the sign alternates between pulses so
  /// the laugh reads as a lopsided cackle rather than a mechanical hinge.
  final double tilt;

  /// Fraction of the peak lost while the mouth is held open.
  static const double sag = 0.08;

  double get peak => start + open;
  double get end => start + open + hold + close;

  /// Normalised envelope: 0 closed, 1 at the peak.
  double shape(double t) {
    if (t <= start || t >= end) return 0;
    final u = t - start;
    if (u < open) return easeOutCubic(u / open);
    if (u < open + hold) return 1 - sag * ((u - open) / hold);
    return (1 - sag) * (1 - easeInCubic((u - open - hold) / close));
  }
}

/// Peak jaw drop in line heights for `jawOpen == 1`.
const double kJawMaxDropLines = 1.08;

/// Maximum head bob (upwards) in line heights for `headBob == 1`.
const double kHeadBobLines = 0.10;

/// Maximum backwards head tilt (chin up) in degrees for `headBob == 1`.
const double kHeadPitchDegrees = 3.0;

/// Length of one laugh (three pulses) in seconds.
const double kLaughDuration = 1.5;

/// The three pulses: "HA" (1.0 line heights), a quicker, smaller "ha"
/// (0.92) and a long, widest final "HA!" (1.08).
const List<LaughPulse> kLaughPulses = <LaughPulse>[
  LaughPulse(start: 0.05, open: 0.14, hold: 0.06, close: 0.17, amplitude: 1.0 / kJawMaxDropLines, tilt: 2.2),
  LaughPulse(start: 0.52, open: 0.12, hold: 0.05, close: 0.15, amplitude: 0.92 / kJawMaxDropLines, tilt: -1.8),
  LaughPulse(start: 0.95, open: 0.16, hold: 0.10, close: 0.24, amplitude: 1.0, tilt: 2.8),
];

/// Lag of the head bob behind the jaw (the head follows the laugh).
const double kHeadLag = 0.03;

/// Jaw opening 0..1 of a laugh that started at local time 0.
double laughJawOpen(double t) {
  for (final p in kLaughPulses) {
    if (t > p.start && t < p.end) return p.amplitude * p.shape(t);
  }
  return 0;
}

/// Jaw roll in degrees of a laugh that started at local time 0.
double laughJawTilt(double t) {
  for (final p in kLaughPulses) {
    if (t > p.start && t < p.end) return p.tilt * p.shape(t);
  }
  return 0;
}

/// Head bob/tilt 0..1 of a laugh that started at local time 0.
double laughHeadBob(double t) => laughJawOpen(t - kHeadLag);

/// Visual parameters of the skull at one instant.
class SkullPose {
  const SkullPose({this.jawOpen = 0, this.jawTilt = 0, this.headBob = 0, this.eyeGlow = kEyeBaseGlow});

  /// Pose of a laugh that started at local time [t].
  factory SkullPose.laughing(double t, {double eyeBase = kEyeBaseGlow}) {
    final open = laughJawOpen(t);
    return SkullPose(
      jawOpen: open,
      jawTilt: laughJawTilt(t),
      headBob: laughHeadBob(t),
      eyeGlow: (eyeBase + (1 - eyeBase) * open).clamp(0.0, 1.0),
    );
  }

  /// 0 closed .. 1 fully open ([kJawMaxDropLines]).
  final double jawOpen;

  /// Jaw roll in degrees about the hinge.
  final double jawTilt;

  /// 0..1 head lift ([kHeadBobLines]) and backwards tilt ([kHeadPitchDegrees]).
  final double headBob;

  /// 0 dark .. 1 full eye glow.
  final double eyeGlow;

  static const SkullPose closed = SkullPose();
  static const SkullPose dark = SkullPose(eyeGlow: 0);

  @override
  bool operator ==(Object other) =>
      other is SkullPose &&
      other.jawOpen == jawOpen &&
      other.jawTilt == jawTilt &&
      other.headBob == headBob &&
      other.eyeGlow == eyeGlow;

  @override
  int get hashCode => Object.hash(jawOpen, jawTilt, headBob, eyeGlow);
}

/// Resting eye glow once the eyes are lit.
const double kEyeBaseGlow = 0.72;

/// The complete intro timeline.
///
/// With [decorative] false (low-effects mode, `EffectsConfig.intensity == 0`)
/// the signal flicker and the glitch burst have zero length; the laugh, the
/// reveal and the title are unchanged.
class IntroTimeline {
  IntroTimeline({this.decorative = true}) : phases = _build(decorative);

  static const double darknessDuration = 0.30;
  static const double signalDuration = 0.30;
  static const double revealDuration = 0.60;
  static const double glitchDuration = 0.22;
  static const double titleDuration = 0.90;
  static const double outroDuration = 0.40;

  /// Fraction of the reveal at which the scanline crosses the eyes and they
  /// ignite (the eye centres sit at ~48% of the skull's height).
  static const double eyeIgniteAt = 0.48;

  /// Length of the eye ignition flicker.
  static const double igniteDuration = 0.22;

  /// Staggered starts and length of the three title lines, relative to the
  /// title phase.
  static const List<double> titleLineStarts = <double>[0.00, 0.10, 0.18];
  static const double titleLineDuration = 0.28;

  /// Typing window of "J3NSONTOP SYSTEM ONLINE", relative to the title phase.
  static const double taglineStart = 0.36;
  static const double taglineEnd = 0.78;

  /// Cursor blink period.
  static const double cursorPeriod = 0.24;

  /// Glitch frames change every [glitchFrameLength] seconds.
  static const double glitchFrameLength = 0.045;

  final bool decorative;

  /// One window per [IntroPhase], in order, back to back.
  final List<PhaseWindow> phases;

  static List<PhaseWindow> _build(bool decorative) {
    final durations = <IntroPhase, double>{
      IntroPhase.darkness: darknessDuration,
      IntroPhase.signal: decorative ? signalDuration : 0,
      IntroPhase.reveal: revealDuration,
      IntroPhase.laugh: kLaughDuration,
      IntroPhase.glitch: decorative ? glitchDuration : 0,
      IntroPhase.title: titleDuration,
      IntroPhase.outro: outroDuration,
    };
    var t = 0.0;
    return [for (final p in IntroPhase.values) PhaseWindow(p, t, t += durations[p]!)];
  }

  PhaseWindow operator [](IntroPhase phase) => phases[phase.index];

  /// Total length in seconds.
  double get total => phases.last.end;

  Duration get duration => Duration(microseconds: (total * 1e6).round());

  /// The phase active at [t] (the outro once the sequence has ended).
  IntroPhase phaseAt(double t) {
    for (final w in phases) {
      if (!w.isEmpty && w.contains(t)) return w.phase;
    }
    return t < 0 ? IntroPhase.darkness : IntroPhase.outro;
  }

  /// Where the sound clip (authored for the decorative timeline) must be
  /// when this timeline is at 0, so the "HA"s stay on the jaw.
  double get soundOffset => IntroTimeline()[IntroPhase.laugh].start - this[IntroPhase.laugh].start;

  // ---------------------------------------------------------------- skull --

  /// Jaw opening 0..1 (three pulses during the laugh phase, closed otherwise).
  double jawOpen(double t) => laughJawOpen(t - this[IntroPhase.laugh].start);

  /// Jaw roll in degrees.
  double jawTilt(double t) => laughJawTilt(t - this[IntroPhase.laugh].start);

  /// Head lift/tilt 0..1, following the jaw with a short lag.
  double headBob(double t) => laughHeadBob(t - this[IntroPhase.laugh].start);

  /// Eye glow 0..1: ignites (with a flicker when [decorative]) as the reveal
  /// scanline crosses the eyes, pulses with the laughs, flares in the glitch
  /// and fades with the scene.
  double eyeGlow(double t) {
    final ignite = eyeIgniteTime;
    if (t < ignite) return 0;
    final u = (t - ignite) / igniteDuration;
    var g = u >= 1
        ? kEyeBaseGlow
        : decorative
        ? _steps(_igniteFlicker, u)
        : kEyeBaseGlow * easeOutCubic(u);
    g += (1 - kEyeBaseGlow) * jawOpen(t);
    g += 0.25 * glitch(t);
    if (decorative && t >= this[IntroPhase.title].start) {
      // Slow smoulder while the title is on screen.
      g += 0.06 * math.sin(2 * math.pi * (t - this[IntroPhase.title].start) / 0.9);
    }
    return (g * sceneOpacity(t)).clamp(0.0, 1.0);
  }

  double get eyeIgniteTime {
    final r = this[IntroPhase.reveal];
    return r.start + r.duration * eyeIgniteAt;
  }

  static const List<(double, double)> _igniteFlicker = <(double, double)>[
    (0.00, 0.95),
    (0.14, 0.10),
    (0.27, 1.00),
    (0.45, 0.30),
    (0.55, 0.90),
    (0.75, kEyeBaseGlow),
  ];

  /// The full skull pose at [t].
  SkullPose pose(double t) =>
      SkullPose(jawOpen: jawOpen(t), jawTilt: jawTilt(t), headBob: headBob(t), eyeGlow: eyeGlow(t));

  // --------------------------------------------------------------- reveal --

  /// Fraction 0..1 of the skull's height revealed by the scanline.
  double reveal(double t) => this[IntroPhase.reveal].progress(t);

  /// Whether the reveal scanline is on screen.
  bool revealing(double t) => this[IntroPhase.reveal].contains(t);

  /// Opacity of the black cover hiding the app backdrop: fully dark until
  /// the reveal, then easing away until the title is complete.
  double cover(double t) {
    final from = this[IntroPhase.reveal].start;
    final to = this[IntroPhase.title].end;
    if (t <= from) return 1;
    if (t >= to) return 0;
    return 1 - easeInOutCubic((t - from) / (to - from));
  }

  // --------------------------------------------------------------- signal --

  /// Brightness 0..1 of the flickering signal line (0 when not decorative).
  double signal(double t) {
    final w = this[IntroPhase.signal];
    if (w.isEmpty || !w.contains(t)) return 0;
    return _steps(_signalFlicker, w.progress(t));
  }

  /// Horizontal extent 0..1 of the signal line (grows from the centre).
  double signalWidth(double t) => easeOutCubic((this[IntroPhase.signal].progress(t) / 0.35).clamp(0.0, 1.0));

  static const List<(double, double)> _signalFlicker = <(double, double)>[
    (0.00, 0.00),
    (0.05, 1.00),
    (0.11, 0.15),
    (0.17, 0.90),
    (0.29, 0.00),
    (0.35, 0.75),
    (0.45, 1.00),
    (0.64, 0.30),
    (0.71, 1.00),
    (0.88, 0.55),
    (0.96, 0.00),
  ];

  // --------------------------------------------------------------- glitch --

  /// Glitch strength 0..1: a choppy, decaying burst (0 when not decorative).
  double glitch(double t) {
    final w = this[IntroPhase.glitch];
    if (w.isEmpty || !w.contains(t)) return 0;
    final p = w.progress(t);
    const chop = <double>[1.0, 0.55, 0.9, 0.35, 0.7];
    final step = chop[math.min(chop.length - 1, (p * chop.length).floor())];
    return step * (1 - 0.6 * p);
  }

  /// Index of the current glitch frame (slice layout changes per frame).
  int glitchFrame(double t) => ((t - this[IntroPhase.glitch].start) / glitchFrameLength).floor();

  // ---------------------------------------------------------------- title --

  /// Reveal progress 0..1 of title line [index] (see `AppInfo.fullNameLines`).
  double titleLine(int index, double t) {
    final w = this[IntroPhase.title];
    final start = w.start + titleLineStarts[math.min(index, titleLineStarts.length - 1)];
    if (t >= w.end) return 1;
    return easeOutCubic(((t - start) / titleLineDuration).clamp(0.0, 1.0));
  }

  /// Typing progress 0..1 of the tagline.
  double tagline(double t) {
    final w = this[IntroPhase.title];
    if (t >= w.end) return 1;
    return ((t - w.start - taglineStart) / (taglineEnd - taglineStart)).clamp(0.0, 1.0);
  }

  /// Whether the block cursor after the tagline is lit.
  bool cursorOn(double t) {
    final since = t - this[IntroPhase.title].start - taglineStart;
    if (since < 0) return false;
    if (tagline(t) < 1) return true;
    return (since / cursorPeriod).floor().isEven;
  }

  // ---------------------------------------------------------------- outro --

  /// Outro progress 0..1.
  double outro(double t) => this[IntroPhase.outro].progress(t);

  /// Opacity of everything on screen (fades out during the outro).
  double sceneOpacity(double t) => 1 - easeInCubic(outro(t));

  /// Position 0..1 (top to bottom) of the outro wipe line.
  double wipe(double t) => easeInOutCubic(outro(t));

  // ----------------------------------------------------------------- cues --

  /// Timing cues for the sound generator (seconds, 3 decimals). Must equal
  /// `tool/sound/intro_cues.json` for the decorative timeline.
  Map<String, Object> cueSheet() {
    double r(double v) => (v * 1000).round() / 1000;
    List<double> span(IntroPhase p) => [r(this[p].start), r(this[p].end)];
    final laughStart = this[IntroPhase.laugh].start;
    return <String, Object>{
      'total': r(total),
      'signal': span(IntroPhase.signal),
      'signalFlicker': [
        for (final (at, v) in _signalFlicker) [r(this[IntroPhase.signal].start + at * signalDuration), v],
      ],
      'reveal': span(IntroPhase.reveal),
      'eyeIgnite': r(eyeIgniteTime),
      'laugh': span(IntroPhase.laugh),
      'pulses': [
        for (final p in kLaughPulses)
          {
            'start': r(laughStart + p.start),
            'peak': r(laughStart + p.peak),
            'holdEnd': r(laughStart + p.peak + p.hold),
            'end': r(laughStart + p.end),
            'amplitude': r(p.amplitude),
          },
      ],
      'glitch': span(IntroPhase.glitch),
      'title': span(IntroPhase.title),
      'taglineDone': r(this[IntroPhase.title].start + taglineEnd),
      'outro': span(IntroPhase.outro),
    };
  }
}

/// Holds each key value until the next key (a hard flicker, not a fade).
double _steps(List<(double, double)> keys, double p) {
  var v = keys.first.$2;
  for (final (at, value) in keys) {
    if (p >= at) v = value;
  }
  return v;
}

double easeOutCubic(double x) {
  final c = x.clamp(0.0, 1.0);
  return 1 - math.pow(1 - c, 3).toDouble();
}

double easeInCubic(double x) {
  final c = x.clamp(0.0, 1.0);
  return c * c * c;
}

double easeInOutCubic(double x) {
  final c = x.clamp(0.0, 1.0);
  return c < 0.5 ? 4 * c * c * c : 1 - math.pow(-2 * c + 2, 3).toDouble() / 2;
}
