import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/platform/capabilities.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/tools/tool_definition.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../../intro/skull_art.dart';
import '../../../shell/section_hub.dart';
import '../shared/requests.dart';
import '../shared/ws_widgets.dart';
import 'manager_actions.dart';
import 'manager_state.dart';

/// Section landing for /workspaces.
class WorkspacesLandingPage extends ConsumerWidget {
  const WorkspacesLandingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fx = context.effects;
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= J3Breakpoints.medium;
        return Scrollbar(
          child: SingleChildScrollView(
            padding: wide ? J3Space.pagePaddingWide : J3Space.pagePadding,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: J3Size.maxContentWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('// WORKSPACES', style: J3Type.kicker.copyWith(color: fx.accentText)),
                              GlitchText(ToolSection.workspaces.label, style: J3Type.headline),
                              const SizedBox(height: J3Space.xs),
                              Text(ToolSection.workspaces.tagline, style: J3Type.bodySecondary),
                            ],
                          ),
                        ),
                        if (wide)
                          // Decorative logo only (excluded from semantics).
                          SizedBox(
                            height: 96,
                            child: AsciiArt(
                              lines: const [...kMiniSkullCranium, ...kMiniSkullJaw],
                              style: J3Type.ascii.copyWith(color: fx.accentColor.withValues(alpha: 0.75)),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: J3Space.lg),
                    const WorkspaceManagerBody(),
                    const SizedBox(height: J3Space.xxl),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Tool page `workspaces.manager` (same UI, searchable, favouritable).
class WorkspaceManagerPage extends StatelessWidget {
  const WorkspaceManagerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const ToolScaffold(toolId: WsTools.manager, children: [WorkspaceManagerBody()]);
  }
}

/// Everything below the page header: actions, status, workspace cards,
/// app storage and the section's tools.
class WorkspaceManagerBody extends ConsumerWidget {
  const WorkspaceManagerBody({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(managerStateProvider);
    final ws = ref.watch(workspacesProvider);
    final caps = ref.watch(capabilitiesProvider);
    final actions = ManagerActions(context, ref);
    final list = ws.recent;
    final busy = state.busy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NeonPanel(
          kicker: 'Workspaces',
          title: 'Create or import',
          icon: Icons.add_box_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ButtonWrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [
                  NeonButton(
                    label: 'New empty workspace',
                    icon: Icons.create_new_folder_outlined,
                    onPressed: busy ? null : actions.newEmpty,
                  ),
                  if (caps.supports(Capability.linkFolder))
                    NeonButton.secondary(
                      label: 'Link folder',
                      icon: Icons.link,
                      tooltip: Capability.linkFolder.description,
                      onPressed: busy ? null : actions.linkFolder,
                    ),
                  NeonButton.secondary(
                    label: 'Import files',
                    icon: Icons.upload_file_outlined,
                    onPressed: busy ? null : actions.importFiles,
                  ),
                  if (caps.supports(Capability.importFolder))
                    NeonButton.secondary(
                      label: 'Import folder',
                      icon: Icons.drive_folder_upload_outlined,
                      onPressed: busy ? null : actions.importFolder,
                    ),
                  NeonButton.secondary(
                    label: 'Import ZIP',
                    icon: Icons.folder_zip_outlined,
                    onPressed: busy ? null : actions.importZip,
                  ),
                  NeonButton.ghost(
                    label: 'Create sample workspace',
                    icon: Icons.science_outlined,
                    onPressed: busy ? null : actions.createSample,
                  ),
                ],
              ),
              if (!caps.supports(Capability.linkFolder)) ...[
                const SizedBox(height: J3Space.md),
                WsBanner(
                  kind: StatusKind.info,
                  title: 'Linking folders is not available on ${caps.platform.label}',
                  message: caps.alternativeFor(Capability.linkFolder),
                ),
              ],
            ],
          ),
        ),
        if (state.runningOpId != null) ...[
          const SizedBox(height: J3Space.md),
          OperationProgress(operationId: state.runningOpId!, label: state.runningLabel ?? 'Working'),
        ],
        if (state.report != null) ...[
          const SizedBox(height: J3Space.md),
          WsBanner(
            kind: state.report!.kind,
            title: state.report!.title,
            message: state.report!.message,
            details: state.report!.details,
            onDismiss: ref.read(managerStateProvider.notifier).clearMessages,
          ),
        ],
        if (state.error != null) ...[
          const SizedBox(height: J3Space.md),
          WsErrorBanner(
            error: state.error!,
            action: state.errorAction ?? 'The operation',
            onDismiss: ref.read(managerStateProvider.notifier).clearMessages,
          ),
        ],
        const SizedBox(height: J3Space.lg),
        SectionHeader(
          title: list.isEmpty ? 'No workspaces yet' : Fmt.count(list.length, 'workspace'),
          kicker: 'Your workspaces',
        ),
        if (list.isEmpty)
          const NeonPanel(
            emphasis: PanelEmphasis.subtle,
            child: EmptyState(
              glyph: '[ 0_0 ]',
              title: 'Nothing here yet',
              message:
                  'Create an empty workspace, import files or a ZIP, or generate the sample workspace to try '
                  'every tool on real files.',
            ),
          )
        else
          LayoutBuilder(
            builder: (context, c) {
              final cols = c.maxWidth >= 1100 ? 2 : 1;
              final w = (c.maxWidth - (cols - 1) * J3Space.md) / cols;
              return ButtonWrap(
                spacing: J3Space.md,
                runSpacing: J3Space.md,
                children: [
                  for (final item in list)
                    SizedBox(
                      width: w,
                      child: WorkspaceCard(
                        key: ValueKey('ws-card-${item.id}'),
                        workspace: item,
                        active: item.id == ws.activeId,
                        actions: actions,
                      ),
                    ),
                ],
              );
            },
          ),
        const SizedBox(height: J3Space.lg),
        _StoragePanel(actions: actions),
        const SizedBox(height: J3Space.xl),
        const SectionHeader(title: 'Workspace tools', kicker: 'Browse, search, rename, replace'),
        const SectionHub(section: ToolSection.workspaces, embedded: true),
      ],
    );
  }
}

