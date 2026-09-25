import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/drafts/drafts.dart';
import '../../../core/platform/capabilities.dart';
import '../../../core/theme/effects.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/widgets/widgets.dart';
import '../../sample/sample_workspace.dart';
import 'library_pane.dart';
import 'mods_controller.dart';
import 'mods_flows.dart';
import 'mods_widgets.dart';
import 'operations_pane.dart';
import 'profiles_pane.dart';

enum ModsPane {
  library('Library', Icons.inventory_2_outlined),
  profiles('Profiles', Icons.playlist_add_check),
  operations('Operations', Icons.history);

  const ModsPane(this.label, this.icon);
  final String label;
  final IconData icon;
}

const String kModsPaneKey = 'mods.manager/pane';

/// Width at which the manager switches from tabs to side-by-side panes.
const double kModsPanesBreakpoint = 900;

/// The Mods section landing and the `mods.manager` tool.
class ModsManagerPage extends ConsumerStatefulWidget {
  const ModsManagerPage({super.key});

  @override
  ConsumerState<ModsManagerPage> createState() => _ModsManagerPageState();
}

class _ModsManagerPageState extends ConsumerState<ModsManagerPage> {
  bool _creatingSample = false;
  String? _sampleError;

  Future<void> _createSample() async {
    setState(() {
      _creatingSample = true;
      _sampleError = null;
    });
    try {
      await createSampleWorkspace(ref);
    } catch (e) {
      if (mounted) setState(() => _sampleError = e is UnimplementedError ? (e.message ?? e.toString()) : e.toString());
    } finally {
      if (mounted) setState(() => _creatingSample = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(modsProvider);
    final caps = ref.watch(capabilitiesProvider);

    if (s.workspace == null) {
      return ToolScaffold(
        toolId: kModsManagerId,
        children: [
          EmptyState(
            title: 'No active workspace',
            message:
                'Mod libraries, profiles and operation journals belong to a workspace. Open or create one, or try the '
                'disposable NEON DUNGEON sample.',
            glyph: '[ x_x ]',
            action: Wrap(
              alignment: WrapAlignment.center,
              spacing: J3Space.sm,
              runSpacing: J3Space.sm,
              children: [
                NeonButton(
                  label: 'Open workspaces',
                  icon: Icons.folder_open,
                  onPressed: () => context.go('/workspaces'),
                ),
                NeonButton.secondary(
                  label: 'Create sample workspace',
                  icon: Icons.science_outlined,
                  busy: _creatingSample,
                  onPressed: _createSample,
                ),
              ],
            ),
          ),
          if (_sampleError != null)
            ModBanner(
              kind: StatusKind.error,
              title: 'Could not create the sample workspace',
              message: _sampleError,
              onDismiss: () => setState(() => _sampleError = null),
            ),
        ],
      );
    }

    final ws = s.workspace!;
    final banners = <Widget>[
      const InterruptedBanner(),
      if (!caps.supports(Capability.inPlaceModApply))
        Padding(
          padding: const EdgeInsets.only(bottom: J3Space.sm),
          child: _MobileBanner(),
        ),
      if (s.healthWarning != null)
        Padding(
          padding: const EdgeInsets.only(bottom: J3Space.sm),
          child: ModBanner(kind: StatusKind.warning, title: 'Workspace unavailable', message: s.healthWarning),
        ),
      if (s.phase == ModsPhase.error)
        Padding(
          padding: const EdgeInsets.only(bottom: J3Space.sm),
          child: ModBanner(
            kind: StatusKind.error,
            title: 'Could not load the mod data',
            message: s.error,
            actions: [
              NeonButton.secondary(
                label: 'Retry',
                icon: Icons.refresh,
                onPressed: () => ref.read(modsProvider.notifier).refresh(),
              ),
            ],
          ),
        ),
    ];

    return ToolScaffold(
      toolId: kModsManagerId,
      headerActions: [
        IconButton(
          tooltip: 'Reload library, profiles and journals',
          onPressed: s.isBusy ? null : () => ref.read(modsProvider.notifier).refresh(),
          icon: const Icon(Icons.refresh),
        ),
      ],
      banner: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: banners),
      children: [
        _WorkspaceLine(workspaceName: ws.name, kindLabel: ws.kind.label, loading: s.phase == ModsPhase.loading),
        if (s.phase == ModsPhase.loading && s.library.isEmpty && s.profiles.isEmpty)
          const LoadingState(label: 'Reading the mod library, profiles and journals')
        else
          LayoutBuilder(
            builder: (context, c) {
              if (c.maxWidth >= kModsPanesBreakpoint) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LibraryPane(),
                          SizedBox(height: J3Space.lg),
                          OperationsPane(),
                        ],
                      ),
                    ),
                    const SizedBox(width: J3Space.lg),
                    const Expanded(flex: 7, child: ProfilesPane()),
                  ],
                );
              }
              final pane = ref.draft<ModsPane>(kModsPaneKey, ModsPane.profiles);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PaneTabs<ModsPane>(
                    values: ModsPane.values,
                    selected: pane,
                    onSelected: (v) => ref.setDraft(kModsPaneKey, v),
                    labelOf: (v) => switch (v) {
                      ModsPane.library => '${v.label} (${s.library.length})',
                      ModsPane.profiles => '${v.label} (${s.profiles.length})',
                      ModsPane.operations => '${v.label} (${s.operations.length})',
                    },
                    iconOf: (v) => v.icon,
                  ),
                  const SizedBox(height: J3Space.md),
                  switch (pane) {
                    ModsPane.library => const LibraryPane(),
                    ModsPane.profiles => const ProfilesPane(),
                    ModsPane.operations => const OperationsPane(),
                  },
                ],
              );
            },
          ),
      ],
    );
  }
}

class _WorkspaceLine extends StatelessWidget {
  const _WorkspaceLine({required this.workspaceName, required this.kindLabel, required this.loading});
  final String workspaceName;
  final String kindLabel;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    return Wrap(
      spacing: J3Space.sm,
      runSpacing: J3Space.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Icon(Icons.folder_special_outlined, size: 18, color: fx.accentText),
        Text('Workspace: $workspaceName', style: J3Type.label),
        InfoChip(kindLabel),
        if (loading) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
      ],
    );
  }
}

class _MobileBanner extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final caps = ref.watch(capabilitiesProvider);
    final s = ref.watch(modsProvider);
    final selected =
        s.profileById(ref.draft<String?>(kSelectedProfileKey, null)) ??
        (s.validProfiles.isEmpty ? null : s.validProfiles.first);
    final target = selected?.target ?? '.';
    return ModBanner(
      kind: StatusKind.info,
      title: 'Profiles apply to the workspace copy on ${caps.platform.label}',
      message:
          '${caps.alternativeFor(Capability.inPlaceModApply) ?? ''} This device cannot modify other apps\' folders, '
          'so linked workspaces are desktop-only.',
      actions: [
        NeonButton.secondary(
          label: target == '.' ? 'Export result (workspace)' : 'Export result ($target/)',
          icon: Icons.archive_outlined,
          onPressed: s.isBusy || !(s.workspace?.kind.isAppOwned ?? false)
              ? null
              : () => exportResultFlow(context, ref, target),
        ),
      ],
    );
  }
}
