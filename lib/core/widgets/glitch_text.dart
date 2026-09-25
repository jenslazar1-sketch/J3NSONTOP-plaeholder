import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/effects.dart';

/// Text with a short RGB-split glitch. Plays once on mount (if [glitchOnMount])
/// and whenever [trigger] changes. Static when motion is reduced.
class GlitchText extends StatefulWidget {
  const GlitchText(
    this.text, {
    super.key,
    required this.style,
    this.trigger,
    this.glitchOnMount = true,
    this.textAlign,
    this.maxLines,
  });

  final String text;
  final TextStyle style;

  /// Change this value to replay the glitch.
  final Object? trigger;
  final bool glitchOnMount;
  final TextAlign? textAlign;
  final int? maxLines;

  @override
  State<GlitchText> createState() => _GlitchTextState();
}

class _GlitchTextState extends State<GlitchText> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
  final _rng = math.Random();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.glitchOnMount && !_c.isAnimating && _c.value == 0 && context.effects.decorativeMotion) {
      _c.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(GlitchText old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger && context.effects.decorativeMotion) {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final base = Text(widget.text, style: widget.style, textAlign: widget.textAlign, maxLines: widget.maxLines, overflow: widget.maxLines == null ? null : TextOverflow.ellipsis);
    if (!fx.decorativeMotion) return base;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        if (t == 0 || t == 1) return base;
        final strength = (1 - t) * (2 + 4 * fx.intensity);
        final jitter = (_rng.nextDouble() - 0.5) * strength;
        return Stack(
          children: [
            Transform.translate(
              offset: Offset(-strength + jitter, 0),
              child: Text(widget.text, style: widget.style.copyWith(color: const Color(0xFF00E5FF).withValues(alpha: 0.55)), textAlign: widget.textAlign, maxLines: widget.maxLines),
            ),
            Transform.translate(
              offset: Offset(strength, jitter * 0.5),
              child: Text(widget.text, style: widget.style.copyWith(color: fx.accentColor.withValues(alpha: 0.8)), textAlign: widget.textAlign, maxLines: widget.maxLines),
            ),
            ClipRect(
              clipper: _SliceClipper(_rng.nextDouble(), 0.12 + _rng.nextDouble() * 0.3),
              child: Transform.translate(offset: Offset(jitter * 2, 0), child: base),
            ),
            Opacity(opacity: 0.85, child: base),
          ],
        );
      },
    );
  }
}

class _SliceClipper extends CustomClipper<Rect> {
  _SliceClipper(this.start, this.height);
  final double start;
  final double height;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, size.height * start * (1 - height), size.width, size.height * height);

  @override
  bool shouldReclip(_SliceClipper old) => true;
}
