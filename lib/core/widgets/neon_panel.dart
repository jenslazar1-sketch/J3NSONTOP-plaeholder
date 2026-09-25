import 'package:flutter/material.dart';

import '../theme/effects.dart';
import '../theme/j3_colors.dart';
import '../theme/j3_spacing.dart';
import '../theme/j3_typography.dart';

/// Raised surface with an illuminated red border, restrained bloom and
/// cyberpunk corner brackets. The standard container for tool sections.
class NeonPanel extends StatelessWidget {
  const NeonPanel({
    super.key,
    required this.child,
    this.title,
    this.kicker,
    this.icon,
    this.actions = const [],
    this.padding = const EdgeInsets.all(J3Space.lg),
    this.emphasis = PanelEmphasis.normal,
    this.brackets = true,
    this.expandChild = false,
  });

  final Widget child;
  final String? title;

  /// Small uppercase mono label above the title (e.g. "INPUT", "RESULT").
  final String? kicker;
  final IconData? icon;
  final List<Widget> actions;
  final EdgeInsetsGeometry padding;
  final PanelEmphasis emphasis;
  final bool brackets;

  /// When true the child fills remaining height (use inside bounded parents).
  final bool expandChild;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final accent = fx.accentColor;
    final borderColor = switch (emphasis) {
      PanelEmphasis.subtle => J3Colors.border,
      PanelEmphasis.normal => accent.withValues(alpha: 0.35),
      PanelEmphasis.strong => accent.withValues(alpha: 0.8),
      PanelEmphasis.danger => J3Colors.error.withValues(alpha: 0.8),
      PanelEmphasis.success => J3Colors.success.withValues(alpha: 0.7),
    };
    final glowColor = emphasis == PanelEmphasis.danger
        ? J3Colors.error
        : emphasis == PanelEmphasis.success
        ? J3Colors.success
        : accent;
    final blur = emphasis == PanelEmphasis.subtle ? 0.0 : fx.glowBlur(emphasis == PanelEmphasis.strong ? 22 : 14);

    final header = (title != null || kicker != null || actions.isNotEmpty)
        ? Padding(
            padding: const EdgeInsets.only(bottom: J3Space.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: fx.accentText),
                  const SizedBox(width: J3Space.sm),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (kicker != null)
                        Text(kicker!.toUpperCase(), style: J3Type.kicker.copyWith(color: fx.accentText)),
                      if (title != null)
                        Text(title!, style: J3Type.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                ...actions,
              ],
            ),
          )
        : null;

    Widget content = Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: expandChild ? MainAxisSize.max : MainAxisSize.min,
        children: [
          ?header,
          expandChild ? Expanded(child: child) : child,
        ],
      ),
    );

    if (brackets && emphasis != PanelEmphasis.subtle) {
      content = CustomPaint(
        foregroundPainter: CornerBracketsPainter(color: borderColor.withValues(alpha: 1), length: 10),
        child: content,
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: J3Colors.surface,
        borderRadius: J3Radius.medium,
        border: Border.all(color: borderColor),
        boxShadow: blur > 0
            ? [BoxShadow(color: glowColor.withValues(alpha: 0.10 + 0.08 * fx.intensity), blurRadius: blur, spreadRadius: -4)]
            : null,
      ),
      child: content,
    );
  }
}

enum PanelEmphasis { subtle, normal, strong, danger, success }

/// Draws short L-shaped brackets on the four corners.
class CornerBracketsPainter extends CustomPainter {
  CornerBracketsPainter({required this.color, this.length = 10, this.stroke = 2});
  final Color color;
  final double length;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.square;
    final l = length;
    final w = size.width;
    final h = size.height;
    const i = 1.0;
    canvas.drawLine(const Offset(i, i), Offset(i + l, i), p);
    canvas.drawLine(const Offset(i, i), Offset(i, i + l), p);
    canvas.drawLine(Offset(w - i, i), Offset(w - i - l, i), p);
    canvas.drawLine(Offset(w - i, i), Offset(w - i, i + l), p);
    canvas.drawLine(Offset(i, h - i), Offset(i + l, h - i), p);
    canvas.drawLine(Offset(i, h - i), Offset(i, h - i - l), p);
    canvas.drawLine(Offset(w - i, h - i), Offset(w - i - l, h - i), p);
    canvas.drawLine(Offset(w - i, h - i), Offset(w - i, h - i - l), p);
  }

  @override
  bool shouldRepaint(CornerBracketsPainter old) => old.color != color || old.length != length;
}

/// Kicker + title used to head page sections.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.kicker, this.trailing});
  final String title;
  final String? kicker;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: J3Space.md, top: J3Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (kicker != null) Text('// ${kicker!.toUpperCase()}', style: J3Type.kicker.copyWith(color: context.effects.accentText)),
                Text(title, style: J3Type.title),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
