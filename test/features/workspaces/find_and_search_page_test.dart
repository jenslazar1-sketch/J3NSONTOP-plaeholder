import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/workspaces/presentation/find/find_files_page.dart';
import 'package:j3nsontop_multitool/features/workspaces/presentation/search/search_text_page.dart';
import 'package:j3nsontop_multitool/features/workspaces/presentation/shared/requests.dart';
import 'package:path/path.dart' as p;

import 'ws_test_utils.dart';

const _files = <String, Object>{
  'game/saves/slot1.json': '{"hp": 10}',
  'game/saves/save_auto.json': '{"hp": 25}',
  'game/config/settings.ini': '[Gameplay]\r\nmax_hp=100\r\nhp_regen=2\r\n',
  'game/sprites/hero.png': [0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0],
  'notes/unicode-名前-ünïcødé.txt': 'hp notes',
};

void main() {
  group('Find Files', () {
    testWidgets('requires a workspace', (tester) async {
      final h = await WsHarness.create(tester);
      await h.pump(tester, const FindFilesPage(), size: const Size(1280, 900));
      expect(find.text('No active workspace'), findsOneWidget);
    });

    testWidgets('glob search lists hits; tapping opens the editor', (tester) async {
      final h = await WsHarness.create(tester);
      final w = await h.workspace(tester, files: _files);
      await h.pump(tester, const FindFilesPage(), size: const Size(1400, 1000));
      await tester.enterText(find.widgetWithText(TextField, 'Pattern'), '**/save*.json');
      await tester.tap(find.text('Search'));
      await pumpUntil(tester, find.text('1 match'));
      expect(find.text('game/saves/save_auto.json'), findsOneWidget);
      await tester.tap(find.text('game/saves/save_auto.json'));
      expect(h.routes.last, WsTools.route(WsTools.editor));
      expect(h.container.read(editorRequestProvider)!.path, p.join(w.rootPath, 'game', 'saves', 'save_auto.json'));
    });

    testWidgets('invalid regex shows an error instead of searching', (tester) async {
      final h = await WsHarness.create(tester);
      await h.workspace(tester, files: _files);
      await h.pump(tester, const FindFilesPage(), size: const Size(1400, 1000));
      await tester.tap(find.text('Regex'));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, 'Pattern'), '([a-z');
      await tester.tap(find.text('Search'));
      await pumpUntil(tester, find.textContaining('Invalid regular expression'));
    });

    testWidgets('phone layout: no overflow at 320x568 with 2x text', (tester) async {
      final h = await WsHarness.create(tester);
      await h.workspace(tester, files: _files);
      await h.pump(tester, const FindFilesPage(), size: const Size(320, 568), textScale: 2);
      await tester.enterText(find.widgetWithText(TextField, 'Pattern'), '*名前*');
      await tapVisible(tester, find.text('Search'));
      await pumpUntil(tester, find.text('1 match'));
      expect(tester.takeException(), isNull);
    });
  });

  group('Search in Files', () {
    testWidgets('groups matches by file; tapping a line opens the editor at that line', (tester) async {
      final h = await WsHarness.create(tester);
      final w = await h.workspace(tester, files: _files);
      await h.pump(tester, const SearchTextPage(), size: const Size(1400, 1100));
      await tester.enterText(find.widgetWithText(TextField, 'Text'), 'hp');
      await tester.tap(find.text('Whole word'));
      await tester.pump();
      await tester.tap(find.text('Search'));
      await pumpUntil(tester, find.textContaining('matches in'));
      expect(find.text('3 matches in 3 files'), findsOneWidget);
      expect(find.text('game/saves/slot1.json'), findsOneWidget);
      expect(find.textContaining('Binary skipped: 1'), findsOneWidget);
      await tester.tap(find.text('notes/unicode-名前-ünïcødé.txt'));
      await tester.pump();
      expect(find.text('hp notes'), findsNothing, reason: 'group collapsed');
      await tester.tap(find.text('notes/unicode-名前-ünïcødé.txt'));
      await tester.pump();
      await tester.tap(find.text('hp notes'));
      expect(h.routes.last, WsTools.route(WsTools.editor));
      final req = h.container.read(editorRequestProvider)!;
      expect(req.path, p.join(w.rootPath, 'notes', 'unicode-名前-ünïcødé.txt'));
      expect(req.line, 1);
    });

    testWidgets('regex with glob filter; invalid regex is reported first', (tester) async {
      final h = await WsHarness.create(tester);
      await h.workspace(tester, files: _files);
      await h.pump(tester, const SearchTextPage(), size: const Size(1400, 1100));
      await tester.tap(find.text('Regular expression'));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, 'Regular expression'), r'hp\w*=(\d+');
      await tester.tap(find.text('Search'));
      await pumpUntil(tester, find.textContaining('Invalid regular expression'));
      await tester.enterText(find.widgetWithText(TextField, 'Regular expression'), r'hp\w*=(\d+)');
      await tester.enterText(find.widgetWithText(TextField, 'Only files matching (glob, optional)'), '*.ini');
      await tester.tap(find.text('Search'));
      await pumpUntil(tester, find.text('2 matches in 1 file'));
      expect(find.text('game/config/settings.ini'), findsOneWidget);
    });

    testWidgets('phone layout: no overflow at 320x568 with 2x text', (tester) async {
      final h = await WsHarness.create(tester);
      await h.workspace(tester, files: _files);
      await h.pump(tester, const SearchTextPage(), size: const Size(320, 568), textScale: 2);
      await tester.enterText(find.widgetWithText(TextField, 'Text'), 'hp');
      await tapVisible(tester, find.text('Search'));
      await pumpUntil(tester, find.textContaining('matches in'));
      expect(tester.takeException(), isNull);
    });
  });
}
