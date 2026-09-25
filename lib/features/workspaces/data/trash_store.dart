import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/storage/atomic_file.dart';
import '../../../core/tasks/cancellation.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/safe_path.dart';
import 'file_ops.dart';
import 'fs_walker.dart';

/// Something that was deleted from a workspace and can be restored.
class TrashItem {
  const TrashItem({
    required this.id,
    required this.relativePath,
    required this.isDirectory,
    required this.deletedAt,
    required this.bytes,
    required this.files,
  });

  /// Folder name under `<meta>/trash/`.
  final String id;

  /// Original location relative to the workspace root (forward slashes).
  final String relativePath;
  final bool isDirectory;
  final DateTime deletedAt;
  final int bytes;
  final int files;

  String get name => relativePath.split('/').last;

  Map<String, Object> toJson() => {
    'format': 'j3trash',
    'version': 1,
    'id': id,
    'relativePath': relativePath,
    'isDirectory': isDirectory,
    'deletedAt': deletedAt.toUtc().toIso8601String(),
    'bytes': bytes,
    'files': files,
  };

  static TrashItem? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final rel = j['relativePath'];
    final at = DateTime.tryParse('${j['deletedAt']}');
    if (id is! String || rel is! String || at == null) return null;
    return TrashItem(
      id: id,
      relativePath: rel,
      isDirectory: j['isDirectory'] == true,
      deletedAt: at,
      bytes: j['bytes'] is int ? j['bytes'] as int : 0,
      files: j['files'] is int ? j['files'] as int : 0,
    );
  }
}

/// Reversible delete for workspace files.
///
/// Layout: `<meta>/trash/<id>/<relative path>` holds the content and
/// `<meta>/trash/<id>.json` describes it, so the original location is
/// known even for nested paths.
class TrashStore {
  TrashStore({required this.rootPath, required this.metaDir, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final String rootPath;
  final String metaDir;
  final DateTime Function() _clock;

  String get trashDir => p.join(metaDir, 'trash');

  String _contentPath(TrashItem item) => p.joinAll([trashDir, item.id, ...item.relativePath.split('/')]);

  /// Moves [absolutePath] (inside the workspace) to the trash.
  Future<TrashItem> moveToTrash(String absolutePath, {CancellationToken? token}) async {
    if (!SafePath.isWithin(rootPath, absolutePath) || p.equals(p.normalize(rootPath), p.normalize(absolutePath))) {
      throw FileSystemException('Only files and folders inside the workspace can be deleted', absolutePath);
    }
    final type = FileSystemEntity.typeSync(absolutePath, followLinks: false);
    if (type == FileSystemEntityType.notFound) throw FileSystemException('No longer exists', absolutePath);
    final rel = FsWalker.relativeOf(rootPath, absolutePath);
    final isDir = type == FileSystemEntityType.directory;
    var files = 1, bytes = 0;
    if (isDir) {
      final m = await FsWalker.measure(absolutePath, token: token);
      files = m.files;
      bytes = m.bytes;
    } else if (type == FileSystemEntityType.file) {
      bytes = await File(absolutePath).length();
    }
    final now = _clock();
    final base = '${Fmt.stamp(now)}-${now.millisecond.toString().padLeft(3, '0')}';
    final id = p.basename(SafePath.uniquePath(p.join(trashDir, base)));
    final item = TrashItem(id: id, relativePath: rel, isDirectory: isDir, deletedAt: now, bytes: bytes, files: files);
    await Directory(p.join(trashDir, id)).create(recursive: true);
    // Record first: if the move is interrupted the manifest still tells
    // where the (partially) moved content belongs.
    await atomicWriteString(p.join(trashDir, '$id.json'), prettyJson.convert(item.toJson()));
    try {
      await FileOps.move(absolutePath, _contentPath(item), token: token);
    } catch (_) {
      // Nothing moved: drop the empty record again.
      if (FileSystemEntity.typeSync(_contentPath(item), followLinks: false) == FileSystemEntityType.notFound) {
        await _deleteRecord(item);
      }
      rethrow;
    }
    return item;
  }

  /// Items in the trash, newest first. Damaged records are skipped.
  Future<List<TrashItem>> list() async {
    final dir = Directory(trashDir);
    if (!await dir.exists()) return const [];
    final items = <TrashItem>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      try {
        final j = jsonDecode(await e.readAsString());
        if (j is Map<String, dynamic>) {
          final item = TrashItem.fromJson(j);
          if (item != null &&
              FileSystemEntity.typeSync(_contentPath(item), followLinks: false) != FileSystemEntityType.notFound) {
            items.add(item);
          }
        }
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    items.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return items;
  }

  /// Restores [item] to its original place. When something now occupies
  /// that path, [asCopy] restores under a unique name instead; otherwise a
  /// [FileSystemException] explains the conflict. Returns the new path.
  Future<String> restore(TrashItem item, {bool asCopy = false, CancellationToken? token}) async {
    var target = SafePath.resolveInside(rootPath, item.relativePath);
    if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
      if (!asCopy) throw FileSystemException('Something already exists at the original location', target);
      target = SafePath.uniquePath(target);
    }
    await FileOps.move(_contentPath(item), target, token: token);
    await _deleteRecord(item);
    return target;
  }

  /// Deletes one item permanently.
  Future<void> deletePermanently(TrashItem item) async {
    final dir = Directory(p.join(trashDir, item.id));
    if (await dir.exists() && SafePath.isWithin(trashDir, dir.path)) await dir.delete(recursive: true);
    await _deleteRecord(item);
  }

  /// Empties the trash. Returns (items, bytes) removed.
  Future<(int, int)> empty() async {
    final items = await list();
    var bytes = 0;
    for (final i in items) {
      await deletePermanently(i);
      bytes += i.bytes;
    }
    // Remove leftovers (damaged records, orphaned folders).
    final dir = Directory(trashDir);
    if (await dir.exists()) await dir.delete(recursive: true);
    return (items.length, bytes);
  }

  Future<void> _deleteRecord(TrashItem item) async {
    final record = File(p.join(trashDir, '${item.id}.json'));
    if (await record.exists()) await record.delete();
    final dir = Directory(p.join(trashDir, item.id));
    if (await dir.exists()) {
      // Remove the now-empty skeleton of parent folders (only when nothing
      // but folders is left inside).
      final leftovers = await dir.list(recursive: true, followLinks: false).where((e) => e is! Directory).length;
      if (leftovers == 0) await dir.delete(recursive: true);
    }
  }
}
