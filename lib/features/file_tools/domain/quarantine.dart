import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/storage/atomic_file.dart';
import '../../../core/tasks/cancellation.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/hashing.dart';
import '../../../core/utils/safe_path.dart';

/// A duplicate copy to move out of the way.
class QuarantineRequest {
  const QuarantineRequest({
    required this.relativePath,
    required this.keeperRelativePath,
    required this.size,
    required this.digest,
  });

  /// Copy to move, relative to the workspace root.
  final String relativePath;

  /// The file that stays; it must still exist with the same content.
  final String keeperRelativePath;
  final int size;

  /// SHA-256 of the content (from the scan).
  final String digest;
}

enum QuarantineState { pending, quarantined, restored, skipped, missing }

class QuarantineEntry {
  QuarantineEntry({
    required this.relativePath,
    required this.keeperRelativePath,
    required this.size,
    required this.digest,
    this.state = QuarantineState.pending,
    this.restoredAs,
    this.note,
    this.at,
  });

  final String relativePath;
  final String keeperRelativePath;
  final int size;
  final String digest;
  QuarantineState state;

  /// Relative path used when the original location was occupied on restore.
  String? restoredAs;
  String? note;
  DateTime? at;

  Map<String, dynamic> toJson() => {
    'path': relativePath,
    'keeper': keeperRelativePath,
    'size': size,
    'sha256': digest,
    'state': state.name,
    'restoredAs': ?restoredAs,
    'note': ?note,
    if (at != null) 'at': at!.toUtc().toIso8601String(),
  };

  static QuarantineEntry? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final path = j['path'];
    final keeper = j['keeper'];
    final size = j['size'];
    final digest = j['sha256'];
    if (path is! String || keeper is! String || size is! int || digest is! String) return null;
    final stateName = j['state'];
    return QuarantineEntry(
      relativePath: path,
      keeperRelativePath: keeper,
      size: size,
      digest: digest,
      state: QuarantineState.values.firstWhere((s) => s.name == stateName, orElse: () => QuarantineState.pending),
      restoredAs: j['restoredAs'] is String ? j['restoredAs'] as String : null,
      note: j['note'] is String ? j['note'] as String : null,
      at: j['at'] is String ? DateTime.tryParse(j['at'] as String) : null,
    );
  }
}

/// One "move to quarantine" action and its journal.
class QuarantineSession {
  QuarantineSession({
    required this.id,
    required this.createdAt,
    required this.workspaceId,
    required this.dir,
    required this.journalPath,
    required this.entries,
  });

  /// Timestamp id, e.g. `20260925-184107`.
  final String id;
  final DateTime createdAt;
  final String workspaceId;

  /// `<meta>/quarantine/<id>` holding the moved files at their relative paths.
  final String dir;

  /// `<meta>/quarantine/<id>.json`.
  final String journalPath;
  final List<QuarantineEntry> entries;

  Iterable<QuarantineEntry> get inQuarantine => entries.where((e) => e.state == QuarantineState.quarantined);
  int get quarantinedBytes => inQuarantine.fold(0, (s, e) => s + e.size);
  bool get fullyRestored => inQuarantine.isEmpty;

  String quarantinePathOf(QuarantineEntry e) => p.join(dir, SafePath.normalizeRelative(e.relativePath));

  Map<String, dynamic> toJson() => {
    'schema': 'j3nsontop.files.quarantine',
    'version': 1,
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'workspaceId': workspaceId,
    'entries': [for (final e in entries) e.toJson()],
  };
}

class QuarantineMoveResult {
  const QuarantineMoveResult({
    required this.session,
    required this.moved,
    required this.skipped,
    this.cancelled = false,
  });
  final QuarantineSession? session;
  final int moved;

  /// `(relative path, reason)`.
  final List<(String, String)> skipped;
  final bool cancelled;
  int get movedBytes => session?.inQuarantine.fold<int>(0, (s, e) => s + e.size) ?? 0;
}

class RestoreResult {
  const RestoreResult({required this.restored, required this.renamed, required this.failed});
  final int restored;

  /// `(original, restored as)` when the original path was occupied.
  final List<(String, String)> renamed;

  /// `(relative path, reason)`.
  final List<(String, String)> failed;
}

