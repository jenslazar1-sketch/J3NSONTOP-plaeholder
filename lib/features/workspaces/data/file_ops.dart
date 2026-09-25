import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/tasks/cancellation.dart';
import '../../../core/utils/safe_path.dart';
import '../domain/fs_errors.dart';
import 'fs_walker.dart';

/// Result of copying a tree.
class CopyReport {
  int files = 0;
  int bytes = 0;
  final List<String> written = [];
  final List<String> skipped = [];
  final List<String> failed = [];

  List<String> get problems => [...skipped, ...failed];
}

/// Low-level file operations with cancellation, progress and cleanup of
/// partial output. All failures surface as [FileSystemException] (or
/// [OperationCancelled]); callers turn them into readable text with
/// `describeError`.
abstract final class FileOps {
  static const int _chunk = 1 << 20;

  /// Copies [source] to [target] (which must not exist) through a
  /// `.j3part` temp file, so an interrupted copy never leaves a truncated
  /// file under the final name. Preserves the modification time.
  static Future<int> copyFile(
    String source,
    String target, {
    CancellationToken? token,
    void Function(int bytesSoFar)? onBytes,
  }) async {
    if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
      throw FileSystemException('Refusing to overwrite an existing file', target);
    }
    await Directory(p.dirname(target)).create(recursive: true);
    final part = '$target.j3part';
    final src = File(source);
    final modified = await src.lastModified();
    final raf = await File(part).open(mode: FileMode.write);
    var done = 0;
    try {
      final input = await src.open();
      try {
        while (true) {
          token?.throwIfCancelled();
          final chunk = await input.read(_chunk);
          if (chunk.isEmpty) break;
          await raf.writeFrom(chunk);
          done += chunk.length;
          onBytes?.call(done);
        }
      } finally {
        await input.close();
      }
      await raf.flush();
      await raf.close();
    } catch (_) {
      try {
        await raf.close();
      } catch (_) {
        // Already closed or the handle is broken; removing the part file is what matters.
      }
      await _deleteQuietly(part);
      rethrow;
    }
    try {
      await File(part).rename(target);
    } catch (_) {
      await _deleteQuietly(part);
      rethrow;
    }
    try {
      await File(target).setLastModified(modified);
    } on FileSystemException {
      // Timestamps are best effort (some mobile storage refuses them).
    }
    return done;
  }

  static Future<void> _deleteTreeQuietly(String dir) async {
    try {
      final d = Directory(dir);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {
      // Best-effort cleanup of our own partial copy.
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // Best-effort cleanup.
    }
  }

  /// Copies every regular file below [sourceDir] into [targetDir],
  /// preserving the folder structure. Symbolic links are skipped (and
  /// reported), existing files are never overwritten (a unique name is
  /// used and reported). Stops at the first "storage full" error because
  /// every following file would fail too.
  static Future<CopyReport> copyTree(
    String sourceDir,
    String targetDir, {
    CancellationToken? token,
    void Function(int files, int bytes, String current)? onProgress,
    bool includeHidden = true,
  }) async {
    final report = CopyReport();
    final stats = WalkStats();
    await Directory(targetDir).create(recursive: true);
    await for (final e in FsWalker.walk(sourceDir, token: token, stats: stats, includeHidden: includeHidden)) {
      token?.throwIfCancelled();
      final String dest;
      try {
        dest = SafePath.resolveInside(targetDir, e.relative);
      } on UnsafePathException catch (err) {
        report.skipped.add('${e.relative}: ${err.reason}');
        continue;
      }
      var finalDest = dest;
      if (FileSystemEntity.typeSync(dest, followLinks: false) != FileSystemEntityType.notFound) {
        finalDest = SafePath.uniquePath(dest);
        report.skipped.add('${e.relative}: already existed, imported as ${p.basename(finalDest)}');
      }
      try {
        final base = report.bytes;
        final n = await copyFile(
          e.path,
          finalDest,
          token: token,
          onBytes: (b) => onProgress?.call(report.files, base + b, e.relative),
        );
        report.files++;
        report.bytes += n;
        report.written.add(finalDest);
        onProgress?.call(report.files, report.bytes, e.relative);
      } on FileSystemException catch (err) {
        if (classifyFsError(err) == FsProblem.noSpace) rethrow;
        report.failed.add('${e.relative}: ${describeError(err).message}');
      }
    }
    if (stats.skippedLinks > 0) {
      report.skipped.add('${stats.skippedLinks} symbolic link(s) were not followed or copied');
    }
    for (final u in stats.unreadable) {
      report.failed.add('unreadable folder $u');
    }
    return report;
  }

  /// Moves a file, folder or link. Uses rename when possible and falls
  /// back to copy + delete when the target is on another drive.
  static Future<void> move(String source, String target, {CancellationToken? token}) async {
    if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
      throw FileSystemException('Target already exists', target);
    }
    await Directory(p.dirname(target)).create(recursive: true);
    final type = FileSystemEntity.typeSync(source, followLinks: false);
    try {
      switch (type) {
        case FileSystemEntityType.directory:
          await Directory(source).rename(target);
        case FileSystemEntityType.link:
          await Link(source).rename(target);
        case FileSystemEntityType.notFound:
          throw FileSystemException('Source does not exist', source);
        default:
          await File(source).rename(target);
      }
      return;
    } on FileSystemException catch (e) {
      final code = e.osError?.errorCode;
      final crossDevice = classifyFsError(e) == FsProblem.crossDevice || code == 18 || code == 17;
      if (!crossDevice || type == FileSystemEntityType.link) rethrow;
    }
    // Cross-device: copy, then delete the source only after a full copy.
    if (type == FileSystemEntityType.directory) {
      CopyReport report;
      try {
        report = await copyTree(source, target, token: token);
      } catch (_) {
        await _deleteTreeQuietly(target);
        rethrow;
      }
      // Anything not copied (unreadable files, symbolic links) would be lost
      // by deleting the source, so the source is kept and the copy removed.
      if (report.failed.isNotEmpty || report.skipped.isNotEmpty) {
        await _deleteTreeQuietly(target);
        final why = [...report.failed, ...report.skipped].first;
        throw FileSystemException('Could not move everything to the other drive ($why); nothing was moved', source);
      }
      await Directory(source).delete(recursive: true);
    } else {
      await copyFile(source, target, token: token);
      await File(source).delete();
    }
  }

  /// Renames within the same folder, handling case-only changes on
  /// case-insensitive file systems via a temporary name.
  static Future<String> renameInPlace(String path, String newName) async {
    final target = p.join(p.dirname(path), newName);
    final caseOnly = p.basename(path) != newName && p.basename(path).toLowerCase() == newName.toLowerCase();
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    Future<FileSystemEntity> ren(String from, String to) => switch (type) {
      FileSystemEntityType.directory => Directory(from).rename(to),
      FileSystemEntityType.link => Link(from).rename(to),
      _ => File(from).rename(to),
    };
    if (type == FileSystemEntityType.notFound) throw FileSystemException('No longer exists', path);
    if (caseOnly) {
      final tmp = SafePath.uniquePath(
        p.join(p.dirname(path), '.j3tmp-rename-${DateTime.now().microsecondsSinceEpoch}'),
      );
      await ren(path, tmp);
      try {
        await ren(tmp, target);
      } catch (_) {
        await ren(tmp, path);
        rethrow;
      }
      return target;
    }
    if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
      throw FileSystemException('A file or folder with this name already exists', target);
    }
    await ren(path, target);
    return target;
  }
}
