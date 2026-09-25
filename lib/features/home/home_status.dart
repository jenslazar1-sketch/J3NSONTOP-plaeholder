import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../core/activity/activity_controller.dart';
import '../../core/platform/capabilities.dart';
import '../../core/theme/effects.dart';
import '../../core/theme/j3_colors.dart';
import '../../core/theme/j3_spacing.dart';
import '../../core/theme/j3_typography.dart';
import '../../core/tools/tool_registry.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/widgets.dart';
import '../../core/workspace/workspace.dart';
import '../../core/workspace/workspace_controller.dart';
import '../shell/activity_panel.dart' show statusKindOf;

/// Real, on-disk facts about the active workspace.
class WorkspaceSnapshot {
  const WorkspaceSnapshot({
    required this.workspace,
    required this.health,
    required this.modPackages,
    required this.profiles,
    this.countError,
  });

  final Workspace workspace;
  final WorkspaceHealth health;

  /// `<metaDir>/mods/*.j3mod`; null when the folder could not be read.
  final int? modPackages;

  /// `<metaDir>/profiles/*.j3profile.json`; null when unreadable.
  final int? profiles;
  final String? countError;
}

/// Counts regular files in [dir] whose name ends with [suffix]
/// (case-insensitive). A missing directory counts as 0.
Future<int> countFilesWithSuffix(String dir, String suffix) async {
  final d = Directory(dir);
  if (!await d.exists()) return 0;
  final lower = suffix.toLowerCase();
  var n = 0;
  await for (final e in d.list(followLinks: false)) {
    if (e is File && p.basename(e.path).toLowerCase().endsWith(lower)) n++;
  }
  return n;
}

/// Changes whenever an operation starts, finishes or history is cleared, so
/// workspace counts are refreshed after mods are imported or profiles saved.
String _activitySignature(ActivityState s) {
  var finished = 0;
  for (final o in s.operations) {
    if (o.status.isFinished) finished++;
  }
  return '$finished/${s.operations.length - finished}';
}

/// Health and mod/profile counts of the active workspace. Never throws (a
/// failing provider would be retried on a timer); errors are reported in
/// the snapshot instead.
final activeWorkspaceSnapshotProvider = FutureProvider.autoDispose<WorkspaceSnapshot?>((ref) async {
  final ws = ref.watch(activeWorkspaceProvider);
  ref.watch(activityProvider.select(_activitySignature));
  if (ws == null) return null;
  final meta = ref.read(workspacesProvider.notifier).metaDir(ws);
  WorkspaceHealth health;
  try {
    health = await WorkspaceController.checkHealth(ws);
  } catch (_) {
    health = WorkspaceHealth.permissionDenied;
  }
  int? mods;
  int? profiles;
  String? error;
  try {
    mods = await countFilesWithSuffix(p.join(meta, 'mods'), '.j3mod');
    profiles = await countFilesWithSuffix(p.join(meta, 'profiles'), '.j3profile.json');
  } catch (e) {
    error = e.toString();
  }
  return WorkspaceSnapshot(workspace: ws, health: health, modPackages: mods, profiles: profiles, countError: error);
});

/// Status kind, short label and explanation for a health result.
(StatusKind, String, String) describeHealth(WorkspaceHealth h) => switch (h) {
  WorkspaceHealth.ok => (StatusKind.success, 'REACHABLE', 'The workspace folder exists and can be read.'),
  WorkspaceHealth.missing => (
    StatusKind.error,
    'MISSING',
    'The folder no longer exists. It may have been moved, renamed or deleted.',
  ),
  WorkspaceHealth.notADirectory => (StatusKind.error, 'NOT A FOLDER', 'The workspace path points to a file.'),
  WorkspaceHealth.permissionDenied => (
    StatusKind.warning,
    'NO ACCESS',
    'The folder exists but cannot be read (permission denied).',
  ),
};

/// Live numbers from the registry, workspaces, activity and the active
/// workspace's files. Nothing here is decorative.
class SystemStatusPanel extends ConsumerWidget {
  const SystemStatusPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registry = ref.watch(toolRegistryProvider);
    final caps = ref.watch(capabilitiesProvider);
    final workspaces = ref.watch(workspacesProvider);
    final activity = ref.watch(activityProvider);
    final snapshot = ref.watch(activeWorkspaceSnapshotProvider);
    final active = workspaces.active;
    final fx = context.effects;

    final total = registry.all.length;
    final available = registry.all.where((t) => t.availableOn(caps)).length;
    final today = activity.countToday(DateTime.now());
    final running = activity.running.length;
    final last = activity.operations.isEmpty ? null : activity.operations.first;

    final snap = snapshot.value;
    final loading = snapshot.isLoading && snap == null;
    String countText(int? Function(WorkspaceSnapshot s) pick) {
      if (active == null) return '--';
      if (loading || snap == null) return '...';
      final v = pick(snap);
      return v == null ? '!' : '$v';
    }

    String countCaption(int? Function(WorkspaceSnapshot s) pick) {
      if (active == null) return 'no active workspace';
      if (loading || snap == null) return 'counting files';
      return pick(snap) == null ? 'could not read folder' : 'in "${active.name}"';
    }

