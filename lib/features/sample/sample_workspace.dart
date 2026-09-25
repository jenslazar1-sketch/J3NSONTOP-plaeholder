import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:path/path.dart' as p;

import '../../core/activity/activity_controller.dart';
import '../../core/archive/safe_zip.dart';
import '../../core/platform/app_paths.dart';
import '../../core/settings/settings_controller.dart';
import '../../core/storage/atomic_file.dart';
import '../../core/utils/safe_path.dart';
import '../../core/workspace/workspace.dart';
import '../../core/workspace/workspace_controller.dart';
import 'sample_content.dart';

export 'sample_content.dart' show sampleWorkspaceName;

/// Reads a provider. Both `WidgetRef.read` and `ProviderContainer.read`
/// tear off to this type, so the logic is testable without widgets.
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// Activity tool id for sample workspace operations.
const String sampleToolId = 'workspaces.sample';

const List<String> _retryHint = [
  'Nothing outside app storage was touched.',
  'Retry any time with "Create sample workspace" in the Workspaces section.',
];

/// Creates the disposable sample workspace on first run (real files), once.
/// On failure the error is recorded in Activity and the settings flag stays
/// unset, so the next launch (or the "Create sample workspace" action)
/// retries.
Future<void> ensureSampleWorkspaceOnFirstRun(WidgetRef ref) async {
  await SampleWorkspaceService(ref.read).ensureOnFirstRun();
}

/// Creates a fresh sample workspace (even if one exists) and returns it.
/// Any feature may call this (e.g. "Create sample workspace" buttons).
Future<Workspace> createSampleWorkspace(WidgetRef ref) => SampleWorkspaceService(ref.read).create();

/// Regenerates every file of the sample workspace [workspaceId] (files and
/// meta: mod library, profiles, operation journals). Only for workspaces of
/// kind [WorkspaceKind.sample]; the caller must confirm with the user first.
/// Never touches anything outside app storage.
Future<void> resetSampleWorkspace(WidgetRef ref, String workspaceId) async {
  await SampleWorkspaceService(ref.read).reset(workspaceId);
}

/// What [installSampleContent] wrote.
class SampleInstallStats {
  const SampleInstallStats({
    required this.files,
    required this.fileBytes,
    required this.packages,
    required this.profiles,
    required this.totalBytes,
  });

  final int files;
  final int fileBytes;
  final int packages;
  final int profiles;

  /// Workspace files + packages + profiles.
  final int totalBytes;

  Map<String, num> get counts => {'files': files, 'bytes': totalBytes, 'packages': packages, 'profiles': profiles};

  @override
  String toString() => '$files files, $totalBytes bytes, $packages packages, $profiles profiles';
}

/// Writes [bundle] into a workspace: files under [rootDir], packages into
/// `<metaDir>/mods/` and profiles into `<metaDir>/profiles/` (atomic writes,
/// paths validated), then verifies every package with [SafeZip.inspect] and
/// checks its manifest id/version against the file name. Existing files at
/// the same paths are replaced; nothing else is touched.
Future<SampleInstallStats> installSampleContent({
  required String rootDir,
  required String metaDir,
  required SampleBundle bundle,
  void Function(double fraction, String message)? onProgress,
}) async {
  final total = bundle.files.length + bundle.packages.length + bundle.profiles.length;
  var done = 0;
  void tick(String what) {
    done++;
    if (done % 8 == 0 || done == total) onProgress?.call(done / total, what);
  }

  for (final e in bundle.files.entries) {
    await atomicWriteBytes(SafePath.resolveInside(rootDir, e.key), e.value);
    tick(e.key);
  }
  final modsDir = p.join(metaDir, 'mods');
  final profilesDir = p.join(metaDir, 'profiles');
  final packagePaths = <String, String>{};
  for (final e in bundle.packages.entries) {
    final path = SafePath.resolveInside(modsDir, e.key);
    await atomicWriteBytes(path, e.value);
    packagePaths[e.key] = path;
    tick('mods/${e.key}');
  }
  for (final e in bundle.profiles.entries) {
    await atomicWriteBytes(SafePath.resolveInside(profilesDir, e.key), e.value);
    tick('profiles/${e.key}');
  }

  for (final e in packagePaths.entries) {
    final inspection = SafeZip.inspect(e.value);
    if (!inspection.isSafe) {
      throw StateError('Sample package ${e.key} failed verification: ${inspection.fatal.join('; ')}');
    }
    final manifest = jsonDecode(SafeZip.readText(e.value, 'j3mod.json'));
    if (manifest is! Map<String, dynamic> || '${manifest['id']}-${manifest['version']}.j3mod' != e.key) {
      throw StateError('Sample package ${e.key}: manifest id/version do not match the file name');
    }
    for (final f in (manifest['files'] as List<dynamic>).cast<Map<String, dynamic>>()) {
      if (inspection.find(f['source'] as String) == null) {
        throw StateError('Sample package ${e.key}: ${f['source']} is missing from the archive');
      }
    }
  }
  return SampleInstallStats(
    files: bundle.files.length,
    fileBytes: bundle.fileBytes,
    packages: bundle.packages.length,
    profiles: bundle.profiles.length,
    totalBytes: bundle.totalBytes,
  );
}

