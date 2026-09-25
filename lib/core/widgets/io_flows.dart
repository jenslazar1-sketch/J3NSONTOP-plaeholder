import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../activity/activity_controller.dart';
import '../platform/app_paths.dart';
import '../platform/capabilities.dart';
import '../platform/file_access.dart';
import '../storage/atomic_file.dart';
import '../theme/j3_spacing.dart';
import '../theme/j3_typography.dart';
import '../utils/safe_path.dart';
import '../workspace/workspace_controller.dart';
import 'dialogs.dart';
import 'workspace_browser_dialog.dart';

/// A readable local file chosen by the user for a tool's input.
class SelectedInput {
  const SelectedInput({required this.path, required this.displayName, required this.fromWorkspace});
  final String path;
  final String displayName;

  /// True when the file lives in the active workspace (edits can be saved
  /// back in place with a backup). False for device imports (copies).
  final bool fromWorkspace;
}

/// Lets the user choose an input file from the active workspace or import
/// one from the device via the system picker. Returns null when cancelled.
Future<SelectedInput?> pickInputFile(
  BuildContext context,
  WidgetRef ref, {
  List<String>? extensions,
  String title = 'Open file',
}) async {
  final ws = ref.read(activeWorkspaceProvider);
  final source = ws == null
      ? _Source.device
      : await showModalBottomSheet<_Source>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(J3Space.lg, 0, J3Space.lg, J3Space.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(title, style: J3Type.title),
                  const SizedBox(height: J3Space.sm),
                  ListTile(
                    leading: const Icon(Icons.folder_special_outlined),
                    title: Text('From workspace "${ws.name}"'),
                    subtitle: const Text('Browse files in the active workspace'),
                    onTap: () => Navigator.of(ctx).pop(_Source.workspace),
                  ),
                  ListTile(
                    leading: const Icon(Icons.upload_file_outlined),
                    title: const Text('From device'),
                    subtitle: const Text('System file picker (a copy is imported)'),
                    onTap: () => Navigator.of(ctx).pop(_Source.device),
                  ),
                ],
              ),
            ),
          ),
        );
  if (source == null || !context.mounted) return null;
  if (source == _Source.workspace && ws != null) {
    final path = await showWorkspaceBrowser(context, workspace: ws, extensions: extensions, title: title);
    if (path == null) return null;
    return SelectedInput(
      path: path,
      displayName: p.relative(path, from: ws.rootPath),
      fromWorkspace: true,
    );
  }
  try {
    final files = await ref.read(fileAccessProvider).pickFiles(multiple: false, extensions: extensions);
    if (files.isEmpty) return null;
    return SelectedInput(path: files.first.path, displayName: files.first.name, fromWorkspace: false);
  } catch (e) {
    ref.read(activityProvider.notifier).notify(NoticeKind.error, 'Could not open the file picker: $e');
    return null;
  }
}

enum _Source { workspace, device }

enum _SaveTarget { workspace, export, share }

/// Saves tool output. Offers, depending on platform capabilities:
/// * save into the active workspace (never overwrites silently),
/// * export via the system save dialog,
/// * share via the share sheet (mobile).
///
/// Returns a short description of where the output went, or null.
Future<String?> saveOutput(
  BuildContext context,
  WidgetRef ref, {
  required String suggestedName,
  required Uint8List bytes,
  String mimeType = 'application/octet-stream',
  String? defaultWorkspaceSubdir,
  String toolId = 'core.save',
}) async {
  final caps = ref.read(capabilitiesProvider);
  final ws = ref.read(activeWorkspaceProvider);
  final target = await showModalBottomSheet<_SaveTarget>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(J3Space.lg, 0, J3Space.lg, J3Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Save "$suggestedName"', style: J3Type.title, overflow: TextOverflow.ellipsis),
            const SizedBox(height: J3Space.sm),
            if (ws != null)
              ListTile(
                leading: const Icon(Icons.save_outlined),
                title: Text('Save to workspace "${ws.name}"'),
                subtitle: const Text('Choose a folder; existing files are never overwritten silently'),
                onTap: () => Navigator.of(ctx).pop(_SaveTarget.workspace),
              ),
            if (caps.supports(Capability.exportSaveDialog))
              ListTile(
                leading: const Icon(Icons.file_download_outlined),
                title: const Text('Export...'),
                subtitle: const Text('System save dialog'),
                onTap: () => Navigator.of(ctx).pop(_SaveTarget.export),
              ),
            if (caps.supports(Capability.shareSheet))
              ListTile(
                leading: const Icon(Icons.ios_share),
                title: const Text('Share...'),
                subtitle: const Text('Send to another app'),
                onTap: () => Navigator.of(ctx).pop(_SaveTarget.share),
              ),
          ],
        ),
      ),
    ),
  );
  if (target == null || !context.mounted) return null;
  final activity = ref.read(activityProvider.notifier);

  switch (target) {
    case _SaveTarget.workspace:
      final wsNow = ws!;
      final folder = await showWorkspaceBrowser(
        context,
        workspace: wsNow,
        mode: BrowseMode.pickFolder,
        title: 'Save into folder',
        initialDir: defaultWorkspaceSubdir == null ? null : p.join(wsNow.rootPath, defaultWorkspaceSubdir),
      );
      if (folder == null || !context.mounted) return null;
      final name = await showJ3TextInput(
        context,
        title: 'File name',
        initial: SafePath.sanitizeFileName(suggestedName),
        monospace: true,
        validator: (v) => v.trim().isEmpty ? 'Enter a name' : null,
      );
      if (name == null) return null;
      var dest = p.join(folder, SafePath.sanitizeFileName(name.trim()));
      if (!SafePath.isWithin(wsNow.rootPath, dest)) {
        activity.notify(NoticeKind.error, 'Refused to save outside the workspace.');
        return null;
      }
      if (File(dest).existsSync()) {
        if (!context.mounted) return null;
        final unique = SafePath.uniquePath(dest);
        final keepBoth = await showJ3Confirm(
          context,
          title: 'File already exists',
          message:
              '"${p.basename(dest)}" already exists. The original will not be overwritten. Save as "${p.basename(unique)}" instead?',
          confirmLabel: 'Save as new file',
        );
        if (!keepBoth) return null;
        dest = unique;
      }
      try {
        await atomicWriteBytes(dest, bytes);
        final rel = p.relative(dest, from: wsNow.rootPath);
        activity.notify(NoticeKind.success, 'Saved $rel');
        return rel;
      } catch (e) {
        activity.notify(NoticeKind.error, 'Save failed: $e');
        return null;
      }
    case _SaveTarget.export:
      final r = await ref
          .read(fileAccessProvider)
          .saveBytes(suggestedName: suggestedName, bytes: bytes, mimeType: mimeType);
      if (r.saved) {
        activity.notify(NoticeKind.success, 'Exported ${r.location ?? suggestedName}');
        return r.location ?? suggestedName;
      }
      if (r.error != null) activity.notify(NoticeKind.error, 'Export failed: ${r.error}');
      return null;
    case _SaveTarget.share:
      final dir = Directory(
        p.join(ref.read(appPathsProvider).exportStagingDir, DateTime.now().microsecondsSinceEpoch.toString()),
      );
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, SafePath.sanitizeFileName(suggestedName)));
      await file.writeAsBytes(bytes, flush: true);
      final r = await ref.read(fileAccessProvider).shareFiles([file.path]);
      if (r.error != null) activity.notify(NoticeKind.error, 'Share failed: ${r.error}');
      return r.saved ? 'shared' : null;
  }
}
