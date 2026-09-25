import 'package:flutter/material.dart';

import '../../../../core/theme/j3_colors.dart';

/// Transparency checkerboard. Only the cells inside the current clip are
/// drawn, so it stays cheap inside large zoomed/scrolled canvases.
class CheckerboardPainter extends CustomPainter {
  const CheckerboardPainter({this.cell = 8, this.light = J3Colors.borderStrong, this.dark = J3Colors.surfaceRaised});

  final double cell;
  final Color light;
  final Color dark;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = dark);
    final clip = canvas.getLocalClipBounds().intersect(bounds);
    if (clip.isEmpty) return;
    final paint = Paint()..color = light;
    final c0 = (clip.left / cell).floor();
    final c1 = (clip.right / cell).ceil();
    final r0 = (clip.top / cell).floor();
    final r1 = (clip.bottom / cell).ceil();
    for (var r = r0; r < r1; r++) {
      for (var c = c0 + ((c0 + r).isOdd ? 1 : 0); c < c1; c += 2) {
        canvas.drawRect(Rect.fromLTWH(c * cell, r * cell, cell, cell).intersect(bounds), paint);
      }
    }
  }

  @override
  bool shouldRepaint(CheckerboardPainter old) => old.cell != cell || old.light != light || old.dark != dark;
}

/// Box with a checkerboard behind [child] (for swatches with alpha).
class Checkerboard extends StatelessWidget {
  const Checkerboard({super.key, required this.child, this.cell = 6});
  final Widget child;
  final double cell;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: CheckerboardPainter(cell: cell),
    child: child,
  );
}

/// Thin lines on every source-pixel boundary, drawn at high zoom so pixel
/// art can be inspected. Only visible lines are drawn.
class PixelGridPainter extends CustomPainter {
  const PixelGridPainter({required this.scale, required this.color});

  /// Display pixels per source pixel.
  final double scale;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (scale < 6) return;
    final bounds = Offset.zero & size;
    final clip = canvas.getLocalClipBounds().intersect(bounds);
    if (clip.isEmpty) return;
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = (clip.left / scale).floor() * scale; x <= clip.right; x += scale) {
      canvas.drawLine(Offset(x, clip.top), Offset(x, clip.bottom), p);
    }
    for (var y = (clip.top / scale).floor() * scale; y <= clip.bottom; y += scale) {
      canvas.drawLine(Offset(clip.left, y), Offset(clip.right, y), p);
    }
  }

  @override
  bool shouldRepaint(PixelGridPainter old) => old.scale != scale || old.color != color;
}
