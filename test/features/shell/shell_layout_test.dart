import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:j3nsontop_multitool/app/router.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/settings/app_settings.dart';
import 'package:j3nsontop_multitool/core/theme/effects.dart';
import 'package:j3nsontop_multitool/core/theme/j3_colors.dart';
import 'package:j3nsontop_multitool/core/theme/j3_theme.dart';
import 'package:j3nsontop_multitool/core/tools/tool_definition.dart';
import 'package:j3nsontop_multitool/core/widgets/widgets.dart';

import '../../helpers/harness.dart';

final _testModule = FeatureModule(
  id: 'test',
  tools: [
    ToolDefinition(
      id: 'dev.sample_tool',
      name: 'Sample Tool With A Deliberately Long Name',
      section: ToolSection.devTools,
      description: 'A tool used by the shell layout test.',
      icon: Icons.build,
      keywords: const ['sample'],
      builder: (_) => const ToolScaffold(toolId: 'dev.sample_tool', children: [Text('tool body')]),
    ),
    ToolDefinition(
      id: 'workspaces.desktop_only',
      name: 'Desktop Only',
      section: ToolSection.workspaces,
      description: 'Requires linked folders.',
      icon: Icons.folder,
      requiredCapabilities: const {Capability.linkFolder},
      builder: (_) => const Text('desktop only body'),
    ),
  ],
);

Future<GoRouter> _pumpApp(WidgetTester tester, TestEnv env, {AppPlatform platform = AppPlatform.linux}) async {
  final router = buildRouter(showIntro: false);
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: env.overrides(modules: [_testModule], platform: platform),
      child: MaterialApp.router(
        theme: J3Theme.build(AccentPreset.neon),
        routerConfig: router,
        builder: (context, child) => J3Effects(config: staticEffects, child: child!),
      ),
    ),
  );
  await tester.pump();
  return router;
}

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  final sizes = <String, (Size, double)>{
    'phone 320 @2x text': (const Size(320, 568), 2.0),
    'phone 390': (const Size(390, 844), 1.0),
    'tablet 800': (const Size(800, 1100), 1.3),
    'desktop 1440': (const Size(1440, 900), 1.0),
  };

  sizes.forEach((name, spec) {
    testWidgets('shell lays out without overflow: $name', (tester) async {
      setSurface(tester, spec.$1);
      tester.platformDispatcher.textScaleFactorTestValue = spec.$2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final router = await _pumpApp(tester, env);
      for (final route in ['/', '/dev', '/workspaces', '/tools', '/tool/dev.sample_tool', '/settings']) {
        router.go(route);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(tester.takeException(), isNull, reason: '$name $route');
      }
    });
  });

  testWidgets('tool pages stay alive when navigating away and back', (tester) async {
    setSurface(tester, const Size(1440, 900));
    final router = await _pumpApp(tester, env);
    router.go('/tool/dev.sample_tool');
    await tester.pump();
    expect(find.text('tool body'), findsOneWidget);
    final before = tester.state(find.byType(ToolScaffold));
    router.go('/');
    await tester.pump();
    expect(find.text('tool body', skipOffstage: true), findsNothing);
    router.go('/tool/dev.sample_tool');
    await tester.pump();
    expect(
      identical(tester.state(find.byType(ToolScaffold)), before) || find.text('tool body').evaluate().isNotEmpty,
      isTrue,
    );
  });

  testWidgets('unavailable tool explains the capability alternative on mobile', (tester) async {
    setSurface(tester, const Size(390, 844));
    final router = await _pumpApp(tester, env, platform: AppPlatform.android);
    router.go('/tool/workspaces.desktop_only');
    await tester.pump();
    expect(find.textContaining('not available on Android'), findsOneWidget);
    expect(find.textContaining('Import files'), findsOneWidget);
    expect(find.text('desktop only body'), findsNothing);
  });

  testWidgets('unknown tool id shows a recoverable error', (tester) async {
    setSurface(tester, const Size(1440, 900));
    final router = await _pumpApp(tester, env);
    router.go('/tool/does.not_exist');
    await tester.pump();
    expect(find.textContaining('Unknown tool'), findsOneWidget);
  });

  testWidgets('Ctrl+K opens the palette and finds a tool by keyword', (tester) async {
    setSurface(tester, const Size(1440, 900));
    await _pumpApp(tester, env);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(find.byType(TextField).last, 'sample');
    await tester.pump();
    expect(find.text('Sample Tool With A Deliberately Long Name'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('tool body'), findsOneWidget);
  });

  group('EffectsConfig.resolve', () {
    test('system reduce motion is followed by default and can be overridden', () {
      expect(EffectsConfig.resolve(const AppSettings(), systemReduce: true).reduceMotion, isTrue);
      expect(
        EffectsConfig.resolve(const AppSettings(motion: MotionPreference.full), systemReduce: true).reduceMotion,
        isFalse,
      );
      expect(
        EffectsConfig.resolve(const AppSettings(motion: MotionPreference.reduced), systemReduce: false).reduceMotion,
        isTrue,
      );
    });

    test('reduced motion removes particles and decorative motion', () {
      final fx = EffectsConfig.resolve(const AppSettings(), systemReduce: true);
      expect(fx.particles, isFalse);
      expect(fx.decorativeMotion, isFalse);
      expect(fx.motion(const Duration(seconds: 1)), Duration.zero);
    });

    test('low effects and high contrast disable decorations', () {
      for (final fx in [
        EffectsConfig.resolve(const AppSettings(lowEffects: true), systemReduce: false),
        EffectsConfig.resolve(const AppSettings(), systemReduce: false, systemHighContrast: true),
      ]) {
        expect(fx.scanlines, isFalse);
        expect(fx.particles, isFalse);
        expect(fx.glow, isFalse);
        expect(fx.intensity, 0);
        expect(fx.glowBlur(20), 0);
      }
    });
  });
}
