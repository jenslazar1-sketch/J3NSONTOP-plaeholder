import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/workspaces/presentation/shared/requests.dart';
import 'package:j3nsontop_multitool/features/workspaces/workspaces_module.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';

/// A test app with the workspaces module, a fake file-access service and a
/// recording navigator. Real files live in the TestEnv temp directory.
class WsHarness {
  WsHarness._(this.env, this.container, this.files, this.routes);

  final TestEnv env;
  final ProviderContainer container;
  final FakeFileAccess files;
  final List<String> routes;

  static Future<WsHarness> create(WidgetTester tester, {AppPlatform platform = AppPlatform.linux}) async {
    final env = (await tester.runAsync(TestEnv.create))!;
    final files = FakeFileAccess();
    final routes = <String>[];
    final container = ProviderContainer(
      overrides: [
        ...env.overrides(modules: [workspacesModule], platform: platform, fileAccess: files),
        wsNavigatorProvider.overrideWithValue((_, route) => routes.add(route)),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await tester.runAsync(env.dispose);
    });
    return WsHarness._(env, container, files, routes);
  }

  /// Creates an app-owned workspace (active) with [files] (relative path ->
  /// content) written into it.
  Future<Workspace> workspace(
    WidgetTester tester, {
    String name = 'Test WS',
    Map<String, Object> files = const {},
  }) async {
    return (await tester.runAsync(() async {
      final w = await container.read(workspacesProvider.notifier).addAppOwned(name);
      for (final e in files.entries) {
        final f = File(p.joinAll([w.rootPath, ...e.key.split('/')]));
        await f.parent.create(recursive: true);
        final v = e.value;
        if (v is String) {
          await f.writeAsString(v);
        } else {
          await f.writeAsBytes(v as List<int>);
        }
      }
      return w;
    }))!;
  }

  Future<void> pump(WidgetTester tester, Widget page, {Size? size, double textScale = 1}) async {
    if (size != null) setSurface(tester, size);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: themed(
          Builder(
            builder: (ctx) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(textScale)),
              child: page,
            ),
          ),
          effects: staticEffects,
        ),
      ),
    );
    await tester.pump();
  }
}

/// Lets real IO / isolates complete and flushes the fake-async zone.
Future<void> settle(WidgetTester tester, {int rounds = 10, int ms = 20}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
    // Advancing fake time also fires zero-duration timers (yield points).
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Pumps until [finder] matches (real time bounded by [timeout]).
Future<void> pumpUntil(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 15)}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump(const Duration(milliseconds: 20));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder');
}

/// Scrolls the page until [finder] is visible and taps it.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  // Let caret "show on screen" scroll animations of focused fields finish:
  // scrollables ignore pointers while they animate.
  await tester.pump(const Duration(milliseconds: 400));
  await tester.ensureVisible(finder.first);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(finder.first);
  await tester.pump();
}
