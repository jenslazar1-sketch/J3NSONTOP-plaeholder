import 'dart:io';

import 'package:path/path.dart' as p;

import '../storage/atomic_file.dart';
import '../utils/format.dart';
import '../utils/safe_path.dart';
import 'workspace.dart';

/// Result of [WorkspaceFileWriter.replaceWithBackup].
class BackupWriteResult {
  const BackupWriteResult({required this.target, this.backupPath});
  final String target;

  /// Where the previous content was copied (null if the file was new).
  final String? backupPath;
}

/// Writes files inside a workspace, always backing up the previous content
/// first. Backups go to `<meta>/backups/<timestamp>/<relative path>` so the
/// user's folder is not littered and every replacement is recoverable.
class WorkspaceFileWriter {
  WorkspaceFileWriter({required this.workspace, required this.metaDir, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final Workspace workspace;
  final String metaDir;
  final DateTime Function() _clock;

  String get backupsRoot => p.join(metaDir, 'backups');

  /// Replaces [absolutePath] (must be inside the workspace) atomically after
  /// copying the old file to the backup area.
  Future<BackupWriteResult> replaceWithBackup(String absolutePath, List<int> bytes) async {
    if (!SafePath.isWithin(workspace.rootPath, absolutePath)) {
      throw FileSystemException('Refusing to write outside the workspace', absolutePath);
    }
    String? backup;
    final existing = File(absolutePath);
    if (await existing.exists()) {
      final rel = p.relative(absolutePath, from: workspace.rootPath);
      backup = p.join(backupsRoot, Fmt.stamp(_clock()), rel);
      backup = SafePath.uniquePath(backup);
      await Directory(p.dirname(backup)).create(recursive: true);
      await existing.copy(backup);
    }
    await atomicWriteBytes(absolutePath, bytes);
    return BackupWriteResult(target: absolutePath, backupPath: backup);
  }

  /// Lists backup snapshots (newest first).
  Future<List<Directory>> snapshots() async {
    final root = Directory(backupsRoot);
    if (!await root.exists()) return const [];
    final dirs = await root.list().where((e) => e is Directory).cast<Directory>().toList();
    dirs.sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
    return dirs;
  }
}
