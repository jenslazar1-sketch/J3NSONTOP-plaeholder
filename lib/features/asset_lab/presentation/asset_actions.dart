import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/activity/activity_controller.dart';
import '../../../core/platform/app_paths.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/widgets.dart';
import '../../../core/workspace/workspace_controller.dart';
import '../data/asset_worker.dart';

/// Export/save flows shared by the Asset Lab tools. Everything goes through
/// the platform's normal export flow ([saveOutput]: workspace, system save
/// dialog or share sheet) or into a folder the user picks inside the active
/// workspace, never replacing existing files.

typedef FileList = List<(String, Uint8List)>;

/// Prepares files with [prepare] (off the UI isolate), zips them with
/// SafeZip as one tracked, cancellable operation, then hands the ZIP to
/// [saveOutput]. Returns where it went, or null.
Future<String?> exportZip(
  BuildContext context,
  WidgetRef ref, {
  required String toolId,
  required String title,
  required String zipName,
  required AssetTask<FileList> prepare,
}) async {
  final activity = ref.read(activityProvider.notifier);
  final worker = ref.read(assetWorkerProvider);
  final staging = ref.read(appPathsProvider).exportStagingDir;
  final Uint8List zip;
  try {
    zip = await activity.run<Uint8List>(
      toolId: toolId,
      title: title,
      cancellable: true,
      body: (op) async {
        op.progress(0.1, 'Preparing files');
        final entries = await worker.run(prepare, token: op.token);
        op.progress(0.6, 'Compressing ${entries.length} files');
        final bytes = await worker.run(buildZipTask(staging, entries), token: op.token);
        op.succeed(
          'ZIP ready: ${Fmt.count(entries.length, 'file')}, ${Fmt.bytes(bytes.length)}',
          counts: {'files': entries.length, 'bytes': bytes.length},
          details: [for (final e in entries.take(40)) e.$1],
          notify: false,
        );
        return bytes;
      },
    );
  } catch (_) {
    // Failure/cancellation is recorded and announced by the activity log.
    return null;
  }
  if (!context.mounted) return null;
  return saveOutput(context, ref, suggestedName: zipName, bytes: zip, mimeType: 'application/zip', toolId: toolId);
}

/// Builds one file with [build] (tracked) and hands it to [saveOutput].
Future<String?> exportFile(
  BuildContext context,
  WidgetRef ref, {
  required String toolId,
  required String title,
  required String fileName,
  required String mimeType,
  required AssetTask<Uint8List> build,
}) async {
  final activity = ref.read(activityProvider.notifier);
  final worker = ref.read(assetWorkerProvider);
  final Uint8List bytes;
  try {
    bytes = await activity.run<Uint8List>(
      toolId: toolId,
      title: title,
      cancellable: true,
      body: (op) async {
        op.progress(null, 'Encoding $fileName');
        final b = await worker.run(build, token: op.token);
        op.succeed('$fileName ready (${Fmt.bytes(b.length)})', counts: {'bytes': b.length}, notify: false);
        return b;
      },
    );
  } catch (_) {
    return null;
  }
  if (!context.mounted) return null;
  return saveOutput(context, ref, suggestedName: fileName, bytes: bytes, mimeType: mimeType, toolId: toolId);
}

/// Lets the user pick a folder in the active workspace, prepares the files
/// and writes them there. Existing names get a numbered suffix; nothing is
/// overwritten. Returns workspace-relative paths, or null.
Future<List<String>?> saveFilesToWorkspace(
  BuildContext context,
  WidgetRef ref, {
  required String toolId,
  required String title,
  required AssetTask<FileList> prepare,
  String? initialDir,
}) async {
  final ws = ref.read(activeWorkspaceProvider);
  final activity = ref.read(activityProvider.notifier);
  if (ws == null) {
    activity.notify(NoticeKind.warning, 'Open or create a workspace first, or use Export instead.');
    return null;
  }
  final folder = await showWorkspaceBrowser(
    context,
    workspace: ws,
    mode: BrowseMode.pickFolder,
    title: 'Save into folder',
    initialDir: initialDir,
  );
  if (folder == null) return null;
  final worker = ref.read(assetWorkerProvider);
  try {
    return await activity.run<List<String>>(
      toolId: toolId,
      title: title,
      workspaceId: ws.id,
      cancellable: true,
      body: (op) async {
        op.progress(0.1, 'Preparing files');
        final files = await worker.run(prepare, token: op.token);
        op.progress(0.5, 'Writing ${files.length} files');
        final paths = await worker.run(writeNewFilesTask(ws.rootPath, folder, files), token: op.token);
        final rel = [for (final x in paths) p.relative(x, from: ws.rootPath).replaceAll(r'\', '/')];
        final where = p.relative(folder, from: ws.rootPath).replaceAll(r'\', '/');
        op.succeed(
          'Saved ${Fmt.count(rel.length, 'file')} to ${where == '.' ? 'the workspace root' : where}',
          counts: {'files': rel.length, 'bytes': files.fold<int>(0, (s, f) => s + f.$2.length)},
          details: rel,
        );
        return rel;
      },
    );
  } catch (_) {
    return null;
  }
}

/// Opens one image (workspace or device).
Future<SelectedInput?> pickImage(BuildContext context, WidgetRef ref, List<String> extensions, {String? title}) =>
    pickInputFile(context, ref, extensions: extensions, title: title ?? 'Open image');
