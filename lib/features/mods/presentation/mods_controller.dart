import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/activity/activity_controller.dart';
import '../../../core/archive/safe_zip.dart';
import '../../../core/platform/app_paths.dart';
import '../../../core/platform/capabilities.dart';
import '../../../core/tasks/cancellation.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/safe_path.dart';
import '../../../core/widgets/status.dart';
import '../../../core/workspace/workspace.dart';
import '../../../core/workspace/workspace_controller.dart';
import '../data/apply_engine.dart';
import '../data/journal.dart';
import '../data/mod_library.dart';
import '../data/profile_store.dart';
import '../data/target_game.dart';
import '../domain/manifest.dart';
import '../domain/plan.dart';
import '../domain/profile.dart';
import '../domain/resolver.dart';

const String kModsManagerId = 'mods.manager';
const String kModsInspectorId = 'mods.inspector';
const String kModsBuilderId = 'mods.builder';

/// Largest target folder "Export result" will pack (it is held in memory
/// for the save dialog).
const int kExportResultMaxBytes = 512 * 1024 * 1024;

enum ModsPhase { noWorkspace, loading, ready, error }

/// A result/notice shown inline (next to the profile or page it concerns).
@immutable
class ResultNote {
  const ResultNote({required this.kind, required this.title, this.message, this.details = const []});
  final StatusKind kind;
  final String title;
  final String? message;
  final List<String> details;
}

/// Everything the Mods section shows for the active workspace.
class ModsState {
  ModsState({
    this.workspace,
    this.metaDir,
    this.phase = ModsPhase.noWorkspace,
    this.error,
    this.healthWarning,
    this.library = const [],
    this.profiles = const [],
    this.operations = const [],
    this.damagedOps = const [],
    this.targets = const {},
    this.results = const {},
    this.busyLabel,
    this.busyOpId,
  }) : manifests = ModLibrary.manifestsById(library),
       invalidIds = ModLibrary.invalidIds(library);

  final Workspace? workspace;
  final String? metaDir;
  final ModsPhase phase;
  final String? error;

  /// E.g. "the linked folder is missing".
  final String? healthWarning;
  final List<LibraryEntry> library;
  final List<StoredProfile> profiles;
  final List<OperationJournal> operations;
  final List<DamagedJournal> damagedOps;

  /// Target game per profile id.
  final Map<String, TargetGame> targets;

  /// Inline results keyed by profile id, or `page` / `op:<id>`.
  final Map<String, ResultNote> results;

  /// Label of the running action (buttons are disabled meanwhile).
  final String? busyLabel;

  /// Activity operation id of the running action (for progress/cancel).
  final String? busyOpId;

  final Map<String, ModManifest> manifests;
  final Set<String> invalidIds;

  bool get isBusy => busyLabel != null;

  List<ModProfile> get validProfiles => [
    for (final s in profiles)
      if (s.profile != null) s.profile!,
  ];

  ModProfile? profileById(String? id) {
    if (id == null) return null;
    for (final s in profiles) {
      if (s.profile?.id == id) return s.profile;
    }
    return null;
  }

  List<OperationJournal> get interrupted => operations.where((o) => o.status.isInterrupted).toList();

  /// Open operation on a target overlapping [targetRel] (LIFO blocker).
  OperationJournal? openOperationOn(String targetRel) {
    for (final o in operations) {
      if (o.isOpen && targetsOverlap(o.targetRel, targetRel)) return o;
    }
    return null;
  }

  /// The latest open operation created by [profileId], if it can be rolled
  /// back now (nothing newer on an overlapping target).
  OperationJournal? rollbackCandidateFor(String profileId) {
    for (final o in operations) {
      if (!o.isOpen) continue;
      if (o.profileId != profileId) continue;
      final newer = operations
          .takeWhile((x) => x.id != o.id)
          .where((x) => x.isOpen && targetsOverlap(x.targetRel, o.targetRel));
      return newer.isEmpty ? o : null;
    }
    return null;
  }

  /// Whether [op] is the newest open operation on its target.
  bool isLatestOnTarget(OperationJournal op) {
    for (final o in operations) {
      if (o.id == op.id) return true;
      if (o.isOpen && targetsOverlap(o.targetRel, op.targetRel)) return false;
    }
    return true;
  }

  /// Profiles that include [modId] (for "remove package" warnings).
  List<ModProfile> profilesUsing(String modId) => validProfiles.where((p) => p.contains(modId)).toList();

