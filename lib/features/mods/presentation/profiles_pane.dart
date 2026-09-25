import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../../../core/activity/activity_controller.dart';
import '../../../core/drafts/drafts.dart';
import '../../../core/theme/effects.dart';
import '../../../core/theme/j3_colors.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/utils/safe_path.dart';
import '../../../core/widgets/widgets.dart';
import '../data/profile_store.dart';
import '../domain/issues.dart';
import '../domain/manifest.dart';
import '../domain/profile.dart';
import '../domain/resolver.dart';
import 'mods_controller.dart';
import 'mods_flows.dart';
import 'mods_widgets.dart';

const String kSelectedProfileKey = 'mods.manager/profile';

/// The selected profile id (falls back to the first valid profile).
String? selectedProfileId(WidgetRef ref) {
  final s = ref.watch(modsProvider);
  final chosen = ref.draft<String?>(kSelectedProfileKey, null);
  if (chosen != null && s.profileById(chosen) != null) return chosen;
  final valid = s.validProfiles;
  return valid.isEmpty ? null : valid.first.id;
}

StatusKind _reportKind(ResolutionReport? r) {
  if (r == null) return StatusKind.neutral;
  if (r.hasErrors) return StatusKind.error;
  if (r.hasWarnings) return StatusKind.warning;
  return StatusKind.success;
}

String _reportLabel(ResolutionReport? r) {
  if (r == null) return '--';
  if (r.hasErrors) return '${r.errors.length} ERR';
  final w = r.issues.where((i) => i.severity == IssueSeverity.warning).length;
  if (w > 0) return '$w WARN';
  return 'READY';
}

/// PROFILES: list with CRUD/import/export, plus the selected profile editor.
class ProfilesPane extends ConsumerWidget {
  const ProfilesPane({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await showJ3TextInput(
      context,
      title: 'New profile',
      label: 'Profile name',
      confirmLabel: 'Create',
      validator: validateProfileName,
    );
    if (name == null || !context.mounted) return;
    final ws = ref.read(modsProvider).workspace;
    // Sensible default target: a folder with game.json, else the root.
    var target = '.';
    if (ws != null) {
      for (final candidate in ['game', 'Game']) {
        if (await Directory(p.join(ws.rootPath, candidate)).exists()) {
          target = candidate;
          break;
        }
      }
    }
    try {
      final prof = await ref.read(modsProvider.notifier).createProfile(name.trim(), target: target);
      ref.setDraft(kSelectedProfileKey, prof.id);
    } catch (e) {
      ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Could not create the profile: $e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(modsProvider);
    final selected = selectedProfileId(ref);
    final prof = s.profileById(selected);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: 'PROFILES',
          title: 'Mod profiles (${s.profiles.length})',
          icon: Icons.playlist_add_check,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [
                  NeonButton(
                    label: 'New profile',
                    icon: Icons.add,
                    onPressed: s.isBusy ? null : () => _create(context, ref),
                  ),
                  NeonButton.secondary(
                    label: 'Import profile',
                    icon: Icons.file_open_outlined,
                    onPressed: s.isBusy ? null : () => importProfileFlow(context, ref),
                  ),
                ],
              ),
              const SizedBox(height: J3Space.md),
              if (s.profiles.isEmpty)
                const EmptyState(
                  title: 'No profiles yet',
                  message: 'A profile is an ordered list of packages applied to one target folder.',
                  glyph: '[ 1 > 2 > 3 ]',
                )
              else
                for (final sp in s.profiles) ...[
                  sp.profile == null
                      ? _DamagedProfileTile(stored: sp)
                      : _ProfileTile(profile: sp.profile!, selected: sp.profile!.id == selected),
                  const SizedBox(height: J3Space.xs),
                ],
            ],
          ),
        ),
        if (prof != null) ...[const SizedBox(height: J3Space.lg), ProfileEditor(profile: prof)],
      ],
    );
  }
}

enum _ProfileAction { duplicate, rename, export, delete }

class _ProfileTile extends ConsumerWidget {
  const _ProfileTile({required this.profile, required this.selected});
  final ModProfile profile;
  final bool selected;

