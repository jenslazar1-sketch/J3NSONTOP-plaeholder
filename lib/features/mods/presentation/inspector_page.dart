import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/activity/activity_controller.dart';
import '../../../core/theme/j3_spacing.dart';
import '../../../core/theme/j3_typography.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../core/workspace/workspace_controller.dart';
import '../domain/package_inspector.dart';
import 'mods_controller.dart';
import 'mods_flows.dart';
import 'mods_widgets.dart';
import 'package_view.dart';

@immutable
class InspectorState {
  const InspectorState({this.path, this.displayName, this.report, this.busy = false, this.error});
  final String? path;
  final String? displayName;
  final PackageReport? report;
  final bool busy;
  final String? error;
}

/// Inspector input and last result (session lifetime, survives navigation).
class InspectorController extends Notifier<InspectorState> {
  @override
  InspectorState build() => const InspectorState();

  Future<void> inspect(String path, String displayName) async {
    state = InspectorState(path: path, displayName: displayName, report: state.report, busy: true);
    try {
      final report = await ref
          .read(activityProvider.notifier)
          .run<PackageReport>(
            toolId: kModsInspectorId,
            title: 'Inspect $displayName',
            notify: false,
            summary: (r) => r.isValid
                ? 'Valid package ${r.displayId} ${r.displayVersion ?? ''} (${r.warningCount} warning(s))'
                : 'Blocked: ${r.errorCount} error(s)',
            counts: (r) => {'errors': r.errorCount, 'warnings': r.warningCount, 'files': r.mapped.length},
            body: (op) {
              op.progress(null, 'Reading the archive directory and manifest');
              return inspectPackageInBackground(path);
            },
          );
      if (!ref.mounted) return;
      state = InspectorState(path: path, displayName: displayName, report: report);
    } catch (e) {
      if (!ref.mounted) return;
      state = InspectorState(path: path, displayName: displayName, error: e.toString());
    }
  }
}

final inspectorProvider = NotifierProvider<InspectorController, InspectorState>(InspectorController.new);

/// Plain-text report for copy/save.
String inspectorReportText(PackageReport r) {
  final b = StringBuffer()
    ..writeln('J3NSONTOP package inspection')
    ..writeln('file:     ${r.fileName} (${Fmt.bytes(r.archiveBytes)})')
    ..writeln('package:  ${r.displayId} ${r.displayVersion ?? '?'} - ${r.displayName}')
    ..writeln('result:   ${r.isValid ? 'VALID' : 'BLOCKED'} (${r.errorCount} error(s), ${r.warningCount} warning(s))')
    ..writeln()
    ..writeln('files:');
  for (final m in r.mapped) {
    b.writeln('  ${m.mapping.target} <- ${m.mapping.source} ${m.exists ? Fmt.bytes(m.size) : 'MISSING'}');
  }
  if (r.unmapped.isNotEmpty) {
    b.writeln('not mapped:');
    for (final u in r.unmapped) {
      b.writeln('  $u');
    }
  }
  b.writeln('issues:');
  if (r.issues.isEmpty) b.writeln('  none');
  for (final i in r.issues) {
    b.writeln('  $i');
  }
  return b.toString();
}

/// `mods.inspector`: inspect any .j3mod without importing it.
class ModInspectorPage extends ConsumerWidget {
  const ModInspectorPage({super.key});

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final picked = await pickInputFile(
      context,
      ref,
      extensions: const ['j3mod', 'zip'],
      title: 'Inspect a mod package',
    );
    if (picked == null) return;
    await ref.read(inspectorProvider.notifier).inspect(picked.path, picked.displayName);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(inspectorProvider);
    final r = s.report;
    final hasWorkspace = ref.watch(activeWorkspaceProvider) != null;
    return ToolScaffold(
      toolId: kModsInspectorId,
      inputs: [
        NeonPanel(
          kicker: 'INPUT',
          title: 'Package file',
          icon: Icons.inventory_2_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Checks a .j3mod (or .zip) without importing or extracting it: archive safety (traversal, links, '
                'bombs, duplicates), every manifest rule and the file mapping.',
                style: J3Type.caption,
              ),
              const SizedBox(height: J3Space.md),
              Wrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [
                  NeonButton(
                    label: 'Choose package',
                    icon: Icons.file_open_outlined,
                    busy: s.busy,
                    onPressed: s.busy ? null : () => _pick(context, ref),
                  ),
                  if (s.path != null && !s.busy)
                    NeonButton.secondary(
                      label: 'Inspect again',
                      icon: Icons.refresh,
                      onPressed: () => ref.read(inspectorProvider.notifier).inspect(s.path!, s.displayName ?? s.path!),
                    ),
                  if (r != null && r.isValid && hasWorkspace && !s.busy)
                    NeonButton.secondary(
                      label: 'Import to library',
                      icon: Icons.add_to_photos_outlined,
                      onPressed: () => importPackageFlow(context, ref, path: r.path),
                    ),
                ],
              ),
              if (s.displayName != null) ...[
                const SizedBox(height: J3Space.sm),
                SelectableText(s.displayName!, style: J3Type.code),
              ],
            ],
          ),
        ),
        if (s.busy) const LoadingState(label: 'Inspecting the package in the background'),
        if (s.error != null) ModBanner(kind: StatusKind.error, title: 'Inspection failed', message: s.error),
        if (r != null)
          NeonPanel(
            kicker: 'SUMMARY',
            title: r.displayName,
            child: PackageSummary(report: r),
          ),
      ],
      results: r == null
          ? [
              if (!s.busy && s.error == null)
                const EmptyState(
                  title: 'Nothing inspected yet',
                  message: 'Choose a package from the workspace (e.g. downloads/) or from your device.',
                  glyph: '[ ?.j3mod ]',
                ),
            ]
          : [
              NeonPanel(
                kicker: 'ISSUES',
                title: 'Validation: ${r.errorCount} error(s), ${r.warningCount} warning(s)',
                emphasis: r.errorCount > 0 ? PanelEmphasis.danger : PanelEmphasis.normal,
                child: PackageIssues(issues: r.issues),
              ),
              NeonPanel(
                kicker: 'FILES',
                title: 'Mapping (${r.mapped.length} file(s))',
                child: PackageMapping(report: r),
              ),
              if (r.parsedManifest != null)
                NeonPanel(
                  kicker: 'RELATIONS',
                  title: 'Dependencies and conflicts',
                  child: PackageRelations(manifest: r.parsedManifest!),
                ),
              if (r.manifestText != null)
                ResultPanel(
                  text: PackageInspector.prettyManifest(r),
                  title: 'j3mod.json',
                  kicker: 'MANIFEST',
                  fileName: '${r.displayId}-j3mod.json',
                  mimeType: 'application/json',
                  toolId: kModsInspectorId,
                  maxHeight: 360,
                ),
              ResultPanel(
                text: inspectorReportText(r),
                title: 'Inspection report',
                kicker: 'REPORT',
                fileName: '${r.displayId}-inspection.txt',
                toolId: kModsInspectorId,
                maxHeight: 280,
              ),
            ],
    );
  }
}
