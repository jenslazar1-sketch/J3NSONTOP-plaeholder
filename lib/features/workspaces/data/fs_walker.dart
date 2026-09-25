import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/tasks/cancellation.dart';
import '../domain/file_types.dart';

/// One entry found by [FsWalker].
class WalkEntry {
  const WalkEntry({required this.path, required this.relative, required this.isDirectory});

  final String path;

  /// Relative to the walk root, forward slashes.
  final String relative;
  final bool isDirectory;

  String get name => p.basename(path);
}

/// Counters collected during a walk.
class WalkStats {
  int directories = 0;
  int files = 0;

  /// Symbolic links (and Windows junctions) are never followed.
  int skippedLinks = 0;
  int skippedHidden = 0;
  final List<String> unreadable = [];

  int get visited => directories + files;
}

/// Recursive directory walker that never follows symbolic links (so link
/// loops cannot hang it), skips unreadable folders instead of failing, and
/// honours cancellation between entries.
abstract final class FsWalker {
  static String relativeOf(String root, String path) => p.relative(path, from: root).replaceAll('\\', '/');

  static Stream<WalkEntry> walk(
    String root, {
    bool includeHidden = true,
    bool yieldDirectories = false,
    bool recursive = true,
    CancellationToken? token,
    WalkStats? stats,
  }) async* {
    final s = stats ?? WalkStats();
    final pending = <String>[root];
    while (pending.isNotEmpty) {
      token?.throwIfCancelled();
      final dir = pending.removeLast();
      final children = <FileSystemEntity>[];
      try {
        await for (final e in Directory(dir).list(followLinks: false)) {
          children.add(e);
        }
      } on FileSystemException catch (e) {
        s.unreadable.add('${relativeOf(root, dir)}: ${e.osError?.message ?? e.message}');
        continue;
      }
      children.sort((a, b) => a.path.compareTo(b.path));
      final subdirs = <String>[];
      for (final e in children) {
        token?.throwIfCancelled();
        final name = p.basename(e.path);
        if (!includeHidden && FileTypes.isHidden(name)) {
          s.skippedHidden++;
          continue;
        }
        if (e is Link) {
          s.skippedLinks++;
          continue;
        }
        if (e is Directory) {
          s.directories++;
          if (yieldDirectories) {
            yield WalkEntry(path: e.path, relative: relativeOf(root, e.path), isDirectory: true);
          }
          if (recursive) subdirs.add(e.path);
        } else if (e is File) {
          s.files++;
          yield WalkEntry(path: e.path, relative: relativeOf(root, e.path), isDirectory: false);
        }
      }
      // Depth-first, alphabetical: push in reverse so 'a' is visited first.
      pending.addAll(subdirs.reversed);
    }
  }

  /// Counts files and bytes below [dir] (links not followed).
  static Future<({int files, int bytes, int dirs})> measure(String dir, {CancellationToken? token}) async {
    var files = 0, bytes = 0;
    final stats = WalkStats();
    await for (final e in walk(dir, token: token, stats: stats)) {
      files++;
      try {
        bytes += await File(e.path).length();
      } on FileSystemException {
        // Unreadable size: still counted as a file.
      }
    }
    return (files: files, bytes: bytes, dirs: stats.directories);
  }
}
