import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/tools/tool_registry.dart';
import 'package:j3nsontop_multitool/features/dev_tools/dev_clock.dart';
import 'package:j3nsontop_multitool/features/dev_tools/dev_tools_module.dart';

import '../../helpers/harness.dart';

/// Fixed "now" for deterministic dates: Fri 2026-09-25 19:41:07.123 UTC.
final DateTime fixedNow = DateTime.utc(2026, 9, 25, 19, 41, 7, 123);

/// Phone portrait size used for the small-screen checks.
const Size smallPhone = Size(320, 568);

/// Pumps a Developer Tools page inside the real theme, effects (static) and
/// provider overrides. Overflow at [size]/[textScale] fails the test.
Future<ProviderContainer> pumpDevTool(
  WidgetTester tester,
  TestEnv env,
  String toolId, {
  Size size = const Size(1280, 1000),
  double textScale = 1.0,
  FakeFileAccess? files,
  AppPlatform platform = AppPlatform.linux,
  DateTime Function()? clock,
  List<Override> overrides = const [],
  Widget Function(Widget page)? wrap,
}) async {
  setSurface(tester, size);
  if (textScale != 1.0) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  final registry = ToolRegistry([devToolsModule]);
  final tool = registry.byId(toolId)!;
  final page = Builder(builder: tool.builder);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...env.overrides(registry: registry, platform: platform, fileAccess: files ?? FakeFileAccess()),
        devClockProvider.overrideWithValue(clock ?? () => fixedNow),
        ...overrides,
      ],
      child: themed(wrap == null ? page : wrap(page), effects: staticEffects),
    ),
  );
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
}

/// The ProviderContainer of the pumped tool page.
ProviderContainer containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));

/// Enters [text] into the field with [key] and lets live results update.
Future<void> enter(WidgetTester tester, String key, String text) async {
  final f = find.byKey(Key(key));
  expect(f, findsOneWidget, reason: 'field $key');
  await tester.enterText(find.descendant(of: f, matching: find.byType(EditableText)).first, text);
  await tester.pump();
}

/// Taps a widget found by [finder] after scrolling it into view.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder.first);
  await tester.pump();
  await tester.tap(finder.first);
  await tester.pump();
}

/// Lets real async work (file IO, isolates, sockets) progress in short
/// `runAsync` slices, pumping frames in between, until [done] holds. Each
/// step also advances fake time by 20 ms so timers created by the code
/// under test (time limits, timeouts) fire as they would in real time.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > timeout) throw StateError('condition not met within $timeout');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}
