import 'package:flutter/material.dart';

import '../theme/effects.dart';
import '../theme/j3_colors.dart';
import '../theme/j3_spacing.dart';
import '../theme/j3_typography.dart';

/// Status semantics. Every status has an icon AND a text label so colour is
/// never the only signal.
enum StatusKind {
  success('OK', Icons.check_circle_outline, J3Colors.success),
  warning('WARN', Icons.warning_amber_rounded, J3Colors.warning),
  error('ERROR', Icons.error_outline, J3Colors.error),
  info('INFO', Icons.info_outline, J3Colors.info),
  running('RUNNING', Icons.sync, J3Colors.info),
  neutral('--', Icons.circle_outlined, J3Colors.textMuted);

  const StatusKind(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.kind, this.text, this.dense = false});
  final StatusKind kind;
  final String? text;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 6 : 8, vertical: dense ? 2 : 4),
      decoration: BoxDecoration(
        color: kind.color.withValues(alpha: 0.10),
        borderRadius: J3Radius.small,
        border: Border.all(color: kind.color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(kind.icon, size: dense ? 12 : 14, color: kind.color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text ?? kind.label,
              style: J3Type.codeSmall.copyWith(color: kind.color, fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Banner for results, warnings, errors and platform notes.
class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.kind,
    required this.title,
    this.message,
    this.details = const [],
    this.actions = const [],
    this.onDismiss,
  });

  final StatusKind kind;
  final String title;
  final String? message;
  final List<String> details;
  final List<Widget> actions;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: kind == StatusKind.error || kind == StatusKind.success,
      child: Container(
        decoration: BoxDecoration(
          color: kind.color.withValues(alpha: 0.07),
          borderRadius: J3Radius.medium,
          border: Border(left: BorderSide(color: kind.color, width: 3), top: BorderSide(color: kind.color.withValues(alpha: 0.3)), right: BorderSide(color: kind.color.withValues(alpha: 0.3)), bottom: BorderSide(color: kind.color.withValues(alpha: 0.3))),
        ),
        padding: const EdgeInsets.all(J3Space.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(kind.icon, color: kind.color, size: 20),
            const SizedBox(width: J3Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${kind.label} // $title', style: J3Type.label.copyWith(color: kind.color)),
                  if (message != null) ...[
                    const SizedBox(height: J3Space.xs),
                    SelectableText(message!, style: J3Type.bodySecondary),
                  ],
                  if (details.isNotEmpty) ...[
                    const SizedBox(height: J3Space.sm),
                    for (final d in details.take(12))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: SelectableText('> $d', style: J3Type.codeSmall),
                      ),
                    if (details.length > 12)
                      Text('... ${details.length - 12} more', style: J3Type.caption),
                  ],
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: J3Space.sm),
                    Wrap(spacing: J3Space.sm, runSpacing: J3Space.sm, children: actions),
                  ],
                ],
              ),
            ),
            if (onDismiss != null)
              IconButton(
                tooltip: 'Dismiss',
                onPressed: onDismiss,
                icon: const Icon(Icons.close, size: 18),
              ),
          ],
        ),
      ),
    );
  }
}

/// Error panel for tool failures and malformed input.
class ErrorPanel extends StatelessWidget {
  const ErrorPanel({super.key, required this.title, required this.error, this.hint, this.onRetry});
  final String title;
  final Object error;
  final String? hint;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return StatusBanner(
      kind: StatusKind.error,
      title: title,
      message: error.toString(),
      details: [?hint],
      actions: [
        if (onRetry != null) TextButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh, size: 18), label: const Text('Retry')),
      ],
    );
  }
}

/// Empty state with a small ASCII glyph, message and optional action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.message,
    this.action,
    this.glyph = '[ -_- ]',
  });

  final String title;
  final String? message;
  final Widget? action;
  final String glyph;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(J3Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(glyph, style: J3Type.ascii.copyWith(fontSize: 22, color: fx.accentColor.withValues(alpha: 0.8))),
            const SizedBox(height: J3Space.md),
            Text(title, style: J3Type.subtitle, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: J3Space.xs),
              Text(message!, style: J3Type.bodySecondary, textAlign: TextAlign.center),
            ],
            if (action != null) ...[const SizedBox(height: J3Space.lg), action!],
          ],
        ),
      ),
    );
  }
}

/// Loading state. Shows real progress when [progress] is known.
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, required this.label, this.progress, this.onCancel});
  final String label;
  final double? progress;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(J3Space.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: J3Type.bodySecondary)),
              if (progress != null) Text('${(progress! * 100).toStringAsFixed(0)}%', style: J3Type.code),
            ],
          ),
          const SizedBox(height: J3Space.sm),
          NeonProgressBar(value: progress),
          if (onCancel != null) ...[
            const SizedBox(height: J3Space.sm),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(onPressed: onCancel, icon: const Icon(Icons.stop_circle_outlined, size: 18), label: const Text('Cancel')),
            ),
          ],
        ],
      ),
    );
  }
}

/// Segmented neon progress bar; indeterminate when [value] is null.
class NeonProgressBar extends StatelessWidget {
  const NeonProgressBar({super.key, this.value, this.height = 6});
  final double? value;
  final double height;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: LinearProgressIndicator(
          value: value,
          color: fx.accentColor,
          backgroundColor: J3Colors.surfaceHigh,
          semanticsLabel: 'Progress',
          semanticsValue: value == null ? null : '${(value! * 100).round()}%',
        ),
      ),
    );
  }
}
