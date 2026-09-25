import 'package:flutter/material.dart';

import '../../../../core/archive/safe_zip.dart';
import '../../../../core/theme/effects.dart';
import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace.dart';
import '../../data/fs_walker.dart';
import '../shared/ws_widgets.dart';

/// Where imported content goes.
enum ImportTarget { newWorkspace, activeWorkspace }

/// Asks whether to import into a new workspace or the active one. Returns
/// null when cancelled. Without an active workspace, a new one is used.
Future<ImportTarget?> chooseImportTarget(BuildContext context, {required Workspace? active, required String what}) {
  if (active == null) return Future.value(ImportTarget.newWorkspace);
  return showModalBottomSheet<ImportTarget>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(J3Space.lg, 0, J3Space.lg, J3Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Import $what into...', style: J3Type.title),
            const SizedBox(height: J3Space.sm),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('A new workspace'),
              subtitle: const Text('Copies go into a fresh app-owned workspace'),
              onTap: () => Navigator.of(ctx).pop(ImportTarget.newWorkspace),
            ),
            ListTile(
              leading: const Icon(Icons.folder_special_outlined),
              title: Text('Active workspace "${active.name}"'),
              subtitle: Text(
                active.kind == WorkspaceKind.linked
                    ? 'Copies are written into your linked folder; existing files are never overwritten'
                    : 'Existing files are never overwritten (new names are used)',
              ),
              onTap: () => Navigator.of(ctx).pop(ImportTarget.activeWorkspace),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Result of [RemoveWorkspaceDialog].
class RemoveDecision {
  const RemoveDecision({required this.deleteFiles});
  final bool deleteFiles;
}

/// Confirmation for removing an app-owned workspace. Measures the copy
/// first and offers an explicit, default-unchecked option to delete it.
class RemoveWorkspaceDialog extends StatefulWidget {
  const RemoveWorkspaceDialog({super.key, required this.workspace});
  final Workspace workspace;

  static Future<RemoveDecision?> show(BuildContext context, Workspace w) => showDialog<RemoveDecision>(
    context: context,
    builder: (_) => RemoveWorkspaceDialog(workspace: w),
  );

  @override
  State<RemoveWorkspaceDialog> createState() => _RemoveWorkspaceDialogState();
}

class _RemoveWorkspaceDialogState extends State<RemoveWorkspaceDialog> {
  ({int files, int bytes, int dirs})? _stats;
  Object? _error;
  bool _delete = false;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    try {
      final s = await FsWalker.measure(widget.workspace.rootPath);
      if (mounted) setState(() => _stats = s);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.workspace;
    final stats = _stats;
    final label = stats == null
        ? 'Also delete the imported copy (measuring...)'
        : 'Also delete the imported copy (${Fmt.count(stats.files, 'file')}, ${Fmt.bytes(stats.bytes)})';
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: J3Colors.warning),
          SizedBox(width: J3Space.sm),
          Expanded(child: Text('Remove workspace?')),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'The record "${w.name}" is removed from the list. Its files live in app storage '
                '(${w.kind.label}). By default they are KEPT and can be recovered later under '
                '"App storage".',
                style: J3Type.body,
              ),
              const SizedBox(height: J3Space.sm),
              PathText(w.rootPath, style: J3Type.codeSmall),
              const SizedBox(height: J3Space.md),
              if (_error != null) WsErrorBanner(error: _error!, action: 'Measuring the workspace'),
              if (_error == null && stats == null) const NeonProgressBar(),
              CheckboxListTile(
                value: _delete,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: stats == null ? null : (v) => setState(() => _delete = v ?? false),
                title: Text(label, style: J3Type.body),
                subtitle: Text(
                  'Permanent. Also deletes this workspace\'s mod library, backups and journals.',
                  style: J3Type.caption.copyWith(color: _delete ? J3Colors.warning : J3Colors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        NeonButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        NeonButton.danger(
          label: _delete ? 'Remove and delete files' : 'Remove record',
          onPressed: () => Navigator.of(context).pop(RemoveDecision(deleteFiles: _delete)),
        ),
      ],
    );
  }
}

/// Choice made in [ImportZipDialog].
class ZipImportChoice {
  const ZipImportChoice(this.target);
  final ImportTarget target;
}

/// Preview of a ZIP before extraction: summary, blocking issues, warnings
/// and the first entries. Extraction is impossible while fatal issues exist.
class ImportZipDialog extends StatelessWidget {
  const ImportZipDialog({super.key, required this.zipName, required this.inspection, required this.active});

  final String zipName;
  final ZipInspection inspection;
  final Workspace? active;

  static const int _maxRows = 200;

  @override
  Widget build(BuildContext context) {
    final fx = context.effects;
    final files = inspection.files.toList();
    final fatal = inspection.fatal;
    final warnings = inspection.issues.where((i) => !i.isFatal).toList();
    final rows = inspection.entries.take(_maxRows).toList();
    return AlertDialog(
      title: Text('Import "$zipName"', maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ButtonWrap(
                spacing: J3Space.sm,
                runSpacing: J3Space.sm,
                children: [
                  CountChip(label: 'Files', value: '${files.length}'),
                  CountChip(label: 'Size', value: Fmt.bytes(inspection.totalBytes)),
                  CountChip(
                    label: 'Blocking',
                    value: '${fatal.length}',
                    kind: fatal.isEmpty ? StatusKind.success : StatusKind.error,
                  ),
                  CountChip(
                    label: 'Warnings',
                    value: '${warnings.length}',
                    kind: warnings.isEmpty ? StatusKind.neutral : StatusKind.warning,
                  ),
                ],
              ),
              const SizedBox(height: J3Space.md),
              if (fatal.isNotEmpty)
                WsBanner(
                  kind: StatusKind.error,
                  title: 'Archive rejected',
                  message:
                      'This archive contains entries that could write outside the workspace or cannot be '
                      'extracted safely. Nothing will be extracted.',
                  details: [for (final i in fatal) '${i.entry}: ${i.message}'],
                )
              else
                const WsBanner(
                  kind: StatusKind.success,
                  title: 'Safe to extract',
                  message: 'Paths are validated, sizes are capped and every entry is CRC-checked while extracting.',
                ),
              if (warnings.isNotEmpty) ...[
                const SizedBox(height: J3Space.sm),
                WsBanner(
                  kind: StatusKind.warning,
                  title: 'Warnings',
                  details: [for (final i in warnings) '${i.entry}: ${i.message}'],
                ),
              ],
              const SizedBox(height: J3Space.md),
              Text('// ENTRIES', style: J3Type.kicker.copyWith(color: fx.accentText)),
              const SizedBox(height: J3Space.xs),
              for (final e in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(
                        e.path == null
                            ? Icons.block
                            : (e.isDirectory ? Icons.folder : Icons.insert_drive_file_outlined),
                        size: 16,
                        color: e.path == null ? J3Colors.error : J3Colors.textSecondary,
                      ),
                      const SizedBox(width: J3Space.sm),
                      Expanded(child: PathText(e.rawName, style: J3Type.codeSmall)),
                      if (!e.isDirectory) Text(Fmt.bytes(e.size), style: J3Type.caption),
                    ],
                  ),
                ),
              if (inspection.entries.length > _maxRows)
                Text('... ${inspection.entries.length - _maxRows} more entries', style: J3Type.caption),
            ],
          ),
        ),
      ),
      actions: [
        NeonButton.secondary(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        if (active != null)
          NeonButton.secondary(
            label: 'Into "${active!.name}"',
            icon: Icons.folder_special_outlined,
            onPressed: inspection.isSafe
                ? () => Navigator.of(context).pop(const ZipImportChoice(ImportTarget.activeWorkspace))
                : null,
          ),
        NeonButton(
          label: 'New workspace',
          icon: Icons.create_new_folder_outlined,
          onPressed: inspection.isSafe
              ? () => Navigator.of(context).pop(const ZipImportChoice(ImportTarget.newWorkspace))
              : null,
        ),
      ],
    );
  }
}
