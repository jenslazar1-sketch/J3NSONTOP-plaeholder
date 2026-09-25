import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/settings/settings_controller.dart';
import 'package:j3nsontop_multitool/core/theme/effects.dart';
import 'package:j3nsontop_multitool/core/theme/j3_colors.dart';
import 'package:j3nsontop_multitool/core/theme/j3_theme.dart';
import 'package:j3nsontop_multitool/core/tools/tool_definition.dart';
import 'package:j3nsontop_multitool/core/tools/tool_registry.dart';
import 'package:j3nsontop_multitool/features/activity/activity_screen.dart';
import 'package:j3nsontop_multitool/features/home/home_screen.dart';
import 'package:j3nsontop_multitool/features/settings/about_screen.dart';
import 'package:j3nsontop_multitool/features/settings/settings_screen.dart';

import '../../helpers/harness.dart';

/// Shared test setup for the Home, Settings, About and Activity screens.

ToolDefinition fakeTool(String id, String name, ToolSection section, {Set<AppPlatform>? platforms}) => ToolDefinition(
  id: id,
  name: name,
  section: section,
  description: '$name test description',
  icon: Icons.build_outlined,
  builder: (_) => const SizedBox.shrink(),
  platforms: platforms ?? const {AppPlatform.android, AppPlatform.ios, AppPlatform.windows, AppPlatform.linux},
);

/// Five tools; one is Windows-only, so Linux shows 4/5 available.
ToolRegistry buildTestRegistry() => ToolRegistry([
  FeatureModule(
    id: 'fake',
    tools: [
      fakeTool('files.hash', 'Hash files', ToolSection.fileTools),
      fakeTool('dev.base64', 'Base64 codec', ToolSection.devTools),
      fakeTool('mods.profiles', 'Mod profiles', ToolSection.mods),
      fakeTool('system.terminal', 'Terminal', ToolSection.system),
      fakeTool('assets.winonly', 'Windows only tool', ToolSection.assetLab, platforms: const {AppPlatform.windows}),
    ],
  ),
]);

/// Effects with motion enabled (for animation tests) but no background
/// decorations.
const EffectsConfig motionEffects = EffectsConfig(
  reduceMotion: false,
  intensity: 0.6,
  scanlines: false,
  particles: false,
  glow: true,
  accent: AccentPreset.neon,
  sound: false,
  volume: 0,
);

/// Placeholder text shown for routes that are not under test.
String routeLabel(String location) => 'ROUTE $location';

/// App with the four screens under test plus placeholder routes. When
/// [liveEffects] is true, effects are resolved from the settings provider
/// like the real app; otherwise [effects] is used.
Widget buildExperienceApp(
  TestEnv env, {
  String initial = '/',
  EffectsConfig effects = staticEffects,
  bool liveEffects = false,
  AppPlatform platform = AppPlatform.linux,
  FakeFileAccess? fileAccess,
  ToolRegistry? registry,
}) {
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/',
        builder: (c, s) => const Scaffold(body: HomeScreen()),
      ),
      GoRoute(
        path: '/settings',
        builder: (c, s) => const Scaffold(body: SettingsScreen()),
      ),
      GoRoute(
        path: '/about',
        builder: (c, s) => const Scaffold(body: AboutScreen()),
      ),
      GoRoute(
        path: '/activity',
        builder: (c, s) => const Scaffold(body: ActivityScreen()),
      ),
      GoRoute(
        path: '/intro',
        builder: (c, s) => Scaffold(body: Text('INTRO replay=${s.uri.queryParameters['replay']}')),
      ),
      GoRoute(
        path: '/tool/:id',
        builder: (c, s) => Scaffold(body: Text('TOOL ${s.pathParameters['id']}')),
      ),
      for (final path in ['/tools', '/workspaces', '/mods', '/config', '/assets', '/files', '/dev'])
        GoRoute(
          path: path,
          builder: (c, s) => Scaffold(body: Text(routeLabel(path))),
        ),
    ],
  );
  addTearDown(router.dispose);
  return ProviderScope(
    overrides: env.overrides(
      registry: registry ?? buildTestRegistry(),
      platform: platform,
      fileAccess: fileAccess ?? FakeFileAccess(),
    ),
    child: Consumer(
      builder: (context, ref, _) {
        final settings = ref.watch(settingsProvider);
        return MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: J3Theme.build(liveEffects ? settings.accent : effects.accent),
          routerConfig: router,
          builder: (context, child) => J3Effects(
            config: liveEffects
                ? EffectsConfig.resolve(settings, systemReduce: MediaQuery.of(context).disableAnimations)
                : effects,
            child: child ?? const SizedBox.shrink(),
          ),
        );
      },
    ),
  );
}

/// The provider container of the app under test.
ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

/// Lets real file I/O started by widgets complete (widget tests run in a
/// fake-async zone), pumping frames in between.
Future<void> settleIo(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    await tester.pump();
  }
}

/// Pumps until [finder] matches or [rounds] I/O rounds have passed.
Future<void> pumpUntilFound(WidgetTester tester, Finder finder, {int rounds = 60}) async {
  for (var i = 0; i < rounds; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    await tester.pump();
  }
}

/// Phone surface with doubled text size; resets afterwards.
void usePhoneWithLargeText(WidgetTester tester) {
  setSurface(tester, const Size(320, 568));
  tester.platformDispatcher.textScaleFactorTestValue = 2.0;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Scrolls the primary scrollable through its whole extent so every part
/// of the page is laid out and painted.
Future<void> scrollThrough(WidgetTester tester, {double step = 400}) async {
  final scrollable = find.byType(Scrollable).first;
  for (var i = 0; i < 80; i++) {
    final state = tester.state<ScrollableState>(scrollable);
    final pos = state.position;
    if (pos.pixels >= pos.maxScrollExtent) break;
    pos.jumpTo((pos.pixels + step).clamp(0, pos.maxScrollExtent));
    await tester.pump();
  }
}

/// Repeats [read] (with real I/O time and a frame in between) until [ok]
/// accepts its result or [rounds] are used up; returns the last result.
Future<T> eventually<T>(
  WidgetTester tester,
  Future<T> Function() read,
  bool Function(T value) ok, {
  int rounds = 120,
}) async {
  late T value;
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    await tester.pump();
    value = (await tester.runAsync(read)) as T;
    if (ok(value)) return value;
  }
  return value;
}

/// Reads the `data` of a persisted JSON document straight from disk without
/// going through the store (whose `load()` would "recover" the `.tmp` file
/// of a save that is still in flight). Missing or unreadable files give `{}`.
Future<Map<String, dynamic>> readDocumentData(String path) async {
  final f = File(path);
  if (!await f.exists()) return <String, dynamic>{};
  try {
    final decoded = jsonDecode(await f.readAsString());
    if (decoded is Map<String, dynamic> && decoded['data'] is Map<String, dynamic>) {
      return decoded['data'] as Map<String, dynamic>;
    }
  } on FormatException {
    // Not a complete document yet.
  }
  return <String, dynamic>{};
}
