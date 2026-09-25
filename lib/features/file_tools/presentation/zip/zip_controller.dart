import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/archive/safe_zip.dart';
import '../../../../core/platform/app_paths.dart';
import '../../../../core/tasks/cancellation.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/utils/safe_path.dart';
import '../../../../core/workspace/file_backup.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../domain/zip_studio.dart';
import '../shared.dart';

const String kZipToolId = 'files.zip';

enum ZipMode {
  create('Create'),
  extract('Extract');

  const ZipMode(this.label);
  final String label;
}

// ---------------------------------------------------------------------------
// Create

class ZipCreated {
  const ZipCreated({
    required this.path,
    required this.label,
    required this.bytes,
    required this.entries,
    this.staged = false,
  });
  final String path;
  final String label;
  final int bytes;
  final int entries;

  /// Written to the export staging area (to be handed to save/share).
  final bool staged;
}

class ZipCreateState {
  ZipCreateState({ZipPlan? plan, this.destFolder, this.opId, this.created, this.error, this.notice})
    : plan = plan ?? ZipPlan.empty;

  final ZipPlan plan;

  /// Workspace folder for "Create in workspace"; null = workspace root.
  final String? destFolder;
  final String? opId;
  final ZipCreated? created;
  final String? error;
  final String? notice;

  bool get running => opId != null;

  ZipCreateState copyWith({
    ZipPlan? plan,
    String? destFolder,
    String? opId,
    bool clearOp = false,
    ZipCreated? created,
    bool clearCreated = false,
    String? error,
    bool clearError = false,
    String? notice,
    bool clearNotice = false,
  }) => ZipCreateState(
    plan: plan ?? this.plan,
    destFolder: destFolder ?? this.destFolder,
    opId: clearOp ? null : (opId ?? this.opId),
    created: clearCreated ? null : (created ?? this.created),
    error: clearError ? null : (error ?? this.error),
    notice: clearNotice ? null : (notice ?? this.notice),
  );
}

class ZipCreateController extends Notifier<ZipCreateState> {
  @override
  ZipCreateState build() {
    ref.watch(activeWorkspaceProvider.select((w) => w?.id));
    return ZipCreateState();
  }

  void addEntries(Iterable<ZipPlanEntry> entries, {String? notice}) => state = state.copyWith(
    plan: state.plan.adding(entries),
    clearCreated: true,
    clearError: true,
    notice: notice,
    clearNotice: notice == null,
  );

  void remove(String archivePath) => state = state.copyWith(plan: state.plan.without([archivePath]));

  void clear() => state = ZipCreateState(destFolder: state.destFolder);

  void setDestFolder(String folder) => state = state.copyWith(destFolder: folder);

  /// Creates the archive in a workspace folder ([toWorkspace]) or in the
  /// export staging area for save/share.
  Future<ZipCreated?> create({required String archiveName, required bool toWorkspace}) async {
    if (state.running || !state.plan.canCreate) return null;
    final ws = ref.read(activeWorkspaceProvider);
    final name = normalizeArchiveName(archiveName);
    String outPath;
    if (toWorkspace) {
      if (ws == null) {
        state = state.copyWith(error: 'Open a workspace to save the archive into it.');
        return null;
      }
      final folder = state.destFolder ?? ws.rootPath;
      outPath = SafePath.uniquePath(p.join(folder, name));
      if (!SafePath.isWithin(ws.rootPath, outPath)) {
        state = state.copyWith(error: 'The destination is outside the workspace.');
        return null;
      }
    } else {
      final dir = p.join(ref.read(appPathsProvider).exportStagingDir, 'zip-${DateTime.now().microsecondsSinceEpoch}');
      await Directory(dir).create(recursive: true);
      outPath = p.join(dir, name);
    }
    final plan = state.plan;
    state = state.copyWith(clearCreated: true, clearError: true, clearNotice: true);
    try {
      final size = await ref
          .read(activityProvider.notifier)
          .run<int>(
            toolId: kZipToolId,
            title: 'Create $name (${Fmt.count(plan.entries.length, 'file')})',
            cancellable: true,
            workspaceId: ws?.id,
            body: (op) async {
              state = state.copyWith(opId: op.id);
              return createArchive(
                outPath,
                plan,
                token: op.token,
                onProgress: (f) =>
                    op.progress(f, 'Compressing ${(f * plan.entries.length).round()}/${plan.entries.length}'),
              );
            },
            summary: (size) => '$name: ${Fmt.bytes(size)} from ${Fmt.bytes(plan.totalBytes)}',
            counts: (size) => {'files': plan.entries.length, 'bytes': size},
          );
      final created = ZipCreated(
        path: outPath,
        label: toWorkspace && ws != null ? workspaceLabel(ws, outPath) : name,
        bytes: size,
        entries: plan.entries.length,
        staged: !toWorkspace,
      );
      if (ref.mounted) state = state.copyWith(clearOp: true, created: created);
      return created;
    } on OperationCancelled {
      if (ref.mounted) state = state.copyWith(clearOp: true, notice: 'Cancelled. No archive was written.');
    } catch (e) {
      if (ref.mounted) state = state.copyWith(clearOp: true, error: describeError(e));
    }
    return null;
  }
}

final zipCreateProvider = NotifierProvider<ZipCreateController, ZipCreateState>(ZipCreateController.new);