  ModsState copyWith({
    ModsPhase? phase,
    String? error,
    bool clearError = false,
    String? healthWarning,
    bool clearHealth = false,
    List<LibraryEntry>? library,
    List<StoredProfile>? profiles,
    List<OperationJournal>? operations,
    List<DamagedJournal>? damagedOps,
    Map<String, TargetGame>? targets,
    Map<String, ResultNote>? results,
    String? busyLabel,
    String? busyOpId,
    bool clearBusy = false,
  }) => ModsState(
    workspace: workspace,
    metaDir: metaDir,
    phase: phase ?? this.phase,
    error: clearError ? null : (error ?? this.error),
    healthWarning: clearHealth ? null : (healthWarning ?? this.healthWarning),
    library: library ?? this.library,
    profiles: profiles ?? this.profiles,
    operations: operations ?? this.operations,
    damagedOps: damagedOps ?? this.damagedOps,
    targets: targets ?? this.targets,
    results: results ?? this.results,
    busyLabel: clearBusy ? null : (busyLabel ?? this.busyLabel),
    busyOpId: clearBusy ? null : (busyOpId ?? this.busyOpId),
  );
}

/// State and actions of the Mods section for the active workspace.
class ModsController extends Notifier<ModsState> {
  int _generation = 0;

  @override
  ModsState build() {
    final activeId = ref.watch(workspacesProvider.select((s) => s.activeId));
    final ws = activeId == null ? null : ref.read(workspacesProvider).byId(activeId);
    final gen = ++_generation;
    if (ws == null) return ModsState();
    final meta = ref.read(workspacesProvider.notifier).metaDir(ws);
    Future.microtask(() => _load(gen));
    return ModsState(workspace: ws, metaDir: meta, phase: ModsPhase.loading);
  }

  ModLibrary get _library => ModLibrary(state.metaDir!);
  ProfileStore get _store => ProfileStore(state.metaDir!);

  ApplyEngine get _engine {
    final ws = state.workspace!;
    return ApplyEngine(metaDir: state.metaDir!, workspaceRoot: ws.rootPath, workspaceId: ws.id);
  }

  ActivityController get _activity => ref.read(activityProvider.notifier);

  bool get _ready => state.workspace != null && state.metaDir != null;

  Future<void> _load(int gen) async {
    final s = state;
    final ws = s.workspace;
    if (ws == null || s.metaDir == null) return;
    try {
      final health = await WorkspaceController.checkHealth(ws);
      final library = await ModLibrary(s.metaDir!).list();
      final profiles = await ProfileStore(s.metaDir!).list();
      final listing = await ApplyEngine(
        metaDir: s.metaDir!,
        workspaceRoot: ws.rootPath,
        workspaceId: ws.id,
      ).listOperations();
      final targets = <String, TargetGame>{};
      for (final sp in profiles) {
        final prof = sp.profile;
        if (prof != null) targets[prof.id] = await readTargetGame(ws.rootPath, prof);
      }
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(
        phase: ModsPhase.ready,
        clearError: true,
        healthWarning: switch (health) {
          WorkspaceHealth.ok => null,
          WorkspaceHealth.missing => 'The workspace folder is missing: ${ws.rootPath}',
          WorkspaceHealth.notADirectory => 'The workspace path is not a folder: ${ws.rootPath}',
          WorkspaceHealth.permissionDenied => 'The workspace folder cannot be read (permission denied)',
        },
        clearHealth: health == WorkspaceHealth.ok,
        library: library,
        profiles: profiles,
        operations: listing.journals,
        damagedOps: listing.damaged,
        targets: targets,
      );
    } catch (e) {
      if (gen != _generation || !ref.mounted) return;
      state = state.copyWith(phase: ModsPhase.error, error: e.toString());
    }
  }

  /// Reloads library, profiles, journals and target games from disk.
  Future<void> refresh() => _load(_generation);

  void setResult(String key, ResultNote? note) {
    final next = Map<String, ResultNote>.from(state.results);
    if (note == null) {
      next.remove(key);
    } else {
      next[key] = note;
    }
    state = state.copyWith(results: next);
  }

  /// Runs [body] as a tracked activity with the page's busy flag set.
  Future<T> _tracked<T>({
    required String title,
    required Future<T> Function(OperationHandle op) body,
    String Function(T result)? summary,
    Map<String, num> Function(T result)? counts,
    bool cancellable = false,
    bool notify = true,
  }) async {
    if (state.isBusy) throw StateError('Another mods operation is running (${state.busyLabel}).');
    state = state.copyWith(busyLabel: title);
    try {
      return await _activity.run<T>(
        toolId: kModsManagerId,
        title: title,
        workspaceId: state.workspace?.id,
        cancellable: cancellable,
        notify: notify,
        summary: summary,
        counts: counts,
        body: (op) {
          state = state.copyWith(busyOpId: op.id);
          return body(op);
        },
      );
    } finally {
      if (ref.mounted) state = state.copyWith(clearBusy: true);
    }
  }

