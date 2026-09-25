import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/intro/intro_timeline.dart';

/// Samples [f] over [from, to] every [step] seconds.
List<double> _sample(double Function(double) f, double from, double to, {double step = 0.002}) => [
  for (var t = from; t <= to + 1e-9; t += step) f(t),
];

/// Number of strict local maxima, treating plateaus as one extremum.
int _localMaxima(List<double> values) {
  var count = 0;
  var rising = false;
  for (var i = 1; i < values.length; i++) {
    final d = values[i] - values[i - 1];
    if (d > 1e-9) {
      rising = true;
    } else if (d < -1e-9) {
      if (rising) count++;
      rising = false;
    }
  }
  return count;
}

void main() {
  group('IntroTimeline (full effects)', () {
    final tl = IntroTimeline();
    final laugh = tl[IntroPhase.laugh];

    test('total duration is within 3-5 s and close to 4.2 s', () {
      expect(tl.total, inInclusiveRange(3.0, 5.0));
      expect(tl.total, closeTo(4.2, 0.1));
      expect(tl.duration.inMilliseconds, (tl.total * 1000).round());
    });

    test('phases are ordered, contiguous and in the specified ranges', () {
      expect(tl.phases.map((w) => w.phase), IntroPhase.values);
      expect(tl.phases.first.start, 0);
      for (var i = 1; i < tl.phases.length; i++) {
        expect(tl.phases[i].start, closeTo(tl.phases[i - 1].end, 1e-9));
        expect(tl.phases[i].end, greaterThanOrEqualTo(tl.phases[i].start));
      }
      expect(tl[IntroPhase.darkness].duration, closeTo(0.3, 1e-9));
      expect(tl[IntroPhase.signal].duration, closeTo(0.3, 1e-9));
      expect(tl[IntroPhase.reveal].duration, closeTo(0.6, 1e-9));
      expect(laugh.duration, closeTo(1.5, 1e-9));
      expect(tl[IntroPhase.glitch].duration, lessThanOrEqualTo(0.25));
      expect(tl[IntroPhase.outro].duration, closeTo(0.4, 1e-9));
    });

    test('phaseAt follows the windows', () {
      expect(tl.phaseAt(0), IntroPhase.darkness);
      expect(tl.phaseAt(0.45), IntroPhase.signal);
      expect(tl.phaseAt(0.9), IntroPhase.reveal);
      expect(tl.phaseAt(laugh.start + 0.1), IntroPhase.laugh);
      expect(tl.phaseAt(tl[IntroPhase.glitch].start + 0.01), IntroPhase.glitch);
      expect(tl.phaseAt(tl[IntroPhase.title].start + 0.01), IntroPhase.title);
      expect(tl.phaseAt(tl.total - 0.01), IntroPhase.outro);
      expect(tl.phaseAt(tl.total + 1), IntroPhase.outro);
    });

    test('jaw: exactly three distinct local maxima during the laugh', () {
      final values = _sample(tl.jawOpen, laugh.start, laugh.end, step: 0.001);
      expect(_localMaxima(values), 3);
      final peaks = [for (final p in kLaughPulses) tl.jawOpen(laugh.start + p.peak)];
      // Peaks are near 1 line height (0.9..1.1) and all different.
      for (final v in peaks) {
        expect(v * kJawMaxDropLines, inInclusiveRange(0.9, 1.1));
      }
      expect(peaks.toSet().length, 3);
      expect(peaks.reduce((a, b) => a > b ? a : b), 1.0);
      // Pulse timing differs so it reads as HA-HA-HA, not a metronome.
      final gaps = [for (var i = 1; i < kLaughPulses.length; i++) kLaughPulses[i].start - kLaughPulses[i - 1].start];
      expect(gaps.toSet().length, gaps.length);
    });

    test('jaw is fully closed before and after the laugh and between pulses', () {
      for (final v in _sample(tl.jawOpen, 0, laugh.start)) {
        expect(v, 0);
      }
      for (final v in _sample(tl.jawOpen, laugh.end, tl.total + 0.5)) {
        expect(v, 0);
      }
      for (var i = 1; i < kLaughPulses.length; i++) {
        final gap = (kLaughPulses[i - 1].end + kLaughPulses[i].start) / 2;
        expect(tl.jawOpen(laugh.start + gap), 0, reason: 'mouth snaps shut between pulses');
      }
      for (final v in _sample(tl.jawOpen, laugh.start, laugh.end)) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });

    test('jaw opens with ease-out and closes with ease-in', () {
      final p = kLaughPulses.first;
      final s = laugh.start + p.start;
      // Ease-out: more than half open after a third of the opening.
      expect(tl.jawOpen(s + p.open / 3) / tl.jawOpen(s + p.open), greaterThan(0.5));
      // Ease-in: still mostly open after a third of the closing.
      final c = laugh.start + p.peak + p.hold;
      expect(tl.jawOpen(c + p.close / 3) / tl.jawOpen(c), greaterThan(0.6));
    });

    test('jaw tilt stays within 3 degrees and alternates', () {
      for (final v in _sample(tl.jawTilt, 0, tl.total)) {
        expect(v.abs(), lessThanOrEqualTo(3.0));
      }
      final signs = [for (final p in kLaughPulses) tl.jawTilt(laugh.start + p.peak).sign];
      expect(signs[0], isNot(signs[1]));
    });

    test('head bob stays within 0..1, lags the jaw and is still outside the laugh', () {
      for (final v in _sample(tl.headBob, 0, tl.total)) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
      expect(kHeadBobLines, lessThanOrEqualTo(0.25));
      expect(tl.headBob(laugh.start - 0.05), 0);
      final p = kLaughPulses.first;
      expect(tl.headBob(laugh.start + p.start + 0.02), lessThan(tl.jawOpen(laugh.start + p.start + 0.02)));
    });

    test('eyes are dark until ignition, flicker on, pulse with the laugh', () {
      final ignite = tl.eyeIgniteTime;
      expect(ignite, greaterThan(tl[IntroPhase.reveal].start));
      expect(ignite, lessThan(tl[IntroPhase.reveal].end));
      for (final v in _sample(tl.eyeGlow, 0, ignite - 0.001)) {
        expect(v, 0);
      }
      // Flicker: not monotonic during ignition.
      final ignition = _sample(tl.eyeGlow, ignite, ignite + IntroTimeline.igniteDuration);
      expect(_localMaxima(ignition), greaterThanOrEqualTo(2));
      final rest = tl.eyeGlow(laugh.start + 0.02);
      final peak = tl.eyeGlow(laugh.start + kLaughPulses[2].peak);
      expect(rest, closeTo(kEyeBaseGlow, 0.05));
      expect(peak, greaterThan(rest + 0.2));
      for (final v in _sample(tl.eyeGlow, 0, tl.total)) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });

    test('glitch burst is short and only inside its window', () {
      final g = tl[IntroPhase.glitch];
      expect(g.duration, lessThanOrEqualTo(0.25));
      for (final v in _sample(tl.glitch, 0, g.start - 0.001)) {
        expect(v, 0);
      }
      for (final v in _sample(tl.glitch, g.end, tl.total)) {
        expect(v, 0);
      }
      expect(tl.glitch(g.start + 0.01), greaterThan(0.5));
      expect(tl.glitchFrame(g.start + 0.1), greaterThan(tl.glitchFrame(g.start)));
    });

    test('signal flickers inside its window only', () {
      final s = tl[IntroPhase.signal];
      expect(tl.signal(s.start - 0.01), 0);
      expect(tl.signal(s.end + 0.01), 0);
      final values = _sample(tl.signal, s.start, s.end, step: 0.005);
      expect(_localMaxima(values), greaterThanOrEqualTo(3));
    });

    test('reveal, title, tagline and outro progress in order', () {
      expect(tl.reveal(tl[IntroPhase.reveal].start), 0);
      expect(tl.reveal(tl[IntroPhase.reveal].end), closeTo(1, 1e-9));
      final title = tl[IntroPhase.title];
      for (var i = 0; i < 3; i++) {
        expect(tl.titleLine(i, title.start - 0.01), 0);
        expect(tl.titleLine(i, title.end), closeTo(1, 1e-9));
      }
      // Lines are staggered.
      expect(tl.titleLine(0, title.start + 0.12), greaterThan(tl.titleLine(2, title.start + 0.12)));
      expect(tl.tagline(title.start + IntroTimeline.taglineStart - 0.01), 0);
      expect(tl.tagline(title.start + IntroTimeline.taglineEnd), closeTo(1, 1e-9));
      expect(tl.sceneOpacity(tl[IntroPhase.outro].start), closeTo(1, 1e-9));
      expect(tl.sceneOpacity(tl.total), closeTo(0, 1e-9));
      expect(tl.wipe(tl.total), closeTo(1, 1e-9));
      expect(tl.cover(0), 1);
      expect(tl.cover(tl[IntroPhase.title].end), closeTo(0, 1e-9));
    });
  });

  group('IntroTimeline (low effects)', () {
    final low = IntroTimeline(decorative: false);
    final full = IntroTimeline();

    test('drops the signal flicker and the glitch, keeps the laugh', () {
      expect(low[IntroPhase.signal].isEmpty, isTrue);
      expect(low[IntroPhase.glitch].isEmpty, isTrue);
      expect(low.total, inInclusiveRange(3.0, 5.0));
      expect(low.total, lessThan(full.total));
      for (final v in _sample(low.glitch, 0, low.total)) {
        expect(v, 0);
      }
      for (final v in _sample(low.signal, 0, low.total)) {
        expect(v, 0);
      }
      final laugh = low[IntroPhase.laugh];
      expect(_localMaxima(_sample(low.jawOpen, laugh.start, laugh.end, step: 0.001)), 3);
    });

    test('sound offset keeps the HAs on the jaw', () {
      expect(full.soundOffset, 0);
      expect(low.soundOffset, closeTo(full[IntroPhase.laugh].start - low[IntroPhase.laugh].start, 1e-9));
      // At the first peak of the low timeline, the clip is at the full timeline's first peak.
      final lowPeak = low[IntroPhase.laugh].start + kLaughPulses.first.peak;
      final fullPeak = full[IntroPhase.laugh].start + kLaughPulses.first.peak;
      expect(lowPeak + low.soundOffset, closeTo(fullPeak, 1e-9));
    });
  });

  test('SkullPose.laughing matches the laugh functions', () {
    final t = kLaughPulses[1].peak;
    final pose = SkullPose.laughing(t);
    expect(pose.jawOpen, laughJawOpen(t));
    expect(pose.jawTilt, laughJawTilt(t));
    expect(pose.headBob, laughHeadBob(t));
    expect(pose.eyeGlow, greaterThan(kEyeBaseGlow));
    expect(SkullPose.laughing(kLaughDuration), SkullPose.closed);
  });

  test('sound cue sheet matches tool/sound/intro_cues.json', () {
    final file = File('tool/sound/intro_cues.json');
    expect(file.existsSync(), isTrue, reason: 'run `dart run tool/sound/export_cues.dart` (see docs/INTRO.md)');
    final onDisk = jsonDecode(file.readAsStringSync());
    final expected = jsonDecode(jsonEncode(IntroTimeline().cueSheet()));
    expect(onDisk, expected, reason: 'regenerate the cues and the sound after changing the timeline');
  });
}