/// Reversible "delete": duplicate copies are moved to
/// `<meta>/quarantine/<stamp>/<relative path>` with a JSON journal next to
/// that folder, and can be restored at any time. Nothing is ever deleted
/// permanently by this class.
class QuarantineStore {
  QuarantineStore({
    required this.workspaceRoot,
    required this.metaDir,
    required this.workspaceId,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final String workspaceRoot;
  final String metaDir;
  final String workspaceId;
  final DateTime Function() _clock;

  String get root => p.join(metaDir, 'quarantine');

  /// Moves [from] to [to]. Uses rename; across volumes (linked folders on
  /// another drive) it copies, verifies the copy by SHA-256 and only then
  /// removes the original.
  static Future<void> moveFile(String from, String to) async {
    await Directory(p.dirname(to)).create(recursive: true);
    try {
      await File(from).rename(to);
      return;
    } on FileSystemException {
      // Fall through to copy + verify.
    }
    final tmp = '$to.j3part';
    final source = await Hashing.file(from);
    await File(from).copy(tmp);
    final copy = await Hashing.file(tmp);
    if (copy != source) {
      await File(tmp).delete();
      throw FileSystemException('Copy verification failed; the original was left in place', from);
    }
    await File(tmp).rename(to);
    await File(from).delete();
  }

  String _newId() {
    final base = Fmt.stamp(_clock());
    var id = base;
    var n = 2;
    while (Directory(p.join(root, id)).existsSync() || File(p.join(root, '$id.json')).existsSync()) {
      id = '$base-${n++}';
    }
    return id;
  }

  Future<void> _save(QuarantineSession s) async {
    await Directory(root).create(recursive: true);
    await atomicWriteString(s.journalPath, prettyJson.convert(s.toJson()));
  }

  String? _checkFile(String abs, int size) {
    final type = FileSystemEntity.typeSync(abs, followLinks: false);
    if (type == FileSystemEntityType.notFound) return 'no longer exists';
    if (type != FileSystemEntityType.file) return 'is not a regular file';
    if (File(abs).lengthSync() != size) return 'size changed since the scan';
    return null;
  }

  /// Moves the requested copies. Each copy and its keeper are re-checked
  /// first (still regular files, same size, same SHA-256), so a copy is
  /// never moved unless an identical keeper remains in place.
  Future<QuarantineMoveResult> quarantine(
    List<QuarantineRequest> requests, {
    CancellationToken? token,
    void Function(int done, int total, String current)? onProgress,
  }) async {
    final skipped = <(String, String)>[];
    final id = _newId();
    final s = QuarantineSession(
      id: id,
      createdAt: _clock(),
      workspaceId: workspaceId,
      dir: p.join(root, id),
      journalPath: p.join(root, '$id.json'),
      entries: [
        for (final r in requests)
          QuarantineEntry(
            relativePath: r.relativePath,
            keeperRelativePath: r.keeperRelativePath,
            size: r.size,
            digest: r.digest,
          ),
      ],
    );
    final selected = {for (final r in requests) SafePath.collisionKey(r.relativePath)};
    // Journal first: if the app stops mid-way, restore still finds files.
    await _save(s);
    final keeperOk = <String, String?>{};
    var moved = 0;
    var cancelled = false;
    for (var i = 0; i < s.entries.length; i++) {
      final e = s.entries[i];
      if (token?.isCancelled ?? false) {
        cancelled = true;
        for (final rest in s.entries.skip(i)) {
          rest
            ..state = QuarantineState.skipped
            ..note = 'cancelled';
        }
        break;
      }
      onProgress?.call(i, s.entries.length, e.relativePath);
      String? reason;
      String? abs;
      String? target;
      try {
        abs = SafePath.resolveInside(workspaceRoot, e.relativePath);
        target = p.join(s.dir, SafePath.normalizeRelative(e.relativePath));
        if (selected.contains(SafePath.collisionKey(e.keeperRelativePath))) {
          reason = 'its keeper is also selected';
        }
        reason ??= _checkFile(abs, e.size);
        if (reason == null) {
          final keeperKey = e.keeperRelativePath;
          if (!keeperOk.containsKey(keeperKey)) {
            final keeperAbs = SafePath.resolveInside(workspaceRoot, keeperKey);
            var kr = _checkFile(keeperAbs, e.size);
            if (kr == null && await Hashing.file(keeperAbs, token: token) != e.digest) {
              kr = 'content changed since the scan';
            }
            keeperOk[keeperKey] = kr == null ? null : 'keeper $kr';
          }
          reason = keeperOk[keeperKey];
        }
        if (reason == null && await Hashing.file(abs, token: token) != e.digest) {
          reason = 'content changed since the scan';
        }
      } on UnsafePathException catch (err) {
        reason = 'unsafe path: ${err.reason}';
      } on OperationCancelled {
        cancelled = true;
        for (final rest in s.entries.skip(i)) {
          rest
            ..state = QuarantineState.skipped
            ..note = 'cancelled';
        }
        break;
      } on FileSystemException catch (err) {
        reason = err.osError?.message ?? err.message;
      }
      if (reason != null) {
        e
          ..state = QuarantineState.skipped
          ..note = reason;
        skipped.add((e.relativePath, reason));
        continue;
      }
      try {
        await moveFile(abs!, target!);
        e
          ..state = QuarantineState.quarantined
          ..at = _clock();
        moved++;
      } on FileSystemException catch (err) {
        final why = err.osError?.message ?? err.message;
        e
          ..state = QuarantineState.skipped
          ..note = why;
        skipped.add((e.relativePath, why));
      }
      if (moved % 25 == 0) await _save(s);
    }
    await _save(s);
    onProgress?.call(s.entries.length, s.entries.length, '');
    if (moved == 0) {
      // Nothing was moved: keep the journal (it explains why) but no folder.
      await _pruneEmpty(s.dir);
    }
    return QuarantineMoveResult(session: s, moved: moved, skipped: skipped, cancelled: cancelled);
  }

  /// Journals of this workspace, newest first. Damaged journals are skipped.
  Future<List<QuarantineSession>> sessions() async {
    final dir = Directory(root);
    if (!await dir.exists()) return const [];
    final out = <QuarantineSession>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      try {
        final j = jsonDecode(await e.readAsString());
        if (j is! Map<String, dynamic> || j['schema'] != 'j3nsontop.files.quarantine') continue;
        final id = p.basenameWithoutExtension(e.path);
        out.add(
          QuarantineSession(
            id: id,
            createdAt: DateTime.tryParse('${j['createdAt']}')?.toLocal() ?? (await e.lastModified()),
            workspaceId: '${j['workspaceId'] ?? workspaceId}',
            dir: p.join(root, id),
            journalPath: e.path,
            entries: [
              for (final x in (j['entries'] is List ? j['entries'] as List : const <Object?>[]))
                ?QuarantineEntry.fromJson(x),
            ],
          ),
        );
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    out.sort((a, b) => b.id.compareTo(a.id));
    return out;
  }

  /// Moves quarantined files back to their original paths. If a path is
  /// occupied the file is restored next to it with a ` (2)` suffix; nothing
  /// is overwritten. [only] limits the restore to some relative paths.
  Future<RestoreResult> restore(QuarantineSession s, {Set<String>? only, CancellationToken? token}) async {
    var restored = 0;
    final renamed = <(String, String)>[];
    final failed = <(String, String)>[];
    for (final e in s.entries) {
      if (e.state != QuarantineState.quarantined && e.state != QuarantineState.pending) continue;
      if (only != null && !only.contains(e.relativePath)) continue;
      if (token?.isCancelled ?? false) break;
      try {
        final q = s.quarantinePathOf(e);
        if (FileSystemEntity.typeSync(q, followLinks: false) != FileSystemEntityType.file) {
          if (e.state == QuarantineState.quarantined) {
            e
              ..state = QuarantineState.missing
              ..note = 'no longer in quarantine';
            failed.add((e.relativePath, 'no longer in quarantine'));
          }
          continue;
        }
        var dest = SafePath.resolveInside(workspaceRoot, e.relativePath);
        if (FileSystemEntity.typeSync(dest, followLinks: false) != FileSystemEntityType.notFound) {
          dest = SafePath.uniquePath(dest);
          e.restoredAs = p.relative(dest, from: workspaceRoot).replaceAll('\\', '/');
          renamed.add((e.relativePath, e.restoredAs!));
        }
        await moveFile(q, dest);
        e
          ..state = QuarantineState.restored
          ..at = _clock();
        restored++;
      } on UnsafePathException catch (err) {
        failed.add((e.relativePath, err.reason));
      } on FileSystemException catch (err) {
        failed.add((e.relativePath, err.osError?.message ?? err.message));
      }
    }
    await _save(s);
    await _pruneEmpty(s.dir);
    return RestoreResult(restored: restored, renamed: renamed, failed: failed);
  }

  /// Removes empty folders inside [dir] (and [dir] itself when empty). Only
  /// ever deletes empty directories inside the quarantine root.
  Future<void> _pruneEmpty(String dir) async {
    if (!SafePath.isWithin(root, dir) || p.equals(root, dir)) return;
    final d = Directory(dir);
    if (!await d.exists()) return;
    final dirs = await d.list(recursive: true, followLinks: false).where((e) => e is Directory).toList();
    dirs.sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final sub in [...dirs, d]) {
      try {
        if (await (sub as Directory).list().isEmpty) await sub.delete();
      } on FileSystemException {
        // Not empty or not removable: leave it.
      }
    }
  }
}
