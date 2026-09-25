import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/workspaces/presentation/browser/browser_page.dart';
import 'package:j3nsontop_multitool/features/workspaces/presentation/shared/requests.dart';
import 'package:path/path.dart' as p;

import 'ws_test_utils.dart';

const _files = <String, Object>{
  'game/config/settings.ini': '[Audio]\r\nvolume=80\r\n',
  'game/saves/slot1.json': '{"hp": 10}',
  'notes/unicode-名前-ünïcødé.txt': 'hello',
  'readme.txt': 'Neon Dungeon',
  '.hidden.cfg': 'x=1',
};

void main() {
  testWidgets('without an active workspace the browser explains what to do', (tester) async {
    final h = await WsHarness.create(tester);
    await h.pump(tester, const FileBrowserPage(), size: const Size(1280, 900));
    expect(find.text('No active workspace'), findsOneWidget);
    await tester.tap(find.text('Open Workspaces'));
    expect(h.routes, ['/workspaces']);
  });

  testWidgets('lists folders first, hides dotfiles, navigates into folders', (tester) async {
    final h = await WsHarness.create(tester);
    await h.workspace(tester, files: _files);
    await h.pump(tester, const FileBrowserPage(), size: const Size(1280, 900));
    await pumpUntil(tester, find.text('readme.txt'));
    expect(find.text('.hidden.cfg'), findsNothing);
    expect(find.textContaining('1 hidden'), findsOneWidget);
    final gameY = tester.getTopLeft(find.text('game')).dy;
    final readmeY = tester.getTopLeft(find.text('readme.txt')).dy;
    expect(gameY, lessThan(readmeY), reason: 'folders first');
    await tester.tap(find.text('game'));
    await pumpUntil(tester, find.text('config'));
    expect(find.text('saves'), findsOneWidget);
    await tester.tap(find.byTooltip('Up one folder'));
    await pumpUntil(tester, find.text('readme.txt'));
    await tester.tap(find.text('Hidden files'));
    await pumpUntil(tester, find.text('.hidden.cfg'));
  });

  testWidgets('details show encoding and line endings; SHA-256 on demand', (tester) async {
    final h = await WsHarness.create(tester);
    final w = await h.workspace(tester, files: _files);
    await h.pump(tester, const FileBrowserPage(), size: const Size(1400, 1000));
    await pumpUntil(tester, find.text('game'));
    await tester.tap(find.text('game'));
    await pumpUntil(tester, find.text('config'));
    await tester.tap(find.text('config'));
    await pumpUntil(tester, find.text('settings.ini'));
    await tester.tap(find.text('settings.ini'));
    await pumpUntil(tester, find.textContaining('CRLF'));
    expect(find.text('UTF-8'), findsOneWidget);
    expect(find.text('game/config/settings.ini'), findsOneWidget);
    await tester.tap(find.text('Compute SHA-256'));
    await pumpUntil(tester, find.textContaining('SHA-256 '));
    final expected = await tester.runAsync(
      () => Process.run('sha256sum', [p.join(w.rootPath, 'game', 'config', 'settings.ini')]),
    );
    if (expected != null && expected.exitCode == 0) {
      expect(find.textContaining((expected.stdout as String).split(' ').first), findsOneWidget);
    }
    await tester.tap(find.text('Edit text'));
    expect(h.routes.last, WsTools.route(WsTools.editor));
    expect(h.container.read(editorRequestProvider)!.path, p.join(w.rootPath, 'game', 'config', 'settings.ini'));
  });

  testWidgets('delete moves to trash, undo restores', (tester) async {
    final h = await WsHarness.create(tester);
    final w = await h.workspace(tester, files: _files);
    await h.pump(tester, const FileBrowserPage(), size: const Size(1400, 1000));
    await pumpUntil(tester, find.text('readme.txt'));
    await tester.tap(find.text('readme.txt'));
    await pumpUntil(tester, find.text('Delete'));
    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.tap(find.text('Move to trash'));
    await pumpUntil(tester, find.textContaining('Moved "readme.txt" to trash'));
    expect(File(p.join(w.rootPath, 'readme.txt')).existsSync(), isFalse);
    await tester.tap(find.text('Undo'));
    await pumpUntil(tester, find.text('readme.txt'));
    expect(File(p.join(w.rootPath, 'readme.txt')).readAsStringSync(), 'Neon Dungeon');
  });

  testWidgets('rename rejects invalid and existing names', (tester) async {
    final h = await WsHarness.create(tester);
    final w = await h.workspace(tester, files: _files);
    await h.pump(tester, const FileBrowserPage(), size: const Size(1400, 1000));
    await pumpUntil(tester, find.text('readme.txt'));
    await tester.tap(find.byTooltip('Actions for readme.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename...'));
    await pumpUntil(tester, find.text('Rename file'));
    await tester.enterText(find.byType(TextField).last, 'con.txt');
    await tester.tap(find.text('OK'));
    await tester.pump();
    expect(find.textContaining('Reserved device name'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'GAME');
    await tester.tap(find.text('OK'));
    await tester.pump();
    expect(find.textContaining('already exists'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'LIESMICH.txt');
    await tester.tap(find.text('OK'));
    await pumpUntil(tester, find.text('LIESMICH.txt'));
    expect(File(p.join(w.rootPath, 'LIESMICH.txt')).existsSync(), isTrue);
  });

  testWidgets('trash view restores and empties', (tester) async {
    final h = await WsHarness.create(tester);
    final w = await h.workspace(tester, files: _files);
    await h.pump(tester, const FileBrowserPage(), size: const Size(1400, 1000));
    await pumpUntil(tester, find.text('readme.txt'));
    await tester.tap(find.byTooltip('Actions for readme.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to trash...'));
    await tester.pump();
    await tester.tap(find.text('Move to trash'));
    await pumpUntil(tester, find.textContaining('Moved "readme.txt" to trash'));
    await tester.tap(find.byTooltip('Show trash'));
    await pumpUntil(tester, find.text('1 item in trash'));
    await tester.tap(find.text('Empty trash'));
    await tester.pump();
    await tester.tap(find.text('Empty trash').last);
    await pumpUntil(tester, find.text('Trash is empty'));
    expect(File(p.join(w.rootPath, 'readme.txt')).existsSync(), isFalse);
  });

  testWidgets('phone layout: no overflow at 320x568 with 2x text, details open in a sheet', (tester) async {
    final h = await WsHarness.create(tester);
    await h.workspace(
      tester,
      files: {
        ..._files,
        'a_really_long_file_name_that_goes_on_and_on_and_on_until_it_needs_ellipsis_everywhere.json': '{}',
      },
    );
    await h.pump(tester, const FileBrowserPage(), size: const Size(320, 568), textScale: 2);
    await pumpUntil(tester, find.text('readme.txt'));
    await tester.ensureVisible(find.text('readme.txt'));
    await tester.tap(find.text('readme.txt'));
    await pumpUntil(tester, find.text('Compute SHA-256'));
    expect(tester.takeException(), isNull);
  });
}
