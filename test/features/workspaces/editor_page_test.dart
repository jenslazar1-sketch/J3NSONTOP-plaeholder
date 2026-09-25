import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/workspaces/presentation/editor/editor_page.dart';
import 'package:j3nsontop_multitool/features/workspaces/presentation/editor/editor_state.dart';
import 'package:j3nsontop_multitool/features/workspaces/presentation/shared/requests.dart';
import 'package:path/path.dart' as p;

import 'ws_test_utils.dart';

void main() {
  testWidgets('empty state offers opening a file', (tester) async {
    final h = await WsHarness.create(tester);
    await h.pump(tester, const TextEditorPage(), size: const Size(1280, 900));
    expect(find.text('No file open'), findsOneWidget);
    expect(find.text('Open file'), findsOneWidget);
  });

  testWidgets('opens a CRLF file from a request, edits and saves with backup, endings kept', (tester) async {
    final h = await WsHarness.create(tester);
    final w = await h.workspace(tester, files: {'game/config/settings.ini': '[Audio]\r\nvolume=80\r\n'});
    final path = p.join(w.rootPath, 'game', 'config', 'settings.ini');
    await h.pump(tester, const TextEditorPage(), size: const Size(1280, 1000));
    h.container.read(editorRequestProvider.notifier).open(path);
    await pumpUntil(tester, find.text('Endings: CRLF'));
    expect(find.text('UTF-8'), findsOneWidget);
    expect(find.text('SAVED'), findsOneWidget);
    expect(h.container.read(editorTextProvider).text, '[Audio]\nvolume=80\n');

    h.container.read(editorTextProvider).text = '[Audio]\nvolume=100\n';
    await tester.pump();
    expect(find.text('MODIFIED'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await pumpUntil(tester, find.text('SAVED'));
    expect(File(path).readAsStringSync(), '[Audio]\r\nvolume=100\r\n');
    final meta = h.container.read(workspacesProvider.notifier).metaDir(w);
    final backups = Directory(p.join(meta, 'backups')).listSync(recursive: true).whereType<File>().toList();
    expect(backups.single.readAsStringSync(), '[Audio]\r\nvolume=80\r\n');
  });

  testWidgets('find shows match count and steps through matches', (tester) async {
    final h = await WsHarness.create(tester);
    final w = await h.workspace(tester, files: {'log.txt': 'hp=1\nmana=2\nhp=3\n'});
    await h.pump(tester, const TextEditorPage(), size: const Size(1280, 1000));
    h.container.read(editorRequestProvider.notifier).open(p.join(w.rootPath, 'log.txt'));
    await pumpUntil(tester, find.text('SAVED'));
    await tester.tap(find.byTooltip('Find (Ctrl+F)'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Find'), 'HP');
    await pumpUntil(tester, find.text('1 / 2'));
    await tester.tap(find.byTooltip('Next match (Enter)'));
    await tester.pump();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(h.container.read(editorTextProvider).highlight, const TextRange(start: 12, end: 14));
    await tester.tap(find.text('Aa'));
    await tester.pump();
    expect(find.text('No matches'), findsOneWidget);
  });

  testWidgets('malformed bytes warn that saving changes bytes; binary files are refused', (tester) async {
    final h = await WsHarness.create(tester);
    final w = await h.workspace(
      tester,
      files: {
        'latin.txt': [0x63, 0x61, 0x66, 0xE9],
        'data.bin': [0, 1, 2, 3, 0, 0, 255],
      },
    );
    await h.pump(tester, const TextEditorPage(), size: const Size(1280, 1000));
    h.container.read(editorRequestProvider.notifier).open(p.join(w.rootPath, 'latin.txt'));
    await pumpUntil(tester, find.text('Latin-1 (fallback)'));
    expect(find.textContaining('changes bytes'), findsOneWidget);
    expect(h.container.read(editorTextProvider).text, 'café');

    h.container.read(editorRequestProvider.notifier).open(p.join(w.rootPath, 'data.bin'));
    await pumpUntil(tester, find.textContaining('This looks like a binary file'));
    await tester.tap(find.text('Open in Hex Viewer'));
    expect(h.routes.last, WsTools.route(WsTools.hex));
  });

  testWidgets('files over 2 MiB open read-only with line numbers', (tester) async {
    final h = await WsHarness.create(tester);
    final big = List.generate(120000, (i) => 'line $i ${'x' * 12}').join('\n');
    expect(utf8.encode(big).length, greaterThan(kEditableLimit));
    final w = await h.workspace(tester, files: {'big.log': big});
    await h.pump(tester, const TextEditorPage(), size: const Size(1280, 1000));
    h.container.read(editorRequestProvider.notifier).open(p.join(w.rootPath, 'big.log'), line: 5000);
    await pumpUntil(tester, find.text('READ-ONLY'));
    expect(find.textContaining('shown read-only'), findsOneWidget);
    await pumpUntil(tester, find.text('line 4999 xxxxxxxxxxxx'));
  });

  testWidgets('device copies explain that Save only works through Save as', (tester) async {
    final h = await WsHarness.create(tester);
    final device = File(p.join(h.env.paths.pickedDir, 'x', 'notes.txt'));
    await tester.runAsync(() async {
      await device.create(recursive: true);
      await device.writeAsString('abc');
    });
    await h.pump(tester, const TextEditorPage(), size: const Size(1280, 1000));
    h.container.read(editorRequestProvider.notifier).open(device.path);
    await pumpUntil(tester, find.textContaining('Device copy'));
    h.container.read(editorTextProvider).text = 'abcd';
    await tester.pump();
    await tester.tap(find.text('Save'));
    await pumpUntil(tester, find.text('This is a copy'));
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(device.readAsStringSync(), 'abc');
  });

  testWidgets('missing files show a readable error', (tester) async {
    final h = await WsHarness.create(tester);
    await h.pump(tester, const TextEditorPage(), size: const Size(1280, 1000));
    h.container.read(editorRequestProvider.notifier).open(p.join(h.env.dir.path, 'nope.txt'));
    await pumpUntil(tester, find.textContaining('ERROR //'));
    expect(find.textContaining('Not a file'), findsOneWidget);
  });

  testWidgets('phone layout: no overflow at 320x568 with 2x text', (tester) async {
    final h = await WsHarness.create(tester);
    final w = await h.workspace(tester, files: {'a.ini': 'a=1\r\nb=2\n'});
    await h.pump(tester, const TextEditorPage(), size: const Size(320, 568), textScale: 2);
    h.container.read(editorRequestProvider.notifier).open(p.join(w.rootPath, 'a.ini'));
    await pumpUntil(tester, find.text('SAVED'));
    await tester.ensureVisible(find.byTooltip('Find (Ctrl+F)'));
    await tester.tap(find.byTooltip('Find (Ctrl+F)'));
    await tester.pump();
    expect(find.textContaining('Mixed line endings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
