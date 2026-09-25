import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/archive/safe_zip.dart';
import '../../../core/tasks/cancellation.dart';
import '../../../core/tasks/isolate_runner.dart';
import '../../../core/utils/hashing.dart';
import '../../../core/utils/safe_path.dart';
import 'manifest.dart';
import 'profile.dart';

/// What applying does to one target file.
enum ChangeAction {
  create('CREATE'),
  overwrite('OVERWRITE'),
  unchanged('UNCHANGED');

  const ChangeAction(this.label);
  final String label;
}

/// An enabled package, in application order, as input for planning.
class PlanSource {
  const PlanSource({required this.manifest, required this.archivePath});
  final ModManifest manifest;
  final String archivePath;
}

/// One target file in the plan.
class PlannedChange {
  const PlannedChange({
    required this.path,
    required this.action,
    required this.size,
    required this.packageId,
    required this.packageVersion,
    required this.archivePath,
    required this.source,
    required this.newSha256,
    this.currentSize,
    this.currentSha256,
    this.overrides = const [],
  });

  /// Target path relative to the target root (forward slashes).
  final String path;
  final ChangeAction action;

  /// Size of the new content.
  final int size;

  /// Size/hash of the existing file (overwrite/unchanged only).
  final int? currentSize;
  final String? currentSha256;
  final String packageId;
  final String packageVersion;

  /// Absolute path of the providing `.j3mod`.
  final String archivePath;

  /// Entry path inside the archive.
  final String source;
  final String newSha256;

  /// Packages that also write this file but lose (applied earlier).
  final List<String> overrides;
}

/// The exact change list for a profile, computed before anything is written.
class ApplyPlan {
  const ApplyPlan({
    required this.profileId,
    required this.profileName,
    required this.targetRel,
    required this.targetRoot,
    required this.changes,
    required this.directoriesToCreate,
    required this.packages,
    required this.createdAt,
  });

  final String profileId;
  final String profileName;

  /// Profile target relative to the workspace (`.` for the root).
  final String targetRel;

  /// Absolute target folder at planning time.
  final String targetRoot;

  /// Every target file, sorted by path.
  final List<PlannedChange> changes;

  /// Folders that will be created (relative to the target, parents first).
  final List<String> directoriesToCreate;

  /// Enabled packages in order as `id@version`.
  final List<String> packages;
  final DateTime createdAt;

  int _count(ChangeAction a) => changes.where((c) => c.action == a).length;
  int get creates => _count(ChangeAction.create);
  int get overwrites => _count(ChangeAction.overwrite);
  int get unchanged => _count(ChangeAction.unchanged);

  /// Files that will actually be written.
  List<PlannedChange> get writes => changes.where((c) => c.action != ChangeAction.unchanged).toList();
  int get bytesToWrite => writes.fold(0, (s, c) => s + c.size);
  bool get hasWork => creates + overwrites > 0;
}