  // --------------------------------------------------------------- library

  Future<ImportOutcome> importPackage(String path, {bool replace = false}) async {
    if (!_ready) throw StateError('No active workspace');
    final outcome = await _tracked<ImportOutcome>(
      title: replace ? 'Replace mod package' : 'Import mod package',
      notify: false,
      body: (op) async {
        op.progress(null, 'Validating ${p.basename(path)}');
        final r = await _library.importPackage(path, replace: replace);
        switch (r) {
          case ImportCompleted(:final entry, :final replaced):
            op.succeed(
              replaced == null
                  ? 'Imported ${entry.id} ${entry.version}'
                  : 'Replaced ${replaced.id} ${replaced.version} with ${entry.version}',
              counts: {'bytes': entry.sizeBytes},
            );
          case ImportRejected(:final report):
            op.warn('Rejected ${p.basename(path)}: ${report.errorCount} error(s)');
          case ImportNeedsReplace(:final existing):
            op.succeed('Waiting for confirmation to replace ${existing.id}', notify: false);
          case ImportIdentical(:final existing):
            op.succeed('${existing.id} ${existing.version} is already in the library');
        }
        return r;
      },
    );
    if (outcome is ImportCompleted) await refresh();
    return outcome;
  }

  Future<void> removePackage(LibraryEntry entry) async {
    await _tracked<void>(
      title: 'Remove ${entry.id}',
      summary: (_) => 'Removed ${entry.fileName} from the library',
      body: (_) => _library.remove(entry),
    );
    await refresh();
  }

  // -------------------------------------------------------------- profiles

  Future<void> _replaceProfile(ModProfile prof, {bool reloadTarget = false}) async {
    final list = [
      for (final s in state.profiles)
        if (s.profile?.id == prof.id) StoredProfile(path: s.path, profile: prof) else s,
    ];
    if (!list.any((s) => s.profile?.id == prof.id)) {
      list.add(StoredProfile(path: _store.pathFor(prof.id), profile: prof));
      list.sort((a, b) => (a.profile?.name.toLowerCase() ?? a.id).compareTo(b.profile?.name.toLowerCase() ?? b.id));
    }
    state = state.copyWith(profiles: list);
    if (reloadTarget) {
      final t = await readTargetGame(state.workspace!.rootPath, prof);
      if (ref.mounted) state = state.copyWith(targets: {...state.targets, prof.id: t});
    }
  }

  /// Optimistic update: the UI changes immediately, then the file is
  /// written atomically. On failure the state is reloaded from disk.
  Future<void> updateProfile(ModProfile prof, {bool targetChanged = false}) async {
    final before = state.profiles;
    await _replaceProfile(prof, reloadTarget: targetChanged);
    try {
      await _store.save(prof);
    } catch (e) {
      state = state.copyWith(profiles: before);
      _activity.notify(NoticeKind.error, 'Could not save profile "${prof.name}": $e');
      await refresh();
    }
  }

  Future<ModProfile> createProfile(String name, {String target = '.'}) async {
    final prof = await _store.create(name: name, target: target);
    await _replaceProfile(prof, reloadTarget: true);
    _activity.notify(NoticeKind.success, 'Created profile "${prof.name}"');
    return prof;
  }

  Future<ModProfile> duplicateProfile(String id) async {
    final prof = await _store.duplicate(id);
    await _replaceProfile(prof, reloadTarget: true);
    _activity.notify(NoticeKind.success, 'Duplicated as "${prof.name}"');
    return prof;
  }

  Future<void> renameProfile(String id, String name) async {
    final prof = await _store.rename(id, name);
    await _replaceProfile(prof);
  }

  Future<void> deleteProfile(String id) async {
    await _store.delete(id);
    state = state.copyWith(profiles: state.profiles.where((s) => s.id != id).toList());
    _activity.notify(NoticeKind.info, 'Profile deleted');
  }

  Future<void> deleteDamagedProfile(StoredProfile sp) async {
    final f = File(sp.path);
    if (SafePath.isWithin(_store.dir, sp.path) && await f.exists()) await f.delete();
    await refresh();
  }

