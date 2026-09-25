import 'package:flutter/material.dart';

import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/widgets/widgets.dart';

/// Compact inline status (icon + text) for short results inside panels,
/// where a full StatusBanner would be too heavy.
class StatusLine extends StatelessWidget {
  const StatusLine({super.key, required this.kind, required this.text});
  final StatusKind kind;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: kind == StatusKind.error,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(kind.icon, size: 16, color: kind.color),
          ),
          const SizedBox(width: J3Space.xs),
          Expanded(
            child: Text(
              kind == StatusKind.neutral ? text : '${kind.label}: $text',
              style: J3Type.bodySecondary.copyWith(color: kind == StatusKind.neutral ? null : J3Colors.text),
            ),
          ),
        ],
      ),
    );
  }
}
