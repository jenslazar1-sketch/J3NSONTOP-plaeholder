import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/effects.dart';
import 'intro_timeline.dart';
import 'skull_rig.dart';

/// Makes a [LaughingSkull] laugh on demand.
class LaughingSkullController extends ChangeNotifier {
  int _laughs = 0;

  /// Number of laughs requested so far.
  int get laughs => _laughs;

  /// Plays one laugh (three "HA" pulses). A laugh in progress restarts.
  void laugh() {
    _laughs++;
    notifyListeners();
  }
}

/// The J3NSONTOP skull as a reusable widget (full or mini art) that laughs
/// on demand with the same jaw mechanics as the intro: jaw drop and roll
/// about the hinge, head bob, eyes pulsing with each "HA".
///
/// Trigger a laugh with a [controller], by changing [laughTrigger], or with
/// [laughOnMount]. The skull scales down (never reflows) to fit the
/// incoming constraints; with unbounded constraints it uses its natural grid
/// size at [fontSize].
///
/// With reduced motion nothing moves: a laugh request only brightens the
/// eyes briefly. The ticker runs only while a laugh plays.
class LaughingSkull extends StatefulWidget {
  const LaughingSkull({
    super.key,
    this.mini = false,
    this.controller,
    this.laughTrigger,
    this.laughOnMount = false,
    this.fontSize = 14,
    this.color,
    this.semanticLabel = 'J3NSONTOP laughing skull',
    this.onLaughComplete,
    this.craniumKey,
    this.jawKey,
  });

  /// Use the compact 13-column skull instead of the full 41-column one.
  final bool mini;
  final LaughingSkullController? controller;

  /// Any value; the skull laughs whenever it changes.
  final Object? laughTrigger;
  final bool laughOnMount;

  /// Base font size of the art before scaling to the constraints.
  final double fontSize;

  /// Glyph colour (defaults to the accent colour).
  final Color? color;
  final String semanticLabel;
  final VoidCallback? onLaughComplete;

  /// Keys for the cranium and jaw layers (tests / measurements).
  final Key? craniumKey;
  final Key? jawKey;

  @override
  State<LaughingSkull> createState() => _LaughingSkullState();
}

class _LaughingSkullState extends State<LaughingSkull> with SingleTickerProviderStateMixin {
  static const Duration _laughDuration = Duration(milliseconds: 1500);
  static const Duration _flashDuration = Duration(milliseconds: 650);

  late final AnimationController _anim = AnimationController(vsync: this, duration: _laughDuration)
    ..addStatusListener(_onStatus);
  final SkullMetricsCache _metrics = SkullMetricsCache();

  /// True while a reduced-motion eye flash (instead of a laugh) plays.
  bool _flashOnly = false;
  bool _mountLaughPending = false;

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_laugh);
    PaintingBinding.instance.systemFonts.addListener(_onFontsChanged);
    _mountLaughPending = widget.laughOnMount;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_mountLaughPending) {
      _mountLaughPending = false;
      _laugh();
    }
  }

  @override
  void didUpdateWidget(LaughingSkull old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?.removeListener(_laugh);
      widget.controller?.addListener(_laugh);
    }
    if (old.laughTrigger != widget.laughTrigger) _laugh();
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_laugh);
    PaintingBinding.instance.systemFonts.removeListener(_onFontsChanged);
    _anim.dispose();
    super.dispose();
  }

  void _onFontsChanged() {
    if (!mounted) return;
    setState(_metrics.invalidate);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _anim.value = 0;
      widget.onLaughComplete?.call();
    }
  }

  void _laugh() {
    if (!mounted) return;
    final fx = context.effects;
    _flashOnly = fx.reduceMotion;
    _anim.duration = _flashOnly ? _flashDuration : _laughDuration;
    _anim.forward(from: 0);
  }

  SkullPose _pose(double v) {
    if (v <= 0) return SkullPose.closed;
    if (_flashOnly) {
      // Brightness only - no movement at all.
      return SkullPose(eyeGlow: kEyeBaseGlow + (1 - kEyeBaseGlow) * math.sin(math.pi * v));
    }
    return SkullPose.laughing(v * kLaughDuration);
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final art = widget.mini ? SkullArt.mini : SkullArt.full;
    final color = widget.color ?? fx.accentColor;
    final style = skullTextStyle(
      color: color,
      fontSize: widget.fontSize,
      shadows: skullGlyphGlow(fx, color: color),
    );
    final metrics = _metrics.of(style);
    final glow = SkullGlow.of(fx);
    return Semantics(
      image: true,
      label: widget.semanticLabel,
      child: ExcludeSemantics(
        child: FittedBox(
          fit: BoxFit.contain,
          child: AnimatedBuilder(
            animation: _anim,
            builder: (context, _) => SkullRig(
              art: art,
              metrics: metrics,
              style: style,
              pose: _pose(_anim.value),
              glow: glow,
              craniumKey: widget.craniumKey,
              jawKey: widget.jawKey,
            ),
          ),
        ),
      ),
    );
  }
}
