import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../domain/image_ops.dart';

enum _Handle { tl, t, tr, r, br, b, bl, l, move, create }

/// Interactive crop rectangle drawn over an [ImageViewport]. Drag inside to
/// move, drag one of the eight neon handles to resize, or drag outside to
/// draw a new selection. With keyboard focus the arrow keys move the
/// rectangle (Shift = 10 px). Coordinates are image pixels.
class CropOverlay extends StatefulWidget {
  const CropOverlay({
    super.key,
    required this.rect,
    required this.bounds,
    required this.scale,
    required this.onChanged,
    this.aspect,
  });

  final CropRect rect;
  final PixelSize bounds;

  /// Display pixels per image pixel.
  final double scale;

  /// Locked width/height ratio, null for free.
  final double? aspect;
  final ValueChanged<CropRect> onChanged;

  /// Touch target radius around each handle (44 px targets).
  static const double hitRadius = 22;

  @override
  State<CropOverlay> createState() => _CropOverlayState();
}

class _CropOverlayState extends State<CropOverlay> {
  final _focus = FocusNode(debugLabel: 'crop-overlay');
  bool _focused = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Offset _toImage(Offset local) => Offset(local.dx / widget.scale, local.dy / widget.scale);

  Map<_Handle, Offset> _handles() {
    final s = widget.scale;
    final r = widget.rect;
    final l = r.x * s, t = r.y * s, rr = r.right * s, b = r.bottom * s;
    final cx = (l + rr) / 2, cy = (t + b) / 2;
    return {
      _Handle.tl: Offset(l, t),
      _Handle.t: Offset(cx, t),
      _Handle.tr: Offset(rr, t),
      _Handle.r: Offset(rr, cy),
      _Handle.br: Offset(rr, b),
      _Handle.b: Offset(cx, b),
      _Handle.bl: Offset(l, b),
      _Handle.l: Offset(l, cy),
    };
  }

  _Handle _hit(Offset local) {
    _Handle? best;
    var bestD = CropOverlay.hitRadius;
    for (final e in _handles().entries) {
      final d = (e.value - local).distance;
      if (d <= bestD) {
        bestD = d;
        best = e.key;
      }
    }
    if (best != null) return best;
    final s = widget.scale;
    final r = widget.rect;
    final inside = Rect.fromLTWH(r.x * s, r.y * s, r.width * s, r.height * s).contains(local);
    return inside ? _Handle.move : _Handle.create;
  }

  Drag? _start(Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final local = box.globalToLocal(global);
    _focus.requestFocus();
    return _CropDrag(this, _hit(local), _toImage(local), widget.rect);
  }

