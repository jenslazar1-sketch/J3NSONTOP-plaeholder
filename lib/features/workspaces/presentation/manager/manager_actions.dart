import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/platform/app_paths.dart';
import '../../../../core/platform/capabilities.dart';
import '../../../../core/platform/file_access.dart';
import '../../../../core/tasks/cancellation.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/utils/safe_path.dart';
import '../../../../core/widgets/widgets.dart';
import '../../../../core/workspace/workspace.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../../sample/sample_workspace.dart';
import '../../data/file_ops.dart';
import '../../data/workspace_transfer.dart';
import '../../domain/fs_errors.dart';
import '../shared/requests.dart';
import 'manager_dialogs.dart';
import 'manager_state.dart';

String? _validateWorkspaceName(String v) {
  final t = v.trim();
  if (t.isEmpty) return 'Enter a name';
  if (t.length > 80) return 'At most 80 characters';
  return null;
}

/// User flows of the workspace manager. Every flow catches its errors and
/// reports them readably (inline + toast); nothing fails silently.
class ManagerActions {
  ManagerActions(this.context, this.ref) : _c = ProviderScope.containerOf(context, listen: false);

  final BuildContext context;
  final WidgetRef ref;

  /// Flows keep running after long awaits (imports, exports) even if the
  /// page was left meanwhile; the container stays valid, a widget ref not.
  final ProviderContainer _c;

  WorkspaceController get _ctrl => _c.read(workspacesProvider.notifier);
  ManagerController get _state => _c.read(managerStateProvider.notifier);
  ActivityController get _activity => _c.read(activityProvider.notifier);
  CapabilityMatrix get _caps => _c.read(capabilitiesProvider);
  AppPaths get _paths => _c.read(appPathsProvider);

  void _fail(Object e, String action) {
    if (e is OperationCancelled) {
      // The activity log already shows the cancellation.
      _state.report(
        ManagerReport(
          kind: StatusKind.info,
          title: '$action was cancelled',
          message: 'No file was left half-written. See the Activity log for what finished before the cancel.',
        ),
      );
      return;
    }
    _state.error(e, action);
    final f = describeError(e, action: action);
    _activity.notify(NoticeKind.error, '$action failed: ${f.message}');
  }

  Future<String?> _askName(String title, String initial) => showJ3TextInput(
    context,
    title: title,
    label: 'Workspace name',
    initial: initial,
    validator: _validateWorkspaceName,
  );

  Future<void> newEmpty() async {
    final name = await _askName('New empty workspace', 'My project');
    if (name == null) return;
    try {
      final w = await _ctrl.addAppOwned(name.trim());
      _state.report(ManagerReport(kind: StatusKind.success, title: 'Created "${w.name}"', message: w.kind.explanation));
      _activity.notify(NoticeKind.success, 'Workspace "${w.name}" created');
    } catch (e) {
      _fail(e, 'Creating the workspace');
    }
  }

  Future<void> linkFolder() async {
    if (!_caps.supports(Capability.linkFolder)) {
      _activity.notify(NoticeKind.info, _caps.alternativeFor(Capability.linkFolder) ?? 'Not supported here.');
      return;
    }
    try {
      final dir = await _c.read(fileAccessProvider).pickDirectory(title: 'Choose a folder to link');
      if (dir == null || !context.mounted) return;
      if (FileSystemEntity.typeSync(dir) != FileSystemEntityType.directory) {
        throw FileSystemException('Not a folder', dir);
      }
      await Directory(dir).list().take(1).toList(); // proves read access
      if (!context.mounted) return;
      final name = await _askName('Link folder', p.basename(dir));
      if (name == null) return;
      final w = await _ctrl.addLinked(name.trim(), dir);
      _state.report(
        ManagerReport(
          kind: StatusKind.success,
          title: 'Linked "${w.name}"',
          message: '${w.kind.explanation} Removing this workspace later never deletes the folder.',
        ),
      );
    } catch (e) {
      _fail(e, 'Linking the folder');
    }
  }

