import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/drafts/drafts.dart';
import 'package:j3nsontop_multitool/core/platform/file_access.dart';
import 'package:j3nsontop_multitool/features/file_tools/domain/log_model.dart';
import 'package:j3nsontop_multitool/features/file_tools/presentation/logs/log_controller.dart';
import 'package:j3nsontop_multitool/features/file_tools/presentation/logs/log_viewer_page.dart';
import 'package:path/path.dart' as p;

import 'ft_harness.dart';

String sampleLog(int n) => [
  for (var i = 0; i < n; i++)
    switch (i % 5) {
      0 => '2026-09-01 12:00:${(i % 60).toString().padLeft(2, '0')} INFO tick $i',
      1 => '2026-09-01 12:00:00 DEBUG frame $i',
      2 => '2026-09-01 12:00:00 WARN slow frame $i',
      3 => '2026-09-01 12:00:00 ERROR texture missing id=$i',
      _ => '    at Renderer.draw(renderer.dart:$i)',
    },
].join('\r\n');

void main() {
  late FtHarness h;
  setUp(() async => h = await FtHarness.create());
  tearDown(() async => h.dispose());

  LogViewerState st() => h.container.read(logViewerProvider);

  Future<void> openThroughPicker(WidgetTester tester, File f) async {
    h.files.queuedPicks.add([PickedLocalFile(name: p.basename(f.path), path: f.path, size: f.lengthSync())]);
    await tapVisible(tester, find.byKey(const Key('logs.open')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('From device'));
    await tester.pump();
    await waitFor(tester, () => st().doc != null || st().loadError != null);
  }

  testWidgets('opens a log, shows severity chips with counts and virtualised lines', (tester) async {
    final f = File(p.join(h.env.dir.path, 'game.log'))..writeAsStringSync(sampleLog(1000));
    await pumpPage(tester, h, const LogViewerPage());
    expect(find.text('No log loaded'), findsOneWidget);
    await openThroughPicker(tester, f);
    expect(st().doc!.lines, hasLength(1000));
    expect(find.text('ERROR 400'), findsOneWidget, reason: '200 errors + 200 stack lines that inherit');
    expect(find.text('WARN 200'), findsOneWidget);
    expect(find.textContaining('CRLF'), findsOneWidget);
    // Only a window of rows is built.
    expect(find.textContaining('tick 0'), findsOneWidget);
    expect(find.textContaining('tick 995'), findsNothing);
    // Filter chips toggle levels.
    await tapVisible(tester, find.byKey(const Key('logs.sev.debug')));
    expect(st().visible, hasLength(800));
    await tapVisible(tester, find.text('Errors only'));
    expect(st().visible, hasLength(400));
    expect(find.text('400 of 1000 lines shown'), findsOneWidget);
  });

  testWidgets('regex search, next match jump, selection, copy and export with header', (tester) async {
    await pumpPage(tester, h, const LogViewerPage());
    h.container.read(logViewerProvider.notifier).setDocument(LogDocument.fromText('logs/game.log', sampleLog(500)));
    await tester.pump();
    h.container.read(draftValueProvider('files.logs/regex').notifier).set(true);
    await tester.enterText(find.byKey(const Key('logs.query')), r'id=4\d3$');
    await tapVisible(tester, find.byKey(const Key('logs.search')));
    await waitFor(tester, () => st().search != null && !st().searching);
    expect(st().search!.matches, [for (var i = 403; i <= 493; i += 10) i]);
    final count = st().visibleMatches.length;
    expect(count, 10);
    expect(find.textContaining('$count matching line(s)'), findsOneWidget);
    // Jump to the next match: the row is built and marked current.
    await tapVisible(tester, find.byKey(const Key('logs.next')));
    await tester.pump();
    final current = st().currentMatch!;
    expect(find.textContaining(st().doc!.lines[current].substring(20)), findsWidgets);

    await tapVisible(tester, find.byKey(const Key('logs.selectMatches')));
    expect(st().selected, hasLength(10));
    await tapVisible(tester, find.byKey(const Key('logs.copy')));
    expect(h.files.copied.single.split('\n'), hasLength(10));

    await tapVisible(tester, find.byKey(const Key('logs.exportSelected')));
    await chooseExport(tester);
    final (name, bytes) = h.files.savedBytes.single;
    expect(name, 'game-selection.log');
    final text = utf8.decode(bytes);
    expect(text, startsWith('# J3NSONTOP log export\n# source: logs/game.log'));
    expect(text, contains('# search: /id=4\\d3\$/ (regex, ignore case)'));
    expect(text, contains('# line ranges (original numbering): 404, 414, 424, 434, 444, 454, 464, 474, 484, 494'));
    expect(text.trim().split('\n').where((l) => !l.startsWith('#')), hasLength(10));
  });

  testWidgets('click and shift-click select ranges; checkbox mode toggles', (tester) async {
    await pumpPage(tester, h, const LogViewerPage());
    h.container.read(logViewerProvider.notifier).setDocument(LogDocument.fromText('x.log', sampleLog(30)));
    await tester.pump();
    await tester.ensureVisible(find.textContaining('tick 0'));
    await tester.tap(find.textContaining('tick 0'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.textContaining('tick 5'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(st().selected, {0, 1, 2, 3, 4, 5});
    await tapVisible(tester, find.byKey(const Key('logs.checkboxes')));
    await tester.tap(find.textContaining('frame 7').first);
    await tester.pump();
    expect(st().selected, {0, 1, 2, 3, 4, 5, 7});
    expect(find.byType(Checkbox), findsWidgets);
  });

  testWidgets('invalid regex shows an inline error', (tester) async {
    await pumpPage(tester, h, const LogViewerPage());
    h.container.read(logViewerProvider.notifier).setDocument(LogDocument.fromText('x.log', sampleLog(10)));
    h.container.read(draftValueProvider('files.logs/regex').notifier).set(true);
    await tester.pump();
    await tester.enterText(find.byKey(const Key('logs.query')), '(unclosed');
    await tapVisible(tester, find.byKey(const Key('logs.search')));
    await tester.pump();
    expect(find.textContaining('Invalid regular expression'), findsOneWidget);
  });

  testWidgets('huge log is truncated with a visible notice', (tester) async {
    final f = File(p.join(h.env.dir.path, 'big.log'));
    await tester.runAsync(() async {
      final sink = f.openWrite();
      for (var i = 0; i < kMaxLogLines + 50; i++) {
        sink.write('l$i\n');
      }
      await sink.close();
    });
    await pumpPage(tester, h, const LogViewerPage());
    await openThroughPicker(tester, f);
    expect(st().doc!.lines, hasLength(kMaxLogLines));
    expect(st().doc!.truncatedByLines, isTrue);
    expect(find.byKey(const Key('logs.truncated')), findsOneWidget);
  });

  testWidgets('fits 320x568 at 2x text with a log open (wrap on and off)', (tester) async {
    await pumpPage(tester, h, const LogViewerPage(), size: const Size(320, 568), textScale: 2);
    expect(tester.takeException(), isNull);
    h.container
        .read(logViewerProvider.notifier)
        .setDocument(LogDocument.fromText('x.log', '${sampleLog(40)}\n${'very long line ' * 200}'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    h.container.read(draftValueProvider('files.logs/wrap').notifier).set(true);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
