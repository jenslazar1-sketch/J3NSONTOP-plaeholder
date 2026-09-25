import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/app_info.dart';
import 'app/tool_catalog.dart';
import 'core/diagnostics/error_log.dart';
import 'core/platform/app_paths.dart';
import 'core/storage/app_stores.dart';
import 'core/theme/j3_colors.dart';
import 'core/theme/j3_typography.dart';
import 'core/tools/tool_registry.dart';
import 'features/settings/licenses.dart';

/// Startup performs only real work: resolve the data directory, load the
/// versioned JSON stores (with recovery), build the tool registry, then run.
/// Nothing is delayed to simulate loading.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorLog.instance.install();
  registerAppLicenses();
  final launch = LaunchArgs.parse(args);
  try {
    final paths = await AppPaths.resolve(overrideRoot: launch.dataDir);
    ErrorLog.instance.attach(paths.root);
    final stores = AppStores.forPaths(paths);
    final boot = await BootData.load(stores, launchArgs: launch);
    final registry = buildToolRegistry();
    runApp(
      ProviderScope(
        overrides: [
          appPathsProvider.overrideWithValue(paths),
          appStoresProvider.overrideWithValue(stores),
          bootDataProvider.overrideWithValue(boot),
          toolRegistryProvider.overrideWithValue(registry),
        ],
        child: const J3App(),
      ),
    );
  } catch (e, st) {
    ErrorLog.instance.record(e, st, source: 'boot');
    runApp(BootFailureApp(error: e));
  }
}

/// Shown if the app cannot initialise its storage (e.g. no writable data
/// directory). Explains the problem instead of crashing silently.
class BootFailureApp extends StatelessWidget {
  const BootFailureApp({super.key, required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppInfo.shortName,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: J3Colors.background,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('J3NSONTOP SYSTEM FAULT', style: J3Type.kicker.copyWith(fontSize: 14)),
                const SizedBox(height: 12),
                Text('The app could not initialise its local storage.', style: J3Type.title),
                const SizedBox(height: 12),
                SelectableText('$error', style: J3Type.code),
                const SizedBox(height: 12),
                Text(
                  'Check that the app data directory is writable and that the disk is not full, then restart.',
                  style: J3Type.bodySecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
