import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/j3_colors.dart';

/// Near-white "phosphor" tint used for beams and hot edges.
Color phosphor(Color accent, [double t = 0.72]) => Color.lerp(accent, const Color(0xFFFFE9EE), t)!;

/// The flickering red signal line (decorative phase before the reveal): a
/// thin horizontal line through the vertical centre, growing outwards from
/// the middle.
class SignalLinePainter extends CustomPainter {
  SignalLinePainter({required this.brightness, required this.extent, required this.accent, required this.bloom});

  /// 0..1 flicker brightness.
  final double brightness;

  /// 0..1 horizontal extent.
  final double extent;
  final Color accent;

  /// Glow blur radius (0 = no glow).
  final double bloom;

  @override
  void paint(Canvas canvas, Size size) {
    if (brightness <= 0 || extent <= 0) return;
    final cy = size.height * 0.46;
    final half = size.width * 0.72 * extent;
    final rect = Rect.fromLTRB(size.width / 2 - half, cy - 1, size.width / 2 + half, cy + 1);
    final shader = LinearGradient(
      colors: [
        accent.withValues(alpha: 0),
        accent.withValues(alpha: brightness),
        phosphor(accent).withValues(alpha: brightness),
        accent.withValues(alpha: brightness),
        accent.withValues(alpha: 0),
      ],
      stops: const [0, 0.25, 0.5, 0.75, 1],
    ).createShader(rect);
    if (bloom > 0) {
      canvas.drawRect(
        rect.inflate(bloom * 0.4),
        Paint()
          ..shader = shader
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, bloom),
      );
    }
    canvas.drawRect(rect, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(SignalLinePainter old) =>
      old.brightness != brightness || old.extent != extent || old.accent != accent || old.bloom != bloom;
}

/// The reveal scanline at [y] (logical pixels from the top) with a short
/// trail of light above it.
class ScanBeamPainter extends CustomPainter {
  ScanBeamPainter({required this.y, required this.accent, required this.bloom, required this.lineHeight});

  final double y;
  final Color accent;
  final double bloom;
  final double lineHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final left = -size.width * 0.12;
    final right = size.width * 1.12;
    final width = right - left;
    // Trail: the rows just decoded still glow; faded at both ends.
    final trail = Rect.fromLTRB(left, y - lineHeight * 2.5, right, y);
    canvas.saveLayer(trail, Paint());
    canvas.drawRect(
      trail,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [accent.withValues(alpha: 0), accent.withValues(alpha: 0.18)],
        ).createShader(trail),
    );
    canvas.drawRect(
      trail,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = const LinearGradient(
          colors: [Color(0x00000000), Color(0xFF000000), Color(0xFF000000), Color(0x00000000)],
          stops: [0, 0.2, 0.8, 1],
        ).createShader(trail),
    );
    canvas.restore();
    final beam = Rect.fromLTWH(left, y - 1, width, 2);
    final shader = LinearGradient(
      colors: [accent.withValues(alpha: 0), accent, phosphor(accent), accent, accent.withValues(alpha: 0)],
      stops: const [0, 0.14, 0.5, 0.86, 1],
    ).createShader(beam);
    if (bloom > 0) {
      canvas.drawRect(
        beam.inflate(bloom * 0.3),
        Paint()
          ..shader = shader
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, bloom),
      );
    }
    canvas.drawRect(beam, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(ScanBeamPainter old) =>
      old.y != y || old.accent != accent || old.bloom != bloom || old.lineHeight != lineHeight;
}

/// Soft red haze behind the skull that breathes with the eyes.
class HazePainter extends CustomPainter {
  HazePainter({required this.strength, required this.accent, required this.centre});

  final double strength;
  final Color accent;

  /// Centre of the haze as a fraction of the size.
  final Offset centre;

  @override
  void paint(Canvas canvas, Size size) {
    if (strength <= 0) return;
    final c = Offset(size.width * centre.dx, size.height * centre.dy);
    final r = size.longestSide * 0.62;
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [
            accent.withValues(alpha: 0.16 * strength),
            accent.withValues(alpha: 0.05 * strength),
            accent.withValues(alpha: 0),
          ],
          stops: const [0, 0.5, 1],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
  }

