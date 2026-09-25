import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/utils/hashing.dart';
import 'package:j3nsontop_multitool/features/mods/domain/package_inspector.dart';
import 'package:j3nsontop_multitool/features/mods/domain/plan.dart';
import 'package:path/path.dart' as p;

import 'mod_fixtures.dart';

void main() {
  late Directory tmp;
  late String ws;
  late String pkgDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('j3_plan_');
    ws = p.join(tmp.path, 'ws');
    pkgDir = p.join(tmp.path, 'pkgs');
    Directory(pkgDir).createSync(recursive: true);
    writeTree(ws, {
      'game/game.json': '{"id":"neon-dungeon","version":"1.4.2"}',
      'game/config/balance.toml': 'hp = 100\n',
      'game/data/items.csv': 'id,name\n1,sword\n',
    });
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<PlanSource> pkg(String id, Map<String, String> contents, {String version = '1.0.0'}) async {
    final path = await buildPackage(Directory(pkgDir), id: id, version: version, contents: contents);
    final r = PackageInspector.inspect(path);
    expect(r.isValid, isTrue, reason: r.issues.join('\n'));
    return PlanSource(manifest: r.manifest!, archivePath: path);
  }

  test('create / overwrite / unchanged with sizes, providers and folders', () async {
    final a = await pkg('hardcore-balance', {
      'config/balance.toml': 'hp = 50\n',
      'data/items.csv': 'id,name\n1,sword\n',
      'data/new/deep/extra.json': '{}',
    });
    final b = await pkg('brutal-mode', {'config/balance.toml': 'hp = 1\n'});
    final plan = await PlanBuilder.build(
      workspaceRoot: ws,
      profile: profileOf('p', ['hardcore-balance', 'brutal-mode']),
      packages: [a, b],
    );

    expect(plan.targetRel, 'game');
    expect(plan.targetRoot, p.join(ws, 'game'));
    expect(plan.changes.map((c) => c.path), ['config/balance.toml', 'data/items.csv', 'data/new/deep/extra.json']);
    final balance = plan.changes[0];
    expect(balance.action, ChangeAction.overwrite);
    expect(balance.packageId, 'brutal-mode', reason: 'last package wins');
    expect(balance.overrides, ['hardcore-balance']);
    expect(balance.size, 'hp = 1\n'.length);
    expect(balance.currentSize, 'hp = 100\n'.length);
    expect(balance.currentSha256, Hashing.text('hp = 100\n'));
    expect(balance.newSha256, Hashing.text('hp = 1\n'));
    expect(plan.changes[1].action, ChangeAction.unchanged);
    expect(plan.changes[2].action, ChangeAction.create);
    expect(plan.directoriesToCreate, ['data/new', 'data/new/deep']);
    expect(plan.creates, 1);
    expect(plan.overwrites, 1);
    expect(plan.unchanged, 1);
    expect(plan.bytesToWrite, 'hp = 1\n'.length + 2);
    expect(plan.hasWork, isTrue);
    expect(plan.packages, ['hardcore-balance@1.0.0', 'brutal-mode@1.0.0']);
  });

  test('background planning gives the same result', () async {
    final a = await pkg('core-patch', {'config/core.ini': 'x=1'});
    final plan = await buildPlanInBackground(workspaceRoot: ws, profile: profileOf('p', ['core-patch']), packages: [a]);
    expect(plan.changes.single.action, ChangeAction.create);
  });

  test('root target "."', () async {
    final a = await pkg('root-mod', {'notes/readme.txt': 'hi'});
    final plan = await PlanBuilder.build(
      workspaceRoot: ws,
      profile: profileOf('p', ['root-mod'], target: '.'),
      packages: [a],
    );
    expect(plan.targetRoot, p.normalize(ws));
    expect(plan.directoriesToCreate, ['notes']);
  });

  group('plan errors', () {
    test('missing target folder', () async {
      final a = await pkg('core-patch', {'x.txt': 'x'});
      expect(
        () => PlanBuilder.build(
          workspaceRoot: ws,
          profile: profileOf('p', ['core-patch'], target: 'nope'),
          packages: [a],
        ),
        throwsA(isA<PlanException>().having((e) => e.message, 'message', contains('does not exist'))),
      );
    });

    test('a folder where a file should go', () async {
      final a = await pkg('core-patch', {'data': 'x'});
      expect(
        () => PlanBuilder.build(workspaceRoot: ws, profile: profileOf('p', ['core-patch']), packages: [a]),
        throwsA(isA<PlanException>().having((e) => e.message, 'message', contains('is a folder'))),
      );
    });

    test('a file where a folder should go', () async {
      final a = await pkg('core-patch', {'data/items.csv/inner.txt': 'x'});
      expect(
        () => PlanBuilder.build(workspaceRoot: ws, profile: profileOf('p', ['core-patch']), packages: [a]),
        throwsA(isA<PlanException>().having((e) => e.message, 'message', contains('a file with that name exists'))),
      );
    });

    test('symlink escape inside the target is refused', () async {
      final outside = Directory(p.join(tmp.path, 'outside'))..createSync();
      Link(p.join(ws, 'game', 'escape')).createSync(outside.path);
      final a = await pkg('core-patch', {'escape/evil.txt': 'x'});
      expect(
        () => PlanBuilder.build(workspaceRoot: ws, profile: profileOf('p', ['core-patch']), packages: [a]),
        throwsA(isA<PlanException>().having((e) => e.message, 'message', contains('unsafe'))),
      );
      expect(outside.listSync(), isEmpty);
    });

    test('unsafe profile target is refused', () async {
      final a = await pkg('core-patch', {'x.txt': 'x'});
      expect(
        () => PlanBuilder.build(
          workspaceRoot: ws,
          profile: profileOf('p', ['core-patch'], target: '../..'),
          packages: [a],
        ),
        throwsA(isA<PlanException>()),
      );
    });
  });
}
