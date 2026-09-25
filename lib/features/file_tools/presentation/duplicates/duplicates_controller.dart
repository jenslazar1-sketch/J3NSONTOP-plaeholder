import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/activity/activity_controller.dart';
import '../../../../core/tasks/cancellation.dart';
import '../../../../core/utils/format.dart';
import '../../../../core/workspace/workspace.dart';
import '../../../../core/workspace/workspace_controller.dart';
import '../../domain/duplicates.dart';
import '../../domain/glob.dart';
import '../../domain/quarantine.dart';
import '../shared.dart';

const String kDuplicatesToolId = 'files.duplicates';

class DuplicatesState {
  const DuplicatesState({
    this.root,
    this.result,
    this.keepers = const {},
    this.unselected = const {},
    this.rule = KeeperRule.shallowest,
    this.opId,
    this.error,
    this.notice,
    this.sessions = const [],
    this.sessionsLoaded = false,
    this.sessionsError,
  });

  /// Folder to scan (absolute); null means the workspace root.
  final String? root;
  final DuplicateScanResult? result;

  /// Keeper index per group id.
  final Map<int, int> keepers;

  /// Absolute paths of copies the user un-ticked (they stay in place).
  final Set<String> unselected;
  final KeeperRule rule;
  final String? opId;
  final String? error;
  final String? notice;
  final List<QuarantineSession> sessions;
  final bool sessionsLoaded;
  final String? sessionsError;

  bool get running => opId != null;

  int keeperOf(DuplicateGroup g) => keepers[g.id] ?? 0;

  bool isSelected(DuplicateGroup g, int index) => index != keeperOf(g) && !unselected.contains(g.files[index].path);

  /// Copies that "Move to quarantine" would move, with their group.
  List<(DuplicateGroup, DuplicateFile)> get selectedCopies => [
    for (final g in result?.groups ?? const <DuplicateGroup>[])
      for (var i = 0; i < g.files.length; i++)
        if (isSelected(g, i)) (g, g.files[i]),
  ];

  int get selectedBytes => selectedCopies.fold(0, (s, e) => s + e.$1.size);

  DuplicateDecisions decisions() =>
      DuplicateDecisions(keepers: keepers, selected: {for (final (_, f) in selectedCopies) f.relativePath});

  DuplicatesState copyWith({
    String? root,
    DuplicateScanResult? result,
    bool clearResult = false,
    Map<int, int>? keepers,
    Set<String>? unselected,
    KeeperRule? rule,
    String? opId,
    bool clearOp = false,
    String? error,
    bool clearError = false,
    String? notice,
    bool clearNotice = false,
    List<QuarantineSession>? sessions,
    bool? sessionsLoaded,
    String? sessionsError,
    bool clearSessionsError = false,
  }) => DuplicatesState(
    root: root ?? this.root,
    result: clearResult ? null : (result ?? this.result),
    keepers: keepers ?? this.keepers,
    unselected: unselected ?? this.unselected,
    rule: rule ?? this.rule,
    opId: clearOp ? null : (opId ?? this.opId),
    error: clearError ? null : (error ?? this.error),
    notice: clearNotice ? null : (notice ?? this.notice),
    sessions: sessions ?? this.sessions,
    sessionsLoaded: sessionsLoaded ?? this.sessionsLoaded,
    sessionsError: clearSessionsError ? null : (sessionsError ?? this.sessionsError),
  );
}

class DuplicatesController extends Notifier<DuplicatesState> {
  @override
  DuplicatesState build() {
    // A different workspace invalidates folder, results and journals.
    ref.watch(activeWorkspaceProvider.select((w) => w?.id));
    return const DuplicatesState();
  }

  Workspace? get _ws => ref.read(activeWorkspaceProvider);

  QuarantineStore? store() {
    final ws = _ws;
    if (ws == null) return null;
    return QuarantineStore(
      workspaceRoot: ws.rootPath,
      metaDir: ref.read(workspacesProvider.notifier).metaDir(ws),
      workspaceId: ws.id,
    );
  }

  void setRoot(String folder) => state = state.copyWith(root: folder, clearResult: true, clearNotice: true);

  void setRule(KeeperRule rule) {
    final r = state.result;
    state = state.copyWith(
      rule: rule,
      keepers: r == null ? const {} : {for (final g in r.groups) g.id: pickKeeper(g, rule)},
      unselected: const {},
    );
  }

  void setKeeper(DuplicateGroup g, int index) {
    final unselected = {...state.unselected}..remove(g.files[index].path);
    state = state.copyWith(keepers: {...state.keepers, g.id: index}, unselected: unselected);
  }