/// Generates the bundle off the UI thread (PNG/ZIP encoding is CPU work).
Future<SampleBundle> generateSampleBundle() => Isolate.run(buildSampleBundle, debugName: 'j3-sample-content');

/// Sample workspace operations. Dependencies are resolved when the service is
/// created, so an operation keeps working if the calling widget goes away.
class SampleWorkspaceService {
  SampleWorkspaceService(ProviderReader read)
    : _read = read,
      _paths = read(appPathsProvider),
      _workspaces = read(workspacesProvider.notifier),
      _activity = read(activityProvider.notifier),
      _settings = read(settingsProvider.notifier);

  final ProviderReader _read;
  final AppPaths _paths;
  final WorkspaceController _workspaces;
  final ActivityController _activity;
  final SettingsController _settings;

  static final Map<String, Future<bool>> _firstRunInFlight = {};

  /// Creates the sample workspace unless `sampleWorkspaceCreated` is set.
  /// Returns true when this run created a workspace. Concurrent calls for
  /// the same data directory share one run and its result.
  Future<bool> ensureOnFirstRun() {
    final key = _paths.root;
    final running = _firstRunInFlight[key];
    if (running != null) return running;
    // Block body on purpose: returning the removed Future from the callback
    // would make whenComplete wait for itself.
    final future = _ensureOnce().whenComplete(() {
      _firstRunInFlight.remove(key);
    });
    _firstRunInFlight[key] = future;
    return future;
  }

  Future<bool> _ensureOnce() async {
    if (_read(settingsProvider).sampleWorkspaceCreated) return false;
    // The flag can be lost (settings reset) while the sample still exists.
    if (_read(workspacesProvider).workspaces.any((w) => w.kind == WorkspaceKind.sample)) {
      await _settings.update((s) => s.copyWith(sampleWorkspaceCreated: true));
      return false;
    }
    try {
      await create();
    } catch (_) {
      // Already recorded by create() as a failed Activity operation with an
      // error toast. The flag stays unset so the next launch retries.
      return false;
    }
    await _settings.update((s) => s.copyWith(sampleWorkspaceCreated: true));
    return true;
  }

