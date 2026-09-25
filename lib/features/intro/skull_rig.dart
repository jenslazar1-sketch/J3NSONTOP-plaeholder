import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/effects.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_typography.dart';
import 'intro_timeline.dart';
import 'skull_art.dart';

/// Describes a two-layer ASCII skull (see skull_art.dart for conventions).
@immutable
class SkullArt {
  const SkullArt({
    required this.cranium,
    required this.jaw,
    required this.columns,
    required this.eyeCentres,
    required this.jawHinge,
    required this.mouthSpan,
  });

  static const SkullArt full = SkullArt(
    cranium: kSkullCranium,
    jaw: kSkullJaw,
    columns: kSkullColumns,
    eyeCentres: kSkullEyeCentres,
    jawHinge: kSkullJawHinge,
    mouthSpan: kSkullMouthSpan,
  );

  static const SkullArt mini = SkullArt(
    cranium: kMiniSkullCranium,
    jaw: kMiniSkullJaw,
    columns: kMiniSkullColumns,
    eyeCentres: kMiniSkullEyeCentres,
    jawHinge: kMiniSkullJawHinge,
    mouthSpan: kMiniSkullMouthSpan,
  );

  final List<String> cranium;
  final List<String> jaw;
  final int columns;

  /// Cell coordinates.
  final List<(double, double)> eyeCentres;

  /// Grid coordinates relative to the jaw layer.
  final (double, double) jawHinge;

  /// Cell columns of the outer mouth walls.
  final (int, int) mouthSpan;

  int get rows => cranium.length + jaw.length;
}

/// The skull text style: [J3Type.ascii] made self-contained
/// (`inherit: false`) so the measured cell size and the rendered layers are
/// guaranteed to use exactly the same font, size, strut and features.
TextStyle skullTextStyle({required Color color, double fontSize = 14, List<Shadow>? shadows}) =>
    J3Type.ascii.copyWith(inherit: false, color: color, fontSize: fontSize, shadows: shadows);

/// Neon glow for the skull glyphs: a tight halo plus a wide bloom, both
/// scaled by the effects intensity; none when glow is off.
List<Shadow>? skullGlyphGlow(EffectsConfig fx, {Color? color}) {
  if (!fx.glow) return null;
  final c = color ?? fx.accentColor;
  return [
    Shadow(color: c.withValues(alpha: 0.85), blurRadius: fx.glowBlur(2.5)),
    Shadow(color: c.withValues(alpha: 0.45), blurRadius: fx.glowBlur(10)),
  ];
}

/// Forced strut for [style]: every row is exactly `fontSize * height` tall,
/// whatever glyphs it contains.
StrutStyle skullStrut(TextStyle style) => StrutStyle(
  fontFamily: style.fontFamily,
  fontSize: style.fontSize,
  fontWeight: style.fontWeight,
  height: style.height,
  forceStrutHeight: true,
);

const TextHeightBehavior _kHeightBehavior = TextHeightBehavior();

/// Size of one character cell, measured once with a [TextPainter] that uses
/// the same style, strut and scaler as the rendered layers.
@immutable
class SkullMetrics {
  const SkullMetrics(this.advance, this.lineHeight);

  factory SkullMetrics.measure(TextStyle style) {
    const probeColumns = 40;
    final probe = 'M' * probeColumns;
    final painter = TextPainter(
      text: TextSpan(text: '$probe\n$probe', style: style),
      strutStyle: skullStrut(style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      textHeightBehavior: _kHeightBehavior,
      maxLines: 2,
    )..layout();
    final metrics = SkullMetrics(painter.width / probeColumns, painter.height / 2);
    painter.dispose();
    return metrics;
  }

  /// Horizontal advance of one character.
  final double advance;

  /// Height of one row.
  final double lineHeight;

  /// Centre of a cell given in cell coordinates.
  Offset cell((double, double) c) => Offset((c.$1 + 0.5) * advance, (c.$2 + 0.5) * lineHeight);

  /// A point given in grid coordinates.
  Offset grid((double, double) g) => Offset(g.$1 * advance, g.$2 * lineHeight);

  @override
  bool operator ==(Object other) => other is SkullMetrics && other.advance == advance && other.lineHeight == lineHeight;

  @override
  int get hashCode => Object.hash(advance, lineHeight);
}

/// Keeps [SkullMetrics] for one style, re-measuring when the style changes
/// or system fonts are (re)loaded.
class SkullMetricsCache {
  TextStyle? _style;
  SkullMetrics? _metrics;

  SkullMetrics of(TextStyle style) {
    if (_metrics == null || _style != style) {
      _style = style;
      _metrics = SkullMetrics.measure(style);
    }
    return _metrics!;
  }

  void invalidate() => _metrics = null;
}

/// Glow parameters derived from [EffectsConfig].
@immutable
class SkullGlow {
  const SkullGlow({required this.accent, required this.enabled, required this.strength});

  factory SkullGlow.of(EffectsConfig fx) =>
      SkullGlow(accent: fx.accentColor, enabled: fx.glow, strength: fx.glow ? fx.glowBlur(1) : 0);