  Future<ProfileImportOutcome> importProfile(String text, {ProfileCollision collision = ProfileCollision.ask}) async {
    final r = await _store.importText(text, collision: collision);
    if (r is ProfileImported) {
      await _replaceProfile(r.profile, reloadTarget: true);
      _activity.notify(NoticeKind.success, 'Imported profile "${r.profile.name}"');
    }
    return r;
  }

  Future<void> setEnabled(ModProfile prof, String modId, bool enabled) =>
      updateProfile(prof.setEnabled(modId, enabled));

  Future<void> moveMod(ModProfile prof, int from, int to) => updateProfile(prof.moveMod(from, to));

  Future<void> addMod(ModProfile prof, String modId) =>
      updateProfile(prof.copyWith(mods: [...prof.mods, ProfileMod(modId)]));

  Future<void> removeMod(ModProfile prof, String modId) =>
      updateProfile(prof.copyWith(mods: prof.mods.where((m) => m.id != modId).toList()));

  /// Applies the stable dependency sort; returns the sort result.
  Future<SortResult> sortByDependencies(ModProfile prof) async {
    final r = ModResolver.sortByDependencies(prof, state.manifests);
    if (r.changed) await updateProfile(prof.copyWith(mods: r.mods));
    return r;
  }

  ResolutionReport? reportFor(String profileId) {
    final prof = state.profileById(profileId);
    if (prof == null) return null;
    return ModResolver.resolve(
      profile: prof,
      library: state.manifests,
      invalid: state.invalidIds,
      target: state.targets[profileId] ?? TargetGame.unknown,
    );
  }

  // ------------------------------------------------------ plan / apply

  /// Computes the plan for [prof] in a background worker.
  Future<ApplyPlan> computePlan(ModProfile prof) async {
    final sources = <PlanSource>[];
    for (final id in prof.enabledIds) {
      final entry = ModLibrary.entryFor(state.library, id);
      if (entry == null) throw StateError('Package $id is not in the library');
      sources.add(PlanSource(manifest: entry.manifest!, archivePath: entry.path));
    }
    final root = state.workspace!.rootPath;
    return _tracked<ApplyPlan>(
      title: 'Plan "${prof.name}"',
      notify: false,
      cancellable: true,
      summary: (plan) => 'Plan: ${plan.creates} create, ${plan.overwrites} overwrite, ${plan.unchanged} unchanged',
      body: (op) {
        op.progress(null, 'Hashing target files');
        return buildPlanInBackground(workspaceRoot: root, profile: prof, packages: sources, token: op.token);
      },
    );
  }

  Future<ApplyOutcome> apply(ApplyPlan plan) async {
    try {
      final out = await _tracked<ApplyOutcome>(
        title: 'Apply "${plan.profileName}"',
        cancellable: true,
        summary: (o) => o.summary,
        counts: (o) => {'created': o.created, 'overwritten': o.overwritten, 'unchanged': o.unchanged},
        body: (op) => _engine.apply(plan, token: op.token, onProgress: op.progress),
      );
      setResult(
        plan.profileId,
        ResultNote(
          kind: StatusKind.success,
          title: out.nothingToDo ? 'Nothing to apply' : 'Applied "${plan.profileName}"',
          message: out.summary,
          details: [
            if (out.journal != null) 'Operation ${out.journal!.id}',
            if (out.bytesWritten > 0) '${Fmt.bytes(out.bytesWritten)} written',
          ],
        ),
      );
      return out;
    } catch (e) {
      setResult(
        plan.profileId,
        ResultNote(
          kind: e is OperationCancelled ? StatusKind.warning : StatusKind.error,
          title: e is OperationCancelled ? 'Apply cancelled' : 'Apply failed',
          message: e is OperationCancelled
              ? 'The journal was kept. Resume or roll back from the banner at the top.'
              : e.toString(),
        ),
      );
      rethrow;
    } finally {
      await refresh();
    }
  }

  Future<ApplyOutcome> resume(String opId) async {
    try {
      final out = await _tracked<ApplyOutcome>(
        title: 'Resume operation',
        cancellable: true,
        summary: (o) => o.summary,
        body: (op) => _engine.resume(opId, token: op.token, onProgress: op.progress),
      );
      setResult(
        'op:$opId',
        ResultNote(kind: StatusKind.success, title: 'Operation resumed and finished', message: out.summary),
      );
      return out;
    } catch (e) {
      setResult('op:$opId', ResultNote(kind: StatusKind.error, title: 'Resume failed', message: e.toString()));
      rethrow;
    } finally {
      await refresh();
    }
  }