  /// Creates a new app-owned sample workspace as one tracked operation. It
  /// becomes the active workspace only if no workspace was active before.
  Future<Workspace> create() async {
    final previousActive = _read(workspacesProvider).activeId;
    final id = _workspaces.newId();
    return _activity.run<Workspace>(
      toolId: sampleToolId,
      title: 'Create sample workspace',
      workspaceId: id,
      body: (op) async {
        Workspace? created;
        try {
          op.progress(0.02, 'Generating sample files');
          final bundle = await generateSampleBundle();
          op.progress(0.1, 'Writing files');
          created = await _workspaces.addAppOwned(
            sampleWorkspaceName,
            kind: WorkspaceKind.sample,
            id: id,
            note: 'Generated files for the fictional game "$sampleGameName" $sampleGameVersion.',
          );
          final meta = _workspaces.metaDir(created);
          final stats = await installSampleContent(
            rootDir: created.rootPath,
            metaDir: meta,
            bundle: bundle,
            onProgress: (f, m) => op.progress(0.1 + f * 0.9, m),
          );
          // addAppOwned activates the new workspace; restore the previous one.
          if (previousActive != null) await _workspaces.setActive(previousActive);
          op.succeed(
            '${stats.files} files, ${stats.packages} mod packages and ${stats.profiles} profiles',
            counts: stats.counts,
            details: [
              'Workspace: ${created.name}',
              'Files: ${created.rootPath}',
              'Mod library: ${p.join(meta, 'mods')}',
              'Profiles: ${p.join(meta, 'profiles')}',
              if (previousActive != null) 'The previously active workspace stays active.',
            ],
          );
          return created;
        } catch (e) {
          if (created != null) {
            try {
              await _workspaces.remove(created.id, deleteAppOwnedFiles: true);
            } catch (_) {
              // Best effort: a leftover app-owned folder is harmless.
            }
          }
          op.fail(e, details: _retryHint);
          rethrow;
        }
      },
    );
  }

  /// Regenerates all files of the sample workspace [workspaceId] in place.
  Future<SampleInstallStats> reset(String workspaceId) async {
    final w = _read(workspacesProvider).byId(workspaceId);
    if (w == null) throw ArgumentError.value(workspaceId, 'workspaceId', 'no such workspace');
    if (w.kind != WorkspaceKind.sample) {
      throw StateError('Only the sample workspace can be reset ("${w.name}" is ${w.kind.label.toLowerCase()}).');
    }
    final root = _paths.workspaceFilesDir(w.id);
    final meta = _paths.workspaceMetaDir(w.id);
    _requireAppOwned(root);
    _requireAppOwned(meta);
    if (!p.equals(p.normalize(w.rootPath), p.normalize(root))) {
      throw StateError('Refusing to reset "${w.name}": its files are not in app storage.');
    }
    return _activity.run<SampleInstallStats>(
      toolId: sampleToolId,
      title: 'Reset sample workspace',
      workspaceId: w.id,
      body: (op) async {
        op.progress(0.02, 'Generating sample files');
        final bundle = await generateSampleBundle();
        op.progress(0.1, 'Removing old files');
        await _recreate(root);
        await _recreate(meta);
        final stats = await installSampleContent(
          rootDir: root,
          metaDir: meta,
          bundle: bundle,
          onProgress: (f, m) => op.progress(0.1 + f * 0.9, m),
        );
        op.succeed(
          'Restored ${stats.files} files, ${stats.packages} mod packages and ${stats.profiles} profiles',
          counts: stats.counts,
          details: ['Workspace: ${w.name}', 'Previous files, imported mods and operation journals were replaced.'],
        );
        return stats;
      },
    );
  }

  /// Guards destructive operations: [dir] must be strictly inside the
  /// app-owned workspaces directory.
  void _requireAppOwned(String dir) {
    final base = p.normalize(p.absolute(_paths.workspacesDir));
    final target = p.normalize(p.absolute(dir));
    if (!p.isWithin(base, target)) {
      throw StateError('Refusing to modify $dir: it is outside app storage.');
    }
  }

  Future<void> _recreate(String dir) async {
    _requireAppOwned(dir);
    switch (FileSystemEntity.typeSync(dir, followLinks: false)) {
      case FileSystemEntityType.link:
        await Link(dir).delete(); // never follow a link out of app storage
      case FileSystemEntityType.notFound:
        break;
      case FileSystemEntityType.directory:
        await Directory(dir).delete(recursive: true);
      default:
        await File(dir).delete();
    }
    await Directory(dir).create(recursive: true);
  }
}
