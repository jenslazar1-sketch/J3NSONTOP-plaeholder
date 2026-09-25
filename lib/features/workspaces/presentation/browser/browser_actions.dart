import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/platform/app_paths.dart';
import '../../../../core/platform/capabilities.dart';
import '../../../../core/platform/file_access.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/utils/hashing.dart';
import '../../../../core/utils/safe_path.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../data/file_ops.dart';
import '../../data/fs_listing.dart';
import '../../data/fs_walker.dart';
import '../../data/trash_store.dart';
import '../../data/workspace_transfer.dart';
import '../../domain/file_names.dart';
import '../../domain/fs_errors.dart';
import '../shared/requests.dart';
import 'browser_state.dart';

/// File operations offered by the browser. All of them stay inside the
/// workspace root, catch file-system errors and explain them.
class BrowserActions {
  BrowserActions(this.context, this.ref, this.workspace) : _c = ProviderScope.containerOf(context, listen: false);

  final BuildContext context;
  final WidgetRef ref;
  final Workspace workspace;

  /// Used after awaits: stays valid even if the page is disposed meanwhile.
  final ProviderContainer _c;

  static const int exportWarnBytes = 100 * 1024 * 1024;

  ActivityController get _activity => _c.read(activityProvider.notifier);
  BrowserController get _state => _c.read(browserStateProvider.notifier);
  String get _meta => _c.read(workspacesProvider.notifier).metaDir(workspace);

  TrashStore get trash => TrashStore(rootPath: workspace.rootPath, metaDir: _meta);

  String relative(String path) => FsWalker.relativeOf(workspace.rootPath, path);

  void _error(Object e, String action) {
    final f = describeError(e, action: action);
    _activity.notify(NoticeKind.error, '$action failed: ${f.message}${f.hint == null ? '' : ' ${f.hint}'}');
  }

  String get currentDirPath {
    final dir = _c.read(browserStateProvider).dir;
    return dir.isEmpty ? workspace.rootPath : p.joinAll([workspace.rootPath, ...dir.split('/')]);
  }

  void openEditor(FsEntry e) => ref.openInEditor(context, e.path);

  void openHex(FsEntry e) => ref.openInHex(context, e.path);

  Future<void> copyPath(FsEntry e) async {
    await _c.read(fileAccessProvider).copyText(e.path);
    _activity.notify(NoticeKind.success, 'Copied path of ${e.name}');
  }

  Future<void> reveal(FsEntry e) async {
    final caps = _c.read(capabilitiesProvider);
    if (!caps.supports(Capability.revealInFileManager)) {
      _activity.notify(NoticeKind.info, caps.alternativeFor(Capability.revealInFileManager) ?? 'Not available here.');
      return;
    }
    final ok = await _c.read(fileAccessProvider).reveal(e.path);
    if (!ok) _activity.notify(NoticeKind.warning, 'The file manager could not be opened.');
  }

  Future<void> export(FsEntry e) async {
    if (e.isDirectory || e.isLink) return;
    try {
      final size = await File(e.path).length();
      if (size > exportWarnBytes) {
        if (!context.mounted) return;
        final ok = await showJ3Confirm(
          context,
          title: 'Large file',
          message:
              '"${e.name}" is ${Fmt.bytes(size)}. Exporting loads it into memory first, which can be slow '
              'or fail on devices with little free memory. Continue?',
          confirmLabel: 'Export anyway',
        );
        if (!ok) return;
      }
      final bytes = await File(e.path).readAsBytes();
      if (!context.mounted) return;
      await saveOutput(context, ref, suggestedName: e.name, bytes: bytes, toolId: WsTools.browser);
    } catch (err) {
      _error(err, 'Exporting ${e.name}');
    }
  }

  Future<void> rename(FsEntry e) async {
    final siblings = await _siblingKeys(p.dirname(e.path));
    if (!context.mounted) return;
    final name = await showJ3TextInput(
      context,
      title: 'Rename ${e.isDirectory ? 'folder' : 'file'}',
      label: 'New name',
      initial: e.name,
      monospace: true,
      validator: (v) {
        final invalid = FileNames.validate(v);
        if (invalid != null) return invalid;
        final caseOnly = v.toLowerCase() == e.name.toLowerCase();
        if (!caseOnly && siblings.contains(v.toLowerCase())) return 'Something named "$v" already exists here';
        return null;
      },
    );
    if (name == null || name == e.name) return;
    try {
      final target = await FileOps.renameInPlace(e.path, name);
      _state
        ..reload()
        ..select(target);
      _activity.notify(NoticeKind.success, 'Renamed to $name');
    } catch (err) {
      _error(err, 'Renaming ${e.name}');
    }
  }

  Future<Set<String>> _siblingKeys(String dir) async {
    try {
      return {await for (final x in Directory(dir).list(followLinks: false)) p.basename(x.path).toLowerCase()};
    } on FileSystemException {
      return {};
    }
  }

  Future<void> newFolder() async {
    final dir = currentDirPath;
    final siblings = await _siblingKeys(dir);
    if (!context.mounted) return;
    final name = await showJ3TextInput(
      context,
      title: 'New folder',
      label: 'Folder name',
      initial: 'New folder',
      validator: (v) {
        final invalid = FileNames.validate(v);
        if (invalid != null) return invalid;
        if (siblings.contains(v.toLowerCase())) return 'Something named "$v" already exists here';
        return null;
      },
    );
    if (name == null) return;
    try {
      final path = SafePath.resolveInside(workspace.rootPath, p.join(relative(dir) == '.' ? '' : relative(dir), name));
      await Directory(path).create();
      _state
        ..reload()
        ..select(path);
    } catch (err) {
      _error(err, 'Creating the folder');
    }
  }

