import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/theme/effects.dart';
import 'package:j3nsontop_multitool/core/theme/j3_colors.dart';
import 'package:j3nsontop_multitool/core/theme/j3_theme.dart';
import 'package:j3nsontop_multitool/features/intro/intro_sound.dart';

import '../../helpers/harness.dart';

/// Full effects at the default intensity, sound off (the app default).
const EffectsConfig fullFx = EffectsConfig(
  reduceMotion: false,
  intensity: 0.75,
  scanlines: true,
  particles: false,
  glow: true,
  accent: AccentPreset.neon,
  sound: false,
  volume: 0.6,
);

/// Low-effects mode as resolved by `EffectsConfig.resolve` (intensity 0,
/// no glow/scanlines/particles) with motion allowed.
const EffectsConfig lowFx = EffectsConfig(
  reduceMotion: false,
  intensity: 0,
  scanlines: false,
  particles: false,
  glow: false,
  accent: AccentPreset.neon,
  sound: false,
  volume: 0.6,
);

/// Reduced motion.
const EffectsConfig reducedFx = EffectsConfig(
  reduceMotion: true,
  intensity: 0.75,
  scanlines: true,
  particles: false,
  glow: true,
  accent: AccentPreset.neon,
  sound: false,
  volume: 0.6,
);

/// Hosts [child] like the app does (theme + effects), with the test env's
/// providers.
Widget introHost(ProviderContainer container, Widget child, {EffectsConfig fx = fullFx, Key? boundaryKey}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: J3Theme.build(fx.accent),
      home: J3Effects(
        config: fx,
        child: RepaintBoundary(key: boundaryKey, child: child),
      ),
    ),
  );
}

/// Container for [env] with optional extra overrides.
ProviderContainer introContainer(TestEnv env, {List<Override> extra = const []}) {
  final container = ProviderContainer(overrides: [...env.overrides(), ...extra]);
  addTearDown(container.dispose);
  return container;
}

/// Records calls instead of playing audio.
class FakeIntroSound implements IntroSound {
  final List<String> calls = [];
  double? volume;
  Duration? startPosition;

  @override
  Future<void> start({required double volume, required Duration Function() position}) async {
    this.volume = volume;
    startPosition = position();
    calls.add('start');
  }

  @override
  void stop() => calls.add('stop');

  @override
  void dispose() => calls.add('dispose');
}

/// Advances the intro clock to absolute time [seconds] (the first
/// `pump()` after `pumpWidget` is t = 0).
class IntroClock {
  IntroClock(this.tester);
  final WidgetTester tester;
  double now = 0;

  Future<void> to(double seconds) async {
    final dt = seconds - now;
    if (dt < 0) throw ArgumentError('time runs forward');
    now = seconds;
    await tester.pump(Duration(microseconds: (dt * 1e6).round()));
  }
}