  final Color accent;

  /// Radial bloom around the eyes and in the mouth. When false the eyes are
  /// drawn as flat embers without any glow.
  final bool enabled;

  /// Bloom scale 0..1 (`EffectsConfig.glowBlur(1)`: 0.35..1 by intensity).
  final double strength;

  @override
  bool operator ==(Object other) =>
      other is SkullGlow && other.accent == accent && other.enabled == enabled && other.strength == strength;

  @override
  int get hashCode => Object.hash(accent, enabled, strength);
}

/// Renders a [SkullArt] in [pose]: the cranium and the jaw are two separate
/// [Text] layers on one character grid (same style, forced strut, no
/// wrapping, no text scaling), positioned in a [Stack] with explicit sizes.
///
/// * The jaw layer translates down by `jawOpen * kJawMaxDropLines` rows and
///   rolls by `jawTilt` degrees about the art's hinge.
/// * The whole head lifts by up to [kHeadBobLines] rows and tilts back by up
///   to [kHeadPitchDegrees] (perspective) with `headBob`.
/// * Eye glows are painted behind the sockets, the mouth gap shows darkness
///   with a faint red inner glow.
///
/// The widget's size is fixed for a given art/metrics ([sizeFor]); it
/// reserves room below the chin for the dropped jaw so nothing reflows while
/// laughing. Scale it with a [FittedBox]; never let the text reflow.
class SkullRig extends StatelessWidget {
  const SkullRig({
    super.key,
    required this.art,
    required this.metrics,
    required this.style,
    required this.pose,
    required this.glow,
    this.craniumKey,
    this.jawKey,
  });

  final SkullArt art;
  final SkullMetrics metrics;
  final TextStyle style;
  final SkullPose pose;
  final SkullGlow glow;

  /// Keys placed on the cranium layer and on the (translated, un-rotated)
  /// jaw layer so tests can measure their rendered positions.
  final Key? craniumKey;
  final Key? jawKey;

  /// Extra rows reserved below the chin for the dropped jaw.
  static const double headroomRows = kJawMaxDropLines + 0.5;

  static Size sizeFor(SkullArt art, SkullMetrics m) =>
      Size(art.columns * m.advance, (art.rows + headroomRows) * m.lineHeight);

