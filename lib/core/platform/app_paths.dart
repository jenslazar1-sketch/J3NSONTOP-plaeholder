import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// All locations the app writes to. Everything lives inside the app's own
/// support directory unless the user explicitly links or exports elsewhere.
class AppPaths {
  AppPaths(this.root);

  /// Root of app-owned data (platform application-support directory, or a
  /// directory supplied with `--data-dir` for tests and smoke runs).
  final String root;

  String get settingsFile => p.join(root, 'settings.json');
  String get userDataFile => p.join(root, 'userdata.json');
  String get historyFile => p.join(root, 'history.json');
  String get workspacesFile => p.join(root, 'workspaces.json');
  String get featureDataFile => p.join(root, 'features.json');

  /// Imported/sample workspace copies and per-workspace metadata.
  String get workspacesDir => p.join(root, 'workspaces');

  /// Scratch space for picked files, previews and staged exports.
  String get cacheDir => p.join(root, 'cache');
  String get pickedDir => p.join(cacheDir, 'picked');
  String get exportStagingDir => p.join(cacheDir, 'export');

  /// Directory holding the files of an imported or sample workspace.
  String workspaceFilesDir(String workspaceId) =>
      p.join(workspacesDir, workspaceId, 'files');

  /// App-owned metadata for any workspace (linked ones included): mod
  /// library, profiles, operation journals and backups. Kept outside linked
  /// folders so the user's game directory stays clean.
  String workspaceMetaDir(String workspaceId) =>
      p.join(workspacesDir, workspaceId, 'meta');

  Future<void> ensureCreated() async {
    for (final dir in [root, workspacesDir, cacheDir, pickedDir]) {
      await Directory(dir).create(recursive: true);
    }
  }

  /// Resolves the platform support directory. [overrideRoot] comes from the
  /// `--data-dir` launch argument (used by smoke tests).
  static Future<AppPaths> resolve({String? overrideRoot}) async {
    final String root;
    if (overrideRoot != null && overrideRoot.isNotEmpty) {
      root = p.absolute(overrideRoot);
    } else {
      final support = await getApplicationSupportDirectory();
      root = support.path;
    }
    final paths = AppPaths(root);
    await paths.ensureCreated();
    return paths;
  }
}

/// Overridden in `main()` with the resolved paths.
final appPathsProvider = Provider<AppPaths>(
  (ref) => throw UnimplementedError('appPathsProvider must be overridden'),
);