  void toggleCopy(DuplicateGroup g, int index, bool selected) {
    final path = g.files[index].path;
    final next = {...state.unselected};
    selected ? next.remove(path) : next.add(path);
    state = state.copyWith(unselected: next);
  }

  void selectAll(bool selected) {
    final r = state.result;
    if (r == null) return;
    state = state.copyWith(
      unselected: selected
          ? const {}
          : {
              for (final g in r.groups)
                for (var i = 0; i < g.files.length; i++)
                  if (i != state.keeperOf(g)) g.files[i].path,
            },
    );
  }

  Future<void> scan({required String include, required String exclude, required int minSize}) async {
    final ws = _ws;
    if (ws == null || state.running) return;
    GlobFilter filter;
    try {
      filter = GlobFilter.parse(include: include, exclude: exclude);
    } on FormatException catch (e) {
      state = state.copyWith(error: 'Invalid pattern: ${e.message}');
      return;
    }
    final root = state.root ?? ws.rootPath;
    state = state.copyWith(
      clearResult: true,
      clearError: true,
      clearNotice: true,
      keepers: const {},
      unselected: const {},
    );
    try {
      final result = await ref
          .read(activityProvider.notifier)
          .run<DuplicateScanResult>(
            toolId: kDuplicatesToolId,
            title: 'Find duplicates in ${workspaceLabel(ws, root) == '.' ? ws.name : workspaceLabel(ws, root)}',
            cancellable: true,
            workspaceId: ws.id,
            body: (op) async {
              state = state.copyWith(opId: op.id);
              final throttle = ProgressThrottle(op);
              return scanDuplicates(
                root,
                filter: filter,
                minSize: minSize,
                token: op.token,
                onProgress: (phase, f, msg) => throttle.report(f, '${phase.label}: $msg'),
              );
            },
            summary: (r) => r.groups.isEmpty
                ? 'No duplicates among ${r.filesScanned} files'
                : '${r.groups.length} groups, ${Fmt.bytes(r.wastedBytes)} reclaimable',
            counts: (r) => {'files': r.filesScanned, 'groups': r.groups.length, 'bytes': r.wastedBytes},
          );
      if (!ref.mounted) return;
      state = state.copyWith(
        result: result,
        clearOp: true,
        keepers: {for (final g in result.groups) g.id: pickKeeper(g, state.rule)},
      );
    } on OperationCancelled {
      if (ref.mounted) state = state.copyWith(clearOp: true, notice: 'Scan cancelled.');
    } catch (e) {
      if (ref.mounted) state = state.copyWith(clearOp: true, error: describeError(e));
    }
  }

  /// Moves the selected copies to the quarantine folder (reversible).
  Future<void> quarantineSelected() async {
    final ws = _ws;
    final st = store();
    final copies = state.selectedCopies;
    if (ws == null || st == null || copies.isEmpty || state.running) return;
    final requests = [
      for (final (g, f) in copies)
        QuarantineRequest(
          relativePath: workspaceLabel(ws, f.path),
          keeperRelativePath: workspaceLabel(ws, g.files[state.keeperOf(g)].path),
          size: f.size,
          digest: g.digest,
        ),
    ];
    state = state.copyWith(clearError: true, clearNotice: true);
    try {
      final r = await ref
          .read(activityProvider.notifier)
          .run<QuarantineMoveResult>(
            toolId: kDuplicatesToolId,
            title: 'Quarantine ${Fmt.count(requests.length, 'duplicate copy', 'duplicate copies')}',
            cancellable: true,
            workspaceId: ws.id,
            body: (op) async {
              state = state.copyWith(opId: op.id);
              final res = await st.quarantine(
                requests,
                token: op.token,
                onProgress: (done, total, cur) =>
                    op.progress(total == 0 ? null : done / total, cur.isEmpty ? null : 'Moving $cur'),
              );
              final counts = {'moved': res.moved, 'skipped': res.skipped.length, 'bytes': res.movedBytes};
              if (res.cancelled) {
                op.warn('Cancelled after moving ${res.moved}', counts: counts);
              } else if (res.skipped.isNotEmpty) {
                op.warn(
                  'Moved ${res.moved}, skipped ${res.skipped.length}',
                  counts: counts,
                  details: [for (final (p, why) in res.skipped) '$p: $why'],
                );
              } else {
                op.succeed('Moved ${res.moved} copies (${Fmt.bytes(res.movedBytes)}) to quarantine', counts: counts);
              }
              return res;
            },
          );
      if (!ref.mounted) return;
      final moved = {for (final e in r.session?.inQuarantine ?? const <QuarantineEntry>[]) e.relativePath};
      final (remaining, keepers) = _withoutMoved(state.result, ws, moved);
      state = state.copyWith(
        clearOp: true,
        result: remaining,
        keepers: keepers,
        notice: [
          'Moved ${r.moved} ${r.moved == 1 ? 'copy' : 'copies'} (${Fmt.bytes(r.movedBytes)}) to quarantine '
              '${r.session?.id ?? ''}. Undo any time below.',
          if (r.skipped.isNotEmpty) '${r.skipped.length} skipped: ${r.skipped.first.$1} (${r.skipped.first.$2})',
          if (r.cancelled) 'Cancelled before all copies were moved.',
        ].join(' '),
      );
      await loadSessions();
    } catch (e) {
      if (ref.mounted) state = state.copyWith(clearOp: true, error: describeError(e));
    }
  }