  @override
  Widget build(BuildContext context) {
    final a = metrics.advance;
    final h = metrics.lineHeight;
    final width = art.columns * a;
    final craniumHeight = art.cranium.length * h;
    final jawHeight = art.jaw.length * h;
    final drop = pose.jawOpen * kJawMaxDropLines * h;
    final hinge = metrics.grid(art.jawHinge);
    final tilt = pose.jawTilt * math.pi / 180;
    final size = sizeFor(art, metrics);

    final head = SizedBox(
      width: width,
      height: craniumHeight + jawHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _SkullUnderlayPainter(
                art: art,
                metrics: metrics,
                pose: pose,
                glow: glow,
                jawOrigin: Offset(0, craniumHeight + drop),
                hinge: hinge,
                tilt: tilt,
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            width: width,
            height: craniumHeight,
            child: KeyedSubtree(
              key: craniumKey,
              child: RepaintBoundary(
                child: SkullLayerText(rows: art.cranium, columns: art.columns, style: style),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: craniumHeight,
            width: width,
            height: jawHeight,
            child: Transform.translate(
              offset: Offset(0, drop),
              child: KeyedSubtree(
                key: jawKey,
                child: Transform(
                  transform: Matrix4.rotationZ(tilt),
                  origin: hinge,
                  child: RepaintBoundary(
                    child: SkullLayerText(rows: art.jaw, columns: art.columns, style: style),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    final lift = pose.headBob * kHeadBobLines * h;
    final pitch = pose.headBob * kHeadPitchDegrees * math.pi / 180;
    final headTransform = Matrix4.identity()
      ..setEntry(3, 2, 0.0008)
      ..translateByDouble(0, -lift, 0, 1)
      // Negative X rotation moves the top of the head away from the viewer:
      // the skull throws its head back as it laughs.
      ..rotateX(-pitch);

    return SizedBox(
      width: size.width,
      height: size.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: Transform(
              transform: headTransform,
              // Pivot at the neck (just above the upper teeth).
              origin: Offset(width / 2, craniumHeight),
              child: head,
            ),
          ),
        ],
      ),
    );
  }
}

/// One text layer of the skull: every row padded to [columns] so spaces and
/// columns are preserved, forced strut, no soft wrap, no text scaling.
class SkullLayerText extends StatelessWidget {
  const SkullLayerText({super.key, required this.rows, required this.columns, required this.style});

  final List<String> rows;
  final int columns;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Text(
      rows.map((r) => r.padRight(columns)).join('\n'),
      style: style,
      strutStyle: skullStrut(style),
      textHeightBehavior: _kHeightBehavior,
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
      softWrap: false,
      maxLines: rows.length,
      overflow: TextOverflow.visible,
      textScaler: TextScaler.noScaling,
    );
  }
}

/// Paints what sits behind the glyphs: the eye glows and the mouth cavity.
class _SkullUnderlayPainter extends CustomPainter {
  _SkullUnderlayPainter({
    required this.art,
    required this.metrics,
    required this.pose,
    required this.glow,
    required this.jawOrigin,
    required this.hinge,
    required this.tilt,
  });

  final SkullArt art;
  final SkullMetrics metrics;
  final SkullPose pose;
  final SkullGlow glow;

  /// Top-left of the (translated) jaw layer in head coordinates.
  final Offset jawOrigin;
  final Offset hinge;
  final double tilt;

  Offset _jawPoint(Offset p) {
    final d = p - hinge;
    final c = math.cos(tilt);
    final s = math.sin(tilt);
    return jawOrigin + hinge + Offset(d.dx * c - d.dy * s, d.dx * s + d.dy * c);
  }

  @override
  void paint(Canvas canvas, Size size) {
    _paintMouth(canvas);
    _paintEyes(canvas);
  }

  void _paintMouth(Canvas canvas) {
    final open = pose.jawOpen;
    if (open <= 0.01) return;
    final a = metrics.advance;
    final h = metrics.lineHeight;
    final x0 = (art.mouthSpan.$1 + 0.5) * a;
    final x1 = (art.mouthSpan.$2 + 0.5) * a;
    final top = art.cranium.length * h - 0.2 * h;
    final path = Path()
      ..moveTo(x0, top)
      ..lineTo(x1, top)
      ..lineTo(_jawPoint(Offset(x1, 0.3 * h)).dx, _jawPoint(Offset(x1, 0.3 * h)).dy)
      ..lineTo(_jawPoint(Offset(x0, 0.3 * h)).dx, _jawPoint(Offset(x0, 0.3 * h)).dy)
      ..close();
    final bounds = path.getBounds();
    final alpha = open.clamp(0.0, 1.0);
    canvas.save();
    canvas.clipPath(path);
    // Darkness inside the mouth hides the backdrop grid...
    canvas.drawPath(path, Paint()..color = J3Colors.background.withValues(alpha: (1.5 * open).clamp(0.0, 0.94)));
    // ...with a faint red glow deep in the throat: a soft ellipse spanning
    // the gap (bloom-scaled with glow on, a flat dark-red shade without).
    final rx = bounds.width * 0.5;
    final ry = math.max(bounds.height * 0.75, h * 0.5);
    final inner = glow.enabled
        ? glow.accent.withValues(alpha: 0.62 * alpha * (0.5 + 0.5 * glow.strength))
        : J3Colors.darkRed.withValues(alpha: 0.55 * alpha);
    final mid = glow.enabled
        ? glow.accent.withValues(alpha: 0.2 * alpha)
        : J3Colors.darkRed.withValues(alpha: 0.2 * alpha);
    canvas.translate(bounds.center.dx, bounds.center.dy);
    canvas.scale(1, ry / rx);
    canvas.drawCircle(
      Offset.zero,
      rx,
      Paint()
        ..shader = RadialGradient(
          colors: [inner, mid, mid.withValues(alpha: 0)],
          stops: const [0, 0.5, 1],
        ).createShader(Rect.fromCircle(center: Offset.zero, radius: rx)),
    );
    canvas.restore();
  }

  void _paintEyes(Canvas canvas) {
    final g = pose.eyeGlow.clamp(0.0, 1.0);
    if (g <= 0.01) return;
    final a = metrics.advance;
    final accent = glow.accent;
    final hot = Color.lerp(accent, const Color(0xFFFFE4EA), 0.6)!;
    for (final e in art.eyeCentres) {
      final c = metrics.cell(e);
      if (glow.enabled) {
        // Wide bloom filling the socket.
        final bloom = a * (3.2 + 2.6 * glow.strength) * (0.75 + 0.25 * g);
        canvas.drawCircle(
          c,
          bloom,
          Paint()
            ..shader = RadialGradient(
              colors: [
                accent.withValues(alpha: 0.55 * g),
                accent.withValues(alpha: 0.16 * g),
                accent.withValues(alpha: 0),
              ],
              stops: const [0, 0.45, 1],
            ).createShader(Rect.fromCircle(center: c, radius: bloom)),
        );
        // Hot core.
        final core = a * 1.5;
        canvas.drawCircle(
          c,
          core,
          Paint()
            ..shader = RadialGradient(
              colors: [
                hot.withValues(alpha: 0.95 * g),
                accent.withValues(alpha: 0.5 * g),
                accent.withValues(alpha: 0),
              ],
              stops: const [0, 0.45, 1],
            ).createShader(Rect.fromCircle(center: c, radius: core)),
        );
      }
      // Ember pupil (flat, no blur): drawn even when glow is off.
      canvas.drawCircle(c, a * 0.42, Paint()..color = hot.withValues(alpha: g));
    }
  }

  @override
  bool shouldRepaint(_SkullUnderlayPainter old) =>
      old.pose != pose ||
      old.glow != glow ||
      old.metrics != metrics ||
      old.art != art ||
      old.jawOrigin != jawOrigin ||
      old.tilt != tilt;
}
