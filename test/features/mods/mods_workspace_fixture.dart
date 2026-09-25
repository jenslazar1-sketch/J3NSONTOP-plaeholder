import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/mods/data/profile_store.dart';
import 'package:j3nsontop_multitool/features/mods/domain/profile.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';
import 'mod_fixtures.dart';

/// A NEON DUNGEON-like workspace with a mod library and the sample profiles
/// described in docs/SAMPLES.md.
class ModsWorkspace {
  const ModsWorkspace(this.workspace, this.meta);
  final Workspace workspace;
  final String meta;

  String get root => workspace.rootPath;
  String get game => p.join(root, 'game');
}

const Map<String, String> kGameFiles = {
  'game/game.json': '{"id":"neon-dungeon","name":"Neon Dungeon","version":"1.4.2"}',
  'game/config/balance.toml': '[player]\nhp = 100\n',
  'game/data/items.csv': 'id,name,type\n1,sword,weapon\n',
  'game/data/ui/hud.json': '{"color":"white"}',
};

Future<ModsWorkspace> createModsWorkspace(ProviderContainer c, {bool withProfiles = true}) async {
  final ws = await c.read(workspacesProvider.notifier).addAppOwned('Neon test', kind: WorkspaceKind.sample);
  final meta = c.read(workspacesProvider.notifier).metaDir(ws);
  writeTree(ws.rootPath, kGameFiles);
  final mods = Directory(p.join(meta, 'mods'))..createSync(recursive: true);
  final downloads = Directory(p.join(ws.rootPath, 'downloads'))..createSync(recursive: true);
  await buildPackage(mods, id: 'core-patch', contents: {'config/core.ini': '[core]\nfixed = true\n'});
  await buildPackage(
    mods,
    id: 'hardcore-balance',
    version: '2.0.1',
    contents: {'config/balance.toml': '[player]\nhp = 50\n', 'data/items.csv': 'id,name,type\n1,sword,weapon\n'},
    deps: [
      {'id': 'core-patch', 'version': '^1.0.0'},
    ],
    compatibility: {'game': 'neon-dungeon', 'gameVersion': '>=1.4.0 <2.0.0'},
  );
  await buildPackage(
    mods,
    id: 'brutal-mode',
    version: '0.9.0',
    contents: {'config/balance.toml': '[player]\nhp = 1\n'},
    deps: [
      {'id': 'core-patch'},
    ],
  );
  await buildPackage(
    mods,
    id: 'neon-hud',
    version: '1.2.0',
    contents: {'data/ui/hud.json': '{"color":"red"}', 'data/ui/neon/theme.json': '{"glow":true}'},
  );
  await buildPackage(
    mods,
    id: 'legacy-skin',
    version: '0.3.0',
    contents: {'data/ui/skin.json': '{}'},
    deps: [
      {'id': 'retro-core'},
    ],
  );
  await buildPackage(
    mods,
    id: 'cycle-a',
    contents: {'data/cycle-a.txt': 'a'},
    deps: [
      {'id': 'cycle-b'},
    ],
  );
  await buildPackage(
    mods,
    id: 'cycle-b',
    contents: {'data/cycle-b.txt': 'b'},
    deps: [
      {'id': 'cycle-a'},
    ],
  );
  // An importable package in the workspace downloads folder.
  await buildPackage(downloads, id: 'extra-mod', contents: {'data/extra.txt': 'extra'});
  if (withProfiles) {
    final store = ProfileStore(meta);
    await store.save(
      const ModProfile(
        id: 'hardcore-run',
        name: 'Hardcore run',
        target: 'game',
        mods: [ProfileMod('core-patch'), ProfileMod('hardcore-balance'), ProfileMod('neon-hud')],
      ),
    );
    await store.save(
      const ModProfile(
        id: 'conflict-demo',
        name: 'Conflict demo',
        target: 'game',
        mods: [ProfileMod('core-patch'), ProfileMod('hardcore-balance'), ProfileMod('brutal-mode')],
      ),
    );
    await store.save(
      const ModProfile(
        id: 'broken-deps',
        name: 'Broken dependencies',
        target: 'game',
        mods: [ProfileMod('legacy-skin'), ProfileMod('cycle-a'), ProfileMod('cycle-b')],
      ),
    );
  }
  return ModsWorkspace(ws, meta);
}

/// Lets real IO / isolates progress inside testWidgets, then pumps.
Future<void> settle(WidgetTester tester, {int rounds = 30}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
    await tester.idle();
  }
  await tester.pump();
}

/// Waits (letting real IO, isolates and fake-zone microtasks progress)
/// until [condition] holds. Frames are pumped periodically so finders see
/// the latest UI.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  String? reason,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  var i = 0;
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      fail('Timed out waiting for ${reason ?? 'condition'}');
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
    await tester.idle();
    if (++i % 10 == 0) await tester.pump();
  }
  await tester.pump();
}

bool shows(Finder f) => f.evaluate().isNotEmpty;

/// Scrolls [f] into view, then taps it.
Future<void> tapVisible(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
}

/// Creates a TestEnv inside a widget test (real IO); removed afterwards.
Future<TestEnv> widgetEnv(WidgetTester tester) async {
  final env = (await tester.runAsync(TestEnv.create))!;
  addTearDown(() {
    if (env.dir.existsSync()) env.dir.deleteSync(recursive: true);
  });
  return env;
}

Widget scoped(ProviderContainer c, Widget child) => UncontrolledProviderScope(
  container: c,
  child: themed(child, effects: staticEffects),
);