/// Planning failed (unsafe target, folder in the way, unreadable package).
class PlanException implements Exception {
  const PlanException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Resolves a profile's target folder inside the workspace.
String resolveProfileTarget(String workspaceRoot, String target) {
  final t = normalizeProfileTarget(target);
  if (t == '.') return p.normalize(workspaceRoot);
  return SafePath.resolveInside(workspaceRoot, t);
}

abstract final class PlanBuilder {
  /// Computes the plan. Reads package entries and hashes existing target
  /// files; never writes anything.
  static Future<ApplyPlan> build({
    required String workspaceRoot,
    required ModProfile profile,
    required List<PlanSource> packages,
    CancellationToken? token,
  }) async {
    final String targetRoot;
    try {
      targetRoot = resolveProfileTarget(workspaceRoot, profile.target);
    } on UnsafePathException catch (e) {
      throw PlanException('The profile target "${profile.target}" is not usable: ${e.reason}');
    }
    if (FileSystemEntity.typeSync(targetRoot, followLinks: false) != FileSystemEntityType.directory) {
      throw PlanException(
        'The target folder "${profile.target}" does not exist in the workspace (or is not a folder). '
        'Choose another target in the profile details.',
      );
    }

    // Winner per target (case-insensitive), last one wins.
    final winners = <String, (PlanSource, FileMapping)>{};
    final losers = <String, List<String>>{};
    for (final src in packages) {
      for (final f in src.manifest.files) {
        final key = SafePath.collisionKey(f.target);
        final prior = winners[key];
        if (prior != null) (losers[key] ??= []).add(prior.$1.manifest.id);
        winners[key] = (src, f);
      }
    }

    final changes = <PlannedChange>[];
    final dirs = <String>{};
    for (final e in winners.entries) {
      token?.throwIfCancelled();
      final (src, mapping) = e.value;
      final String abs;
      try {
        abs = SafePath.resolveInside(targetRoot, mapping.target);
      } on UnsafePathException catch (ex) {
        throw PlanException('${src.manifest.id}: target "${mapping.target}" is unsafe: ${ex.reason}');
      }
      final List<int> bytes;
      try {
        bytes = SafeZip.readEntry(src.archivePath, mapping.source, maxBytes: ZipLimits.standard.maxEntryBytes);
      } on FileSystemException catch (ex) {
        throw PlanException('${src.manifest.id}: cannot read "${mapping.source}" from the package: ${ex.message}');
      } on FormatException catch (ex) {
        throw PlanException('${src.manifest.id}: "${mapping.source}" is damaged: ${ex.message}');
      }
      final newSha = Hashing.bytes(bytes);
      final type = FileSystemEntity.typeSync(abs, followLinks: false);
      ChangeAction action;
      int? currentSize;
      String? currentSha;
      switch (type) {
        case FileSystemEntityType.notFound:
          action = ChangeAction.create;
          // Missing parent folders, checked from the file upwards.
          var dir = p.dirname(abs);
          while (!p.equals(dir, targetRoot) && SafePath.isWithin(targetRoot, dir)) {
            final t = FileSystemEntity.typeSync(dir, followLinks: false);
            if (t == FileSystemEntityType.notFound) {
              dirs.add(p.relative(dir, from: targetRoot).replaceAll('\\', '/'));
            } else if (t != FileSystemEntityType.directory) {
              throw PlanException(
                '${src.manifest.id}: "${mapping.target}" needs the folder '
                '"${p.relative(dir, from: targetRoot)}", but a file with that name exists',
              );
            } else {
              break;
            }
            dir = p.dirname(dir);
          }
        case FileSystemEntityType.file:
          currentSize = File(abs).lengthSync();
          currentSha = await Hashing.file(abs, token: token);
          action = Hashing.digestsEqual(currentSha, newSha) ? ChangeAction.unchanged : ChangeAction.overwrite;
        case FileSystemEntityType.directory:
          throw PlanException(
            '${src.manifest.id}: "${mapping.target}" is a folder in the target; a package cannot replace a folder',
          );
        default:
          throw PlanException('${src.manifest.id}: "${mapping.target}" is a link or special file in the target');
      }
      changes.add(
        PlannedChange(
          path: mapping.target,
          action: action,
          size: bytes.length,
          currentSize: currentSize,
          currentSha256: currentSha,
          packageId: src.manifest.id,
          packageVersion: src.manifest.versionText,
          archivePath: src.archivePath,
          source: mapping.source,
          newSha256: newSha,
          overrides: losers[e.key] ?? const [],
        ),
      );
    }
    changes.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    final dirList = dirs.toList()
      ..sort((a, b) {
        final da = '/'.allMatches(a).length;
        final db = '/'.allMatches(b).length;
        return da != db ? da.compareTo(db) : a.compareTo(b);
      });
    return ApplyPlan(
      profileId: profile.id,
      profileName: profile.name,
      targetRel: normalizeProfileTarget(profile.target),
      targetRoot: targetRoot,
      changes: changes,
      directoriesToCreate: dirList,
      packages: [for (final s in packages) s.manifest.label],
      createdAt: DateTime.now(),
    );
  }
}

/// Builds the plan in a bounded background isolate. The closure captures
/// only sendable values; cancellation kills the worker.
Future<ApplyPlan> buildPlanInBackground({
  required String workspaceRoot,
  required ModProfile profile,
  required List<PlanSource> packages,
  CancellationToken? token,
}) {
  return runBounded(
    () => PlanBuilder.build(workspaceRoot: workspaceRoot, profile: profile, packages: packages),
    timeout: const Duration(minutes: 10),
    token: token,
    debugName: 'j3-mod-plan',
  );
}
