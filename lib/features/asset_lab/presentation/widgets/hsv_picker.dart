import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../domain/color_model.dart';
import 'checkerboard.dart';
import 'color_widgets.dart';

/// Custom HSV colour picker: saturation/value square, hue slider and alpha
/// slider. Every part is draggable (winning over page scrolling), tappable
/// and keyboard adjustable (arrow keys, Shift for bigger steps).
class HsvPicker extends StatelessWidget {
  const HsvPicker({super.key, required this.value, required this.onChanged, this.squareHeight = 200});

  final Hsv value;
  final ValueChanged<Hsv> onChanged;
  final double squareHeight;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: squareHeight,
          child: _SvSquare(value: value, onChanged: onChanged),
        ),
        const SizedBox(height: J3Space.md),
        _Strip(
          label: 'Hue',
          describe: (t) => '${(t * 360).round()} degrees',
          position: value.h / 360,
          step: 1 / 360,
          painter: _HuePainter(),
          thumbColor: toFlutterColor(ColorMath.fromHsv(Hsv(value.h, 1, 1))),
          onChanged: (t) => onChanged(value.copyWith(h: (t * 360).clamp(0, 359.999))),
        ),
        const SizedBox(height: J3Space.md),
        _Strip(
          label: 'Alpha',
          describe: (t) => '${(t * 100).round()} percent',
          position: value.a,
          step: 0.01,
          painter: _AlphaPainter(ColorMath.fromHsv(value.copyWith(a: 1))),
          thumbColor: toFlutterColor(ColorMath.fromHsv(value)),
          onChanged: (t) => onChanged(value.copyWith(a: t)),
        ),
      ],
    );
  }
}

/// Recognises a drag immediately so a surrounding scroll view does not
/// steal it, and reports the pointer position on down and every move.
class _PointerSurface extends StatelessWidget {
  const _PointerSurface({required this.onPoint, required this.child});
  final void Function(Offset local, Size size) onPoint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    void report(Offset global) {
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      onPoint(box.globalToLocal(global), box.size);
    }

    return Listener(
      onPointerDown: (e) => report(e.position),
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: {
          ImmediateMultiDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<ImmediateMultiDragGestureRecognizer>(
                ImmediateMultiDragGestureRecognizer.new,
                (r) => r.onStart = (pos) {
                  report(pos);
                  return _CallbackDrag(report);
                },
              ),
        },
        child: child,
      ),
    );
  }
}

class _CallbackDrag extends Drag {
  _CallbackDrag(this.onMove);
  final void Function(Offset global) onMove;

  @override
  void update(DragUpdateDetails details) => onMove(details.globalPosition);
}

class _FocusFrame extends StatefulWidget {
  const _FocusFrame({required this.onKey, required this.child, required this.semantics});
  final KeyEventResult Function(KeyEvent e, bool shift) onKey;
  final Widget child;
  final Widget Function(Widget child) semantics;

  @override
  State<_FocusFrame> createState() => _FocusFrameState();
}

class _FocusFrameState extends State<_FocusFrame> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    return widget.semantics(
      Focus(
        onFocusChange: (f) => setState(() => _focused = f),
        onKeyEvent: (node, e) {
          if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
          return widget.onKey(e, HardwareKeyboard.instance.isShiftPressed);
        },
        child: Container(
          decoration: BoxDecoration(
            borderRadius: J3Radius.small,
            border: Border.all(color: _focused ? fx.accentColor : J3Colors.border, width: _focused ? 2 : 1),
          ),
          padding: const EdgeInsets.all(2),
          child: widget.child,
        ),
      ),
    );
  }
}

String _describeSv(double s, double v) =>
    'saturation ${(s * 100).round()} percent, brightness ${(v * 100).round()} percent';

class _SvSquare extends StatelessWidget {
  const _SvSquare({required this.value, required this.onChanged});
  final Hsv value;
  final ValueChanged<Hsv> onChanged;