class WorkspaceCard extends ConsumerWidget {
  const WorkspaceCard({super.key, required this.workspace, required this.active, required this.actions});

  final Workspace workspace;
  final bool active;
  final ManagerActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = workspace;
    final caps = ref.watch(capabilitiesProvider);
    final health = ref.watch(workspaceHealthProvider(w.id));
    final busy = ref.watch(managerStateProvider.select((s) => s.busy));
    final fx = context.effects;

    return NeonPanel(
      emphasis: active ? PanelEmphasis.strong : PanelEmphasis.normal,
      padding: const EdgeInsets.all(J3Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                w.kind == WorkspaceKind.linked ? Icons.link : Icons.inventory_2_outlined,
                color: active ? fx.accentText : J3Colors.textSecondary,
              ),
              const SizedBox(width: J3Space.sm),
              Expanded(
                child: Text(w.name, style: J3Type.subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
              if (active) const StatusBadge(kind: StatusKind.success, text: 'ACTIVE', dense: true),
            ],
          ),
          const SizedBox(height: J3Space.sm),
          ButtonWrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Tooltip(
                message: w.kind.explanation,
                child: StatusBadge(kind: StatusKind.info, text: w.kind.label.toUpperCase(), dense: true),
              ),
              _HealthBadge(health: health),
            ],
          ),
          const SizedBox(height: J3Space.xs),
          Text(w.kind.explanation, style: J3Type.caption),
          const SizedBox(height: J3Space.sm),
          PathText(w.rootPath, style: J3Type.codeSmall.copyWith(color: J3Colors.text)),
          const SizedBox(height: J3Space.xs),
          Text(
            'Created ${Fmt.dateTime(w.createdAt)}  |  opened ${Fmt.relative(w.lastOpenedAt)}',
            style: J3Type.caption,
          ),
          if (health.value != null && health.value != WorkspaceHealth.ok) ...[
            const SizedBox(height: J3Space.sm),
            _HealthProblem(
              workspace: w,
              health: health.value!,
              actions: actions,
              canRelink: caps.supports(Capability.linkFolder),
            ),
          ],
          const SizedBox(height: J3Space.md),
          ButtonWrap(
            spacing: J3Space.sm,
            runSpacing: J3Space.sm,
            children: [
              if (!active)
                NeonButton(label: 'Set active', icon: Icons.check, onPressed: busy ? null : () => actions.setActive(w)),
              NeonButton.secondary(label: 'Browse', icon: Icons.folder_open, onPressed: () => actions.browse(w)),
              NeonButton.secondary(
                label: 'Export ZIP',
                icon: Icons.archive_outlined,
                onPressed: busy || health.value != WorkspaceHealth.ok ? null : () => actions.exportZip(w),
              ),
              NeonButton.ghost(label: 'Rename', icon: Icons.edit_outlined, onPressed: () => actions.rename(w)),
              NeonIconButton(
                icon: Icons.copy_rounded,
                tooltip: 'Copy folder path',
                onPressed: () => actions.copyPath(w),
              ),
              if (caps.supports(Capability.revealInFileManager))
                NeonIconButton(
                  icon: Icons.open_in_new,
                  tooltip: 'Show in file manager',
                  onPressed: () => actions.reveal(w),
                ),
              NeonIconButton(
                icon: Icons.refresh,
                tooltip: 'Check folder again',
                onPressed: () => ref.invalidate(workspaceHealthProvider(w.id)),
              ),
              NeonButton.danger(
                label: 'Remove',
                icon: Icons.delete_outline,
                onPressed: busy ? null : () => actions.remove(w),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HealthBadge extends StatelessWidget {
  const _HealthBadge({required this.health});
  final AsyncValue<WorkspaceHealth> health;

  @override
  Widget build(BuildContext context) {
    final h = health.value;
    if (h == null) return const StatusBadge(kind: StatusKind.running, text: 'CHECKING', dense: true);
    return switch (h) {
      WorkspaceHealth.ok => const StatusBadge(kind: StatusKind.success, text: 'REACHABLE', dense: true),
      WorkspaceHealth.missing => const StatusBadge(kind: StatusKind.error, text: 'FOLDER MISSING', dense: true),
      WorkspaceHealth.notADirectory => const StatusBadge(kind: StatusKind.error, text: 'NOT A FOLDER', dense: true),
      WorkspaceHealth.permissionDenied => const StatusBadge(kind: StatusKind.error, text: 'ACCESS DENIED', dense: true),
    };
  }
}

class _HealthProblem extends StatelessWidget {
  const _HealthProblem({required this.workspace, required this.health, required this.actions, required this.canRelink});

  final Workspace workspace;
  final WorkspaceHealth health;
  final ManagerActions actions;
  final bool canRelink;

  @override
  Widget build(BuildContext context) {
    final linked = workspace.kind == WorkspaceKind.linked;
    final (reason, hint) = switch (health) {
      WorkspaceHealth.missing when linked => (
        'The linked folder no longer exists at this path (moved, renamed, or on a drive that is not connected).',
        canRelink
            ? 'Reconnect the drive, or relink to the folder\'s new location. Removing the record never deletes files.'
            : 'Remove the record; linked folders cannot be reconnected on this device.',
      ),
      WorkspaceHealth.missing => (
        'The imported copy was deleted from app storage.',
        'Recreate an empty folder to keep using this workspace, or remove the record.',
      ),
      WorkspaceHealth.notADirectory => (
        'The path now points to a file instead of a folder.',
        linked && canRelink ? 'Relink to the correct folder or remove the record.' : 'Remove the record.',
      ),
      WorkspaceHealth.permissionDenied => (
        'The system denies access to this folder (permission revoked or protected location).',
        linked && canRelink
            ? 'Relink the folder through the folder picker to grant access again, or check its permissions.'
            : 'Check the app\'s storage permissions, or remove the record.',
      ),
      WorkspaceHealth.ok => ('', ''),
    };
    return WsBanner(
      kind: StatusKind.error,
      title: 'Folder unavailable',
      message: reason,
      details: [hint],
      actions: [
        if (linked && canRelink)
          NeonButton.secondary(label: 'Relink...', icon: Icons.link, onPressed: () => actions.relink(workspace)),
        if (!linked && health == WorkspaceHealth.missing)
          NeonButton.secondary(
            label: 'Recreate folder',
            icon: Icons.create_new_folder_outlined,
            onPressed: () => actions.recreateFolder(workspace),
          ),
        NeonButton.danger(label: 'Remove record', onPressed: () => actions.remove(workspace)),
      ],
    );
  }
}

class _StoragePanel extends ConsumerWidget {
  const _StoragePanel({required this.actions});
  final ManagerActions actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orphans = ref.watch(managerStateProvider.select((s) => s.orphans));
    return NeonPanel(
      emphasis: PanelEmphasis.subtle,
      kicker: 'App storage',
      title: 'Unused workspace storage',
      icon: Icons.storage_outlined,
      actions: [NeonIconButton(icon: Icons.manage_search, tooltip: 'Scan app storage', onPressed: actions.scanStorage)],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Removing a workspace record keeps its files unless you choose to delete them. Scan to find kept '
            'copies and metadata that no workspace uses, then recover or delete them.',
            style: J3Type.caption,
          ),
          const SizedBox(height: J3Space.sm),
          if (orphans == null)
            Align(
              alignment: Alignment.centerLeft,
              child: FitButton(
                NeonButton.secondary(
                  label: 'Scan app storage',
                  icon: Icons.manage_search,
                  onPressed: actions.scanStorage,
                ),
              ),
            )
          else if (orphans.isEmpty)
            const WsBanner(
              kind: StatusKind.success,
              title: 'No unused storage',
              message: 'Every folder belongs to a workspace.',
            )
          else
            for (final o in orphans)
              Padding(
                padding: const EdgeInsets.only(bottom: J3Space.sm),
                child: Container(
                  padding: const EdgeInsets.all(J3Space.sm),
                  decoration: BoxDecoration(
                    color: J3Colors.surfaceRaised,
                    borderRadius: J3Radius.small,
                    border: Border.all(color: J3Colors.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      PathText(o.id, style: J3Type.code),
                      Text('${Fmt.count(o.files, 'file')}, ${Fmt.bytes(o.bytes)}', style: J3Type.caption),
                      const SizedBox(height: J3Space.xs),
                      ButtonWrap(
                        spacing: J3Space.sm,
                        runSpacing: J3Space.sm,
                        children: [
                          NeonButton.secondary(
                            label: 'Recover as workspace',
                            icon: Icons.restore,
                            onPressed: () => actions.restoreOrphan(o),
                          ),
                          NeonButton.danger(
                            label: 'Delete',
                            icon: Icons.delete_forever_outlined,
                            onPressed: () => actions.deleteOrphan(o),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
