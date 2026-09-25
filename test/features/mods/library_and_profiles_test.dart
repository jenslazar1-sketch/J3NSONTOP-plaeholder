import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/mods/data/mod_library.dart';
import 'package:j3nsontop_multitool/features/mods/data/profile_store.dart';
import 'package:j3nsontop_multitool/features/mods/data/target_game.dart';
import 'package:j3nsontop_multitool/features/mods/domain/profile.dart';
import 'package:j3nsontop_multitool/features/mods/domain/resolver.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../../helpers/raw_zip.dart';
import 'mod_fixtures.dart';

void main() {
  late Directory tmp;
  late String meta;
  late Directory downloads;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('j3_lib_');
    meta = p.join(tmp.path, 'meta');
    downloads = Directory(p.join(tmp.path, 'downloads'))..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('library', () {
    test('import copies as <id>-<version>.j3mod and lists with reports', () async {
      final lib = ModLibrary(meta);
      final src = await buildPackage(downloads, id: 'core-patch', fileName: 'whatever.zip');
      final out = await lib.importPackage(src);
      expect(out, isA<ImportCompleted>());
      final entry = (out as ImportCompleted).entry;
      expect(entry.fileName, 'core-patch-1.0.0.j3mod');
      expect(entry.isValid, isTrue);
      expect(File(src).existsSync(), isTrue, reason: 'the source is copied, not moved');
      final listed = await lib.list();
      expect(listed.single.id, 'core-patch');
      expect(ModLibrary.manifestsById(listed).keys, ['core-patch']);
    });

    test('invalid packages are rejected and nothing is copied', () async {
      final bad = writeRawZip(downloads, 'bad.j3mod', [
        RawZipEntry('../evil', [1]),
      ]);
      final out = await ModLibrary(meta).importPackage(bad);
      expect(out, isA<ImportRejected>());
      expect((out as ImportRejected).report.errorCount, greaterThan(0));
      expect(Directory(p.join(meta, 'mods')).existsSync(), isFalse);
    });

    test('replace flow: never silent, asks, then replaces the old version', () async {
      final lib = ModLibrary(meta);
      await lib.importPackage(await buildPackage(downloads, id: 'core-patch', version: '1.0.0'));
      final newer = await buildPackage(downloads, id: 'core-patch', version: '1.1.0', contents: {'data/a.txt': 'new'});

      final ask = await lib.importPackage(newer);
      expect(ask, isA<ImportNeedsReplace>());
      final needs = ask as ImportNeedsReplace;
      expect(needs.existing.version, '1.0.0');
      expect(needs.direction, 'upgrade');
      expect((await lib.list()).single.version, '1.0.0', reason: 'nothing replaced without confirmation');

      final done = await lib.importPackage(newer, replace: true);
      expect(done, isA<ImportCompleted>());
      expect((done as ImportCompleted).replaced!.version, '1.0.0');
      final listed = await lib.list();
      expect(listed.map((e) => e.fileName), ['core-patch-1.1.0.j3mod']);
    });

    test('identical re-import is detected', () async {
      final lib = ModLibrary(meta);
      final src = await buildPackage(downloads, id: 'neon-hud');
      await lib.importPackage(src);
      expect(await lib.importPackage(src), isA<ImportIdentical>());
    });

    test('same version, different content asks as well', () async {
      final lib = ModLibrary(meta);
      await lib.importPackage(await buildPackage(downloads, id: 'neon-hud'));
      final other = await buildPackage(
        downloads,
        id: 'neon-hud',
        contents: {'data/a.txt': 'changed'},
        fileName: 'o.j3mod',
      );
      final out = await lib.importPackage(other);
      expect(out, isA<ImportNeedsReplace>());
      expect((out as ImportNeedsReplace).direction, contains('same version'));
    });

    test('remove deletes the file; invalid library files are listed', () async {
      final lib = ModLibrary(meta);
      await lib.importPackage(await buildPackage(downloads, id: 'neon-hud'));
      writeRawZip(Directory(p.join(meta, 'mods')), 'junk.j3mod', [
        RawZipEntry('x.txt', [1]),
      ]);
      var listed = await lib.list();
      expect(listed, hasLength(2));
      expect(ModLibrary.invalidIds(listed), {'junk'});
      await lib.remove(listed.firstWhere((e) => e.id == 'neon-hud'));
      listed = await lib.list();
      expect(listed.single.id, 'junk');
    });

    test('several versions of one id: the highest valid version is used', () async {
      final dir = Directory(p.join(meta, 'mods'))..createSync(recursive: true);
      await buildPackage(dir, id: 'core-patch', version: '1.0.0');
      await buildPackage(dir, id: 'core-patch', version: '1.2.0');
      final listed = await ModLibrary(meta).list();
      expect(ModLibrary.manifestsById(listed)['core-patch']!.version, Version(1, 2, 0));
      expect(ModLibrary.entryFor(listed, 'core-patch')!.fileName, 'core-patch-1.2.0.j3mod');
    });
  });

  group('profiles', () {
    test('create, list, rename, duplicate, delete', () async {
      final store = ProfileStore(meta);
      final a = await store.create(name: 'Hardcore run', target: 'game', mods: const [ProfileMod('core-patch')]);
      expect(a.id, 'hardcore-run');
      expect(File(store.pathFor('hardcore-run')).existsSync(), isTrue);
      final b = await store.create(name: 'Hardcore run');
      expect(b.id, 'hardcore-run-2');
      final renamed = await store.rename('hardcore-run', 'Brutal run');
      expect(renamed.name, 'Brutal run');
      expect(renamed.id, 'hardcore-run', reason: 'ids are stable');
      final dup = await store.duplicate('hardcore-run');
      expect(dup.id, 'hardcore-run-copy');
      expect(dup.name, 'Brutal run (copy)');
      expect(dup.mods, a.mods);
      expect((await store.list()).length, 3);
      await store.delete('hardcore-run-2');
      expect((await store.list()).map((s) => s.id), containsAll(['hardcore-run', 'hardcore-run-copy']));
      expect((await store.list()).length, 2);
    });

    test('enable/disable, reorder, add/remove', () async {
      final store = ProfileStore(meta);
      final created = await store.create(
        name: 'P',
        mods: const [ProfileMod('a-mod'), ProfileMod('b-mod'), ProfileMod('c-mod')],
      );
      expect(created.id, 'profile', reason: 'too-short names fall back to a generic id');
      var prof = await store.setEnabled('profile', 'b-mod', false);
      expect(prof.enabledIds, ['a-mod', 'c-mod']);
      prof = await store.reorder('profile', 2, 0);
      expect(prof.mods.map((m) => m.id), ['c-mod', 'a-mod', 'b-mod']);
      prof = await store.addMod('profile', 'd-mod');
      expect(prof.mods.last.id, 'd-mod');
      prof = await store.removeMod('profile', 'a-mod');
      expect(prof.mods.map((m) => m.id), ['c-mod', 'b-mod', 'd-mod']);
      expect((await store.load('profile'))!.mods, prof.mods, reason: 'every change is persisted');
    });

    test('export / import round trip and collision handling', () async {
      final store = ProfileStore(meta);
      final prof = await store.create(
        name: 'Conflict demo',
        target: 'game',
        mods: const [ProfileMod('core-patch'), ProfileMod('brutal-mode', enabled: false)],
        game: ProfileGame(id: 'neon-dungeon', version: Version(1, 4, 2)),
      );
      final text = ProfileStore.exportText(prof);
      expect(ProfileStore.exportFileName(prof), 'conflict-demo.j3profile.json');

      final other = ProfileStore(p.join(tmp.path, 'other-meta'));
      final imported = await other.importText(text);
      expect(imported, isA<ProfileImported>());
      final got = (imported as ProfileImported).profile;
      expect(got.toJson(), prof.toJson());

      // Same id again: the caller must decide.
      final again = await other.importText(text);
      expect(again, isA<ProfileImportConflict>());
      final both = await other.importText(text, collision: ProfileCollision.keepBoth);
      expect((both as ProfileImported).profile.id, 'conflict-demo-2');
      expect(both.profile.name, 'Conflict demo (imported)');
      final replaced = await other.importText(text, collision: ProfileCollision.replace);
      expect((replaced as ProfileImported).replaced, isTrue);
    });

    test('invalid profile imports are rejected with issues', () async {
      final store = ProfileStore(meta);
      final r1 = await store.importText('{"format":"j3profile","formatVersion":2,"id":"xx","name":"X"}');
      expect((r1 as ProfileImportRejected).issues.single.message, contains('newer'));
      final r2 = await store.importText(
        '{"format":"j3profile","formatVersion":1,"id":"xx","name":"X","target":"../up"}',
      );
      expect((r2 as ProfileImportRejected).issues.single.field, 'target');
      final r3 = await store.importText(
        '{"format":"j3profile","formatVersion":1,"id":"xx","name":"X","mods":[{"id":"a-b"},{"id":"a-b"}]}',
      );
      expect((r3 as ProfileImportRejected).issues.single.field, 'mods[1].id');
      expect(await store.importText('nope'), isA<ProfileImportRejected>());
    });

    test('damaged profile files are listed as invalid, not dropped', () async {
      final store = ProfileStore(meta);
      Directory(store.dir).createSync(recursive: true);
      File(store.pathFor('broken')).writeAsStringSync('{oops');
      final listed = await store.list();
      expect(listed.single.isValid, isFalse);
      expect(listed.single.id, 'broken');
    });

    test('the sample profile format parses', () {
      const text = '''
{
  "format": "j3profile",
  "formatVersion": 1,
  "id": "hardcore-run",
  "name": "Hardcore run",
  "description": "Core patch + hardcore balance + neon HUD.",
  "target": "game",
  "game": { "id": "neon-dungeon", "version": "1.4.2" },
  "mods": [
    { "id": "core-patch", "enabled": true },
    { "id": "hardcore-balance", "enabled": true },
    { "id": "neon-hud", "enabled": false }
  ]
}''';
      final r = ProfileParser.parseText(text);
      expect(r.isValid, isTrue, reason: r.issues.join('\n'));
      expect(r.profile!.enabledIds, ['core-patch', 'hardcore-balance']);
      expect(r.profile!.game!.version, Version(1, 4, 2));
    });
  });

  group('target game', () {
    test('game.json first, then profile game, else unknown', () async {
      final ws = p.join(tmp.path, 'ws');
      writeTree(ws, {'game/game.json': '{"id":"neon-dungeon","name":"Neon Dungeon","version":"1.4.2"}'});
      Directory(p.join(ws, 'other')).createSync();

      final fromJson = await readTargetGame(ws, profileOf('p', const [], target: 'game'));
      expect(fromJson.source, TargetGameSource.gameJson);
      expect(fromJson.id, 'neon-dungeon');
      expect(fromJson.version, Version(1, 4, 2));

      final withGame = ModProfile(
        id: 'p',
        name: 'P',
        target: 'other',
        game: ProfileGame(id: 'space-miner', version: Version(2, 0, 0)),
      );
      final fromProfile = await readTargetGame(ws, withGame);
      expect(fromProfile.source, TargetGameSource.profile);
      expect(fromProfile.id, 'space-miner');

      final unknown = await readTargetGame(ws, profileOf('p', const [], target: 'other'));
      expect(unknown.isKnown, isFalse);

      final mismatch = await readTargetGame(ws, withGame.copyWith(target: 'game'));
      expect(mismatch.id, 'neon-dungeon');
      expect(mismatch.notes.single, contains('game.json is used'));
    });

    test('broken game.json falls back with a note', () async {
      final ws = p.join(tmp.path, 'ws');
      writeTree(ws, {'game/game.json': '{broken'});
      final t = await readTargetGame(ws, profileOf('p', const [], target: 'game'));
      expect(t.isKnown, isFalse);
      expect(t.notes.single, contains('could not be used'));
    });
  });
}
