import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/activity/activity_controller.dart';
import '../../../core/theme/effects.dart';
import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/widgets.dart';
import '../data/journal.dart';
import '../domain/plan.dart';
import 'mods_controller.dart';
import 'mods_flows.dart';
import 'mods_widgets.dart';

StatusKind journalKind(OperationJournal j) => switch (j.status) {
  JournalStatus.applied => StatusKind.success,
  JournalStatus.rolledBack => StatusKind.neutral,
  JournalStatus.failed => StatusKind.error,
  JournalStatus.staging || JournalStatus.applying || JournalStatus.rollingBack => StatusKind.warning,
};

String journalBadge(OperationJournal j) => j.status.isInterrupted ? 'INTERRUPTED (${j.status.label})' : j.status.label;

/// Banner(s) at the top of the Mods page for interrupted operations.
class InterruptedBanner extends ConsumerWidget {
  const InterruptedBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(modsProvider);
    final list = s.interrupted;
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final op in list)
          Padding(
            padding: const EdgeInsets.only(bottom: J3Space.sm),
            child: ModBanner(
              kind: StatusKind.warning,
              title: 'Interrupted operation: "${op.profileName}"',
              message:
                  '${op.status == JournalStatus.rollingBack ? 'Rolling back' : 'Applying'} to "${op.targetRel}" stopped '
                  '(${op.doneCount} of ${op.changes.length} change(s) done, ${Fmt.relative(op.updatedAt)}). '
                  '${op.interruptedReason ?? 'The app closed before it finished.'} '
                  '${op.status == JournalStatus.rollingBack ? 'Roll back again to finish restoring.' : 'Resume to finish, or roll back to restore the recorded originals.'}',
              actions: [
                if (op.canResume)
                  NeonButton(
                    label: 'Resume',
                    icon: Icons.play_arrow_rounded,
                    onPressed: s.isBusy ? null : () => resumeFlow(context, ref, op),
                  ),
                NeonButton.danger(
                  label: 'Roll back',
                  icon: Icons.undo,
                  onPressed: s.isBusy ? null : () => rollbackFlow(context, ref, op),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// OPERATIONS: the journal list with status, details and actions.
class OperationsPane extends ConsumerWidget {
  const OperationsPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(modsProvider);
    return NeonPanel(
      kicker: 'OPERATIONS',
      title: 'Journal (${s.operations.length})',
      icon: Icons.history,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Every apply is journaled with verified backups. Only the newest active operation on a target can be '
            'rolled back.',
            style: J3Type.caption,
          ),
          const SizedBox(height: J3Space.sm),
          if (s.operations.isEmpty && s.damagedOps.isEmpty)
            const EmptyState(
              title: 'No operations yet',
              message: 'Applying a profile records a journal here.',
              glyph: '[ journal ]',
            ),
          for (final op in s.operations) ...[_OperationCard(op: op), const SizedBox(height: J3Space.sm)],
          for (final d in s.damagedOps)
            Padding(
              padding: const EdgeInsets.only(bottom: J3Space.sm),
              child: ModBanner(
                kind: StatusKind.error,
                title: 'Unreadable journal',
                message: '${d.error}. Its files were left in place: ${d.directory}',
              ),
            ),
        ],
      ),
    );
  }
}

