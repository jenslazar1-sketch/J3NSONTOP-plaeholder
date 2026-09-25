import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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

    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (kicker != null) Text(kicker!.toUpperCase(), style: J3Type.kicker.copyWith(color: fx.accentText)),
        if (title != null) Text(title!, style: J3Type.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      ],
    );
    final header = (title != null || kicker != null || actions.isNotEmpty)
        ? Padding(
            padding: const EdgeInsets.only(bottom: J3Space.md),
            child: _PanelHeader(
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[Icon(icon, size: 18, color: fx.accentText), const SizedBox(width: J3Space.sm)],
                  Flexible(child: titleBlock),
                ],
              ),
              actions: actions.isEmpty
                  ? null
                  : Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: actions,
                    ),
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
            ? [
                BoxShadow(
                  color: glowColor.withValues(alpha: 0.10 + 0.08 * fx.intensity),
                  blurRadius: blur,
                  spreadRadius: -4,
                ),
              ]
            : null,
      ),
      child: content,
    );
  }
}

enum PanelEmphasis { subtle, normal, strong, danger, success }

/// Title on the start side, actions on the end side. When the actions would
/// leave the title less than 40% of the width (phones, large text) they move
/// to their own end-aligned row below the title instead of overflowing.
class _PanelHeader extends MultiChildRenderObjectWidget {
  _PanelHeader({required Widget title, Widget? actions}) : super(children: [title, ?actions]);

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPanelHeader(Directionality.of(context));

  @override
  void updateRenderObject(BuildContext context, _RenderPanelHeader renderObject) {
    renderObject.textDirection = Directionality.of(context);
  }
}

class _PanelHeaderParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderPanelHeader extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _PanelHeaderParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _PanelHeaderParentData> {
  _RenderPanelHeader(this._textDirection);

  static const double _gap = J3Space.sm;
  static const double _minTitleFraction = 0.4;

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _PanelHeaderParentData) child.parentData = _PanelHeaderParentData();
  }

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    Size measure(RenderBox child, double maxWidth) {
      final c = BoxConstraints(maxWidth: maxWidth);
      if (dry) return child.getDryLayout(c);
      child.layout(c, parentUsesSize: true);
      return child.size;
    }

    final maxWidth = constraints.maxWidth;
    final title = firstChild!;
    final actions = childCount > 1 ? lastChild : null;
    final a = actions == null ? Size.zero : measure(actions, maxWidth);
    final inline = actions == null || maxWidth - a.width - _gap >= maxWidth * _minTitleFraction;
    final t = measure(title, inline && actions != null ? maxWidth - a.width - _gap : maxWidth);
    final width = constraints.hasBoundedWidth ? maxWidth : t.width + _gap + a.width;
    final height = inline ? math.max(t.height, a.height) : t.height + J3Space.xs + a.height;
    if (!dry) {
      void place(RenderBox child, Size s, double x, double y) {
        final dx = _textDirection == TextDirection.rtl ? width - x - s.width : x;
        (child.parentData! as _PanelHeaderParentData).offset = Offset(dx, y);
      }

      place(title, t, 0, inline ? (height - t.height) / 2 : 0);
      if (actions != null) {
        place(actions, a, width - a.width, inline ? (height - a.height) / 2 : t.height + J3Space.xs);
      }
    }
    return constraints.constrain(Size(width, height));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) => _layout(constraints, dry: true);

  @override
  void performLayout() => size = _layout(constraints, dry: false);

  @override
  double computeMinIntrinsicWidth(double height) =>
      getChildrenAsList().fold(0.0, (m, c) => math.max(m, c.getMinIntrinsicWidth(height)));

  @override
  double computeMaxIntrinsicWidth(double height) =>
      getChildrenAsList().fold(0.0, (m, c) => m + c.getMaxIntrinsicWidth(height)) + (childCount - 1) * _gap;

  @override
  double computeMinIntrinsicHeight(double width) => _layout(BoxConstraints(maxWidth: width), dry: true).height;

  @override
  double computeMaxIntrinsicHeight(double width) => computeMinIntrinsicHeight(width);

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

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
                if (kicker != null)
                  Text('// ${kicker!.toUpperCase()}', style: J3Type.kicker.copyWith(color: context.effects.accentText)),
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
