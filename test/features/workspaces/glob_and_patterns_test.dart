import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/tasks/isolate_runner.dart';
import 'package:j3nsontop_multitool/core/utils/text_codec.dart';
import 'package:j3nsontop_multitool/features/workspaces/domain/file_names.dart';
import 'package:j3nsontop_multitool/features/workspaces/domain/fs_errors.dart';
import 'package:j3nsontop_multitool/features/workspaces/domain/glob.dart';
import 'package:j3nsontop_multitool/features/workspaces/domain/line_endings.dart';
import 'package:j3nsontop_multitool/features/workspaces/domain/name_query.dart';
import 'package:j3nsontop_multitool/features/workspaces/domain/text_pattern.dart';
import 'package:j3nsontop_multitool/features/workspaces/presentation/shared/requests.dart';

void main() {
  group('Glob', () {
    test('pattern without slash matches the file name at any depth', () {
      final g = Glob('*.json');
      expect(g.matchesPath, isFalse);
      expect(g.matches('a.json'), isTrue);
      expect(g.matches('game/config/graphics.json'), isTrue);
      expect(g.matches('a.jsonx'), isFalse);
      expect(g.matches('json'), isFalse);
    });

    test('**/ matches zero or more folders', () {
      final g = Glob('**/save*.json');
      expect(g.matchesPath, isTrue);
      expect(g.matches('save.json'), isTrue);
      expect(g.matches('saves/save_2.json'), isTrue);
      expect(g.matches('a/b/c/save1.json'), isTrue);
      expect(g.matches('saves/slot1.json'), isFalse);
      expect(g.matches('saves/save1.json.bak'), isFalse);
    });

    test('single star does not cross folders; trailing ** does', () {
      expect(Glob('data/*.csv').matches('data/items.csv'), isTrue);
      expect(Glob('data/*.csv').matches('data/sub/items.csv'), isFalse);
      expect(Glob('data/**').matches('data/sub/deep/x.bin'), isTrue);
      expect(Glob('data/**').matches('other/x.bin'), isFalse);
      expect(Glob('a/**/b.txt').matches('a/b.txt'), isTrue);
      expect(Glob('a/**/b.txt').matches('a/x/y/b.txt'), isTrue);
    });

    test('question mark, classes, negation, braces and escapes', () {
      expect(Glob('IMG_000?.png').matches('IMG_0001.png'), isTrue);
      expect(Glob('IMG_000?.png').matches('IMG_00010.png'), isFalse);
      expect(Glob('[a-c]*.txt').matches('b1.txt'), isTrue);
      expect(Glob('[a-c]*.txt').matches('d1.txt'), isFalse);
      expect(Glob('[!0-9]*').matches('x9'), isTrue);
      expect(Glob('[!0-9]*').matches('9x'), isFalse);
      expect(Glob('*.{png,jpg}').matches('a.jpg'), isTrue);
      expect(Glob('*.{png,jpg}').matches('a.gif'), isFalse);
      expect(Glob('{a,b{1,2}}.txt').matches('b2.txt'), isTrue);
      expect(Glob(r'\*.txt').matches('*.txt'), isTrue);
      expect(Glob(r'\*.txt').matches('a.txt'), isFalse);
    });

    test('case sensitivity toggle', () {
      expect(Glob('*.PNG').matches('a.png'), isFalse);
      expect(Glob('*.PNG', caseSensitive: false).matches('a.png'), isTrue);
    });

    test('pathological patterns stay fast (no backtracking)', () {
      final g = Glob('*a*a*a*a*a*a*a*a*a*a*b');
      final subject = 'a' * 250;
      final sw = Stopwatch()..start();
      expect(g.matches(subject), isFalse);
      expect(sw.elapsedMilliseconds, lessThan(500));
    });

    test('rejects empty and absurd brace expansions', () {
      expect(() => Glob('  '), throwsFormatException);
      expect(() => Glob('{a,b}{c,d}{e,f}{g,h}{i,j}{k,l}{m,n}{o,p}{q,r}'), throwsFormatException);
    });
  });

  group('NameQuery', () {
    test('substring looks at the name only, case-insensitive by default', () {
      final q = NameQuery.compile('SAVE', NameMatchMode.substring);
      expect(q.matches('game/saves/slot1.json'), isFalse);
      expect(q.matches('game/saves/save1.json'), isTrue);
    });

    test('invalid regex is reported before searching', () {
      expect(
        () => NameQuery.compile('(unclosed', NameMatchMode.regex),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('Invalid regular expression'))),
      );
      expect(() => NameQuery.compile('', NameMatchMode.glob), throwsFormatException);
    });

    test('regex matching runs bounded and a catastrophic pattern times out', () async {
      final paths = ['${'a' * 32}!'];
      expect(regexMatchIndices(r'^a+!$', true, paths), [0]);
      await expectLater(
        runBounded(() => regexMatchIndices(r'^(a+)+$', true, paths), timeout: const Duration(milliseconds: 300)),
        throwsA(isA<OperationTimedOut>()),
      );
    });
  });

  group('FindSpec / replace', () {
    test('plain text is escaped and replacement is literal', () {
      final r = replaceAllCounting(r'price: $5 (x.y)', const FindSpec(pattern: '(x.y)'), r'$1');
      expect(r.count, 1);
      expect(r.text, r'price: $5 $1');
    });

    test('regex groups, named groups, whole match and escapes', () {
      const spec = FindSpec(pattern: r'(?<k>\w+)=(\d+)', isRegex: true);
      final r = replaceAllCounting('a=1 b=22', spec, r'${k}:$2[$&]$$');
      expect(r.count, 2);
      expect(r.text, r'a:1[a=1]$ b:22[b=22]$');
      final nl = replaceAllCounting('x,y', const FindSpec(pattern: ',', isRegex: true), r'\n');
      expect(nl.text, 'x\ny');
    });

    test('group numbers: longest existing group wins, missing groups kept literally', () {
      final m = RegExp(r'(a)(b)').firstMatch('ab')!;
      expect(expandReplacement(m, r'$12'), 'a2');
      expect(expandReplacement(m, r'$9'), r'$9');
      expect(expandReplacement(m, r'${2}'), 'b');
    });

    test('whole word and case options', () {
      final r = replaceAllCounting(
        'cat Cat concat',
        const FindSpec(pattern: 'cat', wholeWord: true, caseSensitive: false),
        'dog',
      );
      expect(r.text, 'dog dog concat');
      expect(r.count, 2);
    });

    test('invalid regex gives a readable message', () {
      expect(const FindSpec(pattern: '[a-', isRegex: true).validate(), contains('Invalid regular expression'));
      expect(const FindSpec(pattern: '').validate(), isNotNull);
    });

    test('searchLines reports line numbers, columns and highlight ranges', () {
      final re = const FindSpec(pattern: 'hp').compile();
      final lines = searchLines('max_hp = 10\r\nfoo\r\nhp hp\n', re);
      expect(lines.map((l) => l.line), [1, 3]);
      expect(lines.first.column, 5);
      expect(lines.last.ranges, [0, 2, 3, 5]);
      var total = 0;
      searchLines('hp\nhp hp', re, totalMatches: (n) => total = n);
      expect(total, 3);
    });

    test('long lines are windowed around the match', () {
      final re = const FindSpec(pattern: 'needle').compile();
      final line = '${'x' * 1000}needle${'y' * 1000}';
      final m = searchLines(line, re, snippetWidth: 100).single;
      expect(m.snippet.length, lessThan(120));
      expect(m.snippet.substring(m.ranges[0], m.ranges[1]), 'needle');
    });
  });

  group('FileNames', () {
    test('validate rejects reserved, illegal and overlong names', () {
      expect(FileNames.validate('ok name.txt'), isNull);
      expect(FileNames.validate('名前-ünïcødé.txt'), isNull);
      expect(FileNames.validate(''), isNotNull);
      expect(FileNames.validate('a/b'), isNotNull);
      expect(FileNames.validate('what?.txt'), contains('"?"'));
      expect(FileNames.validate('CON'), contains('Reserved'));
      expect(FileNames.validate('lpt1.log'), contains('Reserved'));
      expect(FileNames.validate('trailing.'), isNotNull);
      expect(FileNames.validate('x' * 256), contains('255'));
      expect(FileNames.validate('ü' * 128), contains('255'), reason: '256 UTF-8 bytes');
    });

    test('split and natural compare', () {
      expect(FileNames.split('a.tar.gz'), ('a.tar', '.gz'));
      expect(FileNames.split('.gitignore'), ('.gitignore', ''));
      expect(FileNames.split('noext'), ('noext', ''));
      final names = ['img10.png', 'img2.png', 'IMG1.png', 'img02.png'];
      names.sort(FileNames.compareNatural);
      expect(names, ['IMG1.png', 'img2.png', 'img02.png', 'img10.png']);
    });
  });

  group('line endings', () {
    test('stats, dominant and conversion', () {
      final s = LineEndingStats.of('a\r\nb\r\nc\nd');
      expect(s.kind, LineEnding.mixed);
      expect(s.dominant, LineEnding.crlf);
      expect(LineEndingStats.of('x').kind, LineEnding.none);
      final lf = LineEndings.normalize('a\r\nb\rc\n');
      expect(lf, 'a\nb\nc\n');
      expect(LineEndings.apply(lf, LineEnding.crlf), 'a\r\nb\r\nc\r\n');
      expect(LineEndings.apply(lf, LineEnding.cr), 'a\rb\rc\r');
    });
  });

  group('open requests', () {
    test('each request is handed out exactly once, newest wins', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(editorRequestProvider.notifier);
      expect(n.claim(), isNull);
      n.open('/a.txt', line: 3);
      n.open('/b.txt', line: 7);
      expect(n.hasPending, isTrue);
      final r = n.claim()!;
      expect((r.path, r.line), ('/b.txt', 7));
      expect(n.claim(), isNull, reason: 'a rebuilt page must not replay it');
      expect(n.hasPending, isFalse);
      expect(c.read(hexRequestProvider), isNull, reason: 'editor and hex requests are separate');
    });
  });

  group('describeError', () {
    test('explains storage full, access denied and long paths', () {
      final full = describeError(
        const FileSystemException('write failed', '/x', OSError('No space left on device', 28)),
      );
      expect(full.title, 'Storage is full');
      expect(full.hint, contains('Free up storage'));
      expect(
        describeError(const FileSystemException('open failed', '/x', OSError('Permission denied', 13))).title,
        'Access denied',
      );
      expect(
        describeError(const FileSystemException('x', '/x', OSError('Das Dateisystem ist voll', 112))).title,
        'Storage is full',
        reason: 'localised message falls back to the Windows error code',
      );
      expect(
        describeError(const FileSystemException('x', '/x', OSError('File name too long', 36))).title,
        'Path too long',
      );
      expect(describeError(const OperationCancelled()).title, 'Cancelled');
      expect(describeError(const PatternTimeoutException(Duration(seconds: 2), ['a.txt'])).title, 'Pattern too slow');
    });
  });
}