  void _emit(double l, double t, double r, double b) {
    final bounds = widget.bounds;
    final x0 = l.round(), y0 = t.round();
    var rect = CropRect(x0, y0, math.max(1, r.round() - x0), math.max(1, b.round() - y0)).clampTo(bounds);
    final ratio = widget.aspect;
    if (ratio != null) {
      final actual = rect.width / rect.height;
      if ((actual - ratio).abs() / ratio > 0.02) rect = rect.fitAspect(ratio, bounds);
    }
    if (rect != widget.rect) widget.onChanged(rect);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final step = HardwareKeyboard.instance.isShiftPressed ? 10 : 1;
    final r = widget.rect;
    var dx = 0, dy = 0;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) dx = -step;
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) dx = step;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) dy = -step;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) dy = step;
    if (dx == 0 && dy == 0) return KeyEventResult.ignored;
    final next = CropRect(r.x + dx, r.y + dy, r.width, r.height).clampTo(widget.bounds);
    if (next != r) widget.onChanged(next);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    return Semantics(
      label:
          'Crop selection ${widget.rect.width} by ${widget.rect.height} at ${widget.rect.x}, ${widget.rect.y}. '
          'Arrow keys move it.',
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        onFocusChange: (f) => setState(() => _focused = f),
        child: MouseRegion(
          cursor: SystemMouseCursors.precise,
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              ImmediateMultiDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<ImmediateMultiDragGestureRecognizer>(
                    ImmediateMultiDragGestureRecognizer.new,
                    (r) => r.onStart = _start,
                  ),
            },
            child: CustomPaint(
              painter: _CropPainter(
                rect: widget.rect,
                scale: widget.scale,
                accent: fx.accentColor,
                focused: _focused,
                glow: fx.glow,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CropDrag extends Drag {
  _CropDrag(this.state, this.handle, this.startPoint, CropRect start)
    : l = start.x.toDouble(),
      t = start.y.toDouble(),
      r = start.right.toDouble(),
      b = start.bottom.toDouble();

  final _CropOverlayState state;
  final _Handle handle;
  final Offset startPoint;
  final double l;
  final double t;
  final double r;
  final double b;

  @override
  void update(DragUpdateDetails details) {
    if (!state.mounted) return;
    final box = state.context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final p = state._toImage(box.globalToLocal(details.globalPosition));
    final bw = state.widget.bounds.width.toDouble();
    final bh = state.widget.bounds.height.toDouble();
    final ratio = state.widget.aspect;
    final d = p - startPoint;
    var nl = l, nt = t, nr = r, nb = b;
    switch (handle) {
      case _Handle.move:
        final w = r - l, h = b - t;
        nl = (l + d.dx).clamp(0, bw - w);
        nt = (t + d.dy).clamp(0, bh - h);
        nr = nl + w;
        nb = nt + h;
      case _Handle.create:
        final ax = startPoint.dx.clamp(0.0, bw), ay = startPoint.dy.clamp(0.0, bh);
        final px = p.dx.clamp(0.0, bw), py = p.dy.clamp(0.0, bh);
        nl = math.min(ax, px);
        nr = math.max(ax, px);
        nt = math.min(ay, py);
        nb = math.max(ay, py);
        if (ratio != null) {
          final h = (nr - nl) / ratio;
          if (py >= ay) {
            nt = ay;
            nb = ay + h;
          } else {
            nb = ay;
            nt = ay - h;
          }
        }
      default:
        final moveL = handle == _Handle.tl || handle == _Handle.l || handle == _Handle.bl;
        final moveR = handle == _Handle.tr || handle == _Handle.r || handle == _Handle.br;
        final moveT = handle == _Handle.tl || handle == _Handle.t || handle == _Handle.tr;
        final moveB = handle == _Handle.bl || handle == _Handle.b || handle == _Handle.br;
        if (moveL) nl = (l + d.dx).clamp(0, r - 1);
        if (moveR) nr = (r + d.dx).clamp(l + 1, bw);
        if (moveT) nt = (t + d.dy).clamp(0, b - 1);
        if (moveB) nb = (b + d.dy).clamp(t + 1, bh);
        if (ratio != null) {
          final corner = (moveL || moveR) && (moveT || moveB);
          if (corner || moveL || moveR) {
            // Width drives height; anchor the edge opposite the handle.
            final h = (nr - nl) / ratio;
            if (moveT) {
              nt = nb - h;
            } else if (moveB) {
              nb = nt + h;
            } else {
              final cy = (t + b) / 2;
              nt = cy - h / 2;
              nb = cy + h / 2;
            }
          } else {
            final w = (nb - nt) * ratio;
            final cx = (l + r) / 2;
            nl = cx - w / 2;
            nr = cx + w / 2;
          }
        }
    }
    state._emit(nl, nt, nr, nb);
  }

  @override
  void end(DragEndDetails details) {}

  @override
  void cancel() {}
}

class _CropPainter extends CustomPainter {
  _CropPainter({
    required this.rect,
    required this.scale,
    required this.accent,
    required this.focused,
    required this.glow,
  });

  final CropRect rect;
  final double scale;
  final Color accent;
  final bool focused;
  final bool glow;

  @override
  void paint(Canvas canvas, Size size) {
    final sel = Rect.fromLTWH(rect.x * scale, rect.y * scale, rect.width * scale, rect.height * scale);
    final scrim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(sel);
    canvas.drawPath(scrim, Paint()..color = J3Colors.background.withValues(alpha: 0.6));

    // Rule-of-thirds guides.
    final guide = Paint()
      ..color = J3Colors.text.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = sel.left + sel.width * i / 3;
      final y = sel.top + sel.height * i / 3;
      canvas.drawLine(Offset(x, sel.top), Offset(x, sel.bottom), guide);
      canvas.drawLine(Offset(sel.left, y), Offset(sel.right, y), guide);
    }

    if (glow) {
      canvas.drawRect(
        sel,
        Paint()
          ..color = accent.withValues(alpha: 0.45)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
    }
    canvas.drawRect(
      sel,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = focused ? 3 : 2,
    );
    if (focused) {
      canvas.drawRect(
        sel.inflate(4),
        Paint()
          ..color = J3Colors.text
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    final cx = sel.center.dx, cy = sel.center.dy;
    final points = [
      sel.topLeft,
      Offset(cx, sel.top),
      sel.topRight,
      Offset(sel.right, cy),
      sel.bottomRight,
      Offset(cx, sel.bottom),
      sel.bottomLeft,
      Offset(sel.left, cy),
    ];
    final fill = Paint()..color = accent;
    final edge = Paint()
      ..color = J3Colors.background
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final p in points) {
      final r = Rect.fromCenter(center: p, width: 12, height: 12);
      canvas.drawRect(r, fill);
      canvas.drawRect(r, edge);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.rect != rect || old.scale != scale || old.accent != accent || old.focused != focused || old.glow != glow;
}
