import 'package:flutter/painting.dart';

/// Colour tokens. Contrast ratios (WCAG 2.x) were measured against every
/// surface and are documented in docs/DESIGN.md:
///
/// * [text] >= 15:1, [textSecondary] >= 8.4:1, [textMuted] >= 5.2:1 on all
///   surfaces, so all three are valid for normal-size text.
/// * [neon] is 4.3-5.3:1. Use it for borders, glows, icons and large text.
///   For small red text use [neonText] (>= 5.1:1 everywhere).
/// * White on [neon] is only 3.5:1, therefore filled buttons use [darkRed]
///   (white text 10.4:1) with a neon border instead of a neon fill.
abstract final class J3Colors {
  // Surfaces
  static const Color background = Color(0xFF050507);
  static const Color surface = Color(0xFF101015);
  static const Color surfaceRaised = Color(0xFF16161D);
  static const Color surfaceHigh = Color(0xFF1E1E28);
  static const Color inputFill = Color(0xFF0B0B10);
  static const Color border = Color(0xFF2B2B36);
  static const Color borderStrong = Color(0xFF3D3D4C);

  // Brand
  static const Color neon = Color(0xFFFF163B);
  static const Color neonText = Color(0xFFFF4D6A);
  static const Color darkRed = Color(0xFF750C20);
  static const Color darkRedHover = Color(0xFF8E1029);
  static const Color selection = Color(0xFF3A0610);

  // Text
  static const Color text = Color(0xFFF4F4F7);
  static const Color textSecondary = Color(0xFFB8B8C7);
  static const Color textMuted = Color(0xFF9090A2);
  static const Color textDisabled = Color(0xFF5E5E6E);

  // Status. Always paired with an icon and/or a text label.
  static const Color success = Color(0xFF34E39A);
  static const Color warning = Color(0xFFFFC04D);
  static const Color error = Color(0xFFFF5C6C);
  static const Color info = Color(0xFF7FB3FF);

  static Color neonGlow(double opacity) => neon.withValues(alpha: opacity);
}

/// Accent presets offered in Settings. All stay inside the red identity.
enum AccentPreset {
  neon('Neon red', Color(0xFFFF163B), Color(0xFFFF4D6A), Color(0xFF750C20)),
  crimson('Crimson', Color(0xFFE0112B), Color(0xFFFF5566), Color(0xFF6A0B1C)),
  infrared('Infrared', Color(0xFFFF2A55), Color(0xFFFF6680), Color(0xFF7A0E2E)),
  ember('Ember', Color(0xFFFF3B1F), Color(0xFFFF6A50), Color(0xFF761A0C));

  const AccentPreset(this.label, this.accent, this.accentText, this.accentDeep);

  final String label;

  /// Borders, glows, icons, large text.
  final Color accent;

  /// Small text in the accent colour (>= 4.5:1 on all surfaces).
  final Color accentText;

  /// Filled controls (white text on top).
  final Color accentDeep;
}
