import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../../core/storage/atomic_file.dart';
import '../../../core/tasks/cancellation.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/safe_path.dart';
import '../domain/glob.dart';
import '../domain/rename_plan.dart';
import 'fs_walker.dart';

/// One rename recorded in a journal (paths relative to the workspace root).
class RenameJournalEntry {
  RenameJournalEntry({
    required this.dir,
    required this.from,
    required this.to,
    required this.temp,
    this.size,
    this.modifiedMs,
    this.done = false,
  });

  final String dir;
  final String from;
  final String to;

  /// Temporary name used between the two phases.
  final String temp;
  int? size;
  int? modifiedMs;
  bool done;

  Map<String, Object?> toJson() => {
    'dir': dir,
    'from': from,
    'to': to,
    'temp': temp,
    'size': size,
    'modifiedMs': modifiedMs,
    'done': done,
  };

  static RenameJournalEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final dir = raw['dir'], from = raw['from'], to = raw['to'], temp = raw['temp'];
    if (dir is! String || from is! String || to is! String || temp is! String) return null;
    return RenameJournalEntry(
      dir: dir,
      from: from,
      to: to,
      temp: temp,
      size: raw['size'] is int ? raw['size'] as int : null,
      modifiedMs: raw['modifiedMs'] is int ? raw['modifiedMs'] as int : null,
      done: raw['done'] == true,
    );
  }
}

enum JournalStatus { applying, applied, rolledBack, failed, undone, partiallyUndone }

/// A batch rename journal stored as `<meta>/renames/<stamp>.json`.
class RenameJournal {
  RenameJournal({
    required this.file,
    required this.createdAt,
    required this.root,
    required this.entries,
    this.status = JournalStatus.applying,
    this.note,
  });

  final String file;
  final DateTime createdAt;
  final String root;
  final List<RenameJournalEntry> entries;
  JournalStatus status;
  String? note;

  String get id => p.basenameWithoutExtension(file);
  bool get canUndo =>
      status == JournalStatus.applied ||
      status == JournalStatus.applying ||
      status == JournalStatus.partiallyUndone ||
      status == JournalStatus.failed;

  Map<String, Object?> toJson() => {
    'format': 'j3renames',
    'version': 1,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'root': root,
    'status': status.name,
    'note': note,
    'entries': [for (final e in entries) e.toJson()],
  };

  Future<void> save() => atomicWriteString(file, prettyJson.convert(toJson()));

