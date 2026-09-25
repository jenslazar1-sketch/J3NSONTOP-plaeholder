import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/utils/hashing.dart';
import 'package:j3nsontop_multitool/features/mods/data/apply_engine.dart';
import 'package:j3nsontop_multitool/features/mods/data/journal.dart';
import 'package:j3nsontop_multitool/features/mods/domain/package_inspector.dart';
import 'package:j3nsontop_multitool/features/mods/domain/plan.dart';
import 'package:path/path.dart' as p;

import 'mod_fixtures.dart';

void main() {
  late Directory tmp;
  late String ws;
  late String meta;
  late String game;
  late Map<String, List<int>> original;
  late Set<String> originalDirs;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('j3_apply_');
    ws = p.join(tmp.path, 'ws');
    meta = p.join(tmp.path, 'meta');
    game = p.join(ws, 'game');
    Directory(p.join(meta, 'mods')).createSync(recursive: true);
    writeTree(ws, {
      'game/game.json': '{"id":"neon-dungeon","version":"1.4.2"}',
      'game/config/balance.toml': 'hp = 100\nspeed = 1\n',
      'game/data/items.csv': 'id,name\n1,sword\n',
      'game/data/ui/hud.json': '{"color":"white"}',
    });
    original = snapshot(game);
    originalDirs = dirsUnder(game);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  ApplyEngine engine({EngineFaults faults = EngineFaults.none}) =>
      ApplyEngine(metaDir: meta, workspaceRoot: ws, workspaceId: 'ws-1', faults: faults);

  Future<PlanSource> pkg(String id, Map<String, String> contents) async {
    final path = await buildPackage(Directory(p.join(meta, 'mods')), id: id, contents: contents);
    final r = PackageInspector.inspect(path);
    expect(r.isValid, isTrue, reason: r.issues.join('\n'));
    return PlanSource(manifest: r.manifest!, archivePath: path);
  }

  Future<ApplyPlan> planFor(List<PlanSource> sources, {String target = 'game', String profileId = 'p1'}) =>
      PlanBuilder.build(
        workspaceRoot: ws,
        profile: profileOf(profileId, [for (final s in sources) s.manifest.id], target: target),
        packages: sources,
      );

  /// Standard mod: overwrites two files, creates one file in new folders,
  /// and one file that is identical.
  Future<ApplyPlan> standardPlan() async {
    final a = await pkg('hardcore-balance', {
      'config/balance.toml': 'hp = 50\nspeed = 2\n',
      'data/items.csv': 'id,name\n1,sword\n',
      'data/new/deep/extra.json': '{"extra":true}',
    });
    final b = await pkg('neon-hud', {'data/ui/hud.json': '{"color":"red"}'});
    return planFor([a, b]);
  }

  Map<String, dynamic> journalJson(String opId) =>
      jsonDecode(File(p.join(meta, 'operations', opId, 'journal.json')).readAsStringSync()) as Map<String, dynamic>;

  test('apply writes exactly the plan and records a journal', () async {
    final plan = await standardPlan();
    final out = await engine().apply(plan);
    expect(out.nothingToDo, isFalse);
    expect(out.created, 1);
    expect(out.overwritten, 2);
    expect(out.unchanged, 1);
    expect(out.dirsCreated, 2);
    expect(out.summary, contains('1 file created'));

    expect(File(p.join(game, 'config/balance.toml')).readAsStringSync(), 'hp = 50\nspeed = 2\n');
    expect(File(p.join(game, 'data/ui/hud.json')).readAsStringSync(), '{"color":"red"}');
    expect(File(p.join(game, 'data/new/deep/extra.json')).readAsStringSync(), '{"extra":true}');

    final j = journalJson(out.journal!.id);
    expect(j['status'], 'applied');
    expect(j['touchedTarget'], isTrue);
    expect(j['createdDirs'], ['data/new', 'data/new/deep']);
    expect(j['unchanged'], ['data/items.csv']);
    final changes = (j['changes'] as List).cast<Map<String, dynamic>>();
    expect(changes, hasLength(3));
    expect(changes.every((c) => c['done'] == true), isTrue);
    final overwrite = changes.firstWhere((c) => c['path'] == 'config/balance.toml');
    expect(overwrite['action'], 'overwrite');
    expect(overwrite['originalSha256'], Hashing.text('hp = 100\nspeed = 1\n'));
    expect(overwrite['newSha256'], Hashing.text('hp = 50\nspeed = 2\n'));
    expect(overwrite['backup'], 'backup/config/balance.toml');
    expect(overwrite['packageFile'], 'mods/hardcore-balance-1.0.0.j3mod');
    final backup = File(p.join(meta, 'operations', out.journal!.id, 'backup/config/balance.toml'));
    expect(backup.readAsStringSync(), 'hp = 100\nspeed = 1\n');
    expect(Directory(p.join(meta, 'operations', out.journal!.id, 'staged')).existsSync(), isFalse);
    // No temp files left behind in the target.
    expect(snapshot(game).keys.where((k) => k.contains('.part') || k.contains('aside')), isEmpty);
  });

  test('apply + rollback restores byte-identical originals and removes created items only', () async {
    final plan = await standardPlan();
    final e = engine();
    final out = await e.apply(plan);
    // An unrelated file the user puts into a created folder must survive.
    File(p.join(game, 'data/new/user-notes.txt')).writeAsStringSync('mine');

    final preview = await e.previewRollback(out.journal!.id);
    expect(preview.isBlocked, isFalse);
    expect(preview.conflicts, isEmpty);
    expect(preview.toRestore, 2);
    expect(preview.toDelete, 1);

    final rb = await e.rollback(out.journal!.id);
    expect(rb.problems, isEmpty);
    expect(rb.restored, 2);
    expect(rb.deleted, 1);
    expect(rb.journal.status, JournalStatus.rolledBack);
    expect(rb.journal.removedDirs, ['data/new/deep']);
    expect(rb.journal.keptDirs, ['data/new']);

    final after = snapshot(game);
    expect(after.remove('data/new/user-notes.txt'), utf8.encode('mine'));
    expect(after.keys.toSet(), original.keys.toSet());
    for (final k in original.keys) {
      expect(after[k], original[k], reason: '$k must be byte-identical');
    }
    expect(dirsUnder(game), {...originalDirs, 'data/new'});
    expect(journalJson(out.journal!.id)['status'], 'rolled_back');
  });

  test('rollback removes created empty folders completely', () async {
    final out = await engine().apply(await standardPlan());
    await engine().rollback(out.journal!.id);
    expect(snapshot(game), original);
    expect(dirsUnder(game), originalDirs);
  });

  test('rollback of a finished rollback is a no-op', () async {
    final out = await engine().apply(await standardPlan());
    await engine().rollback(out.journal!.id);
    final again = await engine().rollback(out.journal!.id);
    expect(again.journal.status, JournalStatus.rolledBack);
    expect(snapshot(game), original);
  });

  group('user edits after applying', () {
    test('edited overwrite: conflict reported, "keep" honoured', () async {
      final out = await engine().apply(await standardPlan());
      File(p.join(game, 'config/balance.toml')).writeAsStringSync('hp = 9999\n');
      final preview = await engine().previewRollback(out.journal!.id);
      expect(preview.conflicts.map((c) => c.path), ['config/balance.toml']);
      expect(preview.conflicts.single.kind, ConflictKind.edited);

      final rb = await engine().rollback(
        out.journal!.id,
        decisions: {'config/balance.toml': ConflictDecision.keepUserEdit},
      );
      expect(rb.keptUserEdits, 1);
      expect(File(p.join(game, 'config/balance.toml')).readAsStringSync(), 'hp = 9999\n');
      expect(File(p.join(game, 'data/ui/hud.json')).readAsBytesSync(), original['data/ui/hud.json']);
      expect(rb.journal.status, JournalStatus.rolledBack);
    });

    test('edited overwrite: "restore original" saves the edit next to the backup first', () async {
      final out = await engine().apply(await standardPlan());
      File(p.join(game, 'config/balance.toml')).writeAsStringSync('hp = 9999\n');
      final rb = await engine().rollback(
        out.journal!.id,
        decisions: {'config/balance.toml': ConflictDecision.restoreOriginal},
      );
      expect(rb.restoredAfterSavingEdit, 1);
      expect(File(p.join(game, 'config/balance.toml')).readAsBytesSync(), original['config/balance.toml']);
      final change = rb.journal.changes.firstWhere((c) => c.path == 'config/balance.toml');
      expect(change.rollback, RollbackResult.restoredAfterSavingEdit);
      expect(change.savedEdit, 'backup/config/balance.toml.user-edit');
      final saved = File(p.join(meta, 'operations', out.journal!.id, change.savedEdit!));
      expect(saved.readAsStringSync(), 'hp = 9999\n');
      expect(snapshot(game), original);
    });

    test('undecided conflicts keep the user version', () async {
      final out = await engine().apply(await standardPlan());
      File(p.join(game, 'data/ui/hud.json')).writeAsStringSync('{"color":"blue"}');
      final rb = await engine().rollback(out.journal!.id);
      expect(rb.keptUserEdits, 1);
      expect(File(p.join(game, 'data/ui/hud.json')).readAsStringSync(), '{"color":"blue"}');
    });

    test('edited created file: kept, or removed after saving the edit', () async {
      final out = await engine().apply(await standardPlan());
      final created = File(p.join(game, 'data/new/deep/extra.json'))..writeAsStringSync('{"mine":1}');
      final preview = await engine().previewRollback(out.journal!.id);
      expect(preview.conflicts.single.path, 'data/new/deep/extra.json');

      final keep = await engine().rollback(out.journal!.id);
      expect(created.readAsStringSync(), '{"mine":1}');
      expect(keep.journal.keptDirs, containsAll(['data/new', 'data/new/deep']));
      expect(keep.keptUserEdits, 1);
    });

    test('edited created file removed when asked, edit preserved', () async {
      final out = await engine().apply(await standardPlan());
      File(p.join(game, 'data/new/deep/extra.json')).writeAsStringSync('{"mine":1}');
      final rb = await engine().rollback(
        out.journal!.id,
        decisions: {'data/new/deep/extra.json': ConflictDecision.restoreOriginal},
      );
      expect(rb.restoredAfterSavingEdit, 1);
      expect(snapshot(game), original);
      expect(dirsUnder(game), originalDirs);
      final change = rb.journal.changes.firstWhere((c) => c.path == 'data/new/deep/extra.json');
      expect(File(p.join(meta, 'operations', out.journal!.id, change.savedEdit!)).readAsStringSync(), '{"mine":1}');
    });

    test('deleted overwritten file is a conflict; restoring brings the original back', () async {
      final out = await engine().apply(await standardPlan());
      File(p.join(game, 'data/ui/hud.json')).deleteSync();
      final preview = await engine().previewRollback(out.journal!.id);
      expect(preview.conflicts.single.kind, ConflictKind.deleted);
      await engine().rollback(out.journal!.id, decisions: {'data/ui/hud.json': ConflictDecision.restoreOriginal});
      expect(snapshot(game), original);
    });
  });

  group('interruption', () {
    for (final k in [1, 2]) {
      test('crash after $k change(s): journal says applying, rollback restores', () async {
        final plan = await standardPlan();
        await expectLater(
          engine(faults: EngineFaults(crashAfterApplyChanges: k)).apply(plan),
          throwsA(isA<SimulatedCrash>()),
        );
        final listing = await engine().listOperations();
        final j = listing.journals.single;
        expect(j.status, JournalStatus.applying);
        expect(j.doneCount, k);
        expect(listing.interrupted.single.id, j.id);
        expect(journalJson(j.id)['status'], 'applying');

        final rb = await engine().rollback(j.id);
        expect(rb.problems, isEmpty);
        expect(snapshot(game), original);
        expect(dirsUnder(game), originalDirs);
      });
    }

    test('crash after 2 changes, then resume completes the operation', () async {
      final plan = await standardPlan();
      await expectLater(
        engine(faults: const EngineFaults(crashAfterApplyChanges: 2)).apply(plan),
        throwsA(isA<SimulatedCrash>()),
      );
      final opId = (await engine().listOperations()).journals.single.id;
      final out = await engine().resume(opId);
      expect(out.journal!.status, JournalStatus.applied);
      expect(File(p.join(game, 'config/balance.toml')).readAsStringSync(), 'hp = 50\nspeed = 2\n');
      expect(File(p.join(game, 'data/ui/hud.json')).readAsStringSync(), '{"color":"red"}');
      expect(File(p.join(game, 'data/new/deep/extra.json')).existsSync(), isTrue);
      // And it can still be rolled back fully afterwards.
      await engine().rollback(opId);
      expect(snapshot(game), original);
    });

    test('crash during staging leaves targets untouched; resume applies', () async {
      final plan = await standardPlan();
      await expectLater(
        engine(faults: const EngineFaults(crashAfterStagedFiles: 1)).apply(plan),
        throwsA(isA<SimulatedCrash>()),
      );
      final j = (await engine().listOperations()).journals.single;
      expect(j.status, JournalStatus.staging);
      expect(j.touchedTarget, isFalse);
      expect(snapshot(game), original);
      final out = await engine().resume(j.id);
      expect(out.journal!.status, JournalStatus.applied);
      expect(File(p.join(game, 'data/ui/hud.json')).readAsStringSync(), '{"color":"red"}');
    });

    test('rollback of an interrupted staging touches nothing', () async {
      final plan = await standardPlan();
      await expectLater(
        engine(faults: const EngineFaults(crashAfterStagedFiles: 2)).apply(plan),
        throwsA(isA<SimulatedCrash>()),
      );
      // The user edits a planned file meanwhile: still no conflict prompt,
      // because the operation never touched the target.
      File(p.join(game, 'config/balance.toml')).writeAsStringSync('user');
      final j = (await engine().listOperations()).journals.single;
      final preview = await engine().previewRollback(j.id);
      expect(preview.conflicts, isEmpty);
      final rb = await engine().rollback(j.id);
      expect(rb.journal.status, JournalStatus.rolledBack);
      expect(File(p.join(game, 'config/balance.toml')).readAsStringSync(), 'user');
    });

    test('crash during rollback, then rolling back again finishes', () async {
      final out = await engine().apply(await standardPlan());
      await expectLater(
        engine(faults: const EngineFaults(crashAfterRollbackSteps: 1)).rollback(out.journal!.id),
        throwsA(isA<SimulatedCrash>()),
      );
      final j = await engine().load(out.journal!.id);
      expect(j.status, JournalStatus.rollingBack);
      expect(j.status.isInterrupted, isTrue);
      await engine().rollback(out.journal!.id);
      expect(snapshot(game), original);
      expect(dirsUnder(game), originalDirs);
    });

    test('cancellation between steps leaves a resumable journal', () async {
      final plan = await standardPlan();
      final token = CancellationToken();
      var calls = 0;
      await expectLater(
        engine().apply(
          plan,
          token: token,
          onProgress: (f, m) {
            if (m != null && m.startsWith('Applying') && ++calls == 2) token.cancel();
          },
        ),
        throwsA(isA<OperationCancelled>()),
      );
      final j = (await engine().listOperations()).journals.single;
      expect(j.status, JournalStatus.applying);
      expect(j.interruptedReason, contains('Cancelled'));
      // The step in progress finishes; the next one never starts.
      expect(j.doneCount, 2);
      expect(j.changes.last.done, isFalse);
      final out = await engine().resume(j.id);
      expect(out.journal!.status, JournalStatus.applied);
      expect(out.journal!.interruptedReason, isNull);
    });
  });

  group('LIFO and safety', () {
    test('applying onto a target with an applied operation is refused until it is rolled back', () async {
      final first = await engine().apply(await standardPlan());
      final other = await pkg('core-patch', {'config/core.ini': 'x=1'});
      final plan2 = await planFor([other], profileId: 'p2');
      await expectLater(
        engine().apply(plan2),
        throwsA(isA<ApplyBlocked>().having((e) => e.toString(), 'message', contains('Roll it back first'))),
      );
      // Overlapping targets count too (workspace root contains game/).
      final rootPlan = await PlanBuilder.build(
        workspaceRoot: ws,
        profile: profileOf('p3', ['core-patch'], target: '.'),
        packages: [other],
      );
      await expectLater(engine().apply(rootPlan), throwsA(isA<ApplyBlocked>()));

      await engine().rollback(first.journal!.id);
      final second = await engine().apply(await planFor([other], profileId: 'p2'));
      expect(second.journal!.status, JournalStatus.applied);
    });

    test('only the most recent operation on a target can be rolled back', () async {
      final first = await engine().apply(await standardPlan());
      // Simulate a newer open operation on the same target (e.g. restored
      // from another device): the older one must not be rolled back.
      final newerDir = Directory(p.join(meta, 'operations', 'zzzz-newer'))..createSync(recursive: true);
      final newer = journalJson(first.journal!.id)
        ..['id'] = 'zzzz-newer'
        ..['createdAt'] = DateTime.now().add(const Duration(hours: 1)).toUtc().toIso8601String()
        ..['changes'] = <Object>[]
        ..['createdDirs'] = <Object>[];
      File(p.join(newerDir.path, 'journal.json')).writeAsStringSync(jsonEncode(newer));

      final preview = await engine().previewRollback(first.journal!.id);
      expect(preview.isBlocked, isTrue);
      expect(preview.blockedBy!.id, 'zzzz-newer');
      await expectLater(engine().rollback(first.journal!.id), throwsA(isA<RollbackBlocked>()));
      expect(File(p.join(game, 'data/ui/hud.json')).readAsStringSync(), '{"color":"red"}');

      await engine().rollback('zzzz-newer');
      await engine().rollback(first.journal!.id);
      expect(snapshot(game), original);
    });

    test('target changed since planning: fails before touching anything', () async {
      final plan = await standardPlan();
      File(p.join(game, 'config/balance.toml')).writeAsStringSync('edited after planning');
      await expectLater(engine().apply(plan), throwsA(isA<ApplyFailure>()));
      final j = (await engine().listOperations()).journals.single;
      expect(j.status, JournalStatus.failed);
      expect(j.failedDuring, JournalStatus.staging);
      expect(j.touchedTarget, isFalse);
      expect(j.isOpen, isFalse, reason: 'a failure before touching the target does not block new applies');
      expect(j.error, contains('changed since the plan'));
      expect(File(p.join(game, 'data/ui/hud.json')).readAsBytesSync(), original['data/ui/hud.json']);
      await engine().deleteOperation(j.id);
      expect((await engine().listOperations()).journals, isEmpty);
    });

    test('nothing to do: no operation recorded', () async {
      final same = await pkg('same-mod', {'data/items.csv': 'id,name\n1,sword\n'});
      final out = await engine().apply(await planFor([same]));
      expect(out.nothingToDo, isTrue);
      expect(out.unchanged, 1);
      expect(out.summary, contains('Already up to date'));
      expect((await engine().listOperations()).journals, isEmpty);
    });

    test('open operations cannot be deleted', () async {
      final out = await engine().apply(await standardPlan());
      expect(() => engine().deleteOperation(out.journal!.id), throwsStateError);
      await engine().rollback(out.journal!.id);
      await engine().deleteOperation(out.journal!.id);
      expect(Directory(p.join(meta, 'operations', out.journal!.id)).existsSync(), isFalse);
    });

    test('a damaged backup is reported and the file is left alone', () async {
      final out = await engine().apply(await standardPlan());
      File(p.join(meta, 'operations', out.journal!.id, 'backup/config/balance.toml')).writeAsStringSync('tampered');
      final rb = await engine().rollback(out.journal!.id);
      expect(rb.problems.single, contains('damaged'));
      expect(rb.journal.status, JournalStatus.failed);
      expect(rb.journal.failedDuring, JournalStatus.rollingBack);
      expect(File(p.join(game, 'config/balance.toml')).readAsStringSync(), 'hp = 50\nspeed = 2\n');
      // Everything else was still restored.
      expect(File(p.join(game, 'data/ui/hud.json')).readAsBytesSync(), original['data/ui/hud.json']);
    });

    test('damaged journals are listed separately', () async {
      Directory(p.join(meta, 'operations', 'broken')).createSync(recursive: true);
      File(p.join(meta, 'operations', 'broken', 'journal.json')).writeAsStringSync('{"format":"nope"}');
      final listing = await engine().listOperations();
      expect(listing.journals, isEmpty);
      expect(listing.damaged.single.error, contains('not a J3NSONTOP journal'));
    });

    test('journal with a traversal path is rejected as damaged', () async {
      final out = await engine().apply(await standardPlan());
      final j = journalJson(out.journal!.id);
      ((j['changes'] as List).first as Map<String, dynamic>)['path'] = '../../outside.txt';
      File(p.join(meta, 'operations', out.journal!.id, 'journal.json')).writeAsStringSync(jsonEncode(j));
      final listing = await engine().listOperations();
      expect(listing.journals, isEmpty);
      expect(listing.damaged, hasLength(1));
    });
  });

  test('targetsOverlap', () {
    expect(targetsOverlap('game', 'game'), isTrue);
    expect(targetsOverlap('game', 'Game'), isTrue);
    expect(targetsOverlap('game', 'game/data'), isTrue);
    expect(targetsOverlap('.', 'anything'), isTrue);
    expect(targetsOverlap('game', 'gamer'), isFalse);
    expect(targetsOverlap('a/b', 'a/c'), isFalse);
  });
}