  Future<void> delete(FsEntry e) async {
    final ok = await showJ3Confirm(
      context,
      title: 'Move to trash?',
      message:
          '"${e.name}" is moved to this workspace\'s trash (inside app storage). You can restore it from the '
          'Trash view until you empty the trash.',
      confirmLabel: 'Move to trash',
      destructive: true,
      details: [relative(e.path)],
    );
    if (!ok) return;
    try {
      final item = await _activity.run<TrashItem>(
        toolId: WsTools.browser,
        title: 'Delete ${e.name}',
        workspaceId: workspace.id,
        cancellable: true,
        body: (op) => trash.moveToTrash(e.path, token: op.token),
        summary: (i) =>
            'Moved to trash (${i.isDirectory ? Fmt.count(i.files, 'file') : Fmt.bytes(i.bytes)}). Undo from the browser.',
      );
      _state.trashed(item);
    } catch (err) {
      _error(err, 'Deleting ${e.name}');
    }
  }

  /// Undo of the last delete.
  Future<void> undoDelete(TrashItem item) async {
    try {
      final path = await trash.restore(item);
      _state
        ..clearUndo()
        ..reload()
        ..select(path);
      _activity.notify(NoticeKind.success, 'Restored ${item.relativePath}');
    } on FileSystemException catch (err) {
      if (classifyFsError(err) == FsProblem.exists && context.mounted) {
        final copy = await showJ3Confirm(
          context,
          title: 'Original location is taken',
          message: 'Something new exists at ${item.relativePath}. Restore as a copy with a new name instead?',
          confirmLabel: 'Restore as copy',
        );
        if (!copy) return;
        try {
          final path = await trash.restore(item, asCopy: true);
          _state
            ..clearUndo()
            ..reload()
            ..select(path);
        } catch (e2) {
          _error(e2, 'Restoring');
        }
      } else {
        _error(err, 'Restoring');
      }
    } catch (err) {
      _error(err, 'Restoring');
    }
  }

  Future<bool> deleteForever(TrashItem item) async {
    final ok = await showJ3Confirm(
      context,
      title: 'Delete permanently?',
      message: '"${item.relativePath}" (${Fmt.bytes(item.bytes)}) will be deleted for good.',
      confirmLabel: 'Delete permanently',
      destructive: true,
    );
    if (!ok) return false;
    try {
      await trash.deletePermanently(item);
      final last = _c.read(browserStateProvider).lastTrashed;
      if (last?.id == item.id) _state.clearUndo();
      return true;
    } catch (err) {
      _error(err, 'Deleting permanently');
      return false;
    }
  }

  Future<bool> emptyTrash(List<TrashItem> items) async {
    final bytes = items.fold<int>(0, (s, i) => s + i.bytes);
    final ok = await showJ3Confirm(
      context,
      title: 'Empty trash?',
      message: 'Permanently deletes ${Fmt.count(items.length, 'item')} (${Fmt.bytes(bytes)}). This cannot be undone.',
      confirmLabel: 'Empty trash',
      destructive: true,
      details: [for (final i in items) i.relativePath],
    );
    if (!ok) return false;
    try {
      final (n, b) = await _activity.run<(int, int)>(
        toolId: WsTools.browser,
        title: 'Empty trash of "${workspace.name}"',
        workspaceId: workspace.id,
        body: (_) => trash.empty(),
        summary: (r) => '${Fmt.count(r.$1, 'item')} deleted (${Fmt.bytes(r.$2)})',
      );
      _state.clearUndo();
      return n >= 0 && b >= 0;
    } catch (err) {
      _error(err, 'Emptying the trash');
      return false;
    }
  }

  Future<void> importHere() async {
    final dir = currentDirPath;
    final staging = p.join(_c.read(appPathsProvider).pickedDir, 'here-${DateTime.now().microsecondsSinceEpoch}');
    try {
      final picked = await _c.read(fileAccessProvider).pickFiles(multiple: true, destinationDir: staging);
      if (picked.isEmpty) return;
      final r = await _activity.run(
        toolId: WsTools.browser,
        title:
            'Import ${Fmt.count(picked.length, 'file')} into ${relative(dir) == '.' ? workspace.name : relative(dir)}',
        workspaceId: workspace.id,
        cancellable: true,
        body: (op) => WorkspaceTransfer.importPicked(
          picked,
          dir,
          stagingDir: staging,
          token: op.token,
          onProgress: (d, t, n) => op.progress(t == 0 ? null : d / t, n),
        ),
        summary: (r) =>
            '${Fmt.count(r.files, 'file')} (${Fmt.bytes(r.bytes)})${r.problems.isEmpty ? '' : ', ${r.problems.join('; ')}'}',
      );
      _state.reload();
      if (r.failed.isNotEmpty) _activity.notify(NoticeKind.warning, r.failed.join('\n'));
    } catch (err) {
      _error(err, 'Importing files');
    } finally {
      try {
        final d = Directory(staging);
        if (await d.exists()) await d.delete(recursive: true);
      } catch (_) {
        // Best effort.
      }
    }
  }

  /// SHA-256 of a file through the activity system (progress + cancel).
  Future<String?> hash(FsEntry e, void Function(String opId) onStart) async {
    try {
      return await _activity.run<String>(
        toolId: WsTools.browser,
        title: 'SHA-256 of ${e.name}',
        workspaceId: workspace.id,
        cancellable: true,
        body: (op) {
          onStart(op.id);
          return Hashing.file(e.path, token: op.token, onProgress: (f, m) => op.progress(f, m));
        },
        summary: (h) => h,
      );
    } catch (err) {
      _error(err, 'Hashing ${e.name}');
      return null;
    }
  }
}