  Future<void> _act(BuildContext context, WidgetRef ref, _ProfileAction a) async {
    final ctrl = ref.read(modsProvider.notifier);
    final activity = ref.read(activityProvider.notifier);
    try {
      switch (a) {
        case _ProfileAction.duplicate:
          final copy = await ctrl.duplicateProfile(profile.id);
          ref.setDraft(kSelectedProfileKey, copy.id);
        case _ProfileAction.rename:
          final name = await showJ3TextInput(
            context,
            title: 'Rename profile',
            label: 'Profile name',
            initial: profile.name,
            confirmLabel: 'Rename',
            validator: validateProfileName,
          );
          if (name != null) await ctrl.renameProfile(profile.id, name.trim());
        case _ProfileAction.export:
          await saveOutput(
            context,
            ref,
            suggestedName: ProfileStore.exportFileName(profile),
            bytes: Uint8List.fromList(utf8.encode(ProfileStore.exportText(profile))),
            mimeType: 'application/json',
            toolId: kModsManagerId,
          );
        case _ProfileAction.delete:
          final ok = await showJ3Confirm(
            context,
            title: 'Delete "${profile.name}"?',
            message:
                'Deletes the profile file only. Packages stay in the library and files already applied to the '
                'target are not touched (roll back first to undo them).',
            confirmLabel: 'Delete',
            destructive: true,
          );
          if (ok) await ctrl.deleteProfile(profile.id);
      }
    } catch (e) {
      activity.notify(NoticeKind.error, 'Profile action failed: $e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fx = context.effects;
    final report = ref.watch(profileReportProvider(profile.id));
    final s = ref.watch(modsProvider);
    final applied = s.operations.any((o) => o.isOpen && o.profileId == profile.id);
    return Material(
      color: selected ? J3Colors.selection : J3Colors.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: J3Radius.medium,
        side: BorderSide(color: selected ? fx.accentColor : J3Colors.border, width: selected ? 1.5 : 1),
      ),
      child: InkWell(
        borderRadius: J3Radius.medium,
        onTap: () => ref.setDraft(kSelectedProfileKey, profile.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(J3Space.md, J3Space.sm, J3Space.xs, J3Space.sm),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(profile.name, style: J3Type.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                    Text(
                      '${profile.id}  |  target ${profile.target}  |  ${enabledSummary(profile)}',
                      style: J3Type.codeSmall,
                    ),
                    const SizedBox(height: J3Space.xs),
                    Wrap(
                      spacing: J3Space.xs,
                      runSpacing: J3Space.xs,
                      children: [
                        StatusBadge(kind: _reportKind(report), text: _reportLabel(report), dense: true),
                        if (applied) const StatusBadge(kind: StatusKind.info, text: 'APPLIED', dense: true),
                      ],
                    ),
                  ],
                ),
              ),
              PopupMenuButton<_ProfileAction>(
                tooltip: 'Actions for ${profile.name}',
                onSelected: (a) => _act(context, ref, a),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: _ProfileAction.duplicate, child: Text('Duplicate')),
                  PopupMenuItem(value: _ProfileAction.rename, child: Text('Rename')),
                  PopupMenuItem(value: _ProfileAction.export, child: Text('Export .j3profile.json')),
                  PopupMenuItem(value: _ProfileAction.delete, child: Text('Delete')),
                ],
                icon: const Icon(Icons.more_vert),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DamagedProfileTile extends ConsumerWidget {
  const _DamagedProfileTile({required this.stored});
  final StoredProfile stored;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ModBanner(
      kind: StatusKind.error,
      title: 'Unreadable profile ${p.basename(stored.path)}',
      details: [for (final i in stored.issues) i.toString()],
      actions: [
        NeonButton.danger(
          label: 'Delete file',
          onPressed: () async {
            final ok = await showJ3Confirm(
              context,
              title: 'Delete the damaged profile file?',
              message: stored.path,
              confirmLabel: 'Delete',
              destructive: true,
            );
            if (ok) await ref.read(modsProvider.notifier).deleteDamagedProfile(stored);
          },
        ),
      ],
    );
  }
}

/// Editor for one profile: load order, enable switches, live resolution,
/// sort fix, plan & apply, roll back, export result.
class ProfileEditor extends ConsumerWidget {
  const ProfileEditor({super.key, required this.profile});
  final ModProfile profile;

  Future<void> _changeTarget(BuildContext context, WidgetRef ref) async {
    final ws = ref.read(modsProvider).workspace;
    if (ws == null) return;
    final dir = await showWorkspaceBrowser(
      context,
      workspace: ws,
      mode: BrowseMode.pickFolder,
      title: 'Choose the target folder',
    );
    if (dir == null) return;
    var rel = p.relative(dir, from: ws.rootPath).replaceAll('\\', '/');
    try {
      rel = normalizeProfileTarget(rel);
    } on UnsafePathException catch (e) {
      ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Unusable folder: ${e.reason}');
      return;
    }
    await ref.read(modsProvider.notifier).updateProfile(profile.copyWith(target: rel), targetChanged: true);
  }

  Future<void> _editDetails(BuildContext context, WidgetRef ref) async {
    final updated = await showDialog<ModProfile>(
      context: context,
      builder: (_) => _ProfileDetailsDialog(profile: profile),
    );
    if (updated != null) {
      await ref.read(modsProvider.notifier).updateProfile(updated, targetChanged: true);
    }
  }

  Future<void> _addPackage(BuildContext context, WidgetRef ref) async {
    final s = ref.read(modsProvider);
    final candidates = s.manifests.values.where((m) => !profile.contains(m.id)).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final id = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Add package'),
        children: [
          if (candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.all(J3Space.lg),
              child: Text('Every valid library package is already in this profile.', style: J3Type.bodySecondary),
            ),
          for (final m in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.of(ctx).pop(m.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: J3Space.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.name, style: J3Type.label),
                    Text('${m.id} ${m.version}', style: J3Type.codeSmall),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    if (id != null) await ref.read(modsProvider.notifier).addMod(profile, id);
  }

  Future<void> _sort(WidgetRef ref) async {
    final r = await ref.read(modsProvider.notifier).sortByDependencies(profile);
    final activity = ref.read(activityProvider.notifier);
    if (r.unsortable.isNotEmpty) {
      activity.notify(NoticeKind.warning, 'Sorted; a cycle keeps ${r.unsortable.join(', ')} in their order');
    } else {
      activity.notify(NoticeKind.success, r.changed ? 'Load order sorted by dependencies' : 'Order already valid');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fx = context.effects;
    final s = ref.watch(modsProvider);
    final report = ref.watch(profileReportProvider(profile.id));
    final canApplyHere = ref.watch(canApplyHereProvider);
    final target = s.targets[profile.id] ?? TargetGame.unknown;
    final result = s.results[profile.id];
    final rollbackOp = s.rollbackCandidateFor(profile.id);
    final sortWouldChange = ModResolver.sortByDependencies(profile, s.manifests).changed;
    final ws = s.workspace;

    return NeonPanel(
      kicker: 'PROFILE EDITOR',
      title: profile.name,
      icon: Icons.tune,
      emphasis: PanelEmphasis.strong,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (profile.description.isNotEmpty) ...[
            Text(profile.description, style: J3Type.bodySecondary),
            const SizedBox(height: J3Space.sm),
          ],
          KeyValueTable(
            keyWidth: 90,
            rows: [
              ('Target', profile.target == '.' ? '. (workspace root)' : '${profile.target}/'),
              ('Game', target.isKnown ? target.toString() : 'unknown (no game.json, no profile game)'),
            ],
          ),
          const SizedBox(height: J3Space.xs),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.xs,
            children: [
              NeonButton.ghost(
                label: 'Change target',
                icon: Icons.drive_folder_upload_outlined,
                onPressed: s.isBusy ? null : () => _changeTarget(context, ref),
              ),
              NeonButton.ghost(
                label: 'Edit details',
                icon: Icons.edit_outlined,
                onPressed: s.isBusy ? null : () => _editDetails(context, ref),
              ),
            ],
          ),
          const SizedBox(height: J3Space.md),
          Text('LOAD ORDER  (first -> last, last wins)', style: J3Type.kicker.copyWith(color: fx.accentText)),
          const SizedBox(height: J3Space.xs),
          if (profile.mods.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: J3Space.sm),
              child: Text('No packages in this profile yet. Add some from the library.', style: J3Type.caption),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: profile.mods.length,
              onReorderItem: (from, to) => ref.read(modsProvider.notifier).moveMod(profile, from, to),
              itemBuilder: (context, i) => _ModRow(
                key: ValueKey('mod-${profile.id}-${profile.mods[i].id}'),
                profile: profile,
                index: i,
                report: report,
                disabled: s.isBusy,
              ),
            ),
          const SizedBox(height: J3Space.xs),
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.xs,
            children: [
              NeonButton.secondary(
                label: 'Add package',
                icon: Icons.add,
                onPressed: s.isBusy ? null : () => _addPackage(context, ref),
              ),
              NeonButton.secondary(
                label: 'Sort by dependencies',
                icon: Icons.sort,
                onPressed: s.isBusy || !sortWouldChange ? null : () => _sort(ref),
                tooltip: sortWouldChange
                    ? 'Move dependencies before their dependents (stable)'
                    : 'The order already respects every dependency',
              ),
            ],
          ),
          if (report != null) ...[
            const SizedBox(height: J3Space.lg),
            Text('DEPENDENCY CHAINS', style: J3Type.kicker.copyWith(color: fx.accentText)),
            const SizedBox(height: J3Space.xs),
            DependencyChainView(report: report, manifests: s.manifests),
            const SizedBox(height: J3Space.md),
            ResolutionView(report: report),
          ],
          const SizedBox(height: J3Space.md),
          if (!canApplyHere)
            ModBanner(
              kind: StatusKind.info,
              title: 'Apply is not available for this workspace here',
              message:
                  'Linked folders can only be modified on desktop. Import the files into a workspace copy to apply '
                  'profiles on this device.',
            ),
          if (result != null) ...[
            ModBanner.note(result, onDismiss: () => ref.read(modsProvider.notifier).setResult(profile.id, null)),
            const SizedBox(height: J3Space.sm),
          ],
          if (s.isBusy) ...[_BusyLine(), const SizedBox(height: J3Space.sm)],
          Wrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              NeonButton(
                label: 'Plan & apply',
                icon: Icons.play_arrow_rounded,
                busy: s.isBusy && (s.busyLabel?.contains(profile.name) ?? false),
                onPressed: s.isBusy || report == null || !report.canApply || !canApplyHere
                    ? null
                    : () => planAndApplyFlow(context, ref, profile),
                tooltip: report != null && report.hasErrors ? 'Fix the errors above first' : null,
              ),
              if (rollbackOp != null)
                NeonButton.danger(
                  label: 'Roll back',
                  icon: Icons.undo,
                  onPressed: s.isBusy ? null : () => rollbackFlow(context, ref, rollbackOp),
                  tooltip: 'Undo operation ${rollbackOp.id}',
                ),
              if (ws != null && ws.kind.isAppOwned)
                NeonButton.secondary(
                  label: 'Export result',
                  icon: Icons.archive_outlined,
                  onPressed: s.isBusy ? null : () => exportResultFlow(context, ref, profile.target),
                  tooltip: 'ZIP the target folder and save or share it',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BusyLine extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(modsProvider);
    final op = ref.watch(activityProvider.select((a) => a.operations.where((o) => o.id == s.busyOpId).firstOrNull));
    return LoadingState(
      label: op?.progressMessage ?? s.busyLabel ?? 'Working',
      progress: op?.progress,
      onCancel: op != null && op.cancellable ? () => ref.read(activityProvider.notifier).cancel(op.id) : null,
    );
  }
}

class _ModRow extends ConsumerWidget {
  const _ModRow({super.key, required this.profile, required this.index, required this.report, required this.disabled});
  final ModProfile profile;
  final int index;
  final ResolutionReport? report;
  final bool disabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fx = context.effects;
    final s = ref.watch(modsProvider);
    final mod = profile.mods[index];
    final ModManifest? man = s.manifests[mod.id];
    final issues = report?.forPackage(mod.id).where((i) => i.code != ResolutionCode.overlap).toList() ?? const [];
    final ctrl = ref.read(modsProvider.notifier);
    final missing = man == null;
    final worst = issues.any((i) => i.isError)
        ? StatusKind.error
        : issues.any((i) => i.severity == IssueSeverity.warning)
        ? StatusKind.warning
        : null;

    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          man?.name ?? mod.id,
          style: J3Type.label.copyWith(color: mod.enabled ? J3Colors.text : J3Colors.textMuted),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          missing
              ? '${mod.id}  |  ${s.invalidIds.contains(mod.id) ? 'INVALID PACKAGE' : 'MISSING FROM LIBRARY'}'
              : '${mod.id} ${man.version}${mod.enabled ? '' : '  |  disabled'}',
          style: J3Type.codeSmall.copyWith(color: missing ? J3Colors.error : null),
        ),
        if (mod.enabled && worst != null)
          for (final i in issues.take(3))
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(statusOfSeverity(i.severity).icon, size: 13, color: statusOfSeverity(i.severity).color),
                const SizedBox(width: 4),
                Expanded(child: Text(i.message, style: J3Type.caption)),
              ],
            ),
      ],
    );

    final handle = ReorderableDragStartListener(
      index: index,
      enabled: !disabled,
      child: Tooltip(
        message: 'Drag to reorder',
        child: Padding(
          padding: const EdgeInsets.all(J3Space.xs),
          child: Icon(Icons.drag_indicator, color: disabled ? J3Colors.textDisabled : J3Colors.textSecondary),
        ),
      ),
    );
    final number = Text(
      (index + 1).toString().padLeft(2, '0'),
      style: J3Type.code.copyWith(color: fx.accentText, fontWeight: FontWeight.w700),
    );
    final toggle = Semantics(
      label: '${mod.enabled ? 'Disable' : 'Enable'} ${man?.name ?? mod.id}',
      child: Switch(value: mod.enabled, onChanged: disabled ? null : (v) => ctrl.setEnabled(profile, mod.id, v)),
    );
    final buttons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        NeonIconButton(
          icon: Icons.arrow_upward,
          tooltip: 'Move ${mod.id} up (applied earlier)',
          onPressed: disabled || index == 0 ? null : () => ctrl.moveMod(profile, index, index - 1),
        ),
        NeonIconButton(
          icon: Icons.arrow_downward,
          tooltip: 'Move ${mod.id} down (applied later)',
          onPressed: disabled || index == profile.mods.length - 1
              ? null
              : () => ctrl.moveMod(profile, index, index + 1),
        ),
        NeonIconButton(
          icon: Icons.remove_circle_outline,
          tooltip: 'Remove ${mod.id} from this profile',
          onPressed: disabled ? null : () => ctrl.removeMod(profile, mod.id),
        ),
      ],
    );

    return Container(
      margin: const EdgeInsets.only(bottom: J3Space.xs),
      decoration: BoxDecoration(
        color: J3Colors.surfaceRaised,
        borderRadius: J3Radius.small,
        border: Border.all(
          color: worst == StatusKind.error && mod.enabled
              ? J3Colors.error.withValues(alpha: 0.6)
              : (mod.enabled ? J3Colors.borderStrong : J3Colors.border),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: J3Space.xs, vertical: J3Space.xs),
      child: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth >= 520) {
            return Row(
              children: [
                handle,
                number,
                const SizedBox(width: J3Space.xs),
                toggle,
                const SizedBox(width: J3Space.xs),
                Expanded(child: title),
                buttons,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  handle,
                  Padding(
                    padding: const EdgeInsets.only(top: J3Space.xs),
                    child: number,
                  ),
                  const SizedBox(width: J3Space.xs),
                  Expanded(child: title),
                ],
              ),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [toggle, buttons],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Live resolution report grouped into errors, warnings, overlaps, notes.
class ResolutionView extends StatelessWidget {
  const ResolutionView({super.key, required this.report});
  final ResolutionReport report;

  @override
  Widget build(BuildContext context) {
    final errors = report.errors;
    final warnings = report.warnings;
    final notes = report.notes;
    if (errors.isEmpty && warnings.isEmpty && report.overlaps.isEmpty) {
      return ModBanner(
        kind: StatusKind.success,
        title: 'Ready',
        message:
            'All ${report.order.length} enabled package(s) resolve: dependencies, order, conflicts and '
            'compatibility check out.',
        details: [for (final n in notes) n.message],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (errors.isNotEmpty)
          IssueGroup(
            title: 'Errors (block applying)',
            kind: StatusKind.error,
            children: [for (final i in errors) IssueLine(severity: i.severity, message: i.message)],
          ),
        if (warnings.isNotEmpty)
          IssueGroup(
            title: 'Warnings',
            kind: StatusKind.warning,
            children: [for (final i in warnings) IssueLine(severity: i.severity, message: i.message)],
          ),
        if (report.overlaps.isNotEmpty)
          IssueGroup(
            title: 'Overlaps (last one wins)',
            kind: StatusKind.warning,
            children: [for (final o in report.overlaps) OverlapView(overlap: o)],
          ),
        if (notes.isNotEmpty)
          IssueGroup(
            title: 'Notes',
            kind: StatusKind.info,
            initiallyExpanded: false,
            children: [for (final i in notes) IssueLine(severity: i.severity, message: i.message)],
          ),
      ],
    );
  }
}

class _ProfileDetailsDialog extends StatefulWidget {
  const _ProfileDetailsDialog({required this.profile});
  final ModProfile profile;

  @override
  State<_ProfileDetailsDialog> createState() => _ProfileDetailsDialogState();
}

class _ProfileDetailsDialogState extends State<_ProfileDetailsDialog> {
  late final _name = TextEditingController(text: widget.profile.name);
  late final _desc = TextEditingController(text: widget.profile.description);
  late final _gameId = TextEditingController(text: widget.profile.game?.id ?? '');
  late final _gameVersion = TextEditingController(text: widget.profile.game?.version?.toString() ?? '');
  String? _nameError;
  String? _gameError;
  String? _versionError;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _gameId.dispose();
    _gameVersion.dispose();
    super.dispose();
  }

  void _save() {
    final nameErr = validateProfileName(_name.text);
    final gid = _gameId.text.trim();
    final gv = _gameVersion.text.trim();
    String? gameErr;
    String? versionErr;
    Version? version;
    if (gid.isNotEmpty) gameErr = validateModId(gid);
    if (gv.isNotEmpty) {
      if (gid.isEmpty) versionErr = 'Set a game id first';
      version ??= tryParseVersion(gv, (m) => versionErr = m);
    }
    if (_desc.text.length > 2000) {
      setState(() => _nameError = 'Description must be at most 2000 characters');
      return;
    }
    setState(() {
      _nameError = nameErr;
      _gameError = gameErr;
      _versionError = versionErr;
    });
    if (nameErr != null || gameErr != null || versionErr != null) return;
    Navigator.of(context).pop(
      widget.profile.copyWith(
        name: _name.text.trim(),
        description: _desc.text.trim(),
        game: gid.isEmpty ? null : ProfileGame(id: gid, version: version),
        clearGame: gid.isEmpty,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Profile details'),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              decoration: InputDecoration(labelText: 'Name', errorText: _nameError),
            ),
            const SizedBox(height: J3Space.sm),
            TextField(
              controller: _desc,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Description (optional)'),
            ),
            const SizedBox(height: J3Space.md),
            Text(
              'Game override: used for compatibility checks when the target folder has no game.json.',
              style: J3Type.caption,
            ),
            const SizedBox(height: J3Space.xs),
            TextField(
              controller: _gameId,
              style: J3Type.code,
              decoration: InputDecoration(labelText: 'Game id (e.g. neon-dungeon)', errorText: _gameError),
            ),
            const SizedBox(height: J3Space.sm),
            TextField(
              controller: _gameVersion,
              style: J3Type.code,
              inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
              decoration: InputDecoration(labelText: 'Game version (e.g. 1.4.2)', errorText: _versionError),
            ),
          ],
        ),
      ),
      actions: [
        NeonButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        NeonButton(label: 'Save', onPressed: _save),
      ],
    );
  }
}
