import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/file_tools/file_tools_module.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/harness.dart';

/// Test environment for File Tools pages: temp data dir, real stores, a
/// fake file-access service and (optionally) an active workspace.
class FtHarness {
  FtHarness._(this.env, this.files, this.container, this.ws);

  final TestEnv env;
  final FakeFileAccess files;
  final ProviderContainer container;
  final Workspace? ws;

  /// Call from `setUp` (real async zone).
  static Future<FtHarness> create({bool withWorkspace = true}) async {
    final env = await TestEnv.create();
    final files = FakeFileAccess();
    final c = env.container(modules: [fileToolsModule], fileAccess: files);
    Workspace? ws;
    if (withWorkspace) ws = await c.read(workspacesProvider.notifier).addAppOwned('Test WS');
    return FtHarness._(env, files, c, ws);
  }

  String get root => ws!.rootPath;

  File write(String rel, List<int> bytes) {
    final f = File(p.join(root, rel));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    return f;
  }

  Widget app(Widget page) => UncontrolledProviderScope(
    container: container,
    child: themed(page, effects: staticEffects),
  );

  Future<void> dispose() async {
    container.dispose();
    // Let fire-and-forget history writes finish before the folder goes.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await env.dispose();
  }
}

/// Pumps [page] at [size] with [textScale].
Future<void> pumpPage(
  WidgetTester tester,
  FtHarness h,
  Widget page, {
  Size size = const Size(1280, 1000),
  double textScale = 1,
}) async {
  setSurface(tester, size);
  if (textScale != 1) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  await tester.pumpWidget(h.app(page));
  await tester.pump();
}

/// Alternates real-time waits (so file I/O and isolates progress) with
/// frames until [done] holds.
Future<void> waitFor(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final sw = Stopwatch()..start();
  while (!done()) {
    if (sw.elapsed > timeout) throw TestFailure('Timed out after $timeout');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    // Duration.zero (not null) so zero-delay timers created by the code under
    // test (e.g. SafeZip yielding between entries) fire in fake time.
    await tester.pump(Duration.zero);
  }
  await tester.pump(Duration.zero);
}

/// Scrolls [finder] into view inside the page and taps it.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  // Let short scroll animations finish first (e.g. a focused TextField
  // revealing its caret); a scrolling view ignores pointers meanwhile.
  await tester.pump(const Duration(milliseconds: 300));
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(finder);
  await tester.pump();
}

/// Picks "Export..." in the saveOutput sheet.
Future<void> chooseExport(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.text('Export...'));
  await tester.pump();
}
