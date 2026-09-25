import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/tasks/cancellation.dart';
import 'glob.dart';

/// A regular file found by [walkFolder].
class WalkedFile {
  const WalkedFile({required this.path, required this.relativePath, required this.size, required this.modified});

  /// Absolute path.
  final String path;

  /// Path relative to the scanned root, forward slashes.
  final String relativePath;
  final int size;
  final DateTime modified;
}

/// Outcome of a folder walk.
class WalkResult {
  const WalkResult({
    required this.root,
    required this.files,
    required this.skippedLinks,
    required this.unreadable,
    required this.filteredOut,
    required this.tooSmall,
    required this.truncated,
    required this.folders,
  });

  final String root;

  /// Accepted files, sorted by relative path.
  final List<WalkedFile> files;

  /// Symbolic links (and Windows junctions) that were not followed.
  final List<String> skippedLinks;

  /// Paths that could not be listed or stat'ed, with the reason.
  final List<(String, String)> unreadable;

  /// Files rejected by the include/exclude filter.
  final int filteredOut;

  /// Files below the minimum size.
  final int tooSmall;

  /// True when [maxFiles] was reached and the walk stopped early.
  final bool truncated;
  final int folders;

  int get totalBytes => files.fold(0, (s, f) => s + f.size);
}

/// Converts an absolute path below [root] to a forward-slash relative path.
String relativeSlash(String path, String root) => p.relative(path, from: root).replaceAll('\\', '/');

/// Walks [root] recursively without following symbolic links (so link
/// loops are impossible), applying [filter] and [minSize].
///
/// Folders are listed one at a time with asynchronous I/O, so the walk never
/// blocks the UI. [onProgress] receives the number of files seen so far.
Future<WalkResult> walkFolder(
  String root, {
  GlobFilter filter = GlobFilter.all,
  int minSize = 0,
  int? maxFiles,
  CancellationToken? token,
  void Function(int filesSeen, String currentFolder)? onProgress,
}) async {
  final absRoot = p.normalize(p.absolute(root));
  final rootType = await FileSystemEntity.type(absRoot, followLinks: false);
  if (rootType != FileSystemEntityType.directory) {
    throw FileSystemException('Not a folder', absRoot);
  }
  final files = <WalkedFile>[];
  final links = <String>[];
  final unreadable = <(String, String)>[];
  var filtered = 0;
  var small = 0;
  var seen = 0;
  var folders = 0;
  var truncated = false;
  // Real paths of visited folders: defence in depth against loops through
  // mount points or junctions reported as plain directories.
  final visited = <String>{};
  final stack = <String>[absRoot];

  outer:
  while (stack.isNotEmpty) {
    token?.throwIfCancelled();
    final dir = stack.removeLast();
    String real;
    try {
      real = await Directory(dir).resolveSymbolicLinks();
    } on FileSystemException catch (e) {
      unreadable.add((relativeSlash(dir, absRoot), e.osError?.message ?? e.message));
      continue;
    }
    if (!visited.add(real)) continue;
    folders++;
    final List<FileSystemEntity> entries;
    try {
      entries = await Directory(dir).list(followLinks: false).toList();
    } on FileSystemException catch (e) {
      unreadable.add((dir == absRoot ? '.' : relativeSlash(dir, absRoot), e.osError?.message ?? e.message));
      continue;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    final subdirs = <String>[];
    for (final e in entries) {
      final rel = relativeSlash(e.path, absRoot);
      if (e is Link) {
        links.add(rel);
        continue;
      }
      if (e is Directory) {
        if (filter.entersFolder(rel)) subdirs.add(e.path);
        continue;
      }
      if (e is! File) continue;
      seen++;
      if (!filter.acceptsFile(rel)) {
        filtered++;
        continue;
      }
      FileStat st;
      try {
        st = await e.stat();
      } on FileSystemException catch (err) {
        unreadable.add((rel, err.osError?.message ?? err.message));
        continue;
      }
      if (st.type != FileSystemEntityType.file) {
        // Replaced by something else since listing (or a special file).
        continue;
      }
      if (st.size < minSize) {
        small++;
        continue;
      }
      files.add(WalkedFile(path: e.path, relativePath: rel, size: st.size, modified: st.modified));
      if (maxFiles != null && files.length >= maxFiles) {
        truncated = true;
        break outer;
      }
    }
    // Depth-first in sorted order.
    stack.addAll(subdirs.reversed);
    // Every listing and stat above is real asynchronous I/O, so the UI keeps
    // rendering between folders.
    onProgress?.call(seen, dir == absRoot ? '.' : relativeSlash(dir, absRoot));
  }
  files.sort((a, b) => a.relativePath.compareTo(b.relativePath));
  return WalkResult(
    root: absRoot,
    files: files,
    skippedLinks: links,
    unreadable: unreadable,
    filteredOut: filtered,
    tooSmall: small,
    truncated: truncated,
    folders: folders,
  );
}