  Future<Workspace?> _targetWorkspace(ImportTarget target, String defaultName) async {
    if (target == ImportTarget.activeWorkspace) return _c.read(activeWorkspaceProvider);
    final name = await _askName('Name the new workspace', defaultName);
    if (name == null) return null;
    return _ctrl.addAppOwned(name.trim());
  }

  Future<void> importFiles() async {
    final active = _c.read(activeWorkspaceProvider);
    final target = await chooseImportTarget(context, active: active, what: 'files');
    if (target == null || !context.mounted) return;
    final staging = p.join(_paths.pickedDir, 'import-${DateTime.now().microsecondsSinceEpoch}');
    List<PickedLocalFile> picked;
    try {
      picked = await _c.read(fileAccessProvider).pickFiles(multiple: true, destinationDir: staging);
    } catch (e) {
      _fail(e, 'Opening the file picker');
      return;
    }
    if (picked.isEmpty || !context.mounted) {
      await _cleanup(staging);
      return;
    }
    final ws = await _targetWorkspace(target, 'Imported ${Fmt.stamp(DateTime.now())}');
    if (ws == null) {
      await _cleanup(staging);
      return;
    }
    await _runImport(
      title: 'Import ${Fmt.count(picked.length, 'file')} into "${ws.name}"',
      workspace: ws,
      body: (op) => WorkspaceTransfer.importPicked(
        picked,
        ws.rootPath,
        stagingDir: staging,
        token: op.token,
        onProgress: (done, total, name) => op.progress(total == 0 ? null : done / total, name),
      ),
    );
  }

  Future<void> importFolder() async {
    if (!_caps.supports(Capability.importFolder)) {
      _activity.notify(NoticeKind.info, _caps.alternativeFor(Capability.importFolder) ?? 'Not supported here.');
      return;
    }
    String? dir;
    try {
      dir = await _c.read(fileAccessProvider).pickDirectory(title: 'Choose a folder to copy');
    } catch (e) {
      _fail(e, 'Opening the folder picker');
      return;
    }
    if (dir == null || !context.mounted) return;
    final active = _c.read(activeWorkspaceProvider);
    final target = await chooseImportTarget(context, active: active, what: 'folder "${p.basename(dir)}"');
    if (target == null || !context.mounted) return;
    final ws = await _targetWorkspace(target, p.basename(dir));
    if (ws == null) return;
    final dest = target == ImportTarget.newWorkspace
        ? ws.rootPath
        : SafePath.uniquePath(p.join(ws.rootPath, SafePath.sanitizeFileName(p.basename(dir))));
    if (SafePath.isWithin(dir, ws.rootPath)) {
      _fail(FileSystemException('Cannot copy a folder into itself', ws.rootPath), 'Importing the folder');
      return;
    }
    final source = dir;
    await _runImport(
      title: 'Import folder "${p.basename(source)}" into "${ws.name}"',
      workspace: ws,
      body: (op) => WorkspaceTransfer.importFolder(
        source,
        dest,
        token: op.token,
        onProgress: (files, bytes, current) =>
            op.progress(null, '${Fmt.count(files, 'file')}, ${Fmt.bytes(bytes)} - $current'),
      ),
    );
  }

  Future<void> _runImport({
    required String title,
    required Workspace workspace,
    required Future<CopyReport> Function(OperationHandle op) body,
  }) async {
    _state.clearMessages();
    try {
      final report = await _activity.run<CopyReport>(
        toolId: WsTools.manager,
        title: title,
        workspaceId: workspace.id,
        cancellable: true,
        body: (op) {
          _state.running(op.id, title);
          return body(op);
        },
        summary: (r) =>
            '${Fmt.count(r.files, 'file')} (${Fmt.bytes(r.bytes)})'
            '${r.problems.isEmpty ? '' : ', ${r.problems.length} note(s)'}',
        counts: (r) => {'files': r.files, 'bytes': r.bytes, 'failed': r.failed.length},
      );
      await _ctrl.setActive(workspace.id);
      _state.report(
        ManagerReport(
          kind: report.failed.isEmpty ? StatusKind.success : StatusKind.warning,
          title: 'Imported ${Fmt.count(report.files, 'file')} (${Fmt.bytes(report.bytes)}) into "${workspace.name}"',
          message: report.failed.isEmpty ? null : '${report.failed.length} file(s) could not be copied.',
          details: [...report.failed, ...report.skipped],
        ),
      );
    } catch (e) {
      _state.idle();
      _fail(e, 'The import');
    }
  }

