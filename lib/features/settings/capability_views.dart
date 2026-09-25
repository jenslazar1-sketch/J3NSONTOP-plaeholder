import 'package:flutter/material.dart';

import '../../core/platform/capabilities.dart';
import '../../core/theme/effects.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';

/// Icon + text support marker (never colour alone).
class SupportMark extends StatelessWidget {
  const SupportMark({super.key, required this.supported, this.yes = 'Supported', this.no = 'Not available'});
  final bool supported;
  final String yes;
  final String no;

  @override
  Widget build(BuildContext context) {
    final color = supported ? J3Colors.success : J3Colors.textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(supported ? Icons.check_circle_outline : Icons.cancel_outlined, size: 16, color: color),
        const SizedBox(width: J3Space.xs),
        Flexible(
          child: Text(supported ? yes : no, style: J3Type.codeSmall.copyWith(color: color)),
        ),
      ],
    );
  }
}

/// Capabilities of the current device: label, support and the alternative
/// offered when something is unavailable.
class DeviceCapabilityList extends StatelessWidget {
  const DeviceCapabilityList({super.key, required this.caps});
  final CapabilityMatrix caps;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final c in Capability.values) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: J3Space.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: J3Space.md,
                  runSpacing: J3Space.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(c.label, style: J3Type.label),
                    SupportMark(supported: caps.supports(c)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(c.description, style: J3Type.caption),
                if (caps.alternativeFor(c) != null) ...[
                  const SizedBox(height: 2),
                  Text('Alternative: ${caps.alternativeFor(c)}', style: J3Type.caption.copyWith(color: J3Colors.info)),
                ],
              ],
            ),
          ),
          if (c != Capability.values.last) const Divider(),
        ],
      ],
    );
  }
}

/// Platforms shown as columns in the capability matrix.
const List<AppPlatform> kMatrixPlatforms = [
  AppPlatform.android,
  AppPlatform.ios,
  AppPlatform.windows,
  AppPlatform.linux,
];

String matrixColumnLabel(AppPlatform p) => switch (p) {
  AppPlatform.linux => 'Linux (dev)',
  _ => p.label,
};

/// Every capability on every delivered platform, from
/// [CapabilityMatrix.table]. Scrolls horizontally when it does not fit.
class CapabilityMatrixTable extends StatefulWidget {
  const CapabilityMatrixTable({super.key, required this.current});

  /// Highlighted column (the device the app runs on).
  final AppPlatform current;

  @override
  State<CapabilityMatrixTable> createState() => _CapabilityMatrixTableState();
}

class _CapabilityMatrixTableState extends State<CapabilityMatrixTable> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: _buildTable);

  Widget _buildTable(BuildContext context, BoxConstraints constraints) {
    final fx = context.effects;
    final current = widget.current;
    final labelWidth = constraints.maxWidth < 520 ? 150.0 : 210.0;
    // Columns share the available width; below the minimum the table
    // scrolls horizontally instead of squeezing.
    final cellWidth = constraints.maxWidth.isFinite
        ? ((constraints.maxWidth - labelWidth) / kMatrixPlatforms.length).clamp(118.0, 220.0)
        : 118.0;

    Widget cell(Widget child, {double? width, bool highlight = false}) => Container(
      width: width ?? cellWidth,
      padding: const EdgeInsets.symmetric(horizontal: J3Space.sm, vertical: J3Space.sm),
      color: highlight ? fx.accentColor.withValues(alpha: 0.07) : null,
      child: child,
    );

    final header = Container(
      decoration: const BoxDecoration(
        color: J3Colors.surfaceRaised,
        border: Border(bottom: BorderSide(color: J3Colors.border)),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            cell(
              Text('CAPABILITY', style: J3Type.kicker.copyWith(color: fx.accentText)),
              width: labelWidth,
            ),
            for (final p in kMatrixPlatforms)
              cell(
                Text(
                  p == current ? '${matrixColumnLabel(p)}\n(this device)' : matrixColumnLabel(p),
                  style: J3Type.label.copyWith(color: p == current ? fx.accentText : J3Colors.text),
                ),
                highlight: p == current,
              ),
          ],
        ),
      ),
    );

    final rows = [
      for (final c in Capability.values)
        Container(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: J3Colors.border)),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                cell(
                  Tooltip(
                    message: c.description,
                    child: Text(c.label, style: J3Type.bodySecondary.copyWith(color: J3Colors.text)),
                  ),
                  width: labelWidth,
                ),
                for (final p in kMatrixPlatforms)
                  cell(
                    SupportMark(supported: CapabilityMatrix.table[c]?.contains(p) ?? false, yes: 'Yes', no: 'No'),
                    highlight: p == current,
                  ),
              ],
            ),
          ),
        ),
    ];

    final tableWidth = labelWidth + cellWidth * kMatrixPlatforms.length;
    final scrolls = constraints.maxWidth.isFinite && tableWidth > constraints.maxWidth;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (scrolls)
          Padding(
            padding: const EdgeInsets.only(bottom: J3Space.sm),
            child: Row(
              children: [
                const Icon(Icons.swipe_left_outlined, size: 16, color: J3Colors.textMuted),
                const SizedBox(width: J3Space.xs),
                Expanded(child: Text('Scroll sideways to see every platform.', style: J3Type.caption)),
              ],
            ),
          ),
        Scrollbar(
          controller: _scroll,
          thumbVisibility: scrolls,
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: tableWidth),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [header, ...rows]),
            ),
          ),
        ),
      ],
    );
  }
}
