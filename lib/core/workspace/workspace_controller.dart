import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../platform/app_paths.dart';
import '../storage/app_stores.dart';
import 'workspace.dart';

class WorkspacesState {
  const WorkspacesState({this.workspaces = const [], this.activeId});

  final List<Workspace> workspaces;
  final String? activeId;

  Workspace? get active {
    for (final w in workspaces) {
      if (w.id == activeId) return w;
    }
    return null;
  }

  Workspace? byId(String id) {
    for (final w in workspaces) {
      if (w.id == id) return w;
    }
    return null;
  }

  /// Most recently opened first.
  List<Workspace> get recent =>
      [...workspaces]..sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
}

/// Result of checking whether a workspace root is still reachable.
enum WorkspaceHealth { ok, missing, notADirectory, permissionDenied }

/// Workspace records. Records are metadata only: removing a record never
/// deletes a linked folder; app-owned copies are deleted only through
/// [remove] with `deleteAppOwnedFiles: true` after explicit confirmation.
class WorkspaceController extends Notifier<WorkspacesState> {
  static const _uuid = Uuid();

  @override
  WorkspacesState build() {
    final data = ref.watch(bootDataProvider).workspaces.data;
    final list = <Workspace>[];
    final raw = data['workspaces'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          final w = Workspace.fromJson(item);
          if (w != null && list.every((e) => e.id != w.id)) list.add(w);
        }
      }
    }
    final active = data['activeId'];
    return WorkspacesState(
      workspaces: list,
      activeId: active is String && list.any((w) => w.id == active)
          ? active
          : (list.isEmpty ? null : list.first.id),
    );
  }

  AppPaths get _paths => ref.read(appPathsProvider);

  Future<void> _save(WorkspacesState next) async {
    state = next;
    await ref.read(appStoresProvider).workspaces.save({
      'activeId': next.activeId,
      'workspaces': [for (final w in next.workspaces) w.toJson()],
    });
  }

  String newId() => _uuid.v4();

  /// Registers a linked folder (desktop). Does not copy anything.
  Future<Workspace> addLinked(String name, String folderPath) async {
    final now = DateTime.now();
    final w = Workspace(
      id: newId(),
      name: name,
      kind: WorkspaceKind.linked,
      rootPath: p.normalize(p.absolute(folderPath)),
      createdAt: now,
      lastOpenedAt: now,
    );
    await Directory(_paths.workspaceMetaDir(w.id)).create(recursive: true);
    await _save(
      WorkspacesState(workspaces: [...state.workspaces, w], activeId: w.id),
    );
    return w;
  }

  /// Creates an empty app-owned workspace (imported copies or sample).
  Future<Workspace> addAppOwned(
    String name, {
    WorkspaceKind kind = WorkspaceKind.imported,
    String? id,
    String? note,
  }) async {
    assert(kind.isAppOwned);
    final now = DateTime.now();
    final wid = id ?? newId();
    final root = _paths.workspaceFilesDir(wid);
    await Directory(root).create(recursive: true);
    await Directory(_paths.workspaceMetaDir(wid)).create(recursive: true);
    final w = Workspace(
      id: wid,
      name: name,
      kind: kind,
      rootPath: root,
      createdAt: now,
      lastOpenedAt: now,
      note: note,
    );
    await _save(
      WorkspacesState(workspaces: [...state.workspaces, w], activeId: w.id),
    );
    return w;
  }

  Future<void> setActive(String id) async {
    final w = state.byId(id);
    if (w == null) return;
    await _save(
      WorkspacesState(
        workspaces: [
          for (final e in state.workspaces)
            e.id == id ? e.copyWith(lastOpenedAt: DateTime.now()) : e,
        ],
        activeId: id,
      ),
    );
  }

  Future<void> rename(String id, String name) => _save(
    WorkspacesState(
      workspaces: [
        for (final e in state.workspaces)
          e.id == id ? e.copyWith(name: name) : e,
      ],
      activeId: state.activeId,
    ),
  );

  /// Removes the record. Linked folders are never touched. For app-owned
  /// workspaces, files are deleted only when [deleteAppOwnedFiles] is true.
  Future<void> remove(String id, {bool deleteAppOwnedFiles = false}) async {
    final w = state.byId(id);
    if (w == null) return;
    final remaining = state.workspaces.where((e) => e.id != id).toList();
    await _save(
      WorkspacesState(
        workspaces: remaining,
        activeId: state.activeId == id
            ? (remaining.isEmpty ? null : remaining.first.id)
            : state.activeId,
      ),
    );
    if (deleteAppOwnedFiles && w.kind.isAppOwned) {
      final dir = Directory(p.join(_paths.workspacesDir, w.id));
      // Safety: only ever delete inside the app-owned workspaces directory.
      if (p.isWithin(_paths.workspacesDir, dir.path) && await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  }

  /// Metadata directory (mod library, profiles, journals, backups).
  String metaDir(Workspace w) => _paths.workspaceMetaDir(w.id);

  static Future<WorkspaceHealth> checkHealth(Workspace w) async {
    try {
      final type = await FileSystemEntity.type(w.rootPath);
      if (type == FileSystemEntityType.notFound) return WorkspaceHealth.missing;
      if (type != FileSystemEntityType.directory) {
        return WorkspaceHealth.notADirectory;
      }
      await Directory(w.rootPath).list().take(1).toList();
      return WorkspaceHealth.ok;
    } on FileSystemException {
      return WorkspaceHealth.permissionDenied;
    }
  }
}

final workspacesProvider =
    NotifierProvider<WorkspaceController, WorkspacesState>(
      WorkspaceController.new,
    );

final activeWorkspaceProvider = Provider<Workspace?>(
  (ref) => ref.watch(workspacesProvider).active,
);