  Future<void> importZip() async {
    final staging = p.join(_paths.pickedDir, 'zip-${DateTime.now().microsecondsSinceEpoch}');
    try {
      final picked = await ref
          .read(fileAccessProvider)
          .pickFiles(multiple: false, extensions: const ['zip'], destinationDir: staging);
      if (picked.isEmpty || !context.mounted) {
        await _cleanup(staging);
        return;
      }
      final zip = picked.first;
      final inspection = await WorkspaceTransfer.inspectZip(zip.path);
      if (!context.mounted) return;
      final choice = await showDialog<ZipImportChoice>(
        context: context,
        builder: (_) =>
            ImportZipDialog(zipName: zip.name, inspection: inspection, active: _c.read(activeWorkspaceProvider)),
      );
      if (choice == null || !context.mounted) {
        await _cleanup(staging);
        return;
      }
      final stem = p.basenameWithoutExtension(zip.name);
      final created = choice.target == ImportTarget.newWorkspace;
      final ws = await _targetWorkspace(choice.target, stem);
      if (ws == null) {
        await _cleanup(staging);
        return;
      }
      final dest = created
          ? ws.rootPath
          : SafePath.uniquePath(p.join(ws.rootPath, SafePath.sanitizeFileName(stem, fallback: 'archive')));
      _state.clearMessages();
      try {
        final r = await _activity.run(
          toolId: WsTools.manager,
          title: 'Extract "${zip.name}" into "${ws.name}"',
          workspaceId: ws.id,
          cancellable: true,
          body: (op) {
            _state.running(op.id, 'Extracting ${zip.name}');
            return WorkspaceTransfer.extractZip(
              zip.path,
              dest,
              token: op.token,
              onProgress: (f, entry) => op.progress(f, entry),
            );
          },
          summary: (r) => '${Fmt.count(r.written.length, 'file')} (${Fmt.bytes(r.bytes)})',
          counts: (r) => {'files': r.written.length, 'bytes': r.bytes, 'skipped': r.skipped.length},
        );
        await _ctrl.setActive(ws.id);
        _state.report(
          ManagerReport(
            kind: r.skipped.isEmpty ? StatusKind.success : StatusKind.warning,
            title: 'Extracted ${Fmt.count(r.written.length, 'file')} (${Fmt.bytes(r.bytes)}) into "${ws.name}"',
            message: created ? null : 'Folder: ${p.relative(dest, from: ws.rootPath)}',
            details: [for (final s in r.skipped) 'kept existing $s (not overwritten)'],
          ),
        );
      } catch (e) {
        _state.idle();
        if (created) {
          // The workspace was created only for this import: remove it with
          // its partial content so no half-extracted copy is left behind.
          await _ctrl.remove(ws.id, deleteAppOwnedFiles: true);
        }
        _fail(e, 'The ZIP import');
        if (created) {
          _activity.notify(NoticeKind.info, 'The new workspace "${ws.name}" was removed again (import incomplete).');
        }
      }
    } catch (e) {
      _fail(e, 'The ZIP import');
    } finally {
      await _cleanup(staging);
    }
  }

  Future<void> createSample() async {
    _state.clearMessages();
    try {
      final w = await createSampleWorkspace(ref);
      _state.report(
        ManagerReport(
          kind: StatusKind.success,
          title: 'Sample workspace "${w.name}" created',
          message: w.kind.explanation,
        ),
      );
    } catch (e) {
      _fail(
        e is UnimplementedError ? StateError('The sample generator is not available in this build (${e.message})') : e,
        'Creating the sample workspace',
      );
    }
  }

  Future<void> rename(Workspace w) async {
    final name = await _askName('Rename workspace', w.name);
    if (name == null || name.trim() == w.name) return;
    try {
      await _ctrl.rename(w.id, name.trim());
    } catch (e) {
      _fail(e, 'Renaming');
    }
  }

