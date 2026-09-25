import 'package:flutter/painting.dart';

import 'j3_colors.dart';

/// Typography tokens. Two bundled, OFL-licensed families:
/// * [ui] - Chakra Petch for labels, headings and body text.
/// * [mono] - JetBrains Mono for ASCII art, code, paths and logs.
abstract final class J3Type {
  static const String ui = 'ChakraPetch';
  static const String mono = 'JetBrainsMono';

  /// Disable ligatures/contextual alternates so every character occupies
  /// exactly one column. Required for ASCII art and aligned code.
  static const List<FontFeature> asciiFeatures = <FontFeature>[
    FontFeature.disable('liga'),
    FontFeature.disable('calt'),
    FontFeature.disable('dlig'),
  ];

  static const TextStyle display = TextStyle(
    fontFamily: ui,
    fontSize: 34,
    fontWeight: FontWeight.w700,
    letterSpacing: 2.0,
    height: 1.1,
    color: J3Colors.text,
  );

  static const TextStyle headline = TextStyle(
    fontFamily: ui,
    fontSize: 24,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.2,
    height: 1.2,
    color: J3Colors.text,
  );

  static const TextStyle title = TextStyle(
    fontFamily: ui,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
    height: 1.25,
    color: J3Colors.text,
  );

  static const TextStyle subtitle = TextStyle(
    fontFamily: ui,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.6,
    height: 1.3,
    color: J3Colors.text,
  );

  static const TextStyle body = TextStyle(
    fontFamily: ui,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    height: 1.4,
    color: J3Colors.text,
  );

  static const TextStyle bodySecondary = TextStyle(
    fontFamily: ui,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.4,
    color: J3Colors.textSecondary,
  );

  static const TextStyle caption = TextStyle(
    fontFamily: ui,
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.4,
    height: 1.3,
    color: J3Colors.textMuted,
  );

  /// Uppercase micro-labels ("J3NSONTOP SYSTEM ONLINE", section kickers).
  static const TextStyle kicker = TextStyle(
    fontFamily: mono,
    fontSize: 11.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 2.0,
    height: 1.3,
    color: J3Colors.neonText,
    fontFeatures: asciiFeatures,
  );

  static const TextStyle label = TextStyle(
    fontFamily: ui,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
    height: 1.2,
    color: J3Colors.text,
  );

  static const TextStyle code = TextStyle(
    fontFamily: mono,
    fontSize: 13.5,
    fontWeight: FontWeight.w400,
    height: 1.45,
    color: J3Colors.text,
    fontFeatures: asciiFeatures,
  );

  static const TextStyle codeSmall = TextStyle(
    fontFamily: mono,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.4,
    color: J3Colors.textSecondary,
    fontFeatures: asciiFeatures,
  );

  /// ASCII art: fixed line height so rows never drift.
  static const TextStyle ascii = TextStyle(
    fontFamily: mono,
    fontSize: 14,
    fontWeight: FontWeight.w700,
    height: 1.18,
    color: J3Colors.neon,
    fontFeatures: asciiFeatures,
    letterSpacing: 0,
  );
}
