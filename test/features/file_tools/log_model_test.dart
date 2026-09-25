import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/tasks/isolate_runner.dart';
import 'package:j3nsontop_multitool/features/file_tools/domain/log_model.dart';
import 'package:j3nsontop_multitool/features/file_tools/presentation/logs/log_controller.dart';
import 'package:path/path.dart' as p;

void main() {
  group('detectSeverity', () {
    final cases = <String, LogSeverity?>{
      '[ERROR] failed to load texture': LogSeverity.error,
      '2026-09-01 12:00:00.123 WARN  low memory': LogSeverity.warn,
      '2026-09-01T12:00:00Z INFO loaded ERROR table': LogSeverity.info,
      'ts=1 level=error msg="disk full"': LogSeverity.error,
      'time=2 lvl=debug x=1': LogSeverity.debug,
      '{"time":"x","level":"warning","msg":"slow"}': LogSeverity.warn,
      '{"level":50,"msg":"pino error"}': LogSeverity.error,
      '{"@l":"Fatal","@m":"serilog"}': LogSeverity.fatal,
      'E/ActivityManager( 1234): ANR in com.example': LogSeverity.error,
      'W/Tag: something odd': LogSeverity.warn,
      'V/Chatty: spam': LogSeverity.trace,
      '09-01 12:00:00.123  1234  5678 I MyApp: started': LogSeverity.info,
      '09-01 12:00:00.123  1234  5678 F libc: abort': LogSeverity.fatal,
      'E0925 12:00:00.000123 main.cc:12] glog error': LogSeverity.error,
      'W something happened': LogSeverity.warn,
      'D: detail': LogSeverity.debug,
      'I 12:00:01 boot': LogSeverity.info,
      '<critical> reactor core': LogSeverity.fatal,
      '[debug] tick': LogSeverity.debug,
      'Warning: config missing': LogSeverity.warn,
      '12:00:00 | TRACE | enter()': LogSeverity.trace,
      'java.lang.IllegalStateException: SEVERE state': LogSeverity.error,
      'VERBOSE mode': LogSeverity.trace,
      'PANIC: kernel': LogSeverity.fatal,
      // No level markers:
      'no error here in lowercase prose': null,
      r'F:\games\neon\save.json loaded': null,
      'I went home early': null,
      'Errors are counted later': null,
      '    at com.example.Main.run(Main.java:42)': null,
    };
    cases.forEach((line, expected) {
      test('"$line" -> ${expected?.label ?? 'none'}', () => expect(detectSeverity(line), expected));
    });

    test('continuation lines inherit; new timestamped records reset', () {
      final doc = LogDocument.fromText(
        'x.log',
        '2026-09-01 12:00:00 ERROR crash in renderer\n'
            'java.lang.NullPointerException: boom\n'
            '    at a.b.C.d(C.java:1)\n'
            '\n'
            '2026-09-01 12:00:01 plain record without level\n'
            '  indented detail\n'
            '2026-09-01 12:00:02 INFO ok\n',
      );
      expect(
        [for (var i = 0; i < doc.lines.length; i++) doc.severityOf(i)],
        [
          LogSeverity.error,
          LogSeverity.error,
          LogSeverity.error,
          LogSeverity.error,
          LogSeverity.other,
          LogSeverity.other,
          LogSeverity.info,
        ],
      );
      expect(doc.count(LogSeverity.error), 4);
      expect(filterBySeverity(doc, {LogSeverity.info, LogSeverity.other}), [4, 5, 6]);
    });
  });

  group('loadLogFile', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('j3_log_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String write(String name, List<int> bytes) {
      final f = File(p.join(tmp.path, name))..writeAsBytesSync(bytes);
      return f.path;
    }

    test('CRLF lines, counts and progress', () async {
      final path = write('a.log', utf8.encode('[INFO] a\r\n[WARN] b\r\n[ERROR] c ✓\r\n'));
      final fractions = <double>[];
      final doc = await loadLogFile(path, onProgress: (f, _) => fractions.add(f));
      expect(doc.lines, ['[INFO] a', '[WARN] b', '[ERROR] c ✓']);
      expect(doc.lineEndings.crlf, 3);
      expect(doc.encodingLabel, 'UTF-8');
      expect(doc.truncated, isFalse);
      expect(doc.malformed, isFalse);
      expect(fractions.last, 1);
    });

    test('invalid UTF-8 falls back to Latin-1 with a notice', () async {
      final path = write('bad.log', [...utf8.encode('[ERROR] caf'), 0xE9, 0x0A, ...utf8.encode('next')]);
      final doc = await loadLogFile(path);
      expect(doc.malformed, isTrue);
      expect(doc.encodingLabel, contains('Latin-1'));
      expect(doc.lines, ['[ERROR] café', 'next']);
    });

    test('UTF-16 LE with BOM and UTF-8 BOM', () async {
      final units = '[WARN] ünï\r\nsecond'.codeUnits;
      final path = write('u16.log', [
        0xFF,
        0xFE,
        for (final u in units) ...[u & 0xFF, u >> 8],
      ]);
      final doc = await loadLogFile(path);
      expect(doc.lines, ['[WARN] ünï', 'second']);
      expect(doc.encodingLabel, 'UTF-16 LE');
      final bom = await loadLogFile(write('bom.log', [0xEF, 0xBB, 0xBF, ...utf8.encode('x\ny')]));
      expect(bom.lines, ['x', 'y']);
      expect(bom.encodingLabel, 'UTF-8 with BOM');
    });

    test('line cap and byte cap truncate with a notice (no split characters)', () async {
      final many = write('many.log', utf8.encode(List.generate(50, (i) => 'line $i').join('\n')));
      final capped = await loadLogFile(many, maxLines: 10);
      expect(capped.lines, hasLength(10));
      expect(capped.truncatedByLines, isTrue);
      expect(capped.truncationNotice(), contains('first 10 lines'));

      // "é" is two bytes; a cut in the middle must not corrupt the text.
      final text = 'ééééé\nééééé\n';
      final bytes = write('multi.log', utf8.encode(text));
      final cut = await loadLogFile(bytes, maxBytes: 15);
      expect(cut.truncatedByBytes, isTrue);
      expect(cut.malformed, isFalse);
      expect(cut.lines.first, 'ééééé');
      expect(cut.lines.last, 'éé');
    });

    test('cancellation', () async {
      final path = write('big.log', utf8.encode(List.generate(10000, (i) => 'l$i').join('\n')));
      await expectLater(loadLogFile(path, token: CancellationToken()..cancel()), throwsA(isA<OperationCancelled>()));
    });
  });

  group('search and export', () {
    final lines = ['Timeout after 3s', 'all good', 'TIMEOUT again', 'retry timeout-2'];

    test('plain search is case-insensitive by default and records ranges', () {
      final r = searchPlain(lines, const LogQuery('timeout'));
      expect(r.matches, [0, 2, 3]);
      expect(r.firstRange[3], (6, 13));
      expect(searchPlain(lines, const LogQuery('TIMEOUT', caseSensitive: true)).matches, [2]);
      expect(searchPlain(lines, const LogQuery('a.l')).matches, isEmpty, reason: 'plain text is not a pattern');
    });

    test('regex search runs chunked in bounded workers', () async {
      final many = [for (var i = 0; i < 2500; i++) i.isEven ? 'code=$i ok' : 'code=$i fail'];
      final r = await searchRegex(many, const LogQuery(r'code=\d+ fail$', regex: true), chunkSize: 1000);
      expect(r.count, 1250);
      expect(r.matches.first, 1);
      expect(r.firstRange[1], (0, 11));
    });

    test('invalid regex is a FormatException', () async {
      await expectLater(searchRegex(lines, const LogQuery('([a-', regex: true)), throwsFormatException);
    });

    test('catastrophic pattern is stopped by the time limit', () async {
      final evil = ['${'a' * 40}!'];
      final sw = Stopwatch()..start();
      await expectLater(
        searchRegex(evil, const LogQuery(r'^(a+)+$', regex: true), budget: const Duration(milliseconds: 600)),
        throwsA(isA<OperationTimedOut>()),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('line ranges and export header', () {
      expect(formatLineRanges([1, 2, 3, 7, 10, 11]), '1-3, 7, 10-11');
      expect(formatLineRanges([5]), '5');
      final doc = LogDocument.fromText('logs/game.log', '[INFO] a\n[ERROR] b\n[ERROR] c\n[INFO] d\n');
      final text = buildLogExport(
        doc: doc,
        indices: [2, 1],
        scope: 'selected lines',
        severities: {LogSeverity.error},
        query: const LogQuery('b|c', regex: true),
        onlyMatches: true,
        now: DateTime(2026, 9, 25, 10),
      );
      expect(text, contains('# source: logs/game.log'));
      expect(text, contains('# severity filter: ERROR'));
      expect(text, contains('# search: /b|c/ (regex, ignore case), only matching lines'));
      expect(text, contains('# line ranges (original numbering): 2-3'));
      expect(text.trimRight().split('\n').sublist(text.trimRight().split('\n').length - 2), ['[ERROR] b', '[ERROR] c']);
    });
  });

  group('LogViewerController selection', () {
    late ProviderContainer c;
    setUp(() => c = ProviderContainer());
    tearDown(() => c.dispose());

    test('click, shift-click range, toggle, select matches and export content', () async {
      final ctl = c.read(logViewerProvider.notifier);
      ctl.setDocument(
        LogDocument.fromText(
          'game.log',
          List.generate(10, (i) => i.isEven ? '[INFO] tick $i' : '[WARN] slow frame $i').join('\n'),
        ),
      );
      ctl.tapLine(1);
      ctl.tapLine(4, range: true);
      expect(c.read(logViewerProvider).selected, {1, 2, 3, 4});
      ctl.tapLine(8, toggle: true);
      expect(c.read(logViewerProvider).selected, {1, 2, 3, 4, 8});
      final exported = ctl.exportText(selectedOnly: true, now: DateTime(2026));
      expect(exported, contains('line ranges (original numbering): 2-5, 9'));
      expect(exported, contains('[WARN] slow frame 3\n[INFO] tick 4\n[INFO] tick 8\n'));
      expect(exported, isNot(contains('frame 7')));
      expect(ctl.selectedText().split('\n'), hasLength(5));

      // Filter to warnings, search, select the matches.
      ctl.onlySeverity(LogSeverity.warn);
      expect(c.read(logViewerProvider).visible, [1, 3, 5, 7, 9]);
      await ctl.search(const LogQuery('frame [37]', regex: true));
      final st = c.read(logViewerProvider);
      expect(st.visibleMatches, [3, 7]);
      expect(st.currentMatch, 3);
      ctl.stepMatch(1);
      expect(c.read(logViewerProvider).currentMatch, 7);
      ctl.stepMatch(1);
      expect(c.read(logViewerProvider).currentMatch, 3, reason: 'wraps around');
      ctl.clearSelection();
      ctl.selectAllMatches();
      expect(c.read(logViewerProvider).selected, {3, 7});
      ctl.setOnlyMatches(true);
      final filtered = ctl.exportText(selectedOnly: false, now: DateTime(2026));
      expect(filtered, contains('# scope: all lines passing the filters, 2 line(s)'));
      expect(filtered, contains('# severity filter: FATAL, ERROR, WARN'));

      await ctl.search(const LogQuery('([', regex: true));
      expect(c.read(logViewerProvider).searchError, contains('Invalid regular expression'));
      expect(c.read(logViewerProvider).search, isNull);
    });
  });

  test('LogDocument.fromText counts bytes', () {
    final d = LogDocument.fromText('x', 'é\n');
    expect(d.fileBytes, Uint8List.fromList(utf8.encode('é\n')).length);
  });
}