  Future<void> setActive(Workspace w) async {
    try {
      await _ctrl.setActive(w.id);
    } catch (e) {
      _fail(e, 'Switching workspace');
    }
  }

  Future<void> browse(Workspace w) async {
    await setActive(w);
    if (context.mounted) ref.goTool(context, WsTools.browser);
  }

  Future<void> remove(Workspace w) async {
    bool deleteFiles = false;
    if (w.kind.isAppOwned) {
      final decision = await RemoveWorkspaceDialog.show(context, w);
      if (decision == null) return;
      deleteFiles = decision.deleteFiles;
    } else {
      final ok = await showJ3Confirm(
        context,
        title: 'Remove linked workspace?',
        message:
            'Only the record "${w.name}" is removed. The linked folder is NOT deleted or changed:\n${w.rootPath}\n\n'
            'App metadata for it (mod library, backups, journals) stays in app storage and can be recovered or '
            'deleted under "App storage".',
        confirmLabel: 'Remove record',
        destructive: true,
      );
      if (!ok) return;
    }
    try {
      await _activity.run<void>(
        toolId: WsTools.manager,
        title: deleteFiles
            ? 'Remove workspace "${w.name}" and delete its files'
            : 'Remove workspace record "${w.name}"',
        workspaceId: w.id,
        body: (_) => _ctrl.remove(w.id, deleteAppOwnedFiles: deleteFiles),
        summary: (_) => deleteFiles ? 'Record and app-owned files deleted' : 'Record removed, files kept',
      );
      _state.report(
        ManagerReport(
          kind: StatusKind.info,
          title: 'Removed "${w.name}"',
          message: deleteFiles
              ? 'The imported copy was deleted.'
              : (w.kind.isAppOwned ? 'Files were kept in app storage.' : 'Your folder was not touched.'),
        ),
      );
    } catch (e) {
      _fail(e, 'Removing the workspace');
    }
  }

  Future<void> exportZip(Workspace w) async {
    final staging = p.join(_paths.exportStagingDir, 'ws-${DateTime.now().microsecondsSinceEpoch}');
    final name = '${SafePath.sanitizeFileName(w.name, fallback: 'workspace')}.zip';
    _state.clearMessages();
    try {
      final r = await _activity.run<ZipExportResult>(
        toolId: WsTools.manager,
        title: 'Export "${w.name}" as ZIP',
        workspaceId: w.id,
        cancellable: true,
        body: (op) {
          _state.running(op.id, 'Zipping ${w.name}');
          return WorkspaceTransfer.exportZip(
            w.rootPath,
            p.join(staging, name),
            token: op.token,
            onProgress: (f, msg) => op.progress(f == 0 ? null : f, msg),
          );
        },
        summary: (r) => '${Fmt.count(r.files, 'file')}, ${Fmt.bytes(r.bytes)} ZIP',
        counts: (r) => {'files': r.files, 'bytes': r.bytes, 'skipped': r.skipped.length},
      );
      _state.idle();
      if (!context.mounted) return;
      if (r.bytes > 200 * 1024 * 1024) {
        final ok = await showJ3Confirm(
          context,
          title: 'Large export',
          message: 'The ZIP is ${Fmt.bytes(r.bytes)}. Saving it needs that much free memory. Continue?',
          confirmLabel: 'Save',
        );
        if (!ok || !context.mounted) return;
      }
      final bytes = await File(r.zipPath).readAsBytes();
      if (!context.mounted) return;
      final where = await saveOutput(
        context,
        ref,
        suggestedName: name,
        bytes: bytes,
        mimeType: 'application/zip',
        toolId: WsTools.manager,
      );
      _state.report(
        ManagerReport(
          kind: r.skipped.isEmpty ? StatusKind.success : StatusKind.warning,
          title: where == null
              ? 'ZIP created (${Fmt.bytes(r.bytes)}) but not saved'
              : 'Exported ${Fmt.count(r.files, 'file')} to $where',
          details: r.skipped,
        ),
      );
    } catch (e) {
      _state.idle();
      _fail(e, 'The export');
    } finally {
      await _cleanup(staging);
    }
  }