class _OperationCard extends ConsumerWidget {
  const _OperationCard({required this.op});
  final OperationJournal op;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(modsProvider);
    final kind = journalKind(op);
    final latest = s.isLatestOnTarget(op);
    final result = s.results['op:${op.id}'];
    return Container(
      padding: const EdgeInsets.all(J3Space.md),
      decoration: BoxDecoration(
        color: J3Colors.surfaceRaised,
        borderRadius: J3Radius.medium,
        border: Border.all(color: kind.color.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusBadge(kind: kind, text: journalBadge(op), dense: true),
              Text(op.profileName, style: J3Type.label),
            ],
          ),
          const SizedBox(height: J3Space.xs),
          Text(
            '${Fmt.dateTime(op.createdAt)}  |  target ${op.targetRel}  |  '
            '${op.count(ChangeAction.create)} create, ${op.count(ChangeAction.overwrite)} overwrite, '
            '${op.createdDirs.length} folder(s)',
            style: J3Type.codeSmall,
          ),
          if (op.error != null) ...[
            const SizedBox(height: J3Space.xs),
            Text(op.error!, style: J3Type.caption.copyWith(color: J3Colors.error)),
          ],
          if (result != null) ...[
            const SizedBox(height: J3Space.sm),
            ModBanner.note(result, onDismiss: () => ref.read(modsProvider.notifier).setResult('op:${op.id}', null)),
          ],
          const SizedBox(height: J3Space.xs),
          Wrap(
            spacing: J3Space.xs,
            runSpacing: J3Space.xs,
            children: [
              NeonButton.ghost(
                label: 'Details',
                icon: Icons.list_alt,
                onPressed: () => showOperationDetails(context, ref, op),
              ),
              if (op.canRollback && latest && !op.status.isInterrupted)
                NeonButton.ghost(
                  label: 'Roll back',
                  icon: Icons.undo,
                  onPressed: s.isBusy ? null : () => rollbackFlow(context, ref, op),
                ),
              if (op.canResume && !op.status.isInterrupted)
                NeonButton.ghost(
                  label: 'Retry',
                  icon: Icons.replay,
                  onPressed: s.isBusy ? null : () => resumeFlow(context, ref, op),
                ),
              if (!op.isOpen)
                NeonIconButton(
                  icon: Icons.delete_sweep_outlined,
                  tooltip: 'Delete this journal and its backups',
                  onPressed: s.isBusy
                      ? null
                      : () async {
                          final ok = await showJ3Confirm(
                            context,
                            title: 'Delete journal?',
                            message:
                                'Deletes the journal, staged files and backups of this finished operation. The target '
                                'folder is not touched.',
                            confirmLabel: 'Delete',
                            destructive: true,
                          );
                          if (!ok) return;
                          try {
                            await ref.read(modsProvider.notifier).deleteOperation(op.id);
                          } catch (e) {
                            ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Delete failed: $e');
                          }
                        },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Journal details: every recorded change with its apply/rollback state.
Future<void> showOperationDetails(BuildContext context, WidgetRef ref, OperationJournal op) {
  final folder = ref.read(modsProvider.notifier).operationFolder(op.id);
  return showModsSheet<void>(
    context,
    title: 'Operation ${op.id}',
    builder: (ctx) {
      final fx = ctx.effects;
      return ListView(
        padding: const EdgeInsets.all(J3Space.lg),
        children: [
          StatusBadge(kind: journalKind(op), text: journalBadge(op)),
          const SizedBox(height: J3Space.sm),
          KeyValueTable(
            keyWidth: 110,
            rows: [
              ('Profile', '${op.profileName} (${op.profileId})'),
              ('Target', op.targetRel),
              ('Packages', op.packages.join(' -> ')),
              ('Created', Fmt.dateTime(op.createdAt)),
              if (op.appliedAt != null) ('Applied', Fmt.dateTime(op.appliedAt!)),
              if (op.rolledBackAt != null) ('Rolled back', Fmt.dateTime(op.rolledBackAt!)),
              ('Unchanged', '${op.unchanged.length} identical file(s) not touched'),
              ('Journal', folder),
            ],
          ),
          if (op.error != null) ...[
            const SizedBox(height: J3Space.sm),
            ModBanner(kind: StatusKind.error, title: 'Error', message: op.error),
          ],
          const SectionHeader(title: 'Changes', kicker: 'recorded'),
          for (final c in op.changes)
            Container(
              margin: const EdgeInsets.only(bottom: J3Space.xs),
              padding: const EdgeInsets.all(J3Space.sm),
              decoration: BoxDecoration(
                color: J3Colors.surfaceRaised,
                borderRadius: J3Radius.small,
                border: Border.all(color: J3Colors.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: J3Space.sm,
                    runSpacing: J3Space.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      ChangeChip(c.action),
                      Text(c.path, style: J3Type.code),
                    ],
                  ),
                  Text(
                    '${c.packageId} ${c.packageVersion}  |  ${Fmt.bytes(c.size)}  |  '
                    '${c.done ? 'applied' : (c.staged ? 'staged, not applied' : 'pending')}'
                    '${c.backup != null ? '  |  backup kept' : ''}',
                    style: J3Type.codeSmall,
                  ),
                  if (c.rollback != null)
                    Text('Rollback: ${c.rollback!.label}', style: J3Type.caption.copyWith(color: fx.accentText)),
                  if (c.savedEdit != null) Text('Your edit saved as ${c.savedEdit}', style: J3Type.caption),
                ],
              ),
            ),
          if (op.createdDirs.isNotEmpty) ...[
            const SectionHeader(title: 'Folders created', kicker: 'directories'),
            for (final d in op.createdDirs)
              Text(
                '$d/${op.removedDirs.contains(d)
                    ? '  (removed)'
                    : op.keptDirs.contains(d)
                    ? '  (kept: not empty)'
                    : ''}',
                style: J3Type.code,
              ),
          ],
        ],
      );
    },
  );
}
