import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/widgets/widgets.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/workspaces/presentation/rename/batch_rename_page.dart';
import 'package:j3nsontop_multitool/features/workspaces/presentation/replace/replace_page.dart';
import 'package:path/path.dart' as p;

import 'ws_test_utils.dart';

void main() {
  group('Batch Rename', () {
    const files = <String, Object>{
      'IMG_0001.png': 'one',
      'IMG_0002.png': 'two',
      'IMG_0010.png': 'ten',
      'notes.txt': 'n',
    };

    testWidgets('requires a workspace', (tester) async {
      final h = await WsHarness.create(tester);
      await h.pump(tester, const BatchRenamePage(), size: const Size(1280, 900));
      expect(find.text('No active workspace'), findsOneWidget);
    });

    testWidgets('live preview, apply, journal and undo', (tester) async {
      final h = await WsHarness.create(tester);
      final w = await h.workspace(tester, files: files);
      await h.pump(tester, const BatchRenamePage(), size: const Size(1400, 1400));
      await pumpUntil(tester, find.text('IMG_0010.png'));
      await tester.enterText(find.widgetWithText(TextField, 'Only files matching (glob)'), '*.png');
      await tester.enterText(find.widgetWithText(TextField, 'Name template (optional)'), 'shot_{n:2}');
      await pumpUntil(tester, find.text('Apply 3 renames'));
      expect(find.text('shot_03.png'), findsOneWidget);
      expect(find.text('notes.txt'), findsNothing, reason: 'filtered out');
      await tester.tap(find.text('Apply 3 renames'));
      await pumpUntil(tester, find.text('Rename 3 files?'));
      await tester.tap(find.text('Rename'));
      await pumpUntil(tester, find.textContaining('Renamed 3 files'));
      expect(File(p.join(w.rootPath, 'shot_01.png')).readAsStringSync(), 'one');
      expect(File(p.join(w.rootPath, 'shot_03.png')).readAsStringSync(), 'ten');
      await pumpUntil(tester, find.text('APPLIED'));
      await tester.tap(find.byTooltip('Undo this rename'));
      await pumpUntil(tester, find.text('Undo this batch rename?'));
      await tester.tap(find.text('Undo rename'));
      await pumpUntil(tester, find.textContaining('Restored 3 files'));
      expect(File(p.join(w.rootPath, 'IMG_0010.png')).readAsStringSync(), 'ten');
      expect(find.text('UNDONE'), findsOneWidget);
    });

    testWidgets('collisions and invalid names disable Apply', (tester) async {
      final h = await WsHarness.create(tester);
      await h.workspace(tester, files: files);
      await h.pump(tester, const BatchRenamePage(), size: const Size(1400, 1400));
      await pumpUntil(tester, find.text('IMG_0010.png'));
      await tester.enterText(find.widgetWithText(TextField, 'Only files matching (glob)'), 'IMG_0001.png');
      await tester.enterText(find.widgetWithText(TextField, 'Name template (optional)'), 'IMG_0002');
      await pumpUntil(tester, find.text('Collision'));
      expect(find.textContaining('"IMG_0002.png" already exists'), findsOneWidget);
      final apply = tester.widget<NeonButton>(find.widgetWithText(NeonButton, 'Apply 1 rename'));
      expect(apply.onPressed, isNull);
      expect(find.textContaining('Apply is disabled'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Name template (optional)'), 'aux');
      await pumpUntil(tester, find.text('Invalid name'));
      await tester.enterText(find.widgetWithText(TextField, 'Name template (optional)'), '{bogus}');
      await pumpUntil(tester, find.textContaining('Unknown token {bogus}'));
    });

    testWidgets('phone layout: no overflow at 320x568 with 2x text', (tester) async {
      final h = await WsHarness.create(tester);
      await h.workspace(tester, files: files);
      await h.pump(tester, const BatchRenamePage(), size: const Size(320, 568), textScale: 2);
      await pumpUntil(tester, find.text('IMG_0010.png'));
      await tester.enterText(find.widgetWithText(TextField, 'Prefix'), 'x_');
      await pumpUntil(tester, find.text('x_IMG_0001.png'));
      expect(find.text('4 files will change'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Replace in Files', () {
    testWidgets('requires a workspace', (tester) async {
      final h = await WsHarness.create(tester);
      await h.pump(tester, const ReplacePage(), size: const Size(1280, 900));
      expect(find.text('No active workspace'), findsOneWidget);
    });

    testWidgets('preview then apply with backups; CRLF kept', (tester) async {
      final h = await WsHarness.create(tester);
      final w = await h.workspace(
        tester,
        files: {
          'game/config/settings.ini': '[Audio]\r\nvolume=80\r\nmusic=80\r\n',
          'game/data/items.csv': 'id,price\n1,80\n',
        },
      );
      await h.pump(tester, const ReplacePage(), size: const Size(1400, 1400));
      await tester.enterText(find.widgetWithText(TextField, 'Find'), '80');
      await tester.enterText(find.widgetWithText(TextField, 'Replace with'), '95');
      await tester.enterText(find.widgetWithText(TextField, 'Only files matching (glob, optional)'), '*.ini');
      await tester.tap(find.text('Preview changes'));
      await pumpUntil(tester, find.text('2 replacements in 1 file'));
      expect(find.text('-volume=80'), findsOneWidget);
      expect(find.text('+volume=95'), findsOneWidget);
      await tester.tap(find.text('Apply to 1 file (2)'));
      await pumpUntil(tester, find.text('Replace in 1 file?'));
      await tester.tap(find.text('Replace'));
      await pumpUntil(tester, find.textContaining('2 replacements in 1 file'));
      await pumpUntil(tester, find.text('Copy backup path'));
      expect(
        File(p.join(w.rootPath, 'game', 'config', 'settings.ini')).readAsBytesSync(),
        utf8.encode('[Audio]\r\nvolume=95\r\nmusic=95\r\n'),
      );
      expect(File(p.join(w.rootPath, 'game', 'data', 'items.csv')).readAsStringSync(), 'id,price\n1,80\n');
      final meta = h.container.read(workspacesProvider.notifier).metaDir(w);
      final backup = Directory(p.join(meta, 'backups')).listSync(recursive: true).whereType<File>().single;
      expect(backup.readAsStringSync(), '[Audio]\r\nvolume=80\r\nmusic=80\r\n');
    });

    testWidgets('deselected files are not changed; invalid regex is reported', (tester) async {
      final h = await WsHarness.create(tester);
      final w = await h.workspace(tester, files: {'a.txt': 'cat', 'b.txt': 'cat'});
      await h.pump(tester, const ReplacePage(), size: const Size(1400, 1400));
      await tester.tap(find.text('Regular expression'));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, 'Find (regular expression)'), '(c)at');
      await tester.enterText(find.widgetWithText(TextField, 'Replace with'), r'$1ow');
      await tester.tap(find.text('Preview changes'));
      await pumpUntil(tester, find.text('2 replacements in 2 files'));
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pump();
      await tester.tap(find.text('Apply to 1 file (1)'));
      await pumpUntil(tester, find.text('Replace in 1 file?'));
      await tester.tap(find.text('Replace'));
      await pumpUntil(tester, find.text('Copy backup path'));
      expect(File(p.join(w.rootPath, 'a.txt')).readAsStringSync(), 'cow');
      expect(File(p.join(w.rootPath, 'b.txt')).readAsStringSync(), 'cat');

      await tester.enterText(find.widgetWithText(TextField, 'Find (regular expression)'), '(c');
      await tester.tap(find.text('Preview changes'));
      await pumpUntil(tester, find.textContaining('Invalid regular expression'));
    });

    testWidgets('phone layout: no overflow at 320x568 with 2x text', (tester) async {
      final h = await WsHarness.create(tester);
      await h.workspace(tester, files: {'a.txt': 'cat\r\n'});
      await h.pump(tester, const ReplacePage(), size: const Size(320, 568), textScale: 2);
      await tester.enterText(find.widgetWithText(TextField, 'Find'), 'cat');
      await tester.enterText(find.widgetWithText(TextField, 'Replace with'), 'dog');
      await tapVisible(tester, find.text('Preview changes'));
      await pumpUntil(tester, find.text('1 replacement in 1 file'));
      expect(tester.takeException(), isNull);
    });
  });
}