// ---------------------------------------------------------------------------
// Extract

class ZipExtractState {
  const ZipExtractState({
    this.zip,
    this.inspection,
    this.inspectError,
    this.destParent,
    this.makeSubfolder = true,
    this.policy = ExistingFilePolicy.skip,
    this.opId,
    this.outcome,
    this.error,
  });

  final FileItem? zip;
  final ZipInspection? inspection;
  final String? inspectError;

  /// Folder the archive is extracted into (or where its subfolder is made).
  final String? destParent;
  final bool makeSubfolder;
  final ExistingFilePolicy policy;
  final String? opId;
  final ExtractOutcome? outcome;
  final String? error;

  bool get running => opId != null;

  ZipExtractState copyWith({
    String? destParent,
    bool? makeSubfolder,
    ExistingFilePolicy? policy,
    String? opId,
    bool clearOp = false,
    ExtractOutcome? outcome,
    bool clearOutcome = false,
    String? error,
    bool clearError = false,
  }) => ZipExtractState(
    zip: zip,
    inspection: inspection,
    inspectError: inspectError,
    destParent: destParent ?? this.destParent,
    makeSubfolder: makeSubfolder ?? this.makeSubfolder,
    policy: policy ?? this.policy,
    opId: clearOp ? null : (opId ?? this.opId),
    outcome: clearOutcome ? null : (outcome ?? this.outcome),
    error: clearError ? null : (error ?? this.error),
  );
}

class ZipExtractController extends Notifier<ZipExtractState> {
  @override
  ZipExtractState build() {
    ref.watch(activeWorkspaceProvider.select((w) => w?.id));
    return const ZipExtractState();
  }

  /// Opens and inspects an archive (central directory only; nothing is
  /// extracted).
  void open(FileItem zip) {
    ZipInspection? inspection;
    String? err;
    try {
      inspection = SafeZip.inspect(zip.path);
    } on FormatException catch (e) {
      err = e.message;
    } on FileSystemException catch (e) {
      err = describeError(e);
    }
    state = ZipExtractState(
      zip: zip,
      inspection: inspection,
      inspectError: err,
      destParent: state.destParent,
      makeSubfolder: state.makeSubfolder,
    );
  }

  void setDestParent(String folder) => state = state.copyWith(destParent: folder, clearOutcome: true);
  void setSubfolder(bool v) => state = state.copyWith(makeSubfolder: v, clearOutcome: true);
  void setPolicy(ExistingFilePolicy p) => state = state.copyWith(policy: p);

  /// Where files would go right now.
  String? destination() {
    final ws = ref.read(activeWorkspaceProvider);
    final zip = state.zip;
    if (ws == null || zip == null) return null;
    final parent = state.destParent ?? ws.rootPath;
    return state.makeSubfolder ? defaultExtractFolder(zip.label, parent) : parent;
  }

  /// Relative paths that already exist at [destination].
  List<String> conflicts() {
    final dest = destination();
    final ins = state.inspection;
    if (dest == null || ins == null) return const [];
    return existingTargets(ins, dest);
  }

  Future<void> extract() async {
    final ws = ref.read(activeWorkspaceProvider);
    final zip = state.zip;
    final ins = state.inspection;
    final dest = destination();
    if (ws == null || zip == null || ins == null || dest == null || state.running) return;
    if (!ins.isSafe) {
      state = state.copyWith(error: 'This archive has blocked entries and cannot be extracted.');
      return;
    }
    if (!SafePath.isWithin(ws.rootPath, dest)) {
      state = state.copyWith(error: 'The destination is outside the workspace.');
      return;
    }
    final writer = WorkspaceFileWriter(workspace: ws, metaDir: ref.read(workspacesProvider.notifier).metaDir(ws));
    final backupRoot = SafePath.uniquePath(p.join(writer.backupsRoot, '${Fmt.stamp(DateTime.now())}-unzip'));
    final policy = state.policy;
    state = state.copyWith(clearOutcome: true, clearError: true);
    try {
      final outcome = await ref
          .read(activityProvider.notifier)
          .run<ExtractOutcome>(
            toolId: kZipToolId,
            title: 'Extract ${zip.label}',
            cancellable: true,
            workspaceId: ws.id,
            body: (op) async {
              state = state.copyWith(opId: op.id);
              final throttle = ProgressThrottle(op);
              final r = await extractArchive(
                zip.path,
                dest,
                policy: policy,
                backupRoot: backupRoot,
                token: op.token,
                onProgress: (f, entry) => throttle.report(f, entry),
              );
              final counts = {'written': r.written.length, 'skipped': r.skipped.length, 'bytes': r.bytes};
              if (r.cancelled) {
                op.warn('Cancelled after ${r.written.length} file(s)', counts: counts);
              } else if (r.skipped.isNotEmpty) {
                op.warn('${r.written.length} written, ${r.skipped.length} existing skipped', counts: counts);
              } else {
                op.succeed('${r.written.length} file(s), ${Fmt.bytes(r.bytes)}', counts: counts);
              }
              return r;
            },
          );
      if (ref.mounted) state = state.copyWith(clearOp: true, outcome: outcome);
    } catch (e) {
      if (ref.mounted) state = state.copyWith(clearOp: true, error: describeError(e));
    }
  }
}

final zipExtractProvider = NotifierProvider<ZipExtractController, ZipExtractState>(ZipExtractController.new);