  static Future<RenameJournal?> load(String file) async {
    try {
      final j = jsonDecode(await File(file).readAsString());
      if (j is! Map || j['format'] != 'j3renames') return null;
      final created = DateTime.tryParse('${j['createdAt']}');
      final root = j['root'];
      final list = j['entries'];
      if (created == null || root is! String || list is! List) return null;
      return RenameJournal(
        file: file,
        createdAt: created,
        root: root,
        entries: [for (final e in list) ?RenameJournalEntry.fromJson(e)],
        status: JournalStatus.values.firstWhere((s) => s.name == j['status'], orElse: () => JournalStatus.failed),
        note: j['note'] is String ? j['note'] as String : null,
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }
}

class RenameResult {
  RenameResult(this.journal);
  final RenameJournal journal;
  int renamed = 0;
  final List<String> skipped = [];
}

/// Applies rename plans safely:
/// * phase 1 moves every source to a unique temporary name in its folder,
/// * phase 2 moves every temporary name to its final name.
/// This handles swaps (a <-> b), chains and case-only renames on
/// case-insensitive file systems. The journal is written before anything
/// moves and after every step, so an interrupted run can be undone. On
/// failure everything already moved is put back.
class RenameExecutor {
  RenameExecutor({required this.root, required this.metaDir, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final String root;
  final String metaDir;
  final DateTime Function() _clock;
  static final Random _rng = Random();

  String get journalDir => p.join(metaDir, 'renames');

  String _abs(String dir, String name) => p.joinAll([root, ...dir.split('/').where((s) => s.isNotEmpty), name]);

  String _tempName(int i) => '.j3tmp-${_rng.nextInt(1 << 32).toRadixString(16)}-$i';

  Future<RenameResult> apply(
    List<RenameRow> rows, {
    CancellationToken? token,
    void Function(int done, int total)? onProgress,
  }) async {
    final changes = rows.where((r) => r.changes).toList();
    if (rows.any((r) => r.status.blocks)) {
      throw StateError('Fix collisions and invalid names before applying');
    }
    // Verify the plan against the disk right now.
    for (final r in changes) {
      final src = _abs(r.item.dir, r.item.name);
      if (FileSystemEntity.typeSync(src, followLinks: false) != FileSystemEntityType.file) {
        throw FileSystemException('File is gone or is no longer a regular file; rescan the folder', src);
      }
      SafePath.resolveInside(root, r.newRelativePath);
    }
    final now = _clock();
    await Directory(journalDir).create(recursive: true);
    final journalFile = SafePath.uniquePath(p.join(journalDir, '${Fmt.stamp(now)}.json'));
    final entries = <RenameJournalEntry>[];
    for (var i = 0; i < changes.length; i++) {
      final r = changes[i];
      var temp = _tempName(i);
      while (FileSystemEntity.typeSync(_abs(r.item.dir, temp), followLinks: false) != FileSystemEntityType.notFound) {
        temp = _tempName(i);
      }
      entries.add(RenameJournalEntry(dir: r.item.dir, from: r.item.name, to: r.newName, temp: temp));
    }
    final journal = RenameJournal(file: journalFile, createdAt: now, root: root, entries: entries);
    await journal.save();
    final result = RenameResult(journal);
    final total = entries.length * 2;
    var step = 0;
    final phase1 = <RenameJournalEntry>[];
    final phase2 = <RenameJournalEntry>[];
    try {
      for (final e in entries) {
        token?.throwIfCancelled();
        await File(_abs(e.dir, e.from)).rename(_abs(e.dir, e.temp));
        phase1.add(e);
        onProgress?.call(++step, total);
      }
      for (final e in entries) {
        token?.throwIfCancelled();
        final target = _abs(e.dir, e.to);
        if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
          throw FileSystemException('Target appeared while renaming (another program?)', target);
        }
        await File(_abs(e.dir, e.temp)).rename(target);
        phase2.add(e);
        final st = await File(target).stat();
        e
          ..done = true
          ..size = st.size
          ..modifiedMs = st.modified.millisecondsSinceEpoch;
        onProgress?.call(++step, total);
      }
      journal.status = JournalStatus.applied;
      await journal.save();
      result.renamed = entries.length;
      return result;
    } catch (error) {
      final problems = await _rollback(phase1, phase2);
      for (final e in entries) {
        e.done = false;
      }
      journal
        ..status = problems.isEmpty ? JournalStatus.rolledBack : JournalStatus.failed
        ..note = problems.isEmpty
            ? 'Rolled back after: $error'
            : 'Rollback incomplete after: $error. Check: ${problems.join('; ')}';
      await journal.save();
      rethrow;
    }
  }

  Future<List<String>> _rollback(List<RenameJournalEntry> phase1, List<RenameJournalEntry> phase2) async {
    final problems = <String>[];
    for (final e in phase2.reversed) {
      try {
        await File(_abs(e.dir, e.to)).rename(_abs(e.dir, e.temp));
      } on FileSystemException catch (err) {
        problems.add('${e.dir}/${e.to}: ${err.message}');
      }
    }
    for (final e in phase1.reversed) {
      try {
        await File(_abs(e.dir, e.temp)).rename(_abs(e.dir, e.from));
      } on FileSystemException catch (err) {
        problems.add('${e.dir}/${e.temp}: ${err.message}');
      }
    }
    return problems;
  }

  /// Journals, newest first.
  Future<List<RenameJournal>> journals({int limit = 20}) async {
    final dir = Directory(journalDir);
    if (!await dir.exists()) return const [];
    final files = await dir.list().where((e) => e is File && e.path.endsWith('.json')).map((e) => e.path).toList();
    files.sort((a, b) => p.basename(b).compareTo(p.basename(a)));
    final out = <RenameJournal>[];
    for (final f in files.take(limit)) {
      final j = await RenameJournal.load(f);
      if (j != null) out.add(j);
    }
    return out;
  }

  /// Reverses a journal. Each file must still be where the journal left it
  /// (same name, size and modification time) and its original name must be
  /// free; files that moved or changed are skipped and reported, never
  /// forced. Uses the same two-phase technique as [apply].
  Future<RenameResult> undo(RenameJournal journal, {CancellationToken? token}) async {
    if (!p.equals(p.normalize(journal.root), p.normalize(root))) {
      throw StateError('This journal belongs to another workspace folder (${journal.root})');
    }
    final result = RenameResult(journal);
    final movable = <RenameJournalEntry>[];
    final sourceOf = <RenameJournalEntry, String>{};
    for (final e in journal.entries) {
      final atTarget = _abs(e.dir, e.to);
      final atTemp = _abs(e.dir, e.temp);
      if (e.done && await _matches(atTarget, e)) {
        movable.add(e);
        sourceOf[e] = e.to;
      } else if (FileSystemEntity.typeSync(atTemp, followLinks: false) == FileSystemEntityType.file) {
        // Interrupted run: the file is still under its temporary name.
        movable.add(e);
        sourceOf[e] = e.temp;
      } else {
        result.skipped.add(
          '${e.dir.isEmpty ? '' : '${e.dir}/'}${e.to}: not where the rename left it (moved, deleted or edited)',
        );
      }
    }
    // Original names must be free (or be freed by this undo).
    final freed = {for (final e in movable) SafePath.collisionKey('${e.dir}/${sourceOf[e]}')};
    final ready = <RenameJournalEntry>[];
    for (final e in movable) {
      final original = _abs(e.dir, e.from);
      final key = SafePath.collisionKey('${e.dir}/${e.from}');
      if (FileSystemEntity.typeSync(original, followLinks: false) != FileSystemEntityType.notFound &&
          !freed.contains(key)) {
        result.skipped.add(
          '${e.dir.isEmpty ? '' : '${e.dir}/'}${e.from}: the original name is taken by another file now',
        );
      } else {
        ready.add(e);
      }
    }
    final moved = <(RenameJournalEntry, String)>[];
    try {
      for (final e in ready) {
        token?.throwIfCancelled();
        var temp = _tempName(0);
        while (FileSystemEntity.typeSync(_abs(e.dir, temp), followLinks: false) != FileSystemEntityType.notFound) {
          temp = _tempName(0);
        }
        await File(_abs(e.dir, sourceOf[e]!)).rename(_abs(e.dir, temp));
        moved.add((e, temp));
      }
      final restored = <(RenameJournalEntry, String)>[];
      for (final (e, temp) in moved) {
        final original = _abs(e.dir, e.from);
        // rename() silently replaces files on most platforms: never let it.
        if (FileSystemEntity.typeSync(original, followLinks: false) != FileSystemEntityType.notFound) {
          throw FileSystemException('The original name was taken while undoing', original);
        }
        await File(_abs(e.dir, temp)).rename(original);
        restored.add((e, temp));
        e.done = false;
        result.renamed++;
      }
      moved.removeWhere((m) => restored.contains(m));
    } catch (error) {
      // Put anything still under a temporary name back where it was.
      for (final (e, temp) in moved) {
        final t = _abs(e.dir, temp);
        if (File(t).existsSync()) {
          try {
            await File(t).rename(_abs(e.dir, sourceOf[e]!));
          } on FileSystemException {
            result.skipped.add('${e.dir}/$temp: left under a temporary name');
          }
        }
      }
      journal
        ..status = result.renamed > 0 ? JournalStatus.partiallyUndone : journal.status
        ..note = 'Undo stopped: $error';
      await journal.save();
      rethrow;
    }
    journal
      ..status = result.skipped.isEmpty ? JournalStatus.undone : JournalStatus.partiallyUndone
      ..note = result.skipped.isEmpty ? null : 'Skipped: ${result.skipped.join('; ')}';
    await journal.save();
    return result;
  }

  Future<bool> _matches(String path, RenameJournalEntry e) async {
    try {
      if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.file) return false;
      final st = await File(path).stat();
      if (e.size != null && st.size != e.size) return false;
      if (e.modifiedMs != null && st.modified.millisecondsSinceEpoch != e.modifiedMs) return false;
      return true;
    } on FileSystemException {
      return false;
    }
  }
}

/// Files to rename plus the names already present in every involved folder.
class RenameScan {
  const RenameScan({required this.items, required this.existing, required this.skippedLinks});
  final List<RenameItem> items;
  final Map<String, List<String>> existing;
  final int skippedLinks;
}

abstract final class RenameScanner {
  /// Scans [folder] (absolute, inside [root]) for regular files matching
  /// [filter] (glob, empty = all). Hidden files are skipped unless
  /// [includeHidden]. Links are never followed or renamed.
  static Future<RenameScan> scan({
    required String root,
    required String folder,
    bool recursive = false,
    String filter = '',
    bool includeHidden = false,
    CancellationToken? token,
    int maxFiles = 20000,
  }) async {
    if (!SafePath.isWithin(root, folder)) {
      throw FileSystemException('Folder is outside the workspace', folder);
    }
    final glob = filter.trim().isEmpty ? null : Glob(filter.trim(), caseSensitive: false);
    final items = <RenameItem>[];
    final dirs = <String>{};
    final stats = WalkStats();
    await for (final e in FsWalker.walk(
      folder,
      recursive: recursive,
      includeHidden: includeHidden,
      token: token,
      stats: stats,
    )) {
      if (glob != null && !glob.matches(e.relative)) continue;
      if (items.length >= maxFiles) {
        throw FileSystemException('More than $maxFiles files; narrow the folder or filter', folder);
      }
      final relToRoot = FsWalker.relativeOf(root, e.path);
      final slash = relToRoot.lastIndexOf('/');
      final dir = slash < 0 ? '' : relToRoot.substring(0, slash);
      DateTime modified;
      try {
        modified = await File(e.path).lastModified();
      } on FileSystemException {
        modified = DateTime.fromMillisecondsSinceEpoch(0);
      }
      items.add(RenameItem(dir: dir, name: e.name, modified: modified, parentName: p.basename(p.dirname(e.path))));
      dirs.add(dir);
    }
    final existing = <String, List<String>>{};
    for (final d in dirs) {
      final abs = p.joinAll([root, ...d.split('/').where((s) => s.isNotEmpty)]);
      existing[d] = await Directory(abs).list(followLinks: false).map((e) => p.basename(e.path)).toList();
    }
    return RenameScan(items: items, existing: existing, skippedLinks: stats.skippedLinks);
  }
}
