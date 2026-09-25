import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../../core/archive/safe_zip.dart';
import '../../../core/platform/file_access.dart';
import '../../../core/tasks/cancellation.dart';
import '../../../core/utils/safe_path.dart';
import '../domain/fs_errors.dart';
import 'file_ops.dart';
import 'fs_walker.dart';

/// Result of exporting a workspace as ZIP.
class ZipExportResult {
  const ZipExportResult({required this.zipPath, required this.bytes, required this.files, required this.skipped});
  final String zipPath;
  final int bytes;
  final int files;

  /// Entries that could not be stored (links, non-portable names).
  final List<String> skipped;
}

/// App storage folder that no workspace record points to.
class OrphanStorage {
  const OrphanStorage({required this.id, required this.path, required this.files, required this.bytes});
  final String id;
  final String path;
  final int files;
  final int bytes;
}

/// Import/export of workspace content. Every copy is cancellable, reports
/// progress and never overwrites existing files (unique names are used).
abstract final class WorkspaceTransfer {
  /// Copies (or moves, when staged by us in [stagingDir]) picked files into
  /// [targetDir].
  static Future<CopyReport> importPicked(
    List<PickedLocalFile> files,
    String targetDir, {
    String? stagingDir,
    CancellationToken? token,
    void Function(int done, int total, String name)? onProgress,
  }) async {
    final report = CopyReport();
    await Directory(targetDir).create(recursive: true);
    try {
      for (var i = 0; i < files.length; i++) {
        token?.throwIfCancelled();
        final f = files[i];
        final name = SafePath.sanitizeFileName(f.name);
        var dest = p.join(targetDir, name);
        if (FileSystemEntity.typeSync(dest, followLinks: false) != FileSystemEntityType.notFound) {
          dest = SafePath.uniquePath(dest);
          report.skipped.add('$name already existed, imported as ${p.basename(dest)}');
        }
        onProgress?.call(i, files.length, name);
        try {
          final staged = stagingDir != null && SafePath.isWithin(stagingDir, f.path);
          if (staged) {
            await FileOps.move(f.path, dest, token: token);
            report.bytes += await File(dest).length();
          } else {
            report.bytes += await FileOps.copyFile(f.path, dest, token: token);
          }
          report.files++;
          report.written.add(dest);
        } on FileSystemException catch (e) {
          if (classifyFsError(e) == FsProblem.noSpace) rethrow;
          report.failed.add('$name: ${describeError(e).message}');
        }
        onProgress?.call(i + 1, files.length, name);
      }
    } finally {
      if (stagingDir != null) await _deleteDir(stagingDir);
    }
    return report;
  }

  /// Recursively copies a folder chosen with the system picker.
  static Future<CopyReport> importFolder(
    String sourceDir,
    String targetDir, {
    CancellationToken? token,
    void Function(int files, int bytes, String current)? onProgress,
  }) async {
    final type = FileSystemEntity.typeSync(sourceDir);
    if (type != FileSystemEntityType.directory) throw FileSystemException('Not a folder', sourceDir);
    return FileOps.copyTree(sourceDir, targetDir, token: token, onProgress: onProgress);
  }

  /// Validates an archive off the UI isolate.
  static Future<ZipInspection> inspectZip(String zipPath) => Isolate.run(() => SafeZip.inspect(zipPath));

  static Future<ZipExtractResult> extractZip(
    String zipPath,
    String targetDir, {
    CancellationToken? token,
    void Function(double fraction, String entry)? onProgress,
  }) => SafeZip.extract(zipPath, targetDir, existing: ExistingFilePolicy.skip, token: token, onProgress: onProgress);

  /// Zips every regular file of [root] into [outPath]. Links and names that
  /// are not portable (e.g. `aux.txt`, `a:b`) cannot be stored safely and
  /// are listed in [ZipExportResult.skipped] instead of failing the export.
  static Future<ZipExportResult> exportZip(
    String root,
    String outPath, {
    CancellationToken? token,
    void Function(double fraction, String message)? onProgress,
  }) async {
    final sources = <ZipSource>[];
    final skipped = <String>[];
    final seen = <String>{};
    final stats = WalkStats();
    await for (final e in FsWalker.walk(root, token: token, stats: stats)) {
      try {
        final rel = SafePath.normalizeRelative(e.relative);
        if (!seen.add(SafePath.collisionKey(rel))) {
          skipped.add('${e.relative}: differs from another file only by upper/lower case');
          continue;
        }
        sources.add(ZipSource.file(rel, e.path));
      } on UnsafePathException catch (err) {
        skipped.add('${e.relative}: ${err.reason}');
      }
      if (sources.length % 200 == 0) onProgress?.call(0, 'Collecting files (${sources.length})');
    }
    if (stats.skippedLinks > 0) skipped.add('${stats.skippedLinks} symbolic link(s) were not included');
    for (final u in stats.unreadable) {
      skipped.add('unreadable folder $u');
    }
    await Directory(p.dirname(outPath)).create(recursive: true);
    final size = await SafeZip.create(
      outPath,
      sources,
      token: token,
      onProgress: (f) => onProgress?.call(f, 'Compressing ${(f * 100).round()}%'),
    );
    return ZipExportResult(zipPath: outPath, bytes: size, files: sources.length, skipped: skipped);
  }

  /// Folders in app storage (`<workspacesDir>/<id>`) without a record.
  static Future<List<OrphanStorage>> findOrphans(String workspacesDir, Set<String> knownIds) async {
    final dir = Directory(workspacesDir);
    if (!await dir.exists()) return const [];
    final out = <OrphanStorage>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! Directory) continue;
      final id = p.basename(e.path);
      if (knownIds.contains(id)) continue;
      final m = await FsWalker.measure(e.path);
      out.add(OrphanStorage(id: id, path: e.path, files: m.files, bytes: m.bytes));
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  /// Moves the metadata folder of a workspace record to a new record.
  static Future<void> migrateMeta(String fromMeta, String toMeta) async {
    if (!await Directory(fromMeta).exists()) return;
    final target = Directory(toMeta);
    if (await target.exists()) {
      final hasContent = await target.list().isEmpty == false;
      if (hasContent) throw FileSystemException('The new workspace already has metadata', toMeta);
      await target.delete();
    }
    await FileOps.move(fromMeta, toMeta);
  }

  static Future<void> _deleteDir(String dir) async {
    try {
      final d = Directory(dir);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {
      // Staging cleanup is best effort.
    }
  }
}
