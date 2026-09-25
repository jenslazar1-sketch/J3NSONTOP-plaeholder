import 'package:flutter/widgets.dart';

import '../settings/app_settings.dart';
import 'j3_colors.dart';

/// Resolved visual-effect settings for the current frame: user preferences
/// combined with the system accessibility flags (reduce motion).
///
/// Widgets read it with `J3Effects.of(context)`.
@immutable
class EffectsConfig {
  const EffectsConfig({
    required this.reduceMotion,
    required this.intensity,
    required this.scanlines,
    required this.particles,
    required this.glow,
    required this.accent,
    required this.sound,
    required this.volume,
  });

  /// [systemHighContrast] (OS accessibility setting) removes decorative
  /// scanlines, particles and bloom that reduce legibility.
  factory EffectsConfig.resolve(AppSettings s, {required bool systemReduce, bool systemHighContrast = false}) {
    final reduce = switch (s.motion) {
      MotionPreference.system => systemReduce,
      MotionPreference.reduced => true,
      MotionPreference.full => false,
    };
    final low = s.lowEffects || systemHighContrast;
    return EffectsConfig(
      reduceMotion: reduce,
      intensity: low ? 0 : s.intensity,
      scanlines: !low && s.scanlines,
      particles: !low && !reduce && s.particles,
      glow: !low && s.glow,
      accent: s.accent,
      sound: s.sound,
      volume: s.volume,
    );
  }

  static const EffectsConfig fallback = EffectsConfig(
    reduceMotion: false,
    intensity: 0.75,
    scanlines: true,
    particles: true,
    glow: true,
    accent: AccentPreset.neon,
    sound: false,
    volume: 0.6,
  );

  /// No movement-based animation (glitches, drifting, laughing jaw).
  final bool reduceMotion;

  /// 0..1 strength of decorative effects. 0 in low-effects mode.
  final double intensity;
  final bool scanlines;
  final bool particles;
  final bool glow;
  final AccentPreset accent;
  final bool sound;
  final double volume;

  /// Whether decorative motion (glitch, drift, pulse) may play.
  bool get decorativeMotion => !reduceMotion && intensity > 0;

  /// Scales a decorative animation duration; zero when motion is reduced.
  Duration motion(Duration d) => reduceMotion ? Duration.zero : d;

  /// Glow blur radius scaled by intensity (0 when glow is off).
  double glowBlur(double base) => glow ? base * (0.35 + 0.65 * intensity) : 0;

  Color get accentColor => accent.accent;
  Color get accentText => accent.accentText;
  Color get accentDeep => accent.accentDeep;

  @override
  bool operator ==(Object other) =>
      other is EffectsConfig &&
      other.reduceMotion == reduceMotion &&
      other.intensity == intensity &&
      other.scanlines == scanlines &&
      other.particles == particles &&
      other.glow == glow &&
      other.accent == accent &&
      other.sound == sound &&
      other.volume == volume;

  @override
  int get hashCode => Object.hash(reduceMotion, intensity, scanlines, particles, glow, accent, sound, volume);
}

class J3Effects extends InheritedWidget {
  const J3Effects({super.key, required this.config, required super.child});

  final EffectsConfig config;

  static EffectsConfig of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<J3Effects>()?.config ?? EffectsConfig.fallback;

  @override
  bool updateShouldNotify(J3Effects oldWidget) => oldWidget.config != config;
}

extension EffectsContext on BuildContext {
  EffectsConfig get effects => J3Effects.of(this);
}
