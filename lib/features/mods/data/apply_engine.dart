import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/archive/safe_zip.dart';
import '../../../core/storage/atomic_file.dart';
import '../../../core/tasks/cancellation.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/hashing.dart';
import '../../../core/utils/safe_path.dart';
import '../domain/plan.dart';
import 'journal.dart';

/// Another operation still affects the target (LIFO rule).
class ApplyBlocked implements Exception {
  const ApplyBlocked(this.blocking);
  final OperationJournal blocking;

  @override
  String toString() {
    final what = blocking.status.isInterrupted
        ? 'an interrupted operation (${blocking.status.label})'
        : 'an ${blocking.status == JournalStatus.failed ? 'incomplete' : 'applied'} operation';
    return 'The target "${blocking.targetRel}" has $what from profile "${blocking.profileName}" '
        '(${Fmt.dateTime(blocking.createdAt)}). Roll it back first.';
  }
}

/// A newer operation on the same target must be rolled back first.
class RollbackBlocked implements Exception {
  const RollbackBlocked(this.newer);
  final OperationJournal newer;

  @override
  String toString() =>
      'Only the most recent operation on a target can be rolled back. Roll back "${newer.profileName}" '
      '(${Fmt.dateTime(newer.createdAt)}) first.';
}

/// An apply step failed; the journal records the error.
class ApplyFailure implements Exception {
  const ApplyFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Test-only fault: thrown by [EngineFaults] to simulate the app being
/// killed. The engine does not catch it, so the journal stays exactly as it
/// was at that moment (e.g. status `applying`).
class SimulatedCrash implements Exception {
  const SimulatedCrash(this.where);
  final String where;
  @override
  String toString() => 'Simulated crash $where';
}

/// Fault injection for tests ("crash after N changes").
class EngineFaults {
  const EngineFaults({this.crashAfterStagedFiles, this.crashAfterApplyChanges, this.crashAfterRollbackSteps});

  static const EngineFaults none = EngineFaults();

  final int? crashAfterStagedFiles;
  final int? crashAfterApplyChanges;
  final int? crashAfterRollbackSteps;
}

class ApplyOutcome {
  const ApplyOutcome({
    required this.journal,
    required this.created,
    required this.overwritten,
    required this.unchanged,
    required this.dirsCreated,
    required this.bytesWritten,
  });

  /// Null when the plan had nothing to write (no operation recorded).
  final OperationJournal? journal;
  final int created;
  final int overwritten;
  final int unchanged;
  final int dirsCreated;
  final int bytesWritten;

  bool get nothingToDo => journal == null;

  String get summary => nothingToDo
      ? 'Already up to date: $unchanged file(s) identical, nothing written'
      : '${Fmt.count(created, 'file')} created, ${Fmt.count(overwritten, 'file')} overwritten, '
            '$unchanged unchanged, ${Fmt.count(dirsCreated, 'folder')} created';
}

enum ConflictKind {
  /// The file differs from both the applied and the original content.
  edited('Edited after applying'),

  /// The file the operation overwrote was deleted.
  deleted('Deleted after applying');

  const ConflictKind(this.label);
  final String label;
}

enum ConflictDecision {
  /// Leave the user's version in place (default).
  keepUserEdit,

  /// Save the user's version next to the backup, then restore the original
  /// (or remove a created file).
  restoreOriginal,
}

class RollbackConflict {
  const RollbackConflict({required this.change, required this.kind});
  final JournalChange change;
  final ConflictKind kind;
  String get path => change.path;
}

enum _RollbackAction {
  restore,
  delete,
  alreadyOriginal,
  alreadyAbsent,
  untouched,
  conflictEdited,
  conflictDeleted,
  notAFile,
}

class RollbackPreview {
  const RollbackPreview({
    required this.journal,
    required this.blockedBy,
    required this.conflicts,
    required this.toRestore,
    required this.toDelete,
    required this.nothingToDo,
    required this.problems,
  });

