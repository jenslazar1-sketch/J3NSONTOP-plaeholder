import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/tasks/cancellation.dart';

/// Size of a directory tree as measured by [measureBreakdown].
class StorageUsage {
  const StorageUsage({this.bytes = 0, this.files = 0, this.directories = 0, this.unreadable = 0, this.exists = true});

  static const StorageUsage missing = StorageUsage(exists: false);

  final int bytes;
  final int files;
  final int directories;

  /// Entries that could not be read (permission errors, files deleted while
  /// scanning). They are skipped, never guessed.
  final int unreadable;

  /// False when the directory does not exist (reported as 0 bytes).
  final bool exists;

  StorageUsage operator +(StorageUsage o) => StorageUsage(
    bytes: bytes + o.bytes,
    files: files + o.files,
    directories: directories + o.directories,
    unreadable: unreadable + o.unreadable,
    exists: exists || o.exists,
  );
}

/// Usage of a data directory split by its top-level entries.
class StorageBreakdown {
  const StorageBreakdown({required this.total, required this.byTopLevel});

  final StorageUsage total;

  /// Keyed by the first path segment below the root (`workspaces`, `cache`,
  /// ...). Files directly inside the root are collected under [rootFiles].
  final Map<String, StorageUsage> byTopLevel;

  static const String rootFiles = '.';

  StorageUsage of(String name) => byTopLevel[name] ?? const StorageUsage();

  /// Everything except the named top-level entries.
  StorageUsage excluding(Iterable<String> names) {
    final skip = names.toSet();
    var sum = const StorageUsage();
    byTopLevel.forEach((k, v) {
      if (!skip.contains(k)) sum = sum + v;
    });
    return sum;
  }
}

/// Walks [root] asynchronously (never blocking the UI isolate), sums the
/// sizes of regular files and attributes each to its top-level folder.
/// Symbolic links are not followed; unreadable entries are counted and
/// skipped. Checks [token] between entries and throws [OperationCancelled]
/// when cancelled; reports the running total through [onProgress] every
/// [progressEvery] files.
Future<StorageBreakdown> measureBreakdown(
  String root, {
  CancellationToken? token,
  void Function(StorageUsage partial)? onProgress,
  int progressEvery = 250,
}) async {
  final dir = Directory(root);
  if (!await dir.exists()) return const StorageBreakdown(total: StorageUsage.missing, byTopLevel: {});
  final buckets = <String, (int bytes, int files, int dirs)>{};
  var bytes = 0;
  var files = 0;
  var dirs = 0;
  var unreadable = 0;
  String bucketOf(String path) {
    final rel = p.split(p.relative(path, from: root));
    return rel.length <= 1 ? StorageBreakdown.rootFiles : rel.first;
  }

  final stream = dir.list(recursive: true, followLinks: false).handleError((Object _) => unreadable++);
  await for (final entity in stream) {
    token?.throwIfCancelled();
    if (entity is File) {
      try {
        final len = await entity.length();
        bytes += len;
        files++;
        final key = bucketOf(entity.path);
        final b = buckets[key] ?? (0, 0, 0);
        buckets[key] = (b.$1 + len, b.$2 + 1, b.$3);
        if (onProgress != null && files % progressEvery == 0) {
          onProgress(StorageUsage(bytes: bytes, files: files, directories: dirs, unreadable: unreadable));
        }
      } on FileSystemException {
        unreadable++;
      }
    } else if (entity is Directory) {
      dirs++;
      final rel = p.split(p.relative(entity.path, from: root));
      final key = rel.first;
      final b = buckets[key] ?? (0, 0, 0);
      buckets[key] = (b.$1, b.$2, rel.length == 1 ? b.$3 : b.$3 + 1);
    }
  }
  token?.throwIfCancelled();
  return StorageBreakdown(
    total: StorageUsage(bytes: bytes, files: files, directories: dirs, unreadable: unreadable),
    byTopLevel: {
      for (final e in buckets.entries)
        e.key: StorageUsage(bytes: e.value.$1, files: e.value.$2, directories: e.value.$3),
    },
  );
}
