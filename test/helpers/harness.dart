import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/platform/app_paths.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/platform/file_access.dart';
import 'package:j3nsontop_multitool/core/settings/app_settings.dart';
import 'package:j3nsontop_multitool/core/storage/app_stores.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/theme/effects.dart';
import 'package:j3nsontop_multitool/core/theme/j3_colors.dart';
import 'package:j3nsontop_multitool/core/theme/j3_theme.dart';
import 'package:j3nsontop_multitool/core/tools/tool_definition.dart';
import 'package:j3nsontop_multitool/core/tools/tool_registry.dart';

/// Isolated app environment for tests: a temp data directory with real
/// stores, plus provider overrides.
class TestEnv {
  TestEnv._(this.dir, this.paths, this.stores, this.boot);

  final Directory dir;
  final AppPaths paths;
  final AppStores stores;
  final BootData boot;

  static Future<TestEnv> create({AppSettings? settings}) async {
    final dir = await Directory.systemTemp.createTemp('j3_test_');
    final paths = AppPaths(dir.path);
    await paths.ensureCreated();
    final stores = AppStores.forPaths(paths);
    if (settings != null) await stores.settings.save(settings.toJson());
    final boot = await BootData.load(stores);
    return TestEnv._(dir, paths, stores, boot);
  }

  List<Override> overrides({
    List<FeatureModule> modules = const [],
    ToolRegistry? registry,
    AppPlatform platform = AppPlatform.linux,
    FileAccessService? fileAccess,
  }) => [
    appPathsProvider.overrideWithValue(paths),
    appStoresProvider.overrideWithValue(stores),
    bootDataProvider.overrideWithValue(boot),
    toolRegistryProvider.overrideWithValue(registry ?? ToolRegistry(modules)),
    appPlatformProvider.overrideWithValue(platform),
    fileAccessProvider.overrideWithValue(fileAccess ?? FakeFileAccess()),
  ];

  ProviderContainer container({
    List<FeatureModule> modules = const [],
    AppPlatform platform = AppPlatform.linux,
    FileAccessService? fileAccess,
  }) => ProviderContainer(
    overrides: overrides(modules: modules, platform: platform, fileAccess: fileAccess),
  );

  Future<void> dispose() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

/// File access fake: returns queued picks and records exports.
class FakeFileAccess extends FileAccessService {
  final List<List<PickedLocalFile>> queuedPicks = [];
  String? queuedDirectory;
  final List<(String name, List<int> bytes)> savedBytes = [];
  final List<List<String>> shared = [];
  final List<String> copied = [];

  @override
  Future<List<PickedLocalFile>> pickFiles({
    bool multiple = true,
    List<String>? extensions,
    String? destinationDir,
    CancellationToken? token,
  }) async => queuedPicks.isEmpty ? const [] : queuedPicks.removeAt(0);

  @override
  Future<String?> pickDirectory({String? title}) async => queuedDirectory;

  @override
  Future<ExportResult> saveBytes({
    required String suggestedName,
    required Uint8List bytes,
    String mimeType = 'application/octet-stream',
  }) async {
    savedBytes.add((suggestedName, bytes));
    return ExportResult.saved('/fake/$suggestedName');
  }

  @override
  Future<ExportResult> shareFiles(List<String> paths, {String? text}) async {
    shared.add(paths);
    return const ExportResult.saved(null);
  }

  @override
  Future<bool> reveal(String path) async => false;

  @override
  Future<void> copyText(String text) async => copied.add(text);
}

/// Wraps [child] with theme, effects and a Material ancestor.
Widget themed(Widget child, {EffectsConfig effects = EffectsConfig.fallback, Size? size}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: J3Theme.build(effects.accent),
    home: J3Effects(
      config: effects,
      child: Scaffold(body: child),
    ),
  );
}

/// Effects with all motion disabled (deterministic widget tests).
const EffectsConfig staticEffects = EffectsConfig(
  reduceMotion: true,
  intensity: 0,
  scanlines: false,
  particles: false,
  glow: false,
  accent: AccentPreset.neon,
  sound: false,
  volume: 0,
);

bool _fontsLoaded = false;

/// Loads the bundled fonts so screenshots/goldens render real glyphs
/// instead of the test font.
Future<void> loadAppFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.sublistView(File('assets/fonts/$f').readAsBytesSync())));
    }
    await loader.load();
  }

  await load('ChakraPetch', [
    'ChakraPetch_400Regular.ttf',
    'ChakraPetch_500Medium.ttf',
    'ChakraPetch_600SemiBold.ttf',
    'ChakraPetch_700Bold.ttf',
  ]);
  await load('JetBrainsMono', [
    'JetBrainsMono_400Regular.ttf',
    'JetBrainsMono_500Medium.ttf',
    'JetBrainsMono_700Bold.ttf',
  ]);
  // Material icons for realistic screenshots.
  final iconFont = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/sdk/flutter'}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (iconFont.existsSync()) {
    final loader = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(iconFont.readAsBytesSync())));
    await loader.load();
  }
}

/// Sets the test surface size (logical pixels) and resets it afterwards.
void setSurface(WidgetTester tester, Size size, {double dpr = 1}) {
  tester.view.physicalSize = size * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
}
