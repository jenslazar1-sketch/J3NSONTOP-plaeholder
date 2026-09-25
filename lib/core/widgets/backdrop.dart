import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/effects.dart';
import '../theme/j3_colors.dart';
import '../theme/j3_typography.dart';

/// App-wide atmosphere: faint grid, vignette, optional scanlines and a few
/// slowly drifting particles. Everything respects [EffectsConfig]; with low
/// effects or reduced motion it degrades to a static grid.
class J3Backdrop extends StatelessWidget {
  const J3Backdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: J3Colors.background),
        RepaintBoundary(
          child: CustomPaint(
            painter: _GridPainter(accent: fx.accentColor, strength: 0.35 + 0.4 * fx.intensity),
          ),
        ),
        if (fx.particles) RepaintBoundary(child: _Particles(intensity: fx.intensity, color: fx.accentColor)),
        child,
        if (fx.scanlines)
          IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(painter: _ScanlinePainter(opacity: 0.05 + 0.05 * fx.intensity)),
            ),
          ),
      ],
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.accent, required this.strength});
  final Color accent;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 36.0;
    final line = Paint()
      ..color = accent.withValues(alpha: 0.035 * strength)
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += cell) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (double y = 0; y < size.height; y += cell) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
    // Red horizon glow at the top and a dark vignette at the edges.
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -1.3),
          radius: 1.2,
          colors: [accent.withValues(alpha: 0.10 * strength), Colors.transparent],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          radius: 1.1,
          colors: [Colors.transparent, Color(0xAA000000)],
          stops: [0.65, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.accent != accent || old.strength != strength;
}

class _ScanlinePainter extends CustomPainter {
  _ScanlinePainter({required this.opacity});
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withValues(alpha: opacity * 4);
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), paint);
    }
  }

  @override
  bool shouldRepaint(_ScanlinePainter old) => old.opacity != opacity;
}

class _Particle {
  _Particle(this.x, this.y, this.speed, this.painter);
  double x;
  double y;
  final double speed;

  /// Laid out once; only the position changes per frame.
  final TextPainter painter;
}

/// A handful of slowly rising glyph particles. Decorative only; paused when
/// the app is not visible (TickerMode) and absent in reduced motion.
class _Particles extends StatefulWidget {
  const _Particles({required this.intensity, required this.color});
  final double intensity;
  final Color color;

  @override
  State<_Particles> createState() => _ParticlesState();
}

class _ParticlesState extends State<_Particles> with SingleTickerProviderStateMixin {
  static const _glyphs = ['0', '1', '+', '.', '*', 'x', ':', '#'];
  final _rng = math.Random(7);
  late final Ticker _ticker;
  final List<_Particle> _particles = [];
  Duration _last = Duration.zero;
  final ValueNotifier<int> _frame = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _seed();
    _ticker = createTicker(_tick)..start();
  }

  void _seed() {
    for (final p in _particles) {
      p.painter.dispose();
    }
    _particles.clear();
    final count = (6 + 14 * widget.intensity).round();
    for (var i = 0; i < count; i++) {
      final painter = TextPainter(
        text: TextSpan(
          text: _glyphs[_rng.nextInt(_glyphs.length)],
          style: TextStyle(
            fontFamily: J3Type.mono,
            fontSize: 9 + _rng.nextDouble() * 6,
            color: widget.color.withValues(alpha: 0.10 + _rng.nextDouble() * 0.22),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      _particles.add(
        _Particle(_rng.nextDouble(), _rng.nextDouble(), 0.004 + _rng.nextDouble() * 0.012, painter),
      );
    }
  }

  @override
  void didUpdateWidget(covariant _Particles oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.intensity != widget.intensity || oldWidget.color != widget.color) _seed();
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (dt <= 0 || dt > 0.25) return;
    for (final p in _particles) {
      p.y -= p.speed * dt;
      if (p.y < -0.05) {
        p.y = 1.05;
        p.x = _rng.nextDouble();
      }
    }
    _frame.value++;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    for (final p in _particles) {
      p.painter.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _ParticlePainter(_particles, _frame),
        size: Size.infinite,
      ),
    );
  }
}

class _ParticlePainter extends CustomPainter {
  _ParticlePainter(this.particles, Listenable repaint) : super(repaint: repaint);
  final List<_Particle> particles;

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      p.painter.paint(canvas, Offset(p.x * size.width, p.y * size.height));
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) => false;
}
