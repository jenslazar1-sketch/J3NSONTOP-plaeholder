import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/drafts/drafts.dart';
import 'package:j3nsontop_multitool/core/platform/file_access.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/config_lab_module.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';

/// Pumps a Config Lab page inside a themed app with real stores.
Future<ProviderContainer> pumpLabPage(
  WidgetTester tester,
  TestEnv env,
  Widget page, {
  Size size = const Size(1400, 2400),
  double textScale = 1.0,
  FakeFileAccess? files,
}) async {
  setSurface(tester, size);
  if (textScale != 1.0) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  final container = env.container(modules: [configLabModule], fileAccess: files ?? FakeFileAccess());
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: themed(page, effects: staticEffects),
    ),
  );
  await tester.pump();
  return container;
}

/// Lets real IO / isolate work complete, then pumps.
Future<void> settleIo(WidgetTester tester, {int rounds = 3, int ms = 60}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
    await tester.pump();
  }
}

/// Waits (in real time) until [condition] holds, pumping in between.
Future<void> waitFor(WidgetTester tester, bool Function() condition, {int maxRounds = 60}) async {
  for (var i = 0; i < maxRounds && !condition(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  expect(condition(), isTrue, reason: 'condition not reached in time');
  // State changed during the last microtask flush schedules another frame.
  await tester.pump();
}

TextEditingController draftText(ProviderContainer c, String key) => c.read(draftTextProvider(key));

/// Creates an active app-owned workspace and writes [files] into it.
Future<Workspace> createWorkspace(WidgetTester tester, ProviderContainer c, Map<String, String> files) async {
  late Workspace ws;
  await tester.runAsync(() async {
    ws = await c.read(workspacesProvider.notifier).addAppOwned('Test workspace');
    for (final e in files.entries) {
      final f = File(p.join(ws.rootPath, e.key));
      await f.parent.create(recursive: true);
      await f.writeAsString(e.value);
    }
  });
  await tester.pump();
  return ws;
}

/// A file outside any workspace for FakeFileAccess picks.
PickedLocalFile writePickedFile(TestEnv env, String name, String content) {
  final dir = Directory(p.join(env.dir.path, 'picked-${DateTime.now().microsecondsSinceEpoch}'))..createSync();
  final f = File(p.join(dir.path, name))..writeAsStringSync(content);
  return PickedLocalFile(name: name, path: f.path, size: f.lengthSync());
}

/// Scrolls until [finder] is visible in the page's main scrollable.
Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  await tester.pump();
}