  Future<RollbackPreview> previewRollback(String opId) => _engine.previewRollback(opId);

  Future<RollbackOutcome> rollback(String opId, {Map<String, ConflictDecision> decisions = const {}}) async {
    final profileId = state.operations.where((o) => o.id == opId).firstOrNull?.profileId;
    try {
      final out = await _tracked<RollbackOutcome>(
        title: 'Roll back operation',
        cancellable: true,
        summary: (o) => o.summary,
        counts: (o) => {'restored': o.restored, 'removed': o.deleted, 'kept': o.keptUserEdits},
        body: (op) => _engine.rollback(opId, decisions: decisions, token: op.token, onProgress: op.progress),
      );
      final note = ResultNote(
        kind: out.problems.isEmpty ? StatusKind.success : StatusKind.warning,
        title: out.problems.isEmpty ? 'Rolled back' : 'Rolled back with problems',
        message: out.summary,
        details: [
          ...out.problems,
          for (final c in out.journal.changes)
            if (c.savedEdit != null) 'Your edit of ${c.path} was saved as operations/$opId/${c.savedEdit}',
        ],
      );
      setResult('op:$opId', note);
      if (profileId != null) setResult(profileId, note);
      return out;
    } catch (e) {
      final note = ResultNote(kind: StatusKind.error, title: 'Rollback failed', message: e.toString());
      setResult('op:$opId', note);
      if (profileId != null) setResult(profileId, note);
      rethrow;
    } finally {
      await refresh();
    }
  }

  Future<void> deleteOperation(String opId) async {
    await _engine.deleteOperation(opId);
    await refresh();
  }

  String operationFolder(String opId) => _engine.opDir(opId);

  // ---------------------------------------------------------- export

  /// Packs [targetRel] of the workspace into a ZIP (for the save dialog /
  /// share sheet on platforms that cannot apply in place).
  Future<(String name, Uint8List bytes)> buildResultZip(String targetRel) async {
    final ws = state.workspace!;
    final root = resolveProfileTarget(ws.rootPath, targetRel);
    final staging = p.join(
      ref.read(appPathsProvider).exportStagingDir,
      DateTime.now().microsecondsSinceEpoch.toString(),
    );
    final label = targetRel == '.' ? SafePath.sanitizeFileName(ws.name) : SafePath.sanitizeFileName(p.basename(root));
    final name = '$label-result-${Fmt.stamp(DateTime.now())}.zip';
    return _tracked<(String, Uint8List)>(
      title: 'Export result ($targetRel)',
      cancellable: true,
      notify: false,
      summary: (r) => 'Packed ${Fmt.bytes(r.$2.length)}',
      body: (op) async {
        op.progress(null, 'Collecting files');
        final sources = <ZipSource>[];
        var total = 0;
        await for (final e in Directory(root).list(recursive: true, followLinks: false)) {
          op.token.throwIfCancelled();
          if (e is! File) continue;
          total += await e.length();
          if (total > kExportResultMaxBytes) {
            throw StateError(
              'The target folder is larger than ${Fmt.bytes(kExportResultMaxBytes)}; export fewer files with the '
              'Workspaces tools instead.',
            );
          }
          sources.add(ZipSource.file(p.relative(e.path, from: root).replaceAll('\\', '/'), e.path));
        }
        if (sources.isEmpty) throw StateError('The target folder is empty');
        await Directory(staging).create(recursive: true);
        final out = p.join(staging, name);
        await SafeZip.create(out, sources, token: op.token, onProgress: (f) => op.progress(f * 0.95, 'Packing'));
        final bytes = await File(out).readAsBytes();
        await Directory(staging).delete(recursive: true);
        return (name, bytes);
      },
    );
  }
}

final modsProvider = NotifierProvider<ModsController, ModsState>(ModsController.new);

/// Live resolution report of a profile (pure, recomputed on change).
final profileReportProvider = Provider.family<ResolutionReport?, String>((ref, profileId) {
  final s = ref.watch(modsProvider);
  final prof = s.profileById(profileId);
  if (prof == null) return null;
  return ModResolver.resolve(
    profile: prof,
    library: s.manifests,
    invalid: s.invalidIds,
    target: s.targets[profileId] ?? TargetGame.unknown,
  );
});

/// Whether profiles can be applied to the active workspace here.
final canApplyHereProvider = Provider<bool>((ref) {
  final ws = ref.watch(modsProvider.select((s) => s.workspace));
  if (ws == null) return false;
  return ref.watch(capabilitiesProvider).supports(Capability.inPlaceModApply) || ws.kind.isAppOwned;
});