  final OperationJournal journal;

  /// A newer open operation on an overlapping target (LIFO).
  final OperationJournal? blockedBy;
  final List<RollbackConflict> conflicts;
  final int toRestore;
  final int toDelete;
  final int nothingToDo;

  /// Paths that cannot be handled (e.g. replaced by a folder).
  final List<String> problems;

  bool get isBlocked => blockedBy != null;
}

class RollbackOutcome {
  const RollbackOutcome({required this.journal, required this.problems});
  final OperationJournal journal;
  final List<String> problems;

  int count(RollbackResult r) => journal.rollbackCounts[r] ?? 0;
  int get restored => count(RollbackResult.restored);
  int get deleted => count(RollbackResult.deleted);
  int get keptUserEdits => count(RollbackResult.keptUserEdit);
  int get restoredAfterSavingEdit =>
      count(RollbackResult.restoredAfterSavingEdit) + count(RollbackResult.removedAfterSavingEdit);
  int get dirsRemoved => journal.removedDirs.length;
  int get dirsKept => journal.keptDirs.length;

  String get summary =>
      '$restored restored, $deleted removed, ${Fmt.count(dirsRemoved, 'folder')} removed'
      '${keptUserEdits > 0 ? ', $keptUserEdits edit(s) kept' : ''}'
      '${restoredAfterSavingEdit > 0 ? ', $restoredAfterSavingEdit edit(s) saved then reverted' : ''}'
      '${problems.isNotEmpty ? ', ${problems.length} problem(s)' : ''}';
}

/// A journal folder that could not be read.
class DamagedJournal {
  const DamagedJournal(this.directory, this.error);
  final String directory;
  final String error;
}

class OperationsListing {
  const OperationsListing(this.journals, this.damaged);
  final List<OperationJournal> journals;
  final List<DamagedJournal> damaged;

