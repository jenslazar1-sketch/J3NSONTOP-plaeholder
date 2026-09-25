import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/utils/hashing.dart';
import 'package:j3nsontop_multitool/features/file_tools/domain/duplicates.dart';
import 'package:j3nsontop_multitool/features/file_tools/domain/glob.dart';
import 'package:j3nsontop_multitool/features/file_tools/domain/quarantine.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late Directory root;
  late Directory meta;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('j3_dup_');
    root = Directory(p.join(tmp.path, 'files'))..createSync();
    meta = Directory(p.join(tmp.path, 'meta'))..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File write(String rel, List<int> bytes) {
    final f = File(p.join(root.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    return f;
  }

  List<int> text(String s) => utf8.encode(s);

  group('scanDuplicates', () {
    test('groups identical content, not same-size different content', () async {
      write('a/one.txt', text('same content'));
      write('b/two.txt', text('same content'));
      write('c/three.txt', text('same content'));
      write('diff1.txt', text('aaaaaaaaaaaa')); // same size (12), different content
      write('diff2.txt', text('bbbbbbbbbbbb'));
      write('unique.txt', text('only one of this size'));
      write('pair/x.bin', List.filled(100, 7));
      write('pair/y.bin', List.filled(100, 7));
      final r = await scanDuplicates(root.path);
      expect(r.groups, hasLength(2));
      // Sorted by wasted bytes: 3 x 12 = 24 wasted vs 2 x 100 = 100 wasted.
      expect(r.groups.first.size, 100);
      expect(r.groups.first.files.map((f) => f.relativePath), ['pair/x.bin', 'pair/y.bin']);
      final text3 = r.groups[1];
      expect(text3.files.map((f) => f.relativePath), ['a/one.txt', 'b/two.txt', 'c/three.txt']);
      expect(text3.digest, Hashing.text('same content'));
      expect(text3.wastedBytes, 24);
      expect(r.wastedBytes, 124);
      expect(r.duplicateFiles, 3);
      expect(r.filesScanned, 8);
    });

    test('large files use the quick head check and still group correctly', () async {
      final big = List<int>.generate(300 * 1024, (i) => i % 251);
      write('big1.bin', big);
      write('big2.bin', big);
      final tail = [...big]..[big.length - 1] = 1; // same head, different tail
      write('big3.bin', tail);
      final head = [...big]..[0] = 99; // different head
      write('big4.bin', head);
      final phases = <DuplicatePhase>{};
      final r = await scanDuplicates(root.path, onProgress: (ph, _, _) => phases.add(ph));
      expect(r.groups.single.files.map((f) => f.relativePath), ['big1.bin', 'big2.bin']);
      expect(phases, containsAll([DuplicatePhase.scanning, DuplicatePhase.quickCheck, DuplicatePhase.hashing]));
      // big4 was rejected by the head check and never fully hashed.
      expect(r.hashedFiles, 3);
    });

    test('symbolic links are skipped and hard links are not duplicates', () async {
      if (Platform.isWindows) return;
      final original = write('orig.dat', text('linked payload'));
      Link(p.join(root.path, 'soft.dat')).createSync(original.path);
      final ln = await Process.run('ln', [original.path, p.join(root.path, 'hard.dat')]);
      expect(ln.exitCode, 0, reason: '${ln.stderr}');
      final r = await scanDuplicates(root.path);
      expect(r.groups, isEmpty, reason: 'a hard link shares storage; a symlink is not followed');
      expect(r.skippedLinks, ['soft.dat']);
      expect(r.hardLinks.single.$1, anyOf('hard.dat', 'orig.dat'));
      // A real copy next to the hard link is a duplicate of the pair.
      write('copy.dat', text('linked payload'));
      final r2 = await scanDuplicates(root.path);
      expect(r2.groups.single.files, hasLength(2));
    });

    test('filters, min size and cancellation', () async {
      write('a.txt', text('dup'));
      write('b.txt', text('dup'));
      write('a.log', text('dup'));
      write('e1.txt', []);
      write('e2.txt', []);
      final r = await scanDuplicates(root.path, filter: GlobFilter.parse(include: '*.txt'));
      expect(r.groups.single.files.map((f) => f.relativePath), ['a.txt', 'b.txt']);
      expect(r.filterDescription, contains('*.txt'));
      final withEmpty = await scanDuplicates(root.path, minSize: 0);
      expect(withEmpty.groups.length, 2);
      await expectLater(
        scanDuplicates(root.path, token: CancellationToken()..cancel()),
        throwsA(isA<OperationCancelled>()),
      );
    });

    test('keeper rules and reports (text, CSV, JSON)', () async {
      final old = write('deep/er/copy.txt', text('payload'));
      old.setLastModifiedSync(DateTime(2020));
      write('top.txt', text('payload'));
      final r = await scanDuplicates(root.path);
      final g = r.groups.single;
      expect(g.files[pickKeeper(g, KeeperRule.shallowest)].relativePath, 'top.txt');
      expect(g.files[pickKeeper(g, KeeperRule.oldest)].relativePath, 'deep/er/copy.txt');
      expect(g.files[pickKeeper(g, KeeperRule.newest)].relativePath, 'top.txt');
      expect(g.files[pickKeeper(g, KeeperRule.alphabetical)].relativePath, 'deep/er/copy.txt');

      final d = DuplicateDecisions(keepers: {g.id: 1}, selected: {'deep/er/copy.txt'});
      final txt = buildDuplicateReport(r, d, ReportFormat.text, rootLabel: 'files');
      expect(txt, contains('KEEP       top.txt'));
      expect(txt, contains('QUARANTINE deep/er/copy.txt'));
      final csv = buildDuplicateReport(r, d, ReportFormat.csv).trim().split('\n');
      expect(csv.first, 'group,sha256,size_bytes,role,path,modified_utc');
      expect(csv, hasLength(3));
      expect(csv[1], contains(',quarantine,deep/er/copy.txt,'));
      final json = jsonDecode(buildDuplicateReport(r, d, ReportFormat.json)) as Map<String, dynamic>;
      expect(json['reclaimableBytes'], 7);
      final files = ((json['groups'] as List).single as Map)['files'] as List;
      expect(files.map((f) => (f as Map)['role']), ['quarantine', 'keep']);
    });
  });

  group('QuarantineStore', () {
    QuarantineStore store() => QuarantineStore(
      workspaceRoot: root.path,
      metaDir: meta.path,
      workspaceId: 'ws1',
      clock: () => DateTime(2026, 9, 25, 12),
    );

    QuarantineRequest req(String rel, String keeper, String content) => QuarantineRequest(
      relativePath: rel,
      keeperRelativePath: keeper,
      size: utf8.encode(content).length,
      digest: Hashing.text(content),
    );

    test('moves copies with a journal, then restores them', () async {
      write('keep.txt', text('payload'));
      write('dup/one.txt', text('payload'));
      write('dup/名前 two.txt', text('payload'));
      final s = store();
      final r = await s.quarantine([
        req('dup/one.txt', 'keep.txt', 'payload'),
        req('dup/名前 two.txt', 'keep.txt', 'payload'),
      ]);
      expect(r.moved, 2);
      expect(r.skipped, isEmpty);
      expect(File(p.join(root.path, 'dup', 'one.txt')).existsSync(), isFalse);
      expect(File(p.join(root.path, 'keep.txt')).existsSync(), isTrue);
      final qFile = File(p.join(meta.path, 'quarantine', '20260925-120000', 'dup', 'one.txt'));
      expect(qFile.readAsStringSync(), 'payload');
      final journal = File(p.join(meta.path, 'quarantine', '20260925-120000.json'));
      expect(journal.existsSync(), isTrue);
      expect(journal.readAsStringSync(), contains('"state": "quarantined"'));

      final sessions = await s.sessions();
      expect(sessions.single.inQuarantine, hasLength(2));
      expect(sessions.single.quarantinedBytes, 14);

      // Restore one, then the rest.
      final one = await s.restore(sessions.single, only: {'dup/one.txt'});
      expect(one.restored, 1);
      expect(File(p.join(root.path, 'dup', 'one.txt')).readAsStringSync(), 'payload');
      final again = (await s.sessions()).single;
      expect(again.inQuarantine.single.relativePath, 'dup/名前 two.txt');
      final rest = await s.restore(again);
      expect(rest.restored, 1);
      expect(File(p.join(root.path, 'dup', '名前 two.txt')).existsSync(), isTrue);
      final done = (await s.sessions()).single;
      expect(done.fullyRestored, isTrue);
      expect(Directory(done.dir).existsSync(), isFalse, reason: 'empty quarantine folders are pruned');
    });

    test('restore never overwrites: occupied paths get a new name', () async {
      write('keep.txt', text('payload'));
      write('copy.txt', text('payload'));
      final s = store();
      await s.quarantine([req('copy.txt', 'keep.txt', 'payload')]);
      write('copy.txt', text('new file the user created later'));
      final r = await s.restore((await s.sessions()).single);
      expect(r.restored, 1);
      expect(r.renamed.single.$2, 'copy (2).txt');
      expect(File(p.join(root.path, 'copy.txt')).readAsStringSync(), 'new file the user created later');
      expect(File(p.join(root.path, 'copy (2).txt')).readAsStringSync(), 'payload');
    });

    test('re-checks before moving: changed copies, missing keepers, unsafe paths', () async {
      write('keep.txt', text('payload'));
      write('changed.txt', text('payloaX'));
      write('orphan.txt', text('payload'));
      final s = store();
      final r = await s.quarantine([
        req('changed.txt', 'keep.txt', 'payload'),
        req('orphan.txt', 'gone.txt', 'payload'),
        req('../outside.txt', 'keep.txt', 'payload'),
      ]);
      final reasons = {for (final (path, why) in r.skipped) path: why};
      expect(reasons['changed.txt'], contains('content changed'));
      expect(reasons['orphan.txt'], contains('keeper no longer exists'));
      expect(reasons['../outside.txt'], contains('unsafe'));
      expect(r.moved, 0);
      expect(File(p.join(root.path, 'changed.txt')).existsSync(), isTrue);
      expect(File(p.join(root.path, 'orphan.txt')).existsSync(), isTrue);

      // Two copies that name each other as keeper are never both moved.
      final cross = await s.quarantine([
        req('keep.txt', 'orphan.txt', 'payload'),
        req('orphan.txt', 'keep.txt', 'payload'),
      ]);
      expect(cross.moved, 0);
      expect(cross.skipped.map((x) => x.$2), everyElement(contains('keeper is also selected')));
      expect(File(p.join(root.path, 'keep.txt')).existsSync(), isTrue);
      expect(File(p.join(root.path, 'orphan.txt')).existsSync(), isTrue);
    });

    test('cancellation stops before moving anything else', () async {
      write('keep.txt', text('payload'));
      write('a.txt', text('payload'));
      final token = CancellationToken()..cancel();
      final r = await store().quarantine([req('a.txt', 'keep.txt', 'payload')], token: token);
      expect(r.cancelled, isTrue);
      expect(r.moved, 0);
      expect(File(p.join(root.path, 'a.txt')).existsSync(), isTrue);
    });

    test('damaged journals are ignored, session ids stay unique', () async {
      write('keep.txt', text('p'));
      write('a.txt', text('p'));
      write('b.txt', text('p'));
      final s = store();
      await s.quarantine([req('a.txt', 'keep.txt', 'p')]);
      await s.quarantine([req('b.txt', 'keep.txt', 'p')]);
      File(p.join(meta.path, 'quarantine', 'broken.json')).writeAsStringSync('{not json');
      final sessions = await s.sessions();
      expect(sessions.map((x) => x.id), ['20260925-120000-2', '20260925-120000']);
    });
  });
}
