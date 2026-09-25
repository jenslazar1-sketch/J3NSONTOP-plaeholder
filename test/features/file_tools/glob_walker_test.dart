import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/features/file_tools/domain/file_walker.dart';
import 'package:j3nsontop_multitool/features/file_tools/domain/glob.dart';
import 'package:path/path.dart' as p;

void main() {
  group('GlobPattern', () {
    test('name patterns match at any depth, case-insensitively', () {
      final g = GlobPattern('*.log');
      expect(g.matches('game.log'), isTrue);
      expect(g.matches('logs/deep/CRASH.LOG'), isTrue);
      expect(g.matches('game.log.bak'), isFalse);
    });

    test('path patterns, ** and classes', () {
      expect(GlobPattern('game/config/*.ini').matches('game/config/settings.ini'), isTrue);
      expect(GlobPattern('game/config/*.ini').matches('game/config/sub/x.ini'), isFalse);
      expect(GlobPattern('**/*.json').matches('a.json'), isTrue);
      expect(GlobPattern('**/*.json').matches('a/b/c.json'), isTrue);
      expect(GlobPattern('data/**').matches('data'), isTrue);
      expect(GlobPattern('data/**').matches('data/x/y.csv'), isTrue);
      expect(GlobPattern('data/**').matches('database/x'), isFalse);
      expect(GlobPattern('a/**/b.txt').matches('a/b.txt'), isTrue);
      expect(GlobPattern('a/**/b.txt').matches('a/x/y/b.txt'), isTrue);
      expect(GlobPattern('img_00[0-4]?.png').matches('IMG_0001.png'), isTrue);
      expect(GlobPattern('img_00[!0-4]?.png').matches('IMG_0051.png'), isTrue);
      expect(GlobPattern('*.{png,jpg}').matches('x.JPG'), isTrue);
      expect(GlobPattern('/top.txt').matches('top.txt'), isTrue);
      expect(GlobPattern('file(1).txt').matches('file(1).txt'), isTrue);
    });

    test('invalid patterns throw FormatException', () {
      expect(() => GlobPattern('[abc'), throwsFormatException);
      expect(() => GlobPattern('{a,b'), throwsFormatException);
      expect(GlobFilter.validate('*.txt, [x'), isNotNull);
      expect(GlobFilter.validate('*.txt, *.{a,b}'), isNull);
    });

    test('filter parsing keeps commas inside braces', () {
      expect(GlobFilter.splitPatterns(' *.txt, *.{ini,json} ;\nfoo '), ['*.txt', '*.{ini,json}', 'foo']);
      final f = GlobFilter.parse(include: '*.txt', exclude: 'skip/**, *.bak.txt');
      expect(f.acceptsFile('a.txt'), isTrue);
      expect(f.acceptsFile('a.bak.txt'), isFalse);
      expect(f.acceptsFile('a.png'), isFalse);
      expect(f.entersFolder('skip'), isFalse);
      expect(f.entersFolder('keep'), isTrue);
      expect(f.describe(), contains('exclude'));
    });
  });

  group('walkFolder', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('j3_walk_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    void write(String rel, [String content = 'x']) {
      final f = File(p.join(tmp.path, rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    test('recursive, sorted, filters, min size and pruned folders', () async {
      write('b.txt', 'hello');
      write('a/deep/c.txt', 'hello world');
      write('a/tiny.txt', '');
      write('node_modules/x.txt', 'zzzz');
      write('a/skip.bin', 'bin');
      final r = await walkFolder(
        tmp.path,
        filter: GlobFilter.parse(include: '*.txt', exclude: 'node_modules'),
        minSize: 1,
      );
      expect(r.files.map((f) => f.relativePath), ['a/deep/c.txt', 'b.txt']);
      expect(r.tooSmall, 1);
      expect(r.filteredOut, 1);
      expect(r.totalBytes, 16);
      expect(r.truncated, isFalse);
    });

    test('symbolic links are skipped, never followed (no loops)', () async {
      if (Platform.isWindows) return;
      write('real/a.txt');
      Link(p.join(tmp.path, 'real', 'loop')).createSync(tmp.path);
      Link(p.join(tmp.path, 'file-link.txt')).createSync(p.join(tmp.path, 'real', 'a.txt'));
      final r = await walkFolder(tmp.path);
      expect(r.files.map((f) => f.relativePath), ['real/a.txt']);
      expect(r.skippedLinks, containsAll(['real/loop', 'file-link.txt']));
    });

    test('max files truncates, cancellation throws, non-folder rejected', () async {
      for (var i = 0; i < 5; i++) {
        write('f$i.txt');
      }
      final r = await walkFolder(tmp.path, maxFiles: 3);
      expect(r.files, hasLength(3));
      expect(r.truncated, isTrue);
      await expectLater(walkFolder(tmp.path, token: CancellationToken()..cancel()), throwsA(isA<OperationCancelled>()));
      await expectLater(walkFolder(p.join(tmp.path, 'f0.txt')), throwsA(isA<FileSystemException>()));
    });
  });
}
