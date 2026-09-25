import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/activity/activity_controller.dart';
import '../../core/activity/operation.dart';
import '../../core/theme/effects.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/status.dart';

StatusKind statusKindOf(OperationStatus s) => switch (s) {
  OperationStatus.running => StatusKind.running,
  OperationStatus.succeeded => StatusKind.success,
  OperationStatus.warning => StatusKind.warning,
  OperationStatus.failed => StatusKind.error,
  OperationStatus.cancelled => StatusKind.neutral,
};

/// Compact live activity feed (right panel on desktop, end drawer on
/// tablets/phones). Shows only real operations recorded by tools.
class ActivityPanel extends ConsumerWidget {
  const ActivityPanel({super.key, this.onClose});
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(activityProvider);
    final fx = context.effects;
    final ops = state.operations.take(40).toList();
    return Container(
      decoration: BoxDecoration(
        color: J3Colors.surface.withValues(alpha: 0.92),
        border: Border(left: BorderSide(color: fx.accentColor.withValues(alpha: 0.35))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(J3Space.lg, J3Space.md, J3Space.xs, J3Space.sm),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('// LIVE ACTIVITY', style: J3Type.kicker.copyWith(color: fx.accentText)),
                      Text(
                        '${state.running.length} running  |  ${state.countToday(DateTime.now())} today',
                        style: J3Type.caption,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Open activity log',
                  onPressed: () => context.go('/activity'),
                  icon: const Icon(Icons.open_in_full, size: 18),
                ),
                if (onClose != null)
                  IconButton(
                    tooltip: 'Hide activity panel',
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 18),
                  ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: ops.isEmpty
                ? const EmptyState(
                    title: 'No operations yet',
                    message: 'Hashes, conversions, profile applies and exports appear here with real results.',
                    glyph: '>_',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(J3Space.sm),
                    itemCount: ops.length,
                    separatorBuilder: (_, _) => const SizedBox(height: J3Space.xs),
                    itemBuilder: (context, i) => OperationTile(op: ops[i], compact: true),
                  ),
          ),
        ],
      ),
    );
  }
}

/// One operation row. Shared by the panel and the Activity screen.
class OperationTile extends ConsumerWidget {
  const OperationTile({super.key, required this.op, this.compact = false});
  final OperationRecord op;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kind = statusKindOf(op.status);
    final running = op.status == OperationStatus.running;
    return AccentBarBox(
      color: kind.color,
      borderOpacity: 0.18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(op.title, style: J3Type.label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              StatusBadge(kind: kind, text: op.status.label, dense: true),
            ],
          ),
          const SizedBox(height: 2),
          if (running) ...[
            const SizedBox(height: J3Space.xs),
            NeonProgressBar(value: op.progress, height: 4),
            if (op.progressMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(op.progressMessage!, style: J3Type.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            if (op.cancellable)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => ref.read(activityProvider.notifier).cancel(op.id),
                  child: const Text('Cancel'),
                ),
              ),
          ] else
            Text(
              op.error ?? op.summary ?? '',
              style: J3Type.caption.copyWith(color: op.error != null ? J3Colors.error : J3Colors.textSecondary),
              maxLines: compact ? 2 : 6,
              overflow: TextOverflow.ellipsis,
            ),
          Text(
            '${Fmt.time(op.startedAt)}${op.elapsed != null ? '  |  ${Fmt.duration(op.elapsed!)}' : ''}  |  ${op.toolId}',
            style: J3Type.codeSmall.copyWith(fontSize: 10.5, color: J3Colors.textMuted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
