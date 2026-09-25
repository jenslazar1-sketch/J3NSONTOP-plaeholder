import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/tasks/isolate_runner.dart';
import 'package:j3nsontop_multitool/core/text/diff.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/common.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/regex_tools.dart';
import 'package:j3nsontop_multitool/features/dev_tools/domain/text_diff.dart';

void main() {
  group('Regex engine', () {
    test('matches with numbered and named groups', () {
      final r = executeRegexJob(
        const RegexJob(pattern: r'(?<key>\w+)=(\d+)', flags: RegexFlags(), input: 'a=1, bb=22, c=x'),
      );
      expect(r.matches.length, 2);
      expect(r.groupCount, 2);
      expect(r.groupNames, ['key']);
      final m = r.matches[1];
      expect((m.start, m.end, m.text), (5, 10, 'bb=22'));
      expect(m.groups, ['bb', '22']);
      expect(m.named, {'key': 'bb'});
    });

    test('group structure is known even without a match', () {
      final r = executeRegexJob(const RegexJob(pattern: r'(?<y>\d{4})-(\d\d)', flags: RegexFlags(), input: 'none'));
      expect(r.matches, isEmpty);
      expect(r.groupCount, 2);
      expect(r.groupNames, ['y']);
    });

    test('flags change matching', () {
      RegexRunResult run(String p, RegexFlags f, String s) => executeRegexJob(RegexJob(pattern: p, flags: f, input: s));
      expect(run('abc', const RegexFlags(), 'ABC').matches, isEmpty);
      expect(run('abc', const RegexFlags(caseSensitive: false), 'ABC').matches.length, 1);
      expect(run(r'^x', const RegexFlags(), 'a\nx').matches, isEmpty);
      expect(run(r'^x', const RegexFlags(multiLine: true), 'a\nx').matches.length, 1);
      expect(run('a.b', const RegexFlags(), 'a\nb').matches, isEmpty);
      expect(run('a.b', const RegexFlags(dotAll: true), 'a\nb').matches.length, 1);
      expect(run(r'\p{Lu}', const RegexFlags(unicode: true), 'aBc').matches.single.text, 'B');
      expect(const RegexFlags(caseSensitive: false, multiLine: true, dotAll: true, unicode: true).letters, 'imsu');
    });

    test('match count cap', () {
      final r = executeRegexJob(RegexJob(pattern: 'a', flags: const RegexFlags(), input: 'a' * 50, maxMatches: 10));
      expect(r.matches.length, 10);
      expect(r.capped, isTrue);
    });

    test('replacement template syntax', () {
      String rep(String p, String input, String t) =>
          executeRegexJob(RegexJob(pattern: p, flags: const RegexFlags(), input: input, replacement: t)).replaced!;
      expect(rep(r'(\w+)@(\w+)', 'me@host', r'$2 at $1'), 'host at me');
      expect(rep(r'(?<user>\w+)@(\w+)', 'me@host', r'${user}/${2}'), 'me/host');
      expect(rep(r'\d+', 'a1b22', r'[$&]'), 'a[1]b[22]');
      expect(rep(r'\d+', 'cost 5', r'$$$0'), r'cost $5');
      expect(rep(r'x', 'x', r'$z'), r'$z');
      final many = List.generate(11, (i) => '(${String.fromCharCode(0x61 + i)})').join();
      expect(rep(many, 'abcdefghijk', r'$11-$1'), 'k-a');
    });

    test('replacement errors carry positions', () {
      final r = executeRegexJob(
        const RegexJob(pattern: r'(a)', flags: RegexFlags(), input: 'a', replacement: r'ok ${nope}'),
      );
      expect(r.replaced, isNull);
      expect(r.replaceError!.offset, 3);
      expect(r.replaceError!.message, contains('nope'));
      expect(
        () => ReplacementTemplate.parse(r'$2', 1, const []),
        throwsA(isA<InputError>().having((e) => e.message, 'message', contains('Group 2'))),
      );
      expect(() => ReplacementTemplate.parse(r'${x', 0, const []), throwsA(isA<InputError>()));
    });

    test('compile errors are reported', () {
      expect(regexCompileError('(', const RegexFlags())!.message, contains('Invalid pattern'));
      expect(regexCompileError('ok', const RegexFlags()), isNull);
    });

    test('bounded run returns results from the worker', () async {
      final r = await runRegexBounded(const RegexJob(pattern: r'\d', flags: RegexFlags(), input: 'a1b2'));
      expect(r.matches.length, 2);
    });

    test('catastrophic backtracking is stopped by the time limit', () async {
      final sw = Stopwatch()..start();
      await expectLater(
        runRegexBounded(
          RegexJob(pattern: r'^(a+)+$', flags: const RegexFlags(), input: '${'a' * 40}!'),
          timeout: const Duration(milliseconds: 300),
        ),
        throwsA(isA<OperationTimedOut>()),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('cancellation stops the worker', () async {
      final token = CancellationToken();
      final f = runRegexBounded(
        RegexJob(pattern: r'^(a+)+$', flags: const RegexFlags(), input: '${'a' * 40}!'),
        token: token,
        timeout: const Duration(seconds: 30),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      token.cancel();
      await expectLater(f, throwsA(isA<OperationCancelled>()));
    });

    test('every example compiles and matches its sample', () {
      for (final e in regexExamples) {
        final r = executeRegexJob(RegexJob(pattern: e.pattern, flags: e.flags, input: e.sample));
        expect(r.matches, isNotEmpty, reason: e.name);
      }
      final ip = regexExamples.firstWhere((e) => e.name.startsWith('IPv4'));
      final r = executeRegexJob(RegexJob(pattern: ip.pattern, flags: ip.flags, input: ip.sample));
      expect(r.matches.map((m) => m.text), ['192.168.1.23', '10.0.2.2']);
    });
  });

  group('Text diff', () {
    test('computes stats and unified text', () {
      final o = TextDiff.compute('a\nb\nc\n', 'a\nB\nc\nd\n');
      expect(o.result.insertions, 2);
      expect(o.result.deletions, 1);
      expect(o.unchanged, 2);
      expect(o.linesA, 3);
      final u = o.unified(oldName: 'left', newName: 'right');
      expect(u, startsWith('--- left\n+++ right\n@@'));
      expect(u, contains('-b\n'));
      expect(u, contains('+B\n'));
      expect(u, contains('+d\n'));
    });

    test('ignore case and whitespace', () {
      expect(
        TextDiff.compute('Hello  World', 'hello world', ignoreCase: true, ignoreWhitespace: true).result.identical,
        isTrue,
      );
      expect(TextDiff.compute('Hello', 'hello').result.identical, isFalse);
      final o = TextDiff.compute('A', 'a', ignoreCase: true);
      expect(o.oldText(o.result.lines.single), 'A');
    });

    test('unified rows collapse unchanged runs', () {
      final a = List.generate(30, (i) => 'line $i').join('\n');
      final b = a.replaceFirst('line 15', 'LINE 15');
      final o = TextDiff.compute(a, b);
      final rows = TextDiff.unifiedRows(o.result, 3);
      expect(rows.first.hidden, 12);
      expect(rows.last.hidden, 11);
      expect(rows.where((r) => r.line != null).length, 8);
      expect(TextDiff.unifiedRows(o.result, null).length, 31);
    });

    test('side-by-side pairs deletions with insertions', () {
      final o = TextDiff.compute('keep\nold 1\nold 2\nend', 'keep\nnew 1\nend');
      final rows = TextDiff.sideBySideRows(o.result, null);
      expect(rows.length, 4);
      expect(rows[1].isChangedPair, isTrue);
      expect(rows[1].left!.text, 'old 1');
      expect(rows[1].right!.text, 'new 1');
      expect(rows[2].left!.text, 'old 2');
      expect(rows[2].right, isNull);
    });

    test('word diff marks changed tokens', () {
      final (l, r) = TextDiff.wordDiff('the quick brown fox', 'the slow brown fox');
      expect(l.where((s) => s.changed).map((s) => s.text), ['quick']);
      expect(r.where((s) => s.changed).map((s) => s.text), ['slow']);
      expect(l.map((s) => s.text).join(), 'the quick brown fox');
    });

    test('edit budget truncates huge differences and the flag is reported', () {
      final a = List.generate(4000, (i) => 'a$i').join('\n');
      final b = List.generate(4000, (i) => 'b$i').join('\n');
      final o = TextDiff.compute(a, b);
      expect(o.result.truncated, isTrue);
      expect(o.editBudget, lessThan(4000));
      expect(o.result.deletions, 4000);
      expect(o.result.insertions, 4000);
    });

    test('size guard', () {
      expect(() => TextDiff.checkSize('x' * (TextDiff.maxBytes + 1), ''), throwsA(isA<InputError>()));
    });

    test('computeAsync uses an isolate for large inputs and matches the sync result', () async {
      final a = List.generate(2000, (i) => 'row $i').join('\n');
      final b = a.replaceAll('row 1000', 'changed');
      final o = await TextDiff.computeAsync(a, b);
      expect(o.result.deletions, 1);
      expect(o.result.insertions, 1);
      expect(o.result.lines.where((l) => l.op == DiffOp.insert).single.newLine, 1001);
    });
  });
}
