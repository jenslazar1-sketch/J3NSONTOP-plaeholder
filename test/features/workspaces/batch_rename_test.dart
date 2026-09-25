import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/workspaces/data/rename_executor.dart';
import 'package:j3nsontop_multitool/features/workspaces/domain/rename_plan.dart';
import 'package:path/path.dart' as p;

RenameItem item(String name, {String dir = '', DateTime? modified, String parent = 'demo'}) =>
    RenameItem(dir: dir, name: name, modified: modified ?? DateTime(2026, 9, 1, 12), parentName: parent);

RenamePlan plan(List<RenameItem> items, RenameRules rules, {Map<String, List<String>>? existing}) => planRenames(
  items: items,
  rules: rules,
  existing:
      existing ??
      {
        for (final d in items.map((i) => i.dir).toSet()) d: [for (final i in items.where((i) => i.dir == d)) i.name],
      },
);

void main() {
  group('planner tokens', () {
    test('numbering, padding, name, ext, parent and date tokens', () {
      final items = [item('IMG_0002.png'), item('IMG_0010.png'), item('IMG_0001.png')];
      final r = plan(items, const RenameRules(template: '{parent}_{n:3}_{name}.{ext}_{date}', startNumber: 5, step: 5));
      expect(r.error, isNull);
      expect(r.rows.map((x) => x.newName), [
        'demo_005_IMG_0001.png_2026-09-01.png',
        'demo_010_IMG_0002.png_2026-09-01.png',
        'demo_015_IMG_0010.png_2026-09-01.png',
      ]);
      expect(r.rows.every((x) => x.status == RenameStatus.ok), isTrue);
      expect(r.canApply, isTrue);
    });

    test('prefix and suffix support tokens; {n} without width', () {
      final r = plan([item('a.txt'), item('b.txt')], const RenameRules(prefix: '{n}-', suffix: '_v{n:2}'));
      expect(r.rows.map((x) => x.newName), ['1-a_v01.txt', '2-b_v02.txt']);
    });

    test('unknown tokens and bad widths are plan errors', () {
      expect(plan([item('a.txt')], const RenameRules(template: '{nope}')).error, contains('Unknown token {nope}'));
      expect(plan([item('a.txt')], const RenameRules(prefix: '{name:3}')).error, contains('Only {n}'));
      expect(plan([item('a.txt')], const RenameRules(template: '{n:99}')).error, contains('1-12'));
      expect(plan([item('a.txt')], const RenameRules(template: '{nope}')).canApply, isFalse);
    });

    test('find/replace plain and regex with groups; extension excluded by default', () {
      final plain = plan([item('IMG_0001.png')], const RenameRules(find: 'IMG_', replace: 'shot-'));
      expect(plain.rows.single.newName, 'shot-0001.png');
      final regex = plan([
        item('level_3_boss.json'),
      ], const RenameRules(find: r'level_(\d+)_(\w+)', replace: r'$2-L$1', useRegex: true));
      expect(regex.rows.single.newName, 'boss-L3.json');
      final ext = plan([item('a.jpeg')], const RenameRules(find: 'jpeg', replace: 'jpg'));
      expect(ext.rows.single.status, RenameStatus.unchanged, reason: 'extension untouched unless included');
      final withExt = plan([item('a.jpeg')], const RenameRules(find: 'jpeg', replace: 'jpg', includeExtension: true));
      expect(withExt.rows.single.newName, 'a.jpg');
      expect(
        plan([item('a.txt')], const RenameRules(find: '(', useRegex: true)).error,
        contains('Invalid regular expression'),
      );
    });

    test('case transforms apply to the name, extension kept', () {
      RenamePlan c(RenameCase k) => plan([item('my_cool-file name.TXT')], RenameRules(caseTransform: k));
      expect(c(RenameCase.lower).rows.single.newName, 'my_cool-file name.TXT');
      expect(c(RenameCase.upper).rows.single.newName, 'MY_COOL-FILE NAME.TXT');
      expect(c(RenameCase.title).rows.single.newName, 'My_Cool-File Name.TXT');
    });

    test('extension change and removal', () {
      expect(
        plan([
          item('a.jpeg'),
        ], const RenameRules(extensionMode: ExtensionMode.change, newExtension: '.JPG')).rows.single.newName,
        'a.JPG',
      );
      expect(plan([item('a.jpeg')], const RenameRules(extensionMode: ExtensionMode.remove)).rows.single.newName, 'a');
      expect(
        plan([item('a.jpeg')], const RenameRules(extensionMode: ExtensionMode.change)).error,
        contains('new extension'),
      );
    });
  });

  group('planner statuses', () {
    test('collision with a file outside the batch', () {
      final r = plan(
        [item('a.txt')],
        const RenameRules(find: 'a', replace: 'b'),
        existing: {
          '': ['a.txt', 'B.TXT'],
        },
      );
      expect(r.rows.single.status, RenameStatus.collision);
      expect(r.rows.single.message, contains('B.TXT'));
      expect(r.canApply, isFalse);
    });

    test('duplicates within the batch (case-insensitive)', () {
      final r = plan([item('a1.txt'), item('A2.txt')], const RenameRules(template: 'same'));
      expect(r.rows.map((x) => x.status), everyElement(RenameStatus.duplicate));
      final ci = plan([item('x.txt'), item('y.txt')], const RenameRules(template: '{n}'));
      expect(ci.rows.map((x) => x.status), everyElement(RenameStatus.ok));
      final ci2 = plan([
        item('x.txt'),
        item('y.txt'),
      ], const RenameRules(find: '^[xy]\$', replace: 'Q', useRegex: true, caseSensitive: false));
      expect(ci2.rows.map((x) => x.status), everyElement(RenameStatus.duplicate));
    });

    test('invalid and reserved names', () {
      expect(plan([item('a.txt')], const RenameRules(template: 'con')).rows.single.status, RenameStatus.invalid);
      expect(plan([item('a.txt')], const RenameRules(template: 'bad?')).rows.single.status, RenameStatus.invalid);
      expect(
        plan([
          item('a.txt'),
        ], const RenameRules(template: 'dot.', extensionMode: ExtensionMode.remove)).rows.single.status,
        RenameStatus.invalid,
      );
      expect(plan([item('a.txt')], const RenameRules(template: 'a/b')).rows.single.message, contains('/'));
    });

    test('case-only change is allowed and flagged', () {
      final r = plan([item('readme.txt')], const RenameRules(caseTransform: RenameCase.upper));
      expect(r.rows.single.newName, 'README.txt');
      expect(r.rows.single.status, RenameStatus.caseOnly);
      expect(r.canApply, isTrue);
    });

    test('swap a <-> b is not a collision', () {
      final r = plan([item('a.txt'), item('b.txt')], const RenameRules(find: '^[ab]\$', useRegex: true, replace: 'X'));
      expect(r.rows.map((x) => x.status), everyElement(RenameStatus.duplicate));
      final swap = planRenames(
        items: [item('a.txt'), item('b.txt')],
        rules: const RenameRules(),
        existing: {
          '': ['a.txt', 'b.txt'],
        },
      );
      expect(swap.rows.every((x) => x.status == RenameStatus.unchanged), isTrue);
      final rows = classify([item('a.txt'), item('b.txt')], ['b.txt', 'a.txt'], {
        '': ['a.txt', 'b.txt'],
      });
      expect(rows.map((x) => x.status), [RenameStatus.ok, RenameStatus.ok]);
    });

    test('renaming onto a file that keeps its name is a collision', () {
      final rows = classify([item('a.txt'), item('b.txt')], ['a.txt', 'a.txt'], {
        '': ['a.txt', 'b.txt'],
      });
      expect(rows[0].status, RenameStatus.unchanged);
      expect(rows[1].status, RenameStatus.collision);
    });

    test('same names in different folders do not collide', () {
      final r = plan([item('x.txt', dir: 'a'), item('x.txt', dir: 'b')], const RenameRules(template: 'same'));
      expect(r.rows.map((x) => x.status), everyElement(RenameStatus.ok));
    });
  });

  group('executor on disk', () {
    late Directory tmp;
    late String root;
    late String meta;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('j3_ren_');
      root = p.join(tmp.path, 'root');
      meta = p.join(tmp.path, 'meta');
      Directory(root).createSync();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    void write(String rel, String content) => File(p.join(root, rel))
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
    String read(String rel) => File(p.join(root, rel)).readAsStringSync();

    test('swap a <-> b is applied correctly, journaled and undone', () async {
      write('a.txt', 'A');
      write('b.txt', 'B');
      final scan = await RenameScanner.scan(root: root, folder: root);
      final rows = classify(scan.items, ['b.txt', 'a.txt'], scan.existing);
      final exec = RenameExecutor(root: root, metaDir: meta);
      final res = await exec.apply(rows);
      expect(res.renamed, 2);
      expect(read('a.txt'), 'B');
      expect(read('b.txt'), 'A');
      final journals = await exec.journals();
      expect(journals.single.status, JournalStatus.applied);
      expect(File(journals.single.file).path, startsWith(p.join(meta, 'renames')));
      expect(Directory(root).listSync().map((e) => p.basename(e.path)).toSet(), {'a.txt', 'b.txt'});

      final undo = await exec.undo(journals.single);
      expect(undo.renamed, 2);
      expect(undo.skipped, isEmpty);
      expect(read('a.txt'), 'A');
      expect(read('b.txt'), 'B');
      expect((await exec.journals()).single.status, JournalStatus.undone);
    });

    test('case-only rename and a chain a->b->c', () async {
      write('readme.txt', 'R');
      write('a.txt', '1');
      write('b.txt', '2');
      final scan = await RenameScanner.scan(root: root, folder: root);
      final names = {for (final i in scan.items) i.name: i};
      final items = [names['readme.txt']!, names['a.txt']!, names['b.txt']!];
      final rows = classify(items, ['README.txt', 'b.txt', 'c.txt'], scan.existing);
      expect(rows.map((r) => r.status), [RenameStatus.caseOnly, RenameStatus.ok, RenameStatus.ok]);
      await RenameExecutor(root: root, metaDir: meta).apply(rows);
      final present = Directory(root).listSync().map((e) => p.basename(e.path)).toSet();
      expect(present, {'README.txt', 'b.txt', 'c.txt'});
      expect(read('b.txt'), '1');
      expect(read('c.txt'), '2');
    });

    test('undo skips files that were moved or edited afterwards', () async {
      write('one.txt', '1');
      write('two.txt', '2');
      final exec = RenameExecutor(root: root, metaDir: meta);
      final scan = await RenameScanner.scan(root: root, folder: root);
      final r = planRenames(
        items: scan.items,
        rules: const RenameRules(prefix: 'x_'),
        existing: scan.existing,
      );
      await exec.apply(r.rows);
      File(p.join(root, 'x_two.txt')).deleteSync();
      final undo = await exec.undo((await exec.journals()).single);
      expect(undo.renamed, 1);
      expect(undo.skipped.single, contains('x_two.txt'));
      expect(File(p.join(root, 'one.txt')).existsSync(), isTrue);
      expect((await exec.journals()).single.status, JournalStatus.partiallyUndone);
    });

    test('refuses plans with blocking rows and rolls back on failure', () async {
      write('a.txt', 'A');
      final scan = await RenameScanner.scan(root: root, folder: root);
      final exec = RenameExecutor(root: root, metaDir: meta);
      final blocked = classify(scan.items, ['con'], scan.existing);
      expect(() => exec.apply(blocked), throwsStateError);
      // Source vanished after planning: apply refuses before moving anything.
      final rows = classify(scan.items, ['z.txt'], scan.existing);
      File(p.join(root, 'a.txt')).deleteSync();
      await expectLater(exec.apply(rows), throwsA(isA<FileSystemException>()));
    });

    test('scanner honours recursion, glob filter and hidden files; unicode names', () async {
      write('rename-demo/IMG_0001.png', 'x');
      write('rename-demo/IMG_0002.png', 'y');
      write('rename-demo/sub/IMG_0003.png', 'z');
      write('rename-demo/notes.txt', 'n');
      write('rename-demo/.hidden.png', 'h');
      write('rename-demo/名前-ünïcødé.png', 'u');
      final folder = p.join(root, 'rename-demo');
      final flat = await RenameScanner.scan(root: root, folder: folder, filter: '*.png');
      expect(flat.items.map((i) => i.name).toSet(), {'IMG_0001.png', 'IMG_0002.png', '名前-ünïcødé.png'});
      expect(flat.items.first.dir, 'rename-demo');
      expect(flat.existing['rename-demo'], containsAll(['notes.txt', '.hidden.png', 'sub']));
      final deep = await RenameScanner.scan(root: root, folder: folder, filter: '*.png', recursive: true);
      expect(deep.items.map((i) => i.relativePath), contains('rename-demo/sub/IMG_0003.png'));
      final plan = planRenames(
        items: deep.items,
        rules: const RenameRules(template: 'shot_{n:2}'),
        existing: deep.existing,
      );
      expect(plan.canApply, isTrue);
      await RenameExecutor(root: root, metaDir: meta).apply(plan.rows);
      expect(File(p.join(folder, 'shot_01.png')).readAsStringSync(), 'x');
      expect(File(p.join(folder, 'sub', 'shot_03.png')).readAsStringSync(), 'z');
      expect(File(p.join(folder, 'shot_04.png')).readAsStringSync(), 'u');
    });
  });
}