  @override
  bool shouldRepaint(HazePainter old) => old.strength != strength || old.accent != accent || old.centre != centre;
}

/// The outro wipe line sweeping down the screen at [position] (0..1).
class WipePainter extends CustomPainter {
  WipePainter({required this.position, required this.accent, required this.bloom, required this.opacity});

  final double position;
  final Color accent;
  final double bloom;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (position <= 0 || position >= 1 || opacity <= 0) return;
    final y = size.height * position;
    final glowBand = Rect.fromLTRB(0, y - 18, size.width, y + 2);
    canvas.drawRect(
      glowBand,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            accent.withValues(alpha: 0),
            accent.withValues(alpha: 0.22 * opacity),
          ],
        ).createShader(glowBand),
    );
    final line = Rect.fromLTWH(0, y - 1, size.width, 2);
    if (bloom > 0) {
      canvas.drawRect(
        line.inflate(bloom * 0.3),
        Paint()
          ..color = accent.withValues(alpha: 0.8 * opacity)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, bloom),
      );
    }
    canvas.drawRect(line, Paint()..color = phosphor(accent, 0.5).withValues(alpha: opacity));
  }

  @override
  bool shouldRepaint(WipePainter old) =>
      old.position != position || old.accent != accent || old.bloom != bloom || old.opacity != opacity;
}

/// Clips away everything below [bottom] (the part of the skull the reveal
/// scanline has not reached yet).
class RevealClipper extends CustomClipper<Rect> {
  RevealClipper(this.bottom);
  final double bottom;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(-size.width, -size.height, size.width * 2, bottom);

  @override
  bool shouldReclip(RevealClipper old) => old.bottom != bottom;
}

/// Clips away everything above [top] (outro wipe).
class WipeClipper extends CustomClipper<Rect> {
  WipeClipper(this.fraction);
  final double fraction;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(-size.width, size.height * fraction, size.width * 2, size.height * 3);

  @override
  bool shouldReclip(WipeClipper old) => old.fraction != fraction;
}

/// One horizontally displaced slice of the glitch burst.
@immutable
class GlitchSlice {
  const GlitchSlice(this.top, this.bottom, this.dx);
  final double top;
  final double bottom;
  final double dx;
}

/// Deterministic slice layout for glitch frame [frame]: one band in each
/// third of the height (so bands never overlap), 2 or 3 bands per frame.
List<GlitchSlice> glitchSlices({
  required int frame,
  required double height,
  required double strength,
  required double maxShift,
}) {
  final rng = math.Random(frame * 7919 + 101);
  final count = frame.isEven ? 3 : 2;
  final zone = height / 3;
  final zones = [0, 1, 2]..shuffle(rng);
  return [
    for (final z in zones.take(count))
      () {
        final h = zone * (0.18 + rng.nextDouble() * 0.4);
        final top = z * zone + rng.nextDouble() * (zone - h);
        final dir = rng.nextBool() ? 1.0 : -1.0;
        return GlitchSlice(top, top + h, dir * maxShift * strength * (0.45 + 0.55 * rng.nextDouble()));
      }(),
  ];
}

/// A single horizontal band.
class BandClipper extends CustomClipper<Rect> {
  BandClipper(this.top, this.bottom);
  final double top;
  final double bottom;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(-size.width, top, size.width * 2, bottom);

  @override
  bool shouldReclip(BandClipper old) => old.top != top || old.bottom != bottom;
}

/// Everything except the given bands (bands must not overlap).
class BandsExcludedClipper extends CustomClipper<Path> {
  BandsExcludedClipper(this.slices);
  final List<GlitchSlice> slices;

  @override
  Path getClip(Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Rect.fromLTRB(-size.width, -size.height, size.width * 2, size.height * 2));
    for (final s in slices) {
      path.addRect(Rect.fromLTRB(-size.width, s.top, size.width * 2, s.bottom));
    }
    return path;
  }

  @override
  bool shouldReclip(BandsExcludedClipper old) => true;
}

/// Cyan / magenta ghost tints of the RGB split.
const Color kGlitchCyan = Color(0xFF00E5FF);
const Color kGlitchMagenta = Color(0xFFFF2A8A);

/// Default dark background colour used by the cover.
const Color kIntroDark = J3Colors.background;
