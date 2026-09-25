import '../storage/json_store.dart';
import '../theme/j3_colors.dart';

/// How the app decides whether to reduce motion.
enum MotionPreference {
  system('Follow system'),
  reduced('Always reduce'),
  full('Full motion');

  const MotionPreference(this.label);
  final String label;
}

/// User preferences. Immutable; update with [copyWith].
class AppSettings {
  const AppSettings({
    this.skipIntro = false,
    this.motion = MotionPreference.system,
    this.intensity = 0.75,
    this.scanlines = true,
    this.particles = true,
    this.glow = true,
    this.lowEffects = false,
    this.sound = false,
    this.volume = 0.6,
    this.accent = AccentPreset.neon,
    this.showActivityPanel = true,
    this.sampleWorkspaceCreated = false,
  });

  /// Skip the laughing-skull intro on launch.
  final bool skipIntro;
  final MotionPreference motion;

  /// Animation intensity 0..1 (glitch strength, particle count, bloom).
  final double intensity;
  final bool scanlines;
  final bool particles;
  final bool glow;

  /// Master switch that disables scanlines, particles, bloom and glitches
  /// for long sessions or slow devices.
  final bool lowEffects;

  /// Optional sounds. Off by default.
  final bool sound;
  final double volume;
  final AccentPreset accent;

  /// Desktop: show the live activity panel on the right.
  final bool showActivityPanel;

  /// The first-run sample workspace has been created (or was declined).
  final bool sampleWorkspaceCreated;

  AppSettings copyWith({
    bool? skipIntro,
    MotionPreference? motion,
    double? intensity,
    bool? scanlines,
    bool? particles,
    bool? glow,
    bool? lowEffects,
    bool? sound,
    double? volume,
    AccentPreset? accent,
    bool? showActivityPanel,
    bool? sampleWorkspaceCreated,
  }) {
    return AppSettings(
      skipIntro: skipIntro ?? this.skipIntro,
      motion: motion ?? this.motion,
      intensity: intensity ?? this.intensity,
      scanlines: scanlines ?? this.scanlines,
      particles: particles ?? this.particles,
      glow: glow ?? this.glow,
      lowEffects: lowEffects ?? this.lowEffects,
      sound: sound ?? this.sound,
      volume: volume ?? this.volume,
      accent: accent ?? this.accent,
      showActivityPanel: showActivityPanel ?? this.showActivityPanel,
      sampleWorkspaceCreated: sampleWorkspaceCreated ?? this.sampleWorkspaceCreated,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'skipIntro': skipIntro,
    'motion': motion.name,
    'intensity': intensity,
    'scanlines': scanlines,
    'particles': particles,
    'glow': glow,
    'lowEffects': lowEffects,
    'sound': sound,
    'volume': volume,
    'accent': accent.name,
    'showActivityPanel': showActivityPanel,
    'sampleWorkspaceCreated': sampleWorkspaceCreated,
  };

  /// Tolerant decoding: invalid or missing fields fall back individually.
  factory AppSettings.fromJson(Map<String, dynamic> j) {
    const d = AppSettings();
    return AppSettings(
      skipIntro: JsonRead.boolean(j, 'skipIntro', d.skipIntro),
      motion: JsonRead.enumByName(j, 'motion', MotionPreference.values, d.motion),
      intensity: JsonRead.number(j, 'intensity', d.intensity, min: 0, max: 1),
      scanlines: JsonRead.boolean(j, 'scanlines', d.scanlines),
      particles: JsonRead.boolean(j, 'particles', d.particles),
      glow: JsonRead.boolean(j, 'glow', d.glow),
      lowEffects: JsonRead.boolean(j, 'lowEffects', d.lowEffects),
      sound: JsonRead.boolean(j, 'sound', d.sound),
      volume: JsonRead.number(j, 'volume', d.volume, min: 0, max: 1),
      accent: JsonRead.enumByName(j, 'accent', AccentPreset.values, d.accent),
      showActivityPanel: JsonRead.boolean(j, 'showActivityPanel', d.showActivityPanel),
      sampleWorkspaceCreated: JsonRead.boolean(j, 'sampleWorkspaceCreated', d.sampleWorkspaceCreated),
    );
  }
}
