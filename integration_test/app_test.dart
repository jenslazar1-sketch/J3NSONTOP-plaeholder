import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:j3nsontop_multitool/app/app_info.dart';
import 'package:j3nsontop_multitool/main.dart' as app;
import 'package:path/path.dart' as p;

/// End-to-end flows on a real device/desktop. Each test boots the real app
/// (same `main()` as production) with an isolated `--data-dir`, so it never
/// touches the user's data. Effects are reduced through seeded settings so
/// frames settle deterministically.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<Directory> seedDataDir({Map<String, dynamic> settings = const {}}) async {
    final dir = await Directory.systemTemp.createTemp('j3_it_');
    final data = <String, dynamic>{
      'skipIntro': true,
      'lowEffects': true,
      'motion': 'reduced',
      'particles': false,
      ...settings,
    };
    await File(p.join(dir.path, 'settings.json')).writeAsString(
      jsonEncode({'schema': 'j3nsontop.settings', 'version': 1, 'savedAt': '2026-09-25T00:00:00Z', 'data': data}),
    );
    return dir;
  }

  Future<void> settle(WidgetTester tester, [int frames = 12]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('boots to the dashboard and navigates every section', (tester) async {
    final dir = await seedDataDir();
    await app.main(['--data-dir=${dir.path}']);
    await settle(tester, 30);

    expect(find.textContaining('J3NSONTOP'), findsWidgets);
    expect(tester.takeException(), isNull);

    for (final route in [
      '/workspaces',
      '/mods',
      '/config',
      '/assets',
      '/files',
      '/dev',
      '/activity',
      '/settings',
      '/about',
      '/',
    ]) {
      // Navigate through the router the same way the UI does.
      GoRouter.of(tester.element(find.byType(Scaffold).first)).go(route);
      await settle(tester);
      expect(tester.takeException(), isNull, reason: 'route $route');
    }
    await dir.delete(recursive: true);
  });

  testWidgets('settings survive a relaunch and damaged settings are recovered', (tester) async {
    final dir = await seedDataDir(settings: {'accent': 'ember'});
    // Damage a store: the app must recover (preserving the file) instead of crashing.
    await File(p.join(dir.path, 'userdata.json')).writeAsString('{ this is not json');
    await app.main(['--data-dir=${dir.path}']);
    await settle(tester, 30);
    expect(tester.takeException(), isNull);
    final corrupt = dir.listSync().whereType<File>().where(
      (f) => p.basename(f.path).startsWith('userdata.json.corrupt-'),
    );
    expect(corrupt, isNotEmpty, reason: 'damaged file must be preserved');
    final settings = jsonDecode(await File(p.join(dir.path, 'settings.json')).readAsString()) as Map<String, dynamic>;
    expect((settings['data'] as Map)['accent'], 'ember');
    await dir.delete(recursive: true);
  });

  testWidgets('command palette opens with Ctrl+K on desktop', (tester) async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
    final dir = await seedDataDir();
    await app.main(['--data-dir=${dir.path}']);
    await settle(tester, 30);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(find.text('Search tools, sections and actions...'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.text('Search tools, sections and actions...'), findsNothing);
    expect(AppInfo.fullName, 'J3NSONTOP BIGGEST MULTITOOL MADE');
    await dir.delete(recursive: true);
  });
}
