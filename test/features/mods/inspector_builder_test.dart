import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/platform/file_access.dart';
import 'package:j3nsontop_multitool/features/mods/data/mod_library.dart';
import 'package:j3nsontop_multitool/features/mods/domain/package_inspector.dart';
import 'package:j3nsontop_multitool/features/mods/mods_module.dart';
import 'package:j3nsontop_multitool/features/mods/presentation/builder_page.dart';
import 'package:j3nsontop_multitool/features/mods/presentation/inspector_page.dart';
import 'package:j3nsontop_multitool/features/mods/presentation/mods_controller.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';
import '../../helpers/raw_zip.dart';
import 'mod_fixtures.dart';
import 'mods_workspace_fixture.dart';

void main() {
  group('inspector', () {
    testWidgets('shows issues for a hostile package picked from the device', (tester) async {
      setSurface(tester, const Size(1300, 1000));
      final env = await widgetEnv(tester);
      final files = FakeFileAccess();
      final c = ProviderContainer(
        overrides: env.overrides(modules: [modsModule], fileAccess: files),
      );
      addTearDown(c.dispose);
      final bad = writeRawZip(env.dir, 'evil.j3mod', [
        RawZipEntry('j3mod.json', utf8.encode(jsonEncode({...manifestMap(id: 'evil-mod'), 'version': '1.0'}))),
        RawZipEntry('files/data/a.txt', utf8.encode('a')),
        RawZipEntry('../../escape.dll', utf8.encode('x')),
      ]);
      files.queuedPicks.add([PickedLocalFile(name: 'evil.j3mod', path: bad, size: File(bad).lengthSync())]);

      await tester.pumpWidget(scoped(c, const ModInspectorPage()));
      expect(find.text('Nothing inspected yet'), findsOneWidget);
      await tapVisible(tester, find.text('Choose package'));
      await pumpUntil(tester, () => c.read(inspectorProvider).report != null, reason: 'inspection');
      await tester.pump();
      expect(find.text('ERROR // Blocked: 2 error(s)'), findsOneWidget);
      expect(find.textContaining('parent-directory traversal'), findsWidgets);
      expect(find.textContaining('is not a semantic version'), findsWidgets);
      expect(find.text('Import to library'), findsNothing);
      expect(find.textContaining('BLOCKED (2 error(s)'), findsOneWidget);
    });

    testWidgets('valid package from the workspace can be imported to the library', (tester) async {
      setSurface(tester, const Size(1300, 1000));
      final env = await widgetEnv(tester);
      final files = FakeFileAccess();
      final c = ProviderContainer(
        overrides: env.overrides(modules: [modsModule], fileAccess: files),
      );
      addTearDown(c.dispose);
      final ws = (await tester.runAsync(() => createModsWorkspace(c, withProfiles: false)))!;
      final pkg = p.join(ws.root, 'downloads', 'extra-mod-1.0.0.j3mod');
      files.queuedPicks.add([PickedLocalFile(name: 'extra-mod-1.0.0.j3mod', path: pkg, size: File(pkg).lengthSync())]);

      await tester.pumpWidget(scoped(c, const ModInspectorPage()));
      await pumpUntil(tester, () => c.read(modsProvider).phase == ModsPhase.ready);
      await tapVisible(tester, find.text('Choose package'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('From device'));
      await pumpUntil(tester, () => c.read(inspectorProvider).report != null, reason: 'inspection');
      expect(find.text('OK // Valid package'), findsOneWidget);
      expect(find.text('data/extra.txt'), findsOneWidget);
      expect(find.text('j3mod.json'), findsOneWidget);

      await tapVisible(tester, find.text('Import to library'));
      await pumpUntil(
        tester,
        () => c.read(modsProvider).library.any((e) => e.id == 'extra-mod'),
        reason: 'library import',
      );
      final listed = (await tester.runAsync(() => ModLibrary(ws.meta).list()))!;
      expect(listed.map((e) => e.fileName), contains('extra-mod-1.0.0.j3mod'));
    });

    testWidgets('no overflow at 320px with 2x text showing a report', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      setSurface(tester, const Size(320, 568));
      final env = await widgetEnv(tester);
      final files = FakeFileAccess();
      final c = ProviderContainer(
        overrides: env.overrides(modules: [modsModule], fileAccess: files),
      );
      addTearDown(c.dispose);
      final pkg = (await tester.runAsync(
        () => buildPackage(
          env.dir,
          id: 'neon-hud',
          contents: {'data/ui/very/long/path/to/some/deeply/nested/hud-configuration-file.json': '{}'},
          deps: [
            {'id': 'core-patch', 'version': '^1.0.0'},
          ],
          extraEntries: {
            'files/unmapped.bin': [1, 2],
          },
        ),
      ))!;
      files.queuedPicks.add([PickedLocalFile(name: 'neon-hud.j3mod', path: pkg, size: File(pkg).lengthSync())]);
      await tester.pumpWidget(scoped(c, const ModInspectorPage()));
      await tapVisible(tester, find.text('Choose package'));
      await pumpUntil(tester, () => c.read(inspectorProvider).report != null);
      await tester.pump();
      expect(find.textContaining('Valid with 1 warning(s)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('builder', () {
    Future<(ProviderContainer, FakeFileAccess, TestEnv)> boot(WidgetTester tester, Size size) async {
      setSurface(tester, size);
      final env = await widgetEnv(tester);
      final files = FakeFileAccess();
      final c = ProviderContainer(
        overrides: env.overrides(modules: [modsModule], fileAccess: files),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(scoped(c, const ModBuilderPage()));
      await tester.pump();
      return (c, files, env);
    }

    Finder fieldLabeled(String label) =>
        find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == label);

    testWidgets('live validation messages from the shared validator', (tester) async {
      await boot(tester, const Size(1300, 1400));
      expect(find.text('1.0.0'), findsWidgets, reason: 'version defaults to 1.0.0');
      await tester.enterText(fieldLabeled('Id'), 'Bad Id');
      await tester.enterText(fieldLabeled('Version'), '1.0');
      await tester.enterText(fieldLabeled('Dependencies: one "id [constraint]" per line'), 'core-patch ^^1');
      await tester.pump();
      expect(find.textContaining('"Bad Id" is not a valid id'), findsWidgets);
      expect(find.textContaining('"1.0" is not a semantic version'), findsWidgets);
      expect(find.textContaining('is not a valid version constraint'), findsWidgets);
      expect(find.textContaining('must not be empty; a package must map at least one file'), findsWidgets);
      expect(find.textContaining('problem(s) to fix'), findsOneWidget);
      final build = tester.widget<Widget>(
        find.ancestor(of: find.text('Build package'), matching: find.byType(Tooltip)),
      );
      expect(build, isNotNull);
    });

    testWidgets('builds a valid package from device files and exports it', (tester) async {
      final (c, files, env) = await boot(tester, const Size(1300, 1400));
      final a = File(p.join(env.dir.path, 'hud.json'))..writeAsStringSync('{"color":"red"}');
      final b = File(p.join(env.dir.path, 'icons.txt'))..writeAsStringSync('icons');
      files.queuedPicks.add([
        PickedLocalFile(name: 'hud.json', path: a.path, size: a.lengthSync()),
        PickedLocalFile(name: 'icons.txt', path: b.path, size: b.lengthSync()),
      ]);
      await tester.enterText(fieldLabeled('Target prefix (optional)'), 'data/ui');
      await tapVisible(tester, find.text('Pick files from device'));
      await pumpUntil(tester, () => c.read(builderProvider).files.length == 2, reason: 'files picked');
      expect(c.read(builderProvider).files.map((f) => f.target), ['data/ui/hud.json', 'data/ui/icons.txt']);

      await tester.enterText(fieldLabeled('Id'), 'neon-hud');
      await tester.enterText(fieldLabeled('Name'), 'Neon HUD');
      await tester.enterText(fieldLabeled('Compatible game id (optional)'), 'neon-dungeon');
      await tester.enterText(fieldLabeled('Game version constraint (optional)'), '>=1.4.0 <2.0.0');
      await tester.enterText(fieldLabeled('Tags (comma separated)'), 'ui, neon');
      await tester.pump();
      expect(find.text('Ready to build'), findsOneWidget);
      expect(find.textContaining('"target": "data/ui/hud.json"'), findsOneWidget);

      // No workspace: the library option is unavailable; export instead.
      await tapVisible(tester, find.text('Export a copy'));
      await tester.pump();
      await tapVisible(tester, find.text('Build package'));
      await pumpUntil(tester, () => shows(find.text('Export...')), reason: 'save sheet');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Export...'));
      await pumpUntil(tester, () => c.read(builderProvider).result != null, reason: 'build result');
      expect(c.read(builderProvider).result!.title, 'Package built');
      expect(files.savedBytes.single.$1, 'neon-hud-1.0.0.j3mod');
      final out = File(p.join(env.dir.path, 'exported.j3mod'))..writeAsBytesSync(files.savedBytes.single.$2);
      final report = PackageInspector.inspect(out.path);
      expect(report.isValid, isTrue, reason: report.issues.join('\n'));
      expect(report.manifest!.files.map((f) => f.target), ['data/ui/hud.json', 'data/ui/icons.txt']);
      expect(report.manifest!.compatibility.game, 'neon-dungeon');
      expect(report.manifest!.tags, ['ui', 'neon']);
    });

    testWidgets('base folder in the workspace maps files and builds into the library', (tester) async {
      setSurface(tester, const Size(1300, 1400));
      final env = await widgetEnv(tester);
      final c = ProviderContainer(overrides: env.overrides(modules: [modsModule]));
      addTearDown(c.dispose);
      final ws = (await tester.runAsync(() => createModsWorkspace(c, withProfiles: false)))!;
      writeTree(ws.root, {'my-mod/data/ui/hud.json': '{"x":1}', 'my-mod/config/extra.ini': '[x]'});
      await tester.pumpWidget(scoped(c, const ModBuilderPage()));
      await pumpUntil(tester, () => c.read(modsProvider).phase == ModsPhase.ready);
      await tapVisible(tester, find.text('Choose base folder'));
      await pumpUntil(tester, () => shows(find.widgetWithText(ListTile, 'my-mod')), reason: 'browser');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.widgetWithText(ListTile, 'my-mod').first);
      await pumpUntil(tester, () => shows(find.widgetWithText(ListTile, 'config')), reason: 'folder opened');
      await tester.tap(find.text('Use this folder'));
      await pumpUntil(tester, () => c.read(builderProvider).files.length == 2, reason: 'folder listed');
      expect(c.read(builderProvider).files.map((f) => f.target), ['config/extra.ini', 'data/ui/hud.json']);
      expect(find.text('my-mod'), findsWidgets, reason: 'id/name prefilled from the folder');
      await tester.pump();
      await tapVisible(tester, find.text('Build package'));
      await pumpUntil(tester, () => c.read(modsProvider).library.any((e) => e.id == 'my-mod'), reason: 'imported');
      await pumpUntil(tester, () => c.read(builderProvider).result != null);
      expect(c.read(builderProvider).result!.details.join(' '), contains('imported'));
    });

    testWidgets('no overflow at 320px with 2x text', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final (c, files, env) = await boot(tester, const Size(320, 568));
      final a = File(p.join(env.dir.path, 'a-really-long-file-name-for-the-hud-configuration.json'))
        ..writeAsStringSync('{}');
      files.queuedPicks.add([PickedLocalFile(name: p.basename(a.path), path: a.path, size: 2)]);
      await tapVisible(tester, find.text('Pick files from device'));
      await pumpUntil(tester, () => c.read(builderProvider).files.length == 1);
      await tester.enterText(fieldLabeled('Id'), 'X');
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
