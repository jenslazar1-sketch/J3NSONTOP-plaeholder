import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/app_paths.dart';
import 'json_store.dart';

/// Schema identifiers and current versions of every persisted document.
/// Bump a version only together with a migration in [AppStores.migrations]
/// and a test in test/core/storage_migration_test.dart.
abstract final class StoreSchemas {
  static const settings = ('j3nsontop.settings', 1);
  static const userData = ('j3nsontop.userdata', 1);
  static const history = ('j3nsontop.history', 1);
  static const workspaces = ('j3nsontop.workspaces', 1);
  static const features = ('j3nsontop.features', 1);
}

/// All JSON documents the app persists.
class AppStores {
  AppStores({
    required this.settings,
    required this.userData,
    required this.history,
    required this.workspaces,
    required this.features,
  });

  factory AppStores.forPaths(AppPaths paths) {
    JsonDocumentStore make(String path, (String, int) schema) => JsonDocumentStore(
      path: path,
      schema: schema.$1,
      currentVersion: schema.$2,
      defaults: () => <String, dynamic>{},
      migrations: migrations[schema.$1],
    );
    return AppStores(
      settings: make(paths.settingsFile, StoreSchemas.settings),
      userData: make(paths.userDataFile, StoreSchemas.userData),
      history: make(paths.historyFile, StoreSchemas.history),
      workspaces: make(paths.workspacesFile, StoreSchemas.workspaces),
      features: make(paths.featureDataFile, StoreSchemas.features),
    );
  }

  final JsonDocumentStore settings;
  final JsonDocumentStore userData;
  final JsonDocumentStore history;
  final JsonDocumentStore workspaces;
  final JsonDocumentStore features;

  /// Registered schema migrations, keyed by schema id then source version.
  /// All documents are at v1 in release 1.0.0; the framework is exercised by
  /// unit tests with synthetic versions.
  static const Map<String, Map<int, JsonMigration>> migrations = {};

  List<JsonDocumentStore> get all => [settings, userData, history, workspaces, features];
}

/// Results of loading every store at startup (including recovery notices).
class BootData {
  const BootData({
    required this.settings,
    required this.userData,
    required this.history,
    required this.workspaces,
    required this.features,
    this.launchArgs = const LaunchArgs(),
  });

  final LoadResult settings;
  final LoadResult userData;
  final LoadResult history;
  final LoadResult workspaces;
  final LoadResult features;
  final LaunchArgs launchArgs;

  List<LoadResult> get all => [settings, userData, history, workspaces, features];

  /// Human-readable notices for recovered or migrated documents.
  List<String> get notices => [
    for (final r in all)
      if (r.message != null) r.message!,
  ];

  static Future<BootData> load(AppStores stores, {LaunchArgs launchArgs = const LaunchArgs()}) async {
    final results = await Future.wait(stores.all.map((s) => s.load()));
    return BootData(
      settings: results[0],
      userData: results[1],
      history: results[2],
      workspaces: results[3],
      features: results[4],
      launchArgs: launchArgs,
    );
  }
}

/// Parsed command-line arguments (desktop). Mobile launches have none.
class LaunchArgs {
  const LaunchArgs({this.dataDir, this.smokeTestReport, this.skipIntro = false});

  /// `--data-dir=<path>`: use an isolated data directory.
  final String? dataDir;

  /// `--smoke-test=<report.json>`: run the packaged-app self test, write a
  /// JSON report and exit.
  final String? smokeTestReport;

  /// `--skip-intro`
  final bool skipIntro;

  bool get isSmokeTest => smokeTestReport != null;

  static LaunchArgs parse(List<String> args) {
    String? dataDir;
    String? smoke;
    var skip = false;
    for (final a in args) {
      if (a.startsWith('--data-dir=')) {
        dataDir = a.substring('--data-dir='.length);
      } else if (a.startsWith('--smoke-test=')) {
        smoke = a.substring('--smoke-test='.length);
      } else if (a == '--skip-intro') {
        skip = true;
      }
    }
    return LaunchArgs(dataDir: dataDir, smokeTestReport: smoke, skipIntro: skip || smoke != null);
  }
}

final appStoresProvider = Provider<AppStores>(
  (ref) => throw UnimplementedError('appStoresProvider must be overridden'),
);

final bootDataProvider = Provider<BootData>((ref) => throw UnimplementedError('bootDataProvider must be overridden'));
