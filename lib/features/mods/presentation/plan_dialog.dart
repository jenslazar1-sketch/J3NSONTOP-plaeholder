import 'package:flutter/material.dart';

import '../../../core/theme/effects.dart';
import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/widgets.dart';
import '../data/apply_engine.dart';
import '../domain/issues.dart';
import '../domain/plan.dart';
import '../domain/resolver.dart';
import 'mods_widgets.dart';

/// Shows every planned change before anything is written. Returns true when
/// the user confirms applying.
Future<bool> showPlanDialog(BuildContext context, {required ApplyPlan plan, required ResolutionReport report}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _PlanDialog(plan: plan, report: report),
  );
  return ok ?? false;
}

class _PlanDialog extends StatefulWidget {
  const _PlanDialog({required this.plan, required this.report});
  final ApplyPlan plan;
  final ResolutionReport report;

  @override
  State<_PlanDialog> createState() => _PlanDialogState();
}

class _PlanDialogState extends State<_PlanDialog> {
  bool _ack = false;

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final report = widget.report;
    final fx = context.effects;
    final warnings = report.issues.where((i) => i.severity == IssueSeverity.warning).length;
    final needsAck = warnings > 0 && plan.hasWork;
    final canApply = plan.hasWork && (!needsAck || _ack);
    return Dialog(
      insetPadding: const EdgeInsets.all(J3Space.md),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(J3Space.lg, J3Space.lg, J3Space.lg, J3Space.sm),
                children: [
                  Text('// APPLY PLAN', style: J3Type.kicker.copyWith(color: fx.accentText)),
                  Text('Apply "${plan.profileName}"', style: J3Type.title),
                  const SizedBox(height: J3Space.xs),
                  Text(
                    'Target: ${plan.targetRel == '.' ? 'workspace root' : plan.targetRel}  |  '
                    '${plan.packages.join(' -> ')}',
                    style: J3Type.caption,
                  ),
                  const SizedBox(height: J3Space.md),
                  Wrap(
                    spacing: J3Space.sm,
                    runSpacing: J3Space.sm,
                    children: [
                      ChangeChip(ChangeAction.create, count: plan.creates),
                      ChangeChip(ChangeAction.overwrite, count: plan.overwrites),
                      ChangeChip(ChangeAction.unchanged, count: plan.unchanged),
                      InfoChip(
                        '${plan.directoriesToCreate.length} new folder(s)',
                        icon: Icons.create_new_folder_outlined,
                      ),
                      InfoChip('${Fmt.bytes(plan.bytesToWrite)} to write', icon: Icons.save_outlined),
                    ],
                  ),
                  const SizedBox(height: J3Space.md),
                  if (!plan.hasWork)
                    const ModBanner(
                      kind: StatusKind.info,
                      title: 'Already up to date',
                      message: 'Every planned file is identical to the target. Nothing would be written.',
                    ),
                  for (final c in plan.changes) _ChangeRow(change: c),
                  if (plan.directoriesToCreate.isNotEmpty) ...[
                    const SizedBox(height: J3Space.sm),
                    Text('FOLDERS TO CREATE', style: J3Type.kicker.copyWith(color: fx.accentText)),
                    for (final d in plan.directoriesToCreate)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.create_new_folder_outlined, size: 16, color: J3Colors.success),
                            const SizedBox(width: J3Space.sm),
                            Expanded(child: Text('$d/', style: J3Type.code)),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: J3Space.md),
                  Text(
                    'Originals of overwritten files are backed up and verified before anything changes. Every step '
                    'is journaled, so the operation can be rolled back later.',
                    style: J3Type.caption,
                  ),
                  if (needsAck) ...[
                    const SizedBox(height: J3Space.sm),
                    CheckboxListTile(
                      value: _ack,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (v) => setState(() => _ack = v ?? false),
                      title: Text('I reviewed $warnings warning(s) and overlap(s)', style: J3Type.body),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(J3Space.md),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [
                  NeonButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop(false)),
                  NeonButton(
                    label: plan.hasWork ? 'Apply ${plan.creates + plan.overwrites} change(s)' : 'Nothing to apply',
                    icon: Icons.bolt,
                    onPressed: canApply ? () => Navigator.of(context).pop(true) : null,
                    tooltip: needsAck && !_ack ? 'Confirm that you reviewed the warnings first' : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({required this.change});
  final PlannedChange change;

  @override
  Widget build(BuildContext context) {
    final c = change;
    final size = switch (c.action) {
      ChangeAction.create => Fmt.bytes(c.size),
      ChangeAction.overwrite => '${Fmt.bytes(c.currentSize ?? 0)} -> ${Fmt.bytes(c.size)}',
      ChangeAction.unchanged => '${Fmt.bytes(c.size)}, identical',
    };
    return Semantics(
      label: '${c.action.label} ${c.path}, $size, from ${c.packageId}',
      excludeSemantics: true,
      child: Container(
        margin: const EdgeInsets.only(bottom: J3Space.xs),
        padding: const EdgeInsets.symmetric(horizontal: J3Space.sm, vertical: J3Space.xs),
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
            const SizedBox(height: 2),
            Text(
              '$size  |  from ${c.packageId} ${c.packageVersion}'
              '${c.overrides.isNotEmpty ? '  |  overrides ${c.overrides.join(', ')}' : ''}',
              style: J3Type.codeSmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks, per conflicting file, whether to keep the user's edit or restore
/// the original (after saving the edit next to the backup). Returns null
/// when cancelled.
Future<Map<String, ConflictDecision>?> showConflictDialog(BuildContext context, {required RollbackPreview preview}) {
  return showDialog<Map<String, ConflictDecision>>(
    context: context,
    builder: (_) => _ConflictDialog(preview: preview),
  );
}

class _ConflictDialog extends StatefulWidget {
  const _ConflictDialog({required this.preview});
  final RollbackPreview preview;

  @override
  State<_ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<_ConflictDialog> {
  late final Map<String, ConflictDecision> _decisions = {
    for (final c in widget.preview.conflicts) c.path: ConflictDecision.keepUserEdit,
  };

  void _all(ConflictDecision d) => setState(() {
    for (final k in _decisions.keys) {
      _decisions[k] = d;
    }
  });

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final pv = widget.preview;
    return Dialog(
      insetPadding: const EdgeInsets.all(J3Space.md),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(J3Space.lg, J3Space.lg, J3Space.lg, J3Space.sm),
                children: [
                  Text('// ROLLBACK CONFLICTS', style: J3Type.kicker.copyWith(color: fx.accentText)),
                  Text('Files changed after applying', style: J3Type.title),
                  const SizedBox(height: J3Space.xs),
                  Text(
                    '${pv.conflicts.length} file(s) no longer match what "${pv.journal.profileName}" wrote. Choose '
                    'per file. "Restore original" first saves your version next to the backup, so nothing is lost. '
                    'Everything else rolls back normally (${pv.toRestore} restore, ${pv.toDelete} remove).',
                    style: J3Type.bodySecondary,
                  ),
                  const SizedBox(height: J3Space.sm),
                  Wrap(
                    spacing: J3Space.sm,
                    runSpacing: J3Space.sm,
                    children: [
                      NeonButton.ghost(
                        label: 'Keep all my edits',
                        icon: Icons.edit_note,
                        onPressed: () => _all(ConflictDecision.keepUserEdit),
                      ),
                      NeonButton.ghost(
                        label: 'Restore all originals',
                        icon: Icons.restore,
                        onPressed: () => _all(ConflictDecision.restoreOriginal),
                      ),
                    ],
                  ),
                  const SizedBox(height: J3Space.sm),
                  for (final c in pv.conflicts)
                    Container(
                      margin: const EdgeInsets.only(bottom: J3Space.sm),
                      padding: const EdgeInsets.all(J3Space.sm),
                      decoration: BoxDecoration(
                        color: J3Colors.surfaceRaised,
                        borderRadius: J3Radius.small,
                        border: Border.all(color: J3Colors.warning.withValues(alpha: 0.5)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.warning_amber_rounded, size: 18, color: J3Colors.warning),
                              const SizedBox(width: J3Space.sm),
                              Expanded(child: SelectableText(c.path, style: J3Type.code)),
                            ],
                          ),
                          Text(
                            '${c.kind.label}  |  ${c.change.action.label.toLowerCase()} by ${c.change.packageId}',
                            style: J3Type.caption,
                          ),
                          const SizedBox(height: J3Space.xs),
                          Wrap(
                            spacing: J3Space.sm,
                            runSpacing: J3Space.xs,
                            children: [
                              ChoiceChip(
                                label: Text(c.kind == ConflictKind.deleted ? 'Keep it deleted' : 'Keep my edit'),
                                selected: _decisions[c.path] == ConflictDecision.keepUserEdit,
                                onSelected: (_) => setState(() => _decisions[c.path] = ConflictDecision.keepUserEdit),
                                materialTapTargetSize: MaterialTapTargetSize.padded,
                              ),
                              ChoiceChip(
                                label: Text(
                                  c.change.action == ChangeAction.create
                                      ? 'Remove (save my edit first)'
                                      : 'Restore original${c.kind == ConflictKind.edited ? ' (save my edit first)' : ''}',
                                ),
                                selected: _decisions[c.path] == ConflictDecision.restoreOriginal,
                                onSelected: (_) =>
                                    setState(() => _decisions[c.path] = ConflictDecision.restoreOriginal),
                                materialTapTargetSize: MaterialTapTargetSize.padded,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  if (pv.problems.isNotEmpty)
                    ModBanner(kind: StatusKind.warning, title: 'Will be left unchanged', details: pv.problems),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(J3Space.md),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [
                  NeonButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
                  NeonButton.danger(label: 'Roll back', onPressed: () => Navigator.of(context).pop(Map.of(_decisions))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
