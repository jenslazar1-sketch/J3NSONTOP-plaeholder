import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/effects.dart';
import '../theme/j3_colors.dart';
import '../theme/j3_spacing.dart';
import '../theme/j3_typography.dart';

enum NeonButtonVariant { primary, secondary, ghost, danger }

/// The app's button. Covers hover, keyboard focus, pressed, disabled and
/// busy states. Primary presses trigger a brief glitch flash when effects
/// allow it.
class NeonButton extends StatefulWidget {
  const NeonButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.variant = NeonButtonVariant.primary,
    this.busy = false,
    this.tooltip,
    this.dense = false,
    this.expand = false,
  });

  const NeonButton.secondary({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.tooltip,
    this.dense = false,
    this.expand = false,
  }) : variant = NeonButtonVariant.secondary;

  const NeonButton.ghost({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.tooltip,
    this.dense = false,
    this.expand = false,
  }) : variant = NeonButtonVariant.ghost;

  const NeonButton.danger({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.tooltip,
    this.dense = false,
    this.expand = false,
  }) : variant = NeonButtonVariant.danger;

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final NeonButtonVariant variant;

  /// Shows a spinner and disables the button while an operation runs.
  final bool busy;
  final String? tooltip;
  final bool dense;
  final bool expand;

  @override
  State<NeonButton> createState() => _NeonButtonState();
}

class _NeonButtonState extends State<NeonButton> with SingleTickerProviderStateMixin {
  bool _hover = false;
  bool _focus = false;
  bool _pressed = false;
  late final AnimationController _glitch = AnimationController(vsync: this, duration: J3Durations.glitch);

  bool get _enabled => widget.onPressed != null && !widget.busy;

  @override
  void dispose() {
    _glitch.dispose();
    super.dispose();
  }

  void _activate() {
    if (!_enabled) return;
    final fx = context.effects;
    if (widget.variant == NeonButtonVariant.primary && fx.decorativeMotion) {
      _glitch.forward(from: 0);
    }
    widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final accent = fx.accentColor;
    final v = widget.variant;
    final danger = v == NeonButtonVariant.danger;
    final edge = danger ? J3Colors.error : accent;

    Color bg;
    Color border;
    Color fg;
    switch (v) {
      case NeonButtonVariant.primary:
        bg = _pressed ? J3Colors.darkRed : (_hover ? J3Colors.darkRedHover : fx.accentDeep);
        border = edge;
        fg = J3Colors.text;
      case NeonButtonVariant.danger:
        bg = _hover ? const Color(0xFF4A0D16) : const Color(0xFF2A080E);
        border = J3Colors.error;
        fg = J3Colors.text;
      case NeonButtonVariant.secondary:
        bg = _hover ? J3Colors.surfaceHigh : J3Colors.surfaceRaised;
        border = _hover || _focus ? edge : J3Colors.borderStrong;
        fg = J3Colors.text;
      case NeonButtonVariant.ghost:
        bg = _hover ? J3Colors.surfaceRaised : Colors.transparent;
        border = _focus ? edge : Colors.transparent;
        fg = fx.accentText;
    }
    if (!_enabled) {
      bg = v == NeonButtonVariant.ghost ? Colors.transparent : J3Colors.surfaceRaised;
      border = v == NeonButtonVariant.ghost ? Colors.transparent : J3Colors.border;
      fg = J3Colors.textDisabled;
    }

    final glow = _enabled && (v == NeonButtonVariant.primary || danger) && (_hover || _focus)
        ? [BoxShadow(color: edge.withValues(alpha: 0.35), blurRadius: fx.glowBlur(16), spreadRadius: -2)]
        : null;

    final height = widget.dense ? 36.0 : 44.0;
    final label = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.busy)
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          )
        else if (widget.icon != null)
          Icon(widget.icon, size: 18, color: fg),
        if (widget.busy || widget.icon != null) const SizedBox(width: J3Space.sm),
        Flexible(
          child: Text(
            widget.label,
            style: J3Type.label.copyWith(color: fg, letterSpacing: 1.0),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      ],
    );

    Widget body = AnimatedContainer(
      duration: fx.motion(J3Durations.instant),
      constraints: BoxConstraints(minHeight: height, minWidth: height),
      padding: EdgeInsets.symmetric(horizontal: widget.dense ? J3Space.md : J3Space.lg),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: J3Radius.medium,
        border: Border.all(color: border, width: _focus ? 2 : 1),
        boxShadow: glow,
      ),
      alignment: Alignment.center,
      child: AnimatedBuilder(
        animation: _glitch,
        child: label,
        builder: (context, child) {
          final t = _glitch.value;
          if (t == 0 || t == 1) return child!;
          final dx = (t < 0.5 ? t : 1 - t) * 6;
          return Stack(
            alignment: Alignment.center,
            children: [
              Transform.translate(
                offset: Offset(-dx, 0),
                child: Opacity(opacity: 0.6, child: ColorFiltered(colorFilter: const ColorFilter.mode(Color(0xFF00E5FF), BlendMode.modulate), child: child)),
              ),
              Transform.translate(offset: Offset(dx, 0), child: child),
            ],
          );
        },
      ),
    );

    body = AnimatedScale(
      scale: _pressed ? 0.97 : 1,
      duration: fx.motion(J3Durations.instant),
      child: body,
    );

    Widget result = FocusableActionDetector(
      enabled: _enabled,
      mouseCursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
      onShowHoverHighlight: (h) => setState(() => _hover = h),
      onShowFocusHighlight: (f) => setState(() => _focus = f),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          _activate();
          return null;
        }),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTap: _activate,
        child: Semantics(
          button: true,
          enabled: _enabled,
          label: widget.label,
          excludeSemantics: true,
          child: body,
        ),
      ),
    );

    if (widget.tooltip != null) {
      result = Tooltip(message: widget.tooltip!, child: result);
    }
    return result;
  }
}

/// Compact icon button with tooltip and a visible focus ring.
class NeonIconButton extends StatelessWidget {
  const NeonIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.color,
    this.size = 20,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      isSelected: selected,
      iconSize: size,
      color: color ?? (selected ? fx.accentText : J3Colors.textSecondary),
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: J3Radius.medium,
          side: selected ? BorderSide(color: fx.accentColor.withValues(alpha: 0.7)) : BorderSide.none,
        ),
      ),
      icon: Icon(icon),
    );
  }
}
