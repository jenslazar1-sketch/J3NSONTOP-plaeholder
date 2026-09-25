import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/activity/activity_controller.dart';
import 'package:j3nsontop_multitool/core/platform/file_access.dart';
import 'package:j3nsontop_multitool/features/dev_tools/presentation/regex_controller.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/harness.dart';
import '../dev_test_utils.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  group('Regex tester', () {
    Future<void> settleRegex(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 350)); // live debounce
      final c = containerOf(tester);
      await pumpUntil(tester, () => !c.read(regexToolProvider).running);
    }

    testWidgets('renders with the example library', (tester) async {
      await pumpDevTool(tester, env, 'dev.regex');
      expect(find.text('Enter a pattern'), findsOneWidget);
      expect(find.byTooltip('Example patterns'), findsOneWidget);
      expect(find.text('i  Ignore case'), findsOneWidget);
    });

    testWidgets('live matching highlights matches with markers and lists groups', (tester) async {
      await pumpDevTool(tester, env, 'dev.regex');
      await enter(tester, 'dev.regex.pattern', r'(?<key>\w+)=(\d+)');
      await enter(tester, 'dev.regex.text', 'a=1, bb=22, c=x');
      await settleRegex(tester);
      expect(find.textContaining('2 matches in'), findsOneWidget);
      expect(find.textContaining('«a=1», «bb=22», c=x'), findsOneWidget);
      expect(find.text('Match #1 at 0-3'), findsOneWidget);
      expect(find.text(r'$1 <key>'), findsOneWidget);
      await tapVisible(tester, find.text('#2'));
      expect(find.text('Match #2 at 5-10'), findsOneWidget);
      expect(find.text('22'), findsWidgets);
    });

    testWidgets('replace preview with named groups', (tester) async {
      await pumpDevTool(tester, env, 'dev.regex');
      await enter(tester, 'dev.regex.pattern', r'(?<key>\w+)=(\d+)');
      await enter(tester, 'dev.regex.text', 'a=1, bb=22');
      await tapVisible(tester, find.text('Replace preview'));
      await enter(tester, 'dev.regex.replacement', r'${key}:$2');
      await settleRegex(tester);
      expect(find.text('a:1, bb:22'), findsOneWidget);
    });

    testWidgets('example library fills pattern and sample', (tester) async {
      await pumpDevTool(tester, env, 'dev.regex');
      await tester.tap(find.byTooltip('Example patterns'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('IPv4 address'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // menu closes; the run is busy (spinner)
      await settleRegex(tester);
      expect(find.textContaining('2 matches in'), findsOneWidget);
      expect(find.textContaining('«192.168.1.23»'), findsOneWidget);
    });

    testWidgets('invalid patterns show the engine message', (tester) async {
      await pumpDevTool(tester, env, 'dev.regex');
      await enter(tester, 'dev.regex.pattern', '(unclosed');
      await enter(tester, 'dev.regex.text', 'x');
      await settleRegex(tester);
      expect(find.textContaining('Invalid pattern: Unterminated group'), findsOneWidget);
    });

    testWidgets('catastrophic backtracking stops at the time limit', (tester) async {
      await pumpDevTool(tester, env, 'dev.regex');
      await enter(tester, 'dev.regex.pattern', r'^(a+)+$');
      await enter(tester, 'dev.regex.text', '${'a' * 40}!');
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const Key('dev.regex.cancel')), findsOneWidget);
      final c = containerOf(tester);
      await pumpUntil(tester, () => !c.read(regexToolProvider).running);
      expect(find.text(RegexToolController.timeLimitMessage), findsOneWidget);
    });

    testWidgets('cancel stops a running match', (tester) async {
      await pumpDevTool(tester, env, 'dev.regex');
      await tapVisible(tester, find.text('Live matching'));
      await enter(tester, 'dev.regex.pattern', r'^(a+)+$');
      await enter(tester, 'dev.regex.text', '${'a' * 40}!');
      await tapVisible(tester, find.byKey(const Key('dev.regex.run')));
      await tester.tap(find.byKey(const Key('dev.regex.cancel')));
      final c = containerOf(tester);
      await pumpUntil(tester, () => !c.read(regexToolProvider).running);
      expect(find.textContaining('Cancelled after'), findsOneWidget);
    });

    testWidgets('fits a small phone at 2x text', (tester) async {
      await pumpDevTool(tester, env, 'dev.regex', size: smallPhone, textScale: 2);
      await enter(tester, 'dev.regex.pattern', r'\d+');
      await enter(tester, 'dev.regex.text', 'a1 b22');
      await settleRegex(tester);
      expect(find.textContaining('2 matches in'), findsOneWidget);
    });
  });

  group('Text diff', () {
    testWidgets('renders an empty state', (tester) async {
      await pumpDevTool(tester, env, 'dev.diff');
      expect(find.text('Paste or open two texts'), findsOneWidget);
    });

    testWidgets('compares live with stats, views and copy', (tester) async {
      final files = FakeFileAccess();
      await pumpDevTool(tester, env, 'dev.diff', files: files);
      await enter(tester, 'dev.diff.a', 'alpha\nbeta\ngamma');
      await enter(tester, 'dev.diff.b', 'alpha\nBETA\ngamma\ndelta');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('+2 added'), findsOneWidget);
      expect(find.text('-1 removed'), findsOneWidget);
      expect(find.text('=2 same'), findsOneWidget);
      expect(find.text('delta'), findsOneWidget);
      expect(find.text('+'), findsWidgets);

      await tapVisible(tester, find.text('Side by side'));
      await tester.pump();
      expect(find.textContaining('beta', findRichText: true), findsWidgets);

      await tapVisible(tester, find.byTooltip('Copy unified diff'));
      expect(files.copied.single, contains('--- a\n+++ b\n@@'));
      expect(files.copied.single, contains('-beta\n+BETA\n'));
    });

    testWidgets('ignore case makes texts identical', (tester) async {
      await pumpDevTool(tester, env, 'dev.diff');
      await enter(tester, 'dev.diff.a', 'Hello');
      await enter(tester, 'dev.diff.b', 'hello');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('-1 removed'), findsOneWidget);
      await tapVisible(tester, find.text('Ignore case'));
      await tester.pump();
      expect(find.text('IDENTICAL'), findsOneWidget);
    });

    testWidgets('opens files and refuses binary input', (tester) async {
      final files = FakeFileAccess();
      final txt = p.join(env.dir.path, 'old.txt');
      File(txt).writeAsStringSync('one\ntwo\n');
      final bin = p.join(env.dir.path, 'blob.bin');
      File(bin).writeAsBytesSync([0, 1, 2, 3, 0, 0]);
      files.queuedPicks
        ..add([PickedLocalFile(name: 'old.txt', path: txt, size: 8)])
        ..add([PickedLocalFile(name: 'blob.bin', path: bin, size: 6)]);
      final c = await pumpDevTool(tester, env, 'dev.diff', files: files);
      await tapVisible(tester, find.byTooltip('Open file for the left side'));
      await pumpUntil(tester, () => find.text('LEFT (old): old.txt').evaluate().isNotEmpty);
      await tapVisible(tester, find.byTooltip('Open file for the right side'));
      String notices() => c.read(activityProvider).notices.map((n) => n.message).join('\n');
      await pumpUntil(tester, () => notices().contains('binary'));
      expect(notices(), contains('blob.bin looks like a binary file'));
    });

    testWidgets('fits a small phone at 2x text', (tester) async {
      await pumpDevTool(tester, env, 'dev.diff', size: smallPhone, textScale: 2);
      await enter(tester, 'dev.diff.a', 'a\nb');
      await enter(tester, 'dev.diff.b', 'a\nc');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('+1 added'), findsOneWidget);
      await tapVisible(tester, find.text('Side by side'));
      await tester.pump();
    });
  });
}