  Future<void> reveal(Workspace w) async {
    if (!_caps.supports(Capability.revealInFileManager)) {
      _activity.notify(NoticeKind.info, _caps.alternativeFor(Capability.revealInFileManager) ?? 'Not supported here.');
      return;
    }
    final ok = await _c.read(fileAccessProvider).reveal(w.rootPath);
    if (!ok) _activity.notify(NoticeKind.warning, 'Could not open the file manager for ${w.rootPath}');
  }

  Future<void> copyPath(Workspace w) async {
    await Clipboard.setData(ClipboardData(text: w.rootPath));
    _activity.notify(NoticeKind.success, 'Path copied');
  }

  /// Points a linked workspace whose folder moved to a new folder. The mod
  /// library, backups and journals move with it.
  Future<void> relink(Workspace w) async {
    if (!_caps.supports(Capability.linkFolder)) return;
    try {
      final dir = await _c.read(fileAccessProvider).pickDirectory(title: 'Choose the new location of "${w.name}"');
      if (dir == null) return;
      final previousActive = _c.read(workspacesProvider).activeId;
      final fresh = await _ctrl.addLinked(w.name, dir);
      await WorkspaceTransfer.migrateMeta(_ctrl.metaDir(w), _ctrl.metaDir(fresh));
      await _ctrl.remove(w.id);
      // addLinked activates the new record; keep whatever was active before.
      if (previousActive != null && previousActive != w.id) await _ctrl.setActive(previousActive);
      _c.invalidate(workspaceHealthProvider(fresh.id));
      _state.report(ManagerReport(kind: StatusKind.success, title: 'Relinked "${w.name}"', message: dir));
    } catch (e) {
      _fail(e, 'Relinking');
    }
  }

  /// Recreates the (empty) folder of an app-owned workspace whose copy was
  /// deleted outside the app.
  Future<void> recreateFolder(Workspace w) async {
    try {
      await Directory(w.rootPath).create(recursive: true);
      _c.invalidate(workspaceHealthProvider(w.id));
    } catch (e) {
      _fail(e, 'Recreating the folder');
    }
  }

  Future<void> scanStorage() async {
    try {
      final known = {for (final w in _c.read(workspacesProvider).workspaces) w.id};
      final list = await WorkspaceTransfer.findOrphans(_paths.workspacesDir, known);
      _state.orphans(list);
    } catch (e) {
      _fail(e, 'Scanning app storage');
    }
  }

  Future<void> restoreOrphan(OrphanStorage o) async {
    try {
      final w = await _ctrl.addAppOwned('Recovered ${o.id.length > 8 ? o.id.substring(0, 8) : o.id}', id: o.id);
      _state.report(ManagerReport(kind: StatusKind.success, title: 'Recovered as "${w.name}"', message: w.rootPath));
      await scanStorage();
    } catch (e) {
      _fail(e, 'Recovering the storage folder');
    }
  }

  Future<void> deleteOrphan(OrphanStorage o) async {
    final ok = await showJ3Confirm(
      context,
      title: 'Delete app storage folder?',
      message:
          'Permanently deletes ${Fmt.count(o.files, 'file')} (${Fmt.bytes(o.bytes)}) in app storage that no '
          'workspace uses any more. Linked folders elsewhere are never affected.',
      details: [o.path],
      confirmLabel: 'Delete permanently',
      destructive: true,
    );
    if (!ok) return;
    try {
      if (!SafePath.isWithin(_paths.workspacesDir, o.path) || p.equals(_paths.workspacesDir, o.path)) {
        throw FileSystemException('Refusing to delete outside app storage', o.path);
      }
      await Directory(o.path).delete(recursive: true);
      _activity.notify(NoticeKind.success, 'Deleted ${Fmt.bytes(o.bytes)} of unused app storage');
      await scanStorage();
    } catch (e) {
      _fail(e, 'Deleting the storage folder');
    }
  }

  Future<void> _cleanup(String dir) async {
    try {
      final d = Directory(dir);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {
      // Staging cleanup is best effort.
    }
  }
}