  /// Drops moved copies from the result; groups left with one file vanish.
  (DuplicateScanResult?, Map<int, int>) _withoutMoved(DuplicateScanResult? r, Workspace ws, Set<String> moved) {
    if (r == null || moved.isEmpty) return (r, state.keepers);
    final groups = <DuplicateGroup>[];
    for (final g in r.groups) {
      final keep = g.files.where((f) => !moved.contains(workspaceLabel(ws, f.path))).toList();
      if (keep.length >= 2) {
        groups.add(DuplicateGroup(id: g.id, digest: g.digest, size: g.size, files: keep));
      }
    }
    // Keeper indices refer to the old lists; recompute by path.
    final oldKeepers = {for (final g in r.groups) g.id: g.files[state.keeperOf(g)].path};
    final keepers = {
      for (final g in groups) g.id: g.files.indexWhere((f) => f.path == oldKeepers[g.id]).clamp(0, g.files.length - 1),
    };
    final next = DuplicateScanResult(
      root: r.root,
      groups: groups,
      filesScanned: r.filesScanned,
      bytesScanned: r.bytesScanned,
      hashedFiles: r.hashedFiles,
      hashedBytes: r.hashedBytes,
      skippedLinks: r.skippedLinks,
      hardLinks: r.hardLinks,
      unreadable: r.unreadable,
      truncated: r.truncated,
      filterDescription: r.filterDescription,
      minSize: r.minSize,
      elapsed: r.elapsed,
    );
    return (next, keepers);
  }

  Future<void> loadSessions() async {
    final st = store();
    if (st == null) return;
    try {
      final sessions = await st.sessions();
      if (ref.mounted) state = state.copyWith(sessions: sessions, sessionsLoaded: true, clearSessionsError: true);
    } catch (e) {
      if (ref.mounted) state = state.copyWith(sessionsLoaded: true, sessionsError: describeError(e));
    }
  }

  /// Restores a whole session, or only [only] (workspace-relative paths).
  Future<void> restore(QuarantineSession session, {Set<String>? only}) async {
    final ws = _ws;
    final st = store();
    if (ws == null || st == null || state.running) return;
    state = state.copyWith(clearError: true, clearNotice: true);
    try {
      final r = await ref
          .read(activityProvider.notifier)
          .run<RestoreResult>(
            toolId: kDuplicatesToolId,
            title: 'Restore from quarantine ${session.id}',
            cancellable: true,
            workspaceId: ws.id,
            body: (op) async {
              state = state.copyWith(opId: op.id);
              final res = await st.restore(session, only: only, token: op.token);
              final counts = {'restored': res.restored, 'failed': res.failed.length};
              if (res.failed.isNotEmpty || res.renamed.isNotEmpty) {
                op.warn(
                  'Restored ${res.restored}${res.renamed.isEmpty ? '' : ', ${res.renamed.length} under a new name'}'
                  '${res.failed.isEmpty ? '' : ', ${res.failed.length} failed'}',
                  counts: counts,
                  details: [
                    for (final (a, b) in res.renamed) '$a -> $b (original path was occupied)',
                    for (final (a, why) in res.failed) '$a: $why',
                  ],
                );
              } else {
                op.succeed('Restored ${res.restored} file(s)', counts: counts);
              }
              return res;
            },
          );
      if (!ref.mounted) return;
      state = state.copyWith(
        clearOp: true,
        notice: [
          'Restored ${r.restored} file(s) from ${session.id}.',
          if (r.renamed.isNotEmpty) '${r.renamed.length} restored under a new name because the path was occupied.',
          if (r.failed.isNotEmpty) '${r.failed.length} could not be restored: ${r.failed.first.$2}.',
          if (state.result != null) 'Scan again to refresh the duplicate groups.',
        ].join(' '),
      );
      await loadSessions();
    } catch (e) {
      if (ref.mounted) state = state.copyWith(clearOp: true, error: describeError(e));
    }
  }
}

final duplicatesProvider = NotifierProvider<DuplicatesController, DuplicatesState>(DuplicatesController.new);