  List<OperationJournal> get interrupted => journals.where((j) => j.status.isInterrupted).toList();
}

class _FileState {
  const _FileState.missing() : exists = false, isFile = false, sha = null;
  const _FileState.other() : exists = true, isFile = false, sha = null;
  const _FileState.file(this.sha) : exists = true, isFile = true;
  final bool exists;
  final bool isFile;
  final String? sha;
}

class _BackupProblem implements Exception {
  const _BackupProblem(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Applies plans with a crash-safe journal, and rolls them back.
///
/// Layout (docs/MOD_FORMAT.md): `<meta>/operations/<opId>/journal.json`,
/// `staged/<path>` (verified new content) and `backup/<path>` (verified
/// originals). The journal is rewritten atomically after every target
/// change, so an interrupted run can be resumed or rolled back.
class ApplyEngine {
  ApplyEngine({
    required this.metaDir,
    required this.workspaceRoot,
    required this.workspaceId,
    this.faults = EngineFaults.none,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final String metaDir;
  final String workspaceRoot;
  final String workspaceId;
  final EngineFaults faults;
  final DateTime Function() _clock;

  static const _uuid = Uuid();
  static const _journalName = 'journal.json';

  String get operationsDir => p.join(metaDir, 'operations');
  String opDir(String id) => p.join(operationsDir, id);
  String _journalPath(String id) => p.join(opDir(id), _journalName);
  String _stagedRoot(String id) => p.join(opDir(id), 'staged');

  // ---------------------------------------------------------------- listing

  Future<OperationsListing> listOperations() async {
    final root = Directory(operationsDir);
    if (!await root.exists()) return const OperationsListing([], []);
    final journals = <OperationJournal>[];
    final damaged = <DamagedJournal>[];
    await for (final e in root.list(followLinks: false)) {
      if (e is! Directory) continue;
      final f = File(p.join(e.path, _journalName));
      if (!await f.exists()) {
        damaged.add(DamagedJournal(e.path, 'journal.json is missing'));
        continue;
      }
      try {
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is! Map<String, dynamic>) throw const FormatException('not a JSON object');
        journals.add(OperationJournal.fromJson(decoded));
      } on FormatException catch (ex) {
        damaged.add(DamagedJournal(e.path, ex.message));
      } on UnsafePathException catch (ex) {
        damaged.add(DamagedJournal(e.path, ex.toString()));
      } on FileSystemException catch (ex) {
        damaged.add(DamagedJournal(e.path, ex.message));
      }
    }
    journals.sort(_newestFirst);
    return OperationsListing(journals, damaged);
  }

  static int _newestFirst(OperationJournal a, OperationJournal b) {
    final c = b.createdAt.compareTo(a.createdAt);
    return c != 0 ? c : b.id.compareTo(a.id);
  }

  static bool _isNewer(OperationJournal a, OperationJournal than) => _newestFirst(a, than) < 0;

  Future<OperationJournal> load(String opId) async {
    if (opId.contains('/') || opId.contains('\\') || opId.contains('..')) {
      throw ArgumentError.value(opId, 'opId', 'invalid operation id');
    }
    final decoded = jsonDecode(await File(_journalPath(opId)).readAsString());
    if (decoded is! Map<String, dynamic>) throw const FormatException('journal is not a JSON object');
    return OperationJournal.fromJson(decoded);
  }

  /// An open operation whose target overlaps [targetRel], if any.
  Future<OperationJournal?> blockingOperation(String targetRel, {String? exceptId}) async {
    final listing = await listOperations();
    for (final j in listing.journals) {
      if (j.id == exceptId || !j.isOpen) continue;
      if (targetsOverlap(j.targetRel, targetRel)) return j;
    }
    return null;
  }

  Future<OperationJournal?> _newerOpenOverlapping(OperationJournal op) async {
    final listing = await listOperations();
    for (final j in listing.journals) {
      if (j.id == op.id || !j.isOpen) continue;
      if (_isNewer(j, op) && targetsOverlap(j.targetRel, op.targetRel)) return j;
    }
    return null;
  }

  /// Removes a finished operation folder (journal, staged files, backups).
  /// Refused while the operation still affects its target.
  Future<void> deleteOperation(String opId) async {
    final j = await load(opId);
    if (j.isOpen) {
      throw StateError('Operation ${j.id} still affects "${j.targetRel}"; roll it back before deleting it');
    }
    final dir = Directory(opDir(opId));
    if (SafePath.isWithin(operationsDir, dir.path) && !p.equals(operationsDir, dir.path) && await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  // ------------------------------------------------------------------ apply

  String _newId() => '${Fmt.stamp(_clock())}-${_uuid.v4().substring(0, 8)}';

  String _packageRef(String archivePath) {
    if (SafePath.isWithin(metaDir, archivePath)) {
      return p.relative(archivePath, from: metaDir).replaceAll('\\', '/');
    }
    return archivePath;
  }

  String _packagePath(String ref) => p.isAbsolute(ref) ? ref : p.join(metaDir, ref);

  String _targetRoot(OperationJournal j) => resolveProfileTarget(workspaceRoot, j.targetRel);

  /// Applies [plan]. Refused while another operation affects the target.
  Future<ApplyOutcome> apply(ApplyPlan plan, {CancellationToken? token, ProgressCallback? onProgress}) async {
    final blocking = await blockingOperation(plan.targetRel);
    if (blocking != null) throw ApplyBlocked(blocking);
    final writes = plan.writes;
    if (writes.isEmpty) {
      return ApplyOutcome(
        journal: null,
        created: 0,
        overwritten: 0,
        unchanged: plan.unchanged,
        dirsCreated: 0,
        bytesWritten: 0,
      );
    }
    final now = _clock();
    final j = OperationJournal(
      id: _newId(),
      status: JournalStatus.staging,
      createdAt: now,
      updatedAt: now,
      workspaceId: workspaceId,
      targetRel: plan.targetRel,
      targetRoot: plan.targetRoot,
      profileId: plan.profileId,
      profileName: plan.profileName,
      packages: plan.packages,
      changes: [
        for (final c in writes)
          JournalChange(
            path: c.path,
            action: c.action,
            packageId: c.packageId,
            packageVersion: c.packageVersion,
            packageFile: _packageRef(c.archivePath),
            source: c.source,
            size: c.size,
            newSha256: c.newSha256,
            originalSha256: c.action == ChangeAction.overwrite ? c.currentSha256 : null,
          ),
      ],
      unchanged: [
        for (final c in plan.changes)
          if (c.action == ChangeAction.unchanged) c.path,
      ],
    );
    await Directory(opDir(j.id)).create(recursive: true);
    await _save(j);
    return _run(j, token, onProgress);
  }

  /// Continues an interrupted (or failed) apply.
  Future<ApplyOutcome> resume(String opId, {CancellationToken? token, ProgressCallback? onProgress}) async {
    final j = await load(opId);
    if (!j.canResume) {
      throw StateError('Operation ${j.id} cannot be resumed (status ${j.status.label})');
    }
    final blocking = await blockingOperation(j.targetRel, exceptId: j.id);
    if (blocking != null) throw ApplyBlocked(blocking);
    if (j.status == JournalStatus.failed) {
      j.status = j.failedDuring!;
      j.failedDuring = null;
      j.error = null;
    }
    j.interruptedReason = null;
    await _save(j);
    return _run(j, token, onProgress);
  }

  Future<ApplyOutcome> _run(OperationJournal j, CancellationToken? token, ProgressCallback? onProgress) async {
    try {
      if (j.status == JournalStatus.staging) {
        await _stage(j, token, onProgress);
        j.status = JournalStatus.applying;
        await _save(j);
      }
      final written = await _applyChanges(j, token, onProgress);
      j.status = JournalStatus.applied;
      j.appliedAt = _clock();
      j.interruptedReason = null;
      j.error = null;
      await _save(j);
      await _deleteDir(_stagedRoot(j.id));
      onProgress?.call(1, 'Applied');
      return ApplyOutcome(
        journal: j,
        created: j.count(ChangeAction.create),
        overwritten: j.count(ChangeAction.overwrite),
        unchanged: j.unchanged.length,
        dirsCreated: j.createdDirs.length,
        bytesWritten: written,
      );
    } on SimulatedCrash {
      rethrow;
    } on OperationCancelled {
      j.interruptedReason = 'Cancelled during ${j.status.label.toLowerCase()}. Resume to finish, or roll back.';
      await _save(j);
      rethrow;
    } catch (e) {
      j.failedDuring = j.status;
      j.status = JournalStatus.failed;
      j.error = e.toString();
      await _save(j);
      rethrow;
    }
  }

  Future<void> _stage(OperationJournal j, CancellationToken? token, ProgressCallback? onProgress) async {
    final root = _targetRoot(j);
    final n = j.changes.length;
    var staged = 0;
    for (var i = 0; i < n; i++) {
      token?.throwIfCancelled();
      final c = j.changes[i];
      onProgress?.call(0.4 * i / n, 'Staging ${c.path}');
      await _stageOne(j, c);
      final target = SafePath.resolveInside(root, c.path);
      final st = await _state(target);
      if (c.action == ChangeAction.overwrite) {
        if (!st.isFile || st.sha != c.originalSha256) {
          throw ApplyFailure('"${c.path}" changed since the plan was made. Nothing was modified; plan again.');
        }
        final backupRel = 'backup/${c.path}';
        final backupAbs = SafePath.resolveInside(opDir(j.id), backupRel);
        await Directory(p.dirname(backupAbs)).create(recursive: true);
        await _copyVerified(target, backupAbs, c.originalSha256!, 'backup of "${c.path}"');
        c.backup = backupRel;
      } else if (st.exists) {
        throw ApplyFailure(
          '"${c.path}" appeared in the target since the plan was made. Nothing was modified; plan again.',
        );
      }
      c.staged = true;
      staged++;
      if (staged % 25 == 0 || i == n - 1) await _save(j);
      if (faults.crashAfterStagedFiles == staged) {
        await _save(j);
        throw const SimulatedCrash('after staging');
      }
    }
  }

  /// Extracts one entry to `staged/<path>` and verifies its hash.
  Future<void> _stageOne(OperationJournal j, JournalChange c) async {
    final archive = _packagePath(c.packageFile);
    if (!await File(archive).exists()) {
      throw ApplyFailure('Package file for ${c.packageId} ${c.packageVersion} is no longer in the library');
    }
    final List<int> bytes;
    try {
      bytes = SafeZip.readEntry(archive, c.source, maxBytes: c.size);
    } on FormatException catch (e) {
      throw ApplyFailure('${c.packageId}: "${c.source}" cannot be extracted (${e.message})');
    } on FileSystemException catch (e) {
      throw ApplyFailure('${c.packageId}: "${c.source}" cannot be extracted (${e.message})');
    }
    if (Hashing.bytes(bytes) != c.newSha256) {
      throw ApplyFailure('${c.packageId}: "${c.source}" no longer matches the plan (package changed?). Plan again.');
    }
    final stagedPath = SafePath.resolveInside(_stagedRoot(j.id), c.path);
    await Directory(p.dirname(stagedPath)).create(recursive: true);
    await atomicWriteBytes(stagedPath, bytes);
  }

  Future<int> _applyChanges(OperationJournal j, CancellationToken? token, ProgressCallback? onProgress) async {
    final root = _targetRoot(j);
    final n = j.changes.length;
    var applied = 0;
    var bytes = 0;
    for (var i = 0; i < n; i++) {
      final c = j.changes[i];
      if (c.done) continue;
      token?.throwIfCancelled();
      onProgress?.call(0.4 + 0.6 * i / n, 'Applying ${c.path}');
      final target = SafePath.resolveInside(root, c.path);
      await _ensureParents(j, root, target);
      final st = await _state(target);
      if (st.isFile && st.sha == c.newSha256) {
        // Already in place (e.g. the app stopped right after the rename).
        c.done = true;
        await _save(j);
        continue;
      }
      if (c.action == ChangeAction.create && st.exists) {
        throw ApplyFailure('"${c.path}" exists in the target but should be new. Roll back, then plan again.');
      }
      if (c.action == ChangeAction.overwrite && (!st.isFile || st.sha != c.originalSha256)) {
        throw ApplyFailure('"${c.path}" was modified by something else during the operation. Roll back to restore.');
      }
      var stagedPath = SafePath.resolveInside(_stagedRoot(j.id), c.path);
      if (!await File(stagedPath).exists() || await Hashing.file(stagedPath) != c.newSha256) {
        await _stageOne(j, c);
        stagedPath = SafePath.resolveInside(_stagedRoot(j.id), c.path);
      }
      if (!j.touchedTarget) {
        j.touchedTarget = true;
        await _save(j);
      }
      await _replaceFrom(stagedPath, target, c.newSha256, j.id);
      c.done = true;
      await _save(j);
      applied++;
      bytes += c.size;
      if (faults.crashAfterApplyChanges == applied) throw const SimulatedCrash('after applying changes');
    }
    return bytes;
  }

  /// Creates missing parent folders of [target] one by one, recording each
  /// in the journal *before* creating it.
  Future<void> _ensureParents(OperationJournal j, String root, String target) async {
    final missing = <String>[];
    var d = p.dirname(target);
    while (!p.equals(d, root) && SafePath.isWithin(root, d)) {
      final t = FileSystemEntity.typeSync(d, followLinks: false);
      if (t == FileSystemEntityType.notFound) {
        missing.add(d);
        d = p.dirname(d);
        continue;
      }
      if (t != FileSystemEntityType.directory) {
        throw ApplyFailure('Folder "${p.relative(d, from: root)}" is blocked by a file or link');
      }
      break;
    }
    for (final dir in missing.reversed) {
      final rel = p.relative(dir, from: root).replaceAll('\\', '/');
      if (!j.createdDirs.contains(rel)) j.createdDirs.add(rel);
      j.touchedTarget = true;
      await _save(j);
      await Directory(dir).create();
    }
  }

  // --------------------------------------------------------------- rollback

  _RollbackAction _classify(OperationJournal j, JournalChange c, _FileState st) {
    if (!j.touchedTarget) return _RollbackAction.untouched;
    if (st.exists && !st.isFile) return _RollbackAction.notAFile;
    if (c.action == ChangeAction.overwrite) {
      if (!st.exists) return _RollbackAction.conflictDeleted;
      if (st.sha == c.originalSha256) return _RollbackAction.alreadyOriginal;
      if (st.sha == c.newSha256) return _RollbackAction.restore;
      return _RollbackAction.conflictEdited;
    }
    if (!st.exists) return _RollbackAction.alreadyAbsent;
    if (st.sha == c.newSha256) return _RollbackAction.delete;
    return _RollbackAction.conflictEdited;
  }

  /// Inspects what rolling back [opId] would do, including user edits made
  /// after applying (conflicts the caller must decide on).
  Future<RollbackPreview> previewRollback(String opId) async {
    final j = await load(opId);
    if (!j.canRollback) {
      return RollbackPreview(
        journal: j,
        blockedBy: null,
        conflicts: const [],
        toRestore: 0,
        toDelete: 0,
        nothingToDo: j.changes.length,
        problems: const [],
      );
    }
    final blocker = await _newerOpenOverlapping(j);
    final conflicts = <RollbackConflict>[];
    final problems = <String>[];
    var restore = 0;
    var delete = 0;
    var nothing = 0;
    String? root;
    try {
      root = _targetRoot(j);
    } on UnsafePathException catch (e) {
      problems.add('Target "${j.targetRel}" is not usable: ${e.reason}');
    }
    if (root != null) {
      for (final c in j.changes.reversed) {
        String target;
        try {
          target = SafePath.resolveInside(root, c.path);
        } on UnsafePathException catch (e) {
          problems.add('${c.path}: ${e.reason}');
          continue;
        }
        switch (_classify(j, c, await _state(target))) {
          case _RollbackAction.restore:
            restore++;
          case _RollbackAction.delete:
            delete++;
          case _RollbackAction.alreadyOriginal || _RollbackAction.alreadyAbsent || _RollbackAction.untouched:
            nothing++;
          case _RollbackAction.conflictEdited:
            conflicts.add(RollbackConflict(change: c, kind: ConflictKind.edited));
          case _RollbackAction.conflictDeleted:
            conflicts.add(RollbackConflict(change: c, kind: ConflictKind.deleted));
          case _RollbackAction.notAFile:
            problems.add('${c.path}: is now a folder or link');
        }
      }
    }
    return RollbackPreview(
      journal: j,
      blockedBy: blocker,
      conflicts: conflicts,
      toRestore: restore,
      toDelete: delete,
      nothingToDo: nothing,
      problems: problems,
    );
  }

  /// Rolls back [opId]. Conflicting files follow [decisions] (keyed by
  /// change path); undecided conflicts keep the user's version.
  Future<RollbackOutcome> rollback(
    String opId, {
    Map<String, ConflictDecision> decisions = const {},
    CancellationToken? token,
    ProgressCallback? onProgress,
  }) async {
    final j = await load(opId);
    if (j.status == JournalStatus.rolledBack) return RollbackOutcome(journal: j, problems: const []);
    if (!j.canRollback) {
      throw StateError('Operation ${j.id} did not modify its target; there is nothing to roll back');
    }
    final newer = await _newerOpenOverlapping(j);
    if (newer != null) throw RollbackBlocked(newer);

    j.status = JournalStatus.rollingBack;
    j.interruptedReason = null;
    j.error = null;
    j.failedDuring = null;
    await _save(j);
    final problems = <String>[];
    try {
      final root = _targetRoot(j);
      final ordered = j.changes.reversed.toList();
      var steps = 0;
      for (var i = 0; i < ordered.length; i++) {
        token?.throwIfCancelled();
        final c = ordered[i];
        onProgress?.call(i / (ordered.length + 1), 'Rolling back ${c.path}');
        String target;
        try {
          target = SafePath.resolveInside(root, c.path);
        } on UnsafePathException catch (e) {
          c.rollback = RollbackResult.skippedNotAFile;
          problems.add('${c.path}: ${e.reason}');
          await _save(j);
          continue;
        }
        final st = await _state(target);
        try {
          switch (_classify(j, c, st)) {
            case _RollbackAction.restore:
              await _restoreBackup(j, c, target);
              c.rollback = RollbackResult.restored;
            case _RollbackAction.delete:
              await File(target).delete();
              c.rollback = RollbackResult.deleted;
            case _RollbackAction.alreadyOriginal:
              c.rollback = RollbackResult.alreadyOriginal;
            case _RollbackAction.alreadyAbsent:
              c.rollback = RollbackResult.alreadyAbsent;
            case _RollbackAction.untouched:
              c.rollback = RollbackResult.untouched;
            case _RollbackAction.notAFile:
              c.rollback = RollbackResult.skippedNotAFile;
              problems.add('${c.path}: is now a folder or link; left unchanged');
            case _RollbackAction.conflictEdited || _RollbackAction.conflictDeleted:
              if (decisions[c.path] != ConflictDecision.restoreOriginal) {
                c.rollback = RollbackResult.keptUserEdit;
              } else {
                if (st.exists) c.savedEdit = await _saveEditedCopy(j, c, target);
                if (c.action == ChangeAction.overwrite) {
                  await _restoreBackup(j, c, target);
                  c.rollback = RollbackResult.restoredAfterSavingEdit;
                } else {
                  await File(target).delete();
                  c.rollback = RollbackResult.removedAfterSavingEdit;
                }
              }
          }
        } on _BackupProblem catch (e) {
          c.rollback = RollbackResult.backupDamaged;
          problems.add('${c.path}: $e');
        }
        await _save(j);
        steps++;
        if (faults.crashAfterRollbackSteps == steps) throw const SimulatedCrash('during rollback');
      }

      // Folders created by the operation, deepest first, only when empty.
      j.removedDirs.clear();
      j.keptDirs.clear();
      for (final rel in j.createdDirs.reversed) {
        final String abs;
        try {
          abs = SafePath.resolveInside(root, rel);
        } on UnsafePathException {
          j.keptDirs.add(rel);
          continue;
        }
        final type = FileSystemEntity.typeSync(abs, followLinks: false);
        if (type == FileSystemEntityType.notFound) continue;
        if (type == FileSystemEntityType.directory && await Directory(abs).list(followLinks: false).isEmpty) {
          await Directory(abs).delete();
          j.removedDirs.add(rel);
        } else {
          j.keptDirs.add(rel);
        }
      }

      if (problems.isEmpty) {
        j.status = JournalStatus.rolledBack;
      } else {
        j.status = JournalStatus.failed;
        j.failedDuring = JournalStatus.rollingBack;
        j.error = 'Rollback incomplete: ${problems.join('; ')}';
      }
      j.rolledBackAt = _clock();
      await _save(j);
      await _deleteDir(_stagedRoot(j.id));
      onProgress?.call(1, 'Rolled back');
      return RollbackOutcome(journal: j, problems: problems);
    } on SimulatedCrash {
      rethrow;
    } on OperationCancelled {
      j.interruptedReason = 'Rollback cancelled. Roll back again to finish.';
      await _save(j);
      rethrow;
    } catch (e) {
      j.status = JournalStatus.failed;
      j.failedDuring = JournalStatus.rollingBack;
      j.error = e.toString();
      await _save(j);
      rethrow;
    }
  }

  Future<void> _restoreBackup(OperationJournal j, JournalChange c, String target) async {
    final rel = c.backup;
    if (rel == null) throw const _BackupProblem('no backup was recorded');
    final String abs;
    try {
      abs = SafePath.resolveInside(opDir(j.id), rel);
    } on UnsafePathException catch (e) {
      throw _BackupProblem('backup path is unsafe (${e.reason})');
    }
    if (!await File(abs).exists()) throw const _BackupProblem('backup file is missing');
    if (await Hashing.file(abs) != c.originalSha256) {
      throw const _BackupProblem('backup file is damaged (hash mismatch)');
    }
    await Directory(p.dirname(target)).create(recursive: true);
    await _replaceFrom(abs, target, c.originalSha256!, j.id);
  }

  /// Saves the user's version next to the backup; returns its path
  /// relative to the operation folder.
  Future<String> _saveEditedCopy(OperationJournal j, JournalChange c, String target) async {
    final desired = SafePath.resolveInside(opDir(j.id), 'backup/${c.path}.user-edit');
    await Directory(p.dirname(desired)).create(recursive: true);
    final dest = SafePath.uniquePath(desired);
    await _copyFlush(target, dest);
    return p.relative(dest, from: opDir(j.id)).replaceAll('\\', '/');
  }

  // ------------------------------------------------------------ primitives

  Future<void> _save(OperationJournal j) async {
    j.updatedAt = _clock();
    await atomicWriteString(_journalPath(j.id), '${prettyJson.convert(j.toJson())}\n');
  }

  Future<_FileState> _state(String path) async {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return const _FileState.missing();
    if (type != FileSystemEntityType.file) return const _FileState.other();
    return _FileState.file(await Hashing.file(path));
  }

  static Future<void> _copyFlush(String src, String dest) async {
    final raf = await File(dest).open(mode: FileMode.writeOnly);
    try {
      await for (final chunk in File(src).openRead()) {
        await raf.writeFrom(chunk);
      }
      await raf.flush();
    } finally {
      await raf.close();
    }
  }

  /// Copies [src] to [dest] (inside the operation folder) and verifies it.
  Future<void> _copyVerified(String src, String dest, String sha, String what) async {
    final part = '$dest.part';
    await _copyFlush(src, part);
    if (await Hashing.file(part) != sha) {
      await File(part).delete();
      throw ApplyFailure('The $what could not be verified (hash mismatch)');
    }
    await File(part).rename(dest);
  }

  /// Atomically replaces [dest] with the content of [src]: copy to a unique
  /// temp file in the same folder, verify its hash, then rename over [dest].
  Future<void> _replaceFrom(String src, String dest, String sha, String opId) async {
    final tmp = SafePath.uniquePath(p.join(p.dirname(dest), '.${p.basename(dest)}.j3mod-${opId.split('-').last}.part'));
    try {
      await _copyFlush(src, tmp);
      if (await Hashing.file(tmp) != sha) {
        throw ApplyFailure('Verification of "${p.basename(dest)}" failed (hash mismatch); the file was not replaced');
      }
      try {
        await File(tmp).rename(dest);
      } on FileSystemException {
        // Some filesystems refuse to rename over an existing file.
        if (!await File(dest).exists()) rethrow;
        final aside = SafePath.uniquePath('$dest.j3mod-aside');
        await File(dest).rename(aside);
        try {
          await File(tmp).rename(dest);
        } catch (_) {
          await File(aside).rename(dest);
          rethrow;
        }
        await File(aside).delete();
      }
    } finally {
      final t = File(tmp);
      if (await t.exists()) await t.delete();
    }
  }

  Future<void> _deleteDir(String path) async {
    final d = Directory(path);
    if (SafePath.isWithin(operationsDir, path) && await d.exists()) await d.delete(recursive: true);
  }
}
