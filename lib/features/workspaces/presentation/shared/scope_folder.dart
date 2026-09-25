import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../../core/theme/j3_colors.dart';
import '../../../../core/theme/j3_spacing.dart';
import '../../../../core/theme/j3_typography.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace.dart';
import '../../data/fs_walker.dart';
import 'ws_widgets.dart';

/// Absolute path of a '/'-separated folder relative to [w]'s root.
String scopePath(Workspace w, String relDir) =>
    relDir.isEmpty ? w.rootPath : p.joinAll([w.rootPath, ...relDir.split('/').where((s) => s.isNotEmpty)]);

/// "Folder: `workspace/sub`" with Change / Whole workspace buttons. The
/// folder chooser cannot leave the workspace root.
class ScopeFolderRow extends StatelessWidget {
  const ScopeFolderRow({
    super.key,
    required this.workspace,
    required this.relDir,
    required this.onChanged,
    this.label = 'Folder',
  });

  final Workspace workspace;
  final String relDir;
  final ValueChanged<String> onChanged;
  final String label;

  Future<void> _choose(BuildContext context) async {
    final start = scopePath(workspace, relDir);
    final picked = await showWorkspaceBrowser(
      context,
      workspace: workspace,
      mode: BrowseMode.pickFolder,
      title: 'Choose a folder',
      initialDir: Directory(start).existsSync() ? start : null,
    );
    if (picked == null) return;
    final rel = FsWalker.relativeOf(workspace.rootPath, picked);
    onChanged(rel == '.' ? '' : rel);
  }

  @override
  Widget build(BuildContext context) {
    final shown = relDir.isEmpty ? '${workspace.name}/' : '${workspace.name}/$relDir';
    final missing = !Directory(scopePath(workspace, relDir)).existsSync();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: J3Type.caption),
        const SizedBox(height: J3Space.xs),
        Row(
          children: [
            const Icon(Icons.folder_outlined, size: 18),
            const SizedBox(width: J3Space.sm),
            Expanded(
              child: PathText(shown, style: J3Type.code.copyWith(color: missing ? J3Colors.error : J3Colors.text)),
            ),
          ],
        ),
        if (missing) Text('This folder no longer exists.', style: J3Type.caption.copyWith(color: J3Colors.error)),
        const SizedBox(height: J3Space.xs),
        ButtonWrap(
          spacing: J3Space.sm,
          runSpacing: J3Space.sm,
          children: [
            NeonButton.secondary(
              label: 'Change...',
              icon: Icons.drive_folder_upload_outlined,
              onPressed: () => _choose(context),
            ),
            if (relDir.isNotEmpty) NeonButton.ghost(label: 'Whole workspace', onPressed: () => onChanged('')),
          ],
        ),
      ],
    );
  }
}