    final stats = <Widget>[
      StatTile(
        label: 'TOOLS ONLINE',
        value: '$available/$total',
        caption: 'available on ${caps.platform.label}',
        icon: Icons.handyman_outlined,
      ),
      StatTile(
        label: 'WORKSPACES',
        value: '${workspaces.workspaces.length}',
        caption: active == null ? 'none active' : '1 active',
        icon: Icons.folder_special_outlined,
      ),
      StatTile(label: 'OPS TODAY', value: '$today', caption: 'operations started today', icon: Icons.bolt_outlined),
      StatTile(
        label: 'RUNNING NOW',
        value: '$running',
        caption: running == 0 ? 'idle' : 'in progress',
        icon: Icons.sync,
        highlight: running > 0,
      ),
      StatTile(
        label: 'MOD PACKAGES',
        value: countText((s) => s.modPackages),
        caption: countCaption((s) => s.modPackages),
        icon: Icons.extension_outlined,
      ),
      StatTile(
        label: 'PROFILES',
        value: countText((s) => s.profiles),
        caption: countCaption((s) => s.profiles),
        icon: Icons.layers_outlined,
      ),
    ];

    return NeonPanel(
      kicker: '// SYSTEM STATUS',
      title: 'Live status',
      icon: Icons.monitor_heart_outlined,
      actions: [
        IconButton(
          tooltip: 'Recount workspace files and re-check health',
          onPressed: () => ref.invalidate(activeWorkspaceSnapshotProvider),
          icon: const Icon(Icons.refresh, size: 20),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, c) {
              final cols = ((c.maxWidth + J3Space.sm) / (150 + J3Space.sm)).floor().clamp(1, 3);
              final w = (c.maxWidth - (cols - 1) * J3Space.sm) / cols;
              return Wrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [for (final s in stats) SizedBox(width: w, child: s)],
              );
            },
          ),
          const SizedBox(height: J3Space.md),
          _StatusLine(
            label: 'ACTIVE WORKSPACE',
            child: active == null
                ? Wrap(
                    spacing: J3Space.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('No active workspace', style: J3Type.body),
                      TextButton(onPressed: () => context.go('/workspaces'), child: const Text('Add one')),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: J3Space.sm,
                        runSpacing: J3Space.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(active.name, style: J3Type.label),
                          KindBadge(kind: active.kind),
                          if (snap != null && snap.workspace.id == active.id)
                            StatusBadge(
                              kind: describeHealth(snap.health).$1,
                              text: describeHealth(snap.health).$2,
                              dense: true,
                            )
                          else
                            const StatusBadge(kind: StatusKind.running, text: 'CHECKING', dense: true),
                        ],
                      ),
                      if (snap != null && snap.workspace.id == active.id) ...[
                        const SizedBox(height: 2),
                        Text(describeHealth(snap.health).$3, style: J3Type.caption),
                        if (snap.countError != null)
                          Text(
                            'Could not count mod files: ${snap.countError}',
                            style: J3Type.caption.copyWith(color: J3Colors.warning),
                          ),
                      ],
                    ],
                  ),
          ),
          _StatusLine(
            label: 'LAST OPERATION',
            child: last == null
                ? Text('Nothing has run yet', style: J3Type.bodySecondary)
                : Wrap(
                    spacing: J3Space.sm,
                    runSpacing: J3Space.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(last.title, style: J3Type.label),
                      StatusBadge(kind: statusKindOf(last.status), text: last.status.label, dense: true),
                      Text(Fmt.relative(last.startedAt), style: J3Type.codeSmall.copyWith(color: fx.accentText)),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: J3Space.sm),
      padding: const EdgeInsets.only(top: J3Space.sm),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: J3Colors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: J3Type.kicker.copyWith(color: J3Colors.textMuted, fontSize: 10.5)),
          const SizedBox(height: J3Space.xs),
          child,
        ],
      ),
    );
  }
}

/// Workspace kind as an icon + text badge.
class KindBadge extends StatelessWidget {
  const KindBadge({super.key, required this.kind});
  final WorkspaceKind kind;

  @override
  Widget build(BuildContext context) {
    final icon = switch (kind) {
      WorkspaceKind.linked => Icons.link,
      WorkspaceKind.imported => Icons.inventory_2_outlined,
      WorkspaceKind.sample => Icons.science_outlined,
    };
    return Tooltip(
      message: kind.explanation,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: J3Radius.small,
          border: Border.all(color: J3Colors.borderStrong),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: J3Colors.textSecondary),
            const SizedBox(width: 4),
            Flexible(child: Text(kind.label.toUpperCase(), style: J3Type.codeSmall.copyWith(fontSize: 10.5))),
          ],
        ),
      ),
    );
  }
}

/// One mono numeral with its label. The value is always a real number or an
/// explicit placeholder (`--` none, `...` counting, `!` unreadable).
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
    this.highlight = false,
  });

  final String label;
  final String value;
  final String caption;
  final IconData icon;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    return Semantics(
      label: '$label: $value, $caption',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(J3Space.md),
        decoration: BoxDecoration(
          color: J3Colors.inputFill,
          borderRadius: J3Radius.medium,
          border: Border.all(color: highlight ? fx.accentColor : J3Colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 14, color: fx.accentText),
                const SizedBox(width: J3Space.xs),
                Expanded(
                  child: Text(label, style: J3Type.kicker.copyWith(fontSize: 10.5, color: J3Colors.textSecondary)),
                ),
              ],
            ),
            const SizedBox(height: J3Space.xs),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                style: J3Type.code.copyWith(
                  fontSize: 28,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  color: highlight ? fx.accentText : J3Colors.text,
                ),
              ),
            ),
            Text(caption, style: J3Type.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}