  @override
  Widget build(BuildContext context) {
    return _FocusFrame(
      semantics: (child) => Semantics(
        label: 'Saturation and brightness',
        value: _describeSv(value.s, value.v),
        increasedValue: _describeSv(value.s, (value.v + 0.01).clamp(0, 1)),
        decreasedValue: _describeSv(value.s, (value.v - 0.01).clamp(0, 1)),
        hint: 'Left and right change saturation, up and down change brightness',
        onIncrease: () => onChanged(value.copyWith(v: value.v + 0.01)),
        onDecrease: () => onChanged(value.copyWith(v: value.v - 0.01)),
        child: child,
      ),
      onKey: (e, shift) {
        final d = shift ? 0.1 : 0.01;
        final k = e.logicalKey;
        if (k == LogicalKeyboardKey.arrowLeft) onChanged(value.copyWith(s: value.s - d));
        if (k == LogicalKeyboardKey.arrowRight) onChanged(value.copyWith(s: value.s + d));
        if (k == LogicalKeyboardKey.arrowUp) onChanged(value.copyWith(v: value.v + d));
        if (k == LogicalKeyboardKey.arrowDown) onChanged(value.copyWith(v: value.v - d));
        final keys = {
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
        };
        return keys.contains(k) ? KeyEventResult.handled : KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.precise,
        child: _PointerSurface(
          onPoint: (p, size) => onChanged(
            value.copyWith(s: (p.dx / size.width).clamp(0.0, 1.0), v: 1 - (p.dy / size.height).clamp(0.0, 1.0)),
          ),
          child: CustomPaint(painter: _SvPainter(value), size: Size.infinite),
        ),
      ),
    );
  }
}

class _SvPainter extends CustomPainter {
  _SvPainter(this.value);
  final Hsv value;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final hue = toFlutterColor(ColorMath.fromHsv(Hsv(value.h, 1, 1)));
    canvas.drawRect(rect, Paint()..color = hue);
    canvas.drawRect(
      rect,
      Paint()..shader = const LinearGradient(colors: [Color(0xFFFFFFFF), Color(0x00FFFFFF)]).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xFF000000)],
        ).createShader(rect),
    );
    final c = Offset(value.s * size.width, (1 - value.v) * size.height);
    canvas.drawCircle(
      c,
      9,
      Paint()
        ..color = J3Colors.background
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
    canvas.drawCircle(
      c,
      9,
      Paint()
        ..color = J3Colors.text
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_SvPainter old) => old.value != value;
}

class _Strip extends StatelessWidget {
  const _Strip({
    required this.label,
    required this.describe,
    required this.position,
    required this.step,
    required this.painter,
    required this.thumbColor,
    required this.onChanged,
  });

  final String label;

  /// Spoken value for a position 0..1.
  final String Function(double position) describe;

  /// 0..1
  final double position;
  final double step;
  final CustomPainter painter;
  final Color thumbColor;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return _FocusFrame(
      semantics: (child) => Semantics(
        slider: true,
        label: label,
        value: describe(position),
        increasedValue: describe((position + step).clamp(0, 1)),
        decreasedValue: describe((position - step).clamp(0, 1)),
        onIncrease: () => onChanged((position + step).clamp(0, 1)),
        onDecrease: () => onChanged((position - step).clamp(0, 1)),
        child: child,
      ),
      onKey: (e, shift) {
        final d = shift ? step * 10 : step;
        if (e.logicalKey == LogicalKeyboardKey.arrowLeft || e.logicalKey == LogicalKeyboardKey.arrowDown) {
          onChanged((position - d).clamp(0, 1));
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.arrowRight || e.logicalKey == LogicalKeyboardKey.arrowUp) {
          onChanged((position + d).clamp(0, 1));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: SizedBox(
        height: 40,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: _PointerSurface(
            onPoint: (p, size) => onChanged(((p.dx - 6) / (size.width - 12)).clamp(0.0, 1.0)),
            child: CustomPaint(
              painter: painter,
              foregroundPainter: _ThumbPainter(position, thumbColor),
              size: Size.infinite,
            ),
          ),
        ),
      ),
    );
  }
}

class _HuePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [for (var h = 0; h <= 360; h += 60) toFlutterColor(ColorMath.fromHsv(Hsv(h.toDouble(), 1, 1)))],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_HuePainter old) => false;
}

class _AlphaPainter extends CustomPainter {
  _AlphaPainter(this.color);
  final Rgba color;

  @override
  void paint(Canvas canvas, Size size) {
    const CheckerboardPainter(cell: 6).paint(canvas, size);
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(colors: [toFlutterColor(color.withAlpha(0)), toFlutterColor(color.withAlpha(255))])
            .createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_AlphaPainter old) => old.color != color;
}

class _ThumbPainter extends CustomPainter {
  _ThumbPainter(this.position, this.color);
  final double position;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Keep the 12 px thumb fully inside the track at both ends.
    final x = 6 + position.clamp(0.0, 1.0) * (size.width - 12);
    final r = Rect.fromCenter(center: Offset(x, size.height / 2), width: 12, height: size.height + 2);
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)), Paint()..color = color);
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(3)),
      Paint()
        ..color = J3Colors.background
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(r.deflate(1.5), const Radius.circular(2)),
      Paint()
        ..color = J3Colors.text
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_ThumbPainter old) => old.position != position || old.color != color;
}
