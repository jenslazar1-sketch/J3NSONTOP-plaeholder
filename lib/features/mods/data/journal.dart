import '../../../core/utils/safe_path.dart';
import '../domain/plan.dart';

/// Lifecycle of an apply operation (`journal.json` "status").
enum JournalStatus {
  staging('staging', 'STAGING'),
  applying('applying', 'APPLYING'),
  applied('applied', 'APPLIED'),
  rollingBack('rolling_back', 'ROLLING BACK'),
  rolledBack('rolled_back', 'ROLLED BACK'),
  failed('failed', 'FAILED');

  const JournalStatus(this.wire, this.label);

  /// Value stored in the journal.
  final String wire;
  final String label;

  /// Unfinished work from a crash, kill or cancellation.
  bool get isInterrupted => this == staging || this == applying || this == rollingBack;

  static JournalStatus? parse(Object? s) {
    for (final v in values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

/// What rollback did with one recorded change.
enum RollbackResult {
  restored('restored', 'Original restored'),
  deleted('deleted', 'Created file removed'),
  alreadyOriginal('already_original', 'Already original'),
  alreadyAbsent('already_absent', 'Already absent'),
  untouched('untouched', 'Never modified'),
  keptUserEdit('kept_user_edit', 'Your edit kept'),
  restoredAfterSavingEdit('restored_after_saving_edit', 'Original restored (your edit saved)'),
  removedAfterSavingEdit('removed_after_saving_edit', 'Removed (your edit saved)'),
  backupDamaged('backup_damaged', 'Backup missing or damaged - left unchanged'),
  skippedNotAFile('skipped_not_a_file', 'Path is now a folder or link - left unchanged');

  const RollbackResult(this.wire, this.label);
  final String wire;
  final String label;

  static RollbackResult? parse(Object? s) {
    for (final v in values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

/// One recorded target change. Mutable: the engine updates flags and
/// rewrites the journal after every step.
class JournalChange {
  JournalChange({
    required this.path,
    required this.action,
    required this.packageId,
    required this.packageVersion,
    required this.packageFile,
    required this.source,
    required this.size,
    required this.newSha256,
    this.originalSha256,
    this.backup,
    this.staged = false,
    this.done = false,
    this.rollback,
    this.savedEdit,
  });

  /// Relative to the target root.
  final String path;

  /// [ChangeAction.create] or [ChangeAction.overwrite].
  final ChangeAction action;
  final String packageId;
  final String packageVersion;

  /// Package path relative to the workspace meta folder (or absolute).
  final String packageFile;
  final String source;
  final int size;
  final String newSha256;

  /// Hash of the file before applying (overwrite only).
  final String? originalSha256;

  /// Backup path relative to the operation folder (overwrite only).
  String? backup;
  bool staged;
  bool done;
  RollbackResult? rollback;

  /// Where the user's edited copy was saved (relative to the op folder).
  String? savedEdit;

  Map<String, dynamic> toJson() => {
    'path': path,
    'action': action.name,
    'packageId': packageId,
    'packageVersion': packageVersion,
    'packageFile': packageFile,
    'source': source,
    'size': size,
    'newSha256': newSha256,
    'originalSha256': ?originalSha256,
    'backup': ?backup,
    'staged': staged,
    'done': done,
    'rollback': ?rollback?.wire,
    'savedEdit': ?savedEdit,
  };

  static JournalChange fromJson(Map<String, dynamic> j) {
    String str(String k) {
      final v = j[k];
      if (v is! String || v.isEmpty) throw FormatException('change field "$k" is missing');
      return v;
    }

    final action = switch (j['action']) {
      'create' => ChangeAction.create,
      'overwrite' => ChangeAction.overwrite,
      _ => throw FormatException('change action "${j['action']}" is not create/overwrite'),
    };
    final path = SafePath.normalizeRelative(str('path'));
    final original = j['originalSha256'];
    if (action == ChangeAction.overwrite && original is! String) {
      throw FormatException('overwrite of "$path" has no originalSha256');
    }
    final size = j['size'];
    return JournalChange(
      path: path,
      action: action,
      packageId: str('packageId'),
      packageVersion: str('packageVersion'),
      packageFile: str('packageFile'),
      source: str('source'),
      size: size is int ? size : 0,
      newSha256: str('newSha256'),
      originalSha256: original is String ? original : null,
      backup: j['backup'] is String ? j['backup'] as String : null,
      staged: j['staged'] == true,
      done: j['done'] == true,
      rollback: RollbackResult.parse(j['rollback']),
      savedEdit: j['savedEdit'] is String ? j['savedEdit'] as String : null,
    );
  }
}

/// `operations/<id>/journal.json`.
class OperationJournal {
  OperationJournal({
    required this.id,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    required this.workspaceId,
    required this.targetRel,
    required this.targetRoot,
    required this.profileId,
    required this.profileName,
    required this.packages,
    required this.changes,
    this.unchanged = const [],
    List<String>? createdDirs,
    this.touchedTarget = false,
    this.error,
    this.failedDuring,
    this.interruptedReason,
    this.appliedAt,
    this.rolledBackAt,
    List<String>? removedDirs,
    List<String>? keptDirs,
  }) : createdDirs = createdDirs ?? [],
       removedDirs = removedDirs ?? [],
       keptDirs = keptDirs ?? [];

  static const String format = 'j3journal';
  static const int formatVersion = 1;

  final String id;
  JournalStatus status;
  final DateTime createdAt;
  DateTime updatedAt;
  final String workspaceId;

  /// Profile target relative to the workspace root (resolved at runtime,
  /// so app-container moves on mobile do not break rollback).
  final String targetRel;

  /// Absolute target at apply time (informational).
  final String targetRoot;
  final String profileId;
  final String profileName;

  /// `id@version` of every enabled package, in order.
  final List<String> packages;
  final List<JournalChange> changes;

  /// Planned files that were already identical (never touched).
  final List<String> unchanged;

  /// Folders created by this operation (relative to the target, in
  /// creation order: parents first). Recorded before each is created.
  final List<String> createdDirs;

  /// Set (and persisted) before the first target modification.
  bool touchedTarget;
  String? error;
  JournalStatus? failedDuring;
  String? interruptedReason;
  DateTime? appliedAt;
  DateTime? rolledBackAt;
  final List<String> removedDirs;
  final List<String> keptDirs;

  /// Still affects its target: blocks new applies (LIFO) until rolled back.
  bool get isOpen => switch (status) {
    JournalStatus.rolledBack => false,
    JournalStatus.failed => touchedTarget,
    _ => true,
  };

  bool get canResume =>
      status == JournalStatus.staging ||
      status == JournalStatus.applying ||
      (status == JournalStatus.failed &&
          (failedDuring == JournalStatus.staging || failedDuring == JournalStatus.applying));

  bool get canRollback => status != JournalStatus.rolledBack && isOpen;

  int get doneCount => changes.where((c) => c.done).length;
  int count(ChangeAction a) => changes.where((c) => c.action == a).length;

  Map<RollbackResult, int> get rollbackCounts {
    final out = <RollbackResult, int>{};
    for (final c in changes) {
      final r = c.rollback;
      if (r != null) out[r] = (out[r] ?? 0) + 1;
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
    'format': format,
    'formatVersion': formatVersion,
    'id': id,
    'status': status.wire,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'workspaceId': workspaceId,
    'targetRel': targetRel,
    'targetRoot': targetRoot,
    'profile': {'id': profileId, 'name': profileName},
    'packages': packages,
    'touchedTarget': touchedTarget,
    'changes': [for (final c in changes) c.toJson()],
    'unchanged': unchanged,
    'createdDirs': createdDirs,
    'error': ?error,
    'failedDuring': ?failedDuring?.wire,
    'interruptedReason': ?interruptedReason,
    'appliedAt': ?appliedAt?.toUtc().toIso8601String(),
    'rolledBackAt': ?rolledBackAt?.toUtc().toIso8601String(),
    if (removedDirs.isNotEmpty) 'removedDirs': removedDirs,
    if (keptDirs.isNotEmpty) 'keptDirs': keptDirs,
  };

  /// Strict decoding: a journal that cannot be understood is reported as
  /// damaged instead of being guessed at.
  static OperationJournal fromJson(Map<String, dynamic> j) {
    if (j['format'] != format) throw const FormatException('not a J3NSONTOP journal');
    final fv = j['formatVersion'];
    if (fv is! int || fv > formatVersion) throw FormatException('unsupported journal version $fv');
    final status = JournalStatus.parse(j['status']);
    if (status == null) throw FormatException('unknown status "${j['status']}"');
    String str(String k) {
      final v = j[k];
      if (v is! String) throw FormatException('field "$k" is missing');
      return v;
    }

    DateTime? date(String k) => j[k] is String ? DateTime.tryParse(j[k] as String) : null;
    List<String> strings(String k) => j[k] is List ? (j[k] as List).whereType<String>().toList() : <String>[];
    final profile = j['profile'];
    if (profile is! Map<String, dynamic>) throw const FormatException('field "profile" is missing');
    final rawChanges = j['changes'];
    if (rawChanges is! List) throw const FormatException('field "changes" is missing');
    final created = date('createdAt');
    if (created == null) throw const FormatException('field "createdAt" is missing');
    final targetRel = str('targetRel');
    return OperationJournal(
      id: str('id'),
      status: status,
      createdAt: created,
      updatedAt: date('updatedAt') ?? created,
      workspaceId: str('workspaceId'),
      targetRel: targetRel == '.' ? '.' : SafePath.normalizeRelative(targetRel),
      targetRoot: j['targetRoot'] is String ? j['targetRoot'] as String : '',
      profileId: profile['id'] is String ? profile['id'] as String : '?',
      profileName: profile['name'] is String ? profile['name'] as String : '?',
      packages: strings('packages'),
      changes: [
        for (final c in rawChanges)
          if (c is Map<String, dynamic>) JournalChange.fromJson(c) else throw const FormatException('bad change'),
      ],
      unchanged: strings('unchanged'),
      createdDirs: [for (final d in strings('createdDirs')) SafePath.normalizeRelative(d)],
      touchedTarget: j['touchedTarget'] == true,
      error: j['error'] is String ? j['error'] as String : null,
      failedDuring: JournalStatus.parse(j['failedDuring']),
      interruptedReason: j['interruptedReason'] is String ? j['interruptedReason'] as String : null,
      appliedAt: date('appliedAt'),
      rolledBackAt: date('rolledBackAt'),
      removedDirs: strings('removedDirs'),
      keptDirs: strings('keptDirs'),
    );
  }
}

/// Whether two profile targets can touch the same files (equal, or one
/// inside the other; `.` overlaps everything).
bool targetsOverlap(String a, String b) {
  if (a == '.' || b == '.') return true;
  final ka = SafePath.collisionKey(a);
  final kb = SafePath.collisionKey(b);
  return ka == kb || ka.startsWith('$kb/') || kb.startsWith('$ka/');
}
