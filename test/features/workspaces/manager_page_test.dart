import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/archive/safe_zip.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/platform/file_access.dart';
import 'package:j3nsontop_multitool/core/widgets/widgets.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/workspaces/presentation/manager/manager_view.dart';
import 'package:path/path.dart' as p;

import '../../helpers/raw_zip.dart';
import 'ws_test_utils.dart';

void main() {
  testWidgets('landing lists workspaces with kind, health, active marker and tools', (tester) async {
    final h = await WsHarness.create(tester);
    await h.workspace(tester, name: 'Alpha', files: {'a.txt': 'A'});
    await h.pump(tester, const WorkspacesLandingPage(), size: const Size(1280, 1000));
    await pumpUntil(tester, find.text('REACHABLE'));
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('ACTIVE'), findsOneWidget);
    expect(find.text('IMPORTED COPY'), findsOneWidget);
    expect(find.text(WorkspaceKindLabels.importedExplanation), findsOneWidget);
    // Section tools are listed below the cards.
    await tester.scrollUntilVisible(find.text('Batch Rename'), 300);
    expect(find.text('Replace in Files'), findsOneWidget);
  });

  testWidgets('new empty workspace via the name dialog becomes active', (tester) async {
    final h = await WsHarness.create(tester);
    await h.pump(tester, const WorkspaceManagerPage(), size: const Size(1280, 1000));
    expect(find.text('Nothing here yet'), findsOneWidget);
    await tapVisible(tester, find.text('New empty workspace'));
    await tester.enterText(find.byType(TextField).last, 'Mod Project');
    await tester.tap(find.text('OK'));
    await pumpUntil(tester, find.text('Mod Project'));
    final ws = h.container.read(workspacesProvider);
    expect(ws.active?.name, 'Mod Project');
    expect(find.text('ACTIVE'), findsOneWidget);
  });

  testWidgets('empty name is rejected in the dialog', (tester) async {
    final h = await WsHarness.create(tester);
    await h.pump(tester, const WorkspaceManagerPage(), size: const Size(1280, 1000));
    await tapVisible(tester, find.text('New empty workspace'));
    await tester.enterText(find.byType(TextField).last, '   ');
    await tester.tap(find.text('OK'));
    await tester.pump();
    expect(find.text('Enter a name'), findsOneWidget);
    expect(h.container.read(workspacesProvider).workspaces, isEmpty);
  });

  testWidgets('missing folder shows health problem with recovery actions', (tester) async {
    final h = await WsHarness.create(tester);
    final w = await h.workspace(tester, name: 'Gone');
    await tester.runAsync(() => Directory(w.rootPath).delete(recursive: true));
    await h.pump(tester, const WorkspaceManagerPage(), size: const Size(1280, 1000));
    await pumpUntil(tester, find.text('FOLDER MISSING'));
    expect(find.textContaining('imported copy was deleted'), findsOneWidget);
    await tapVisible(tester, find.text('Recreate folder'));
    await pumpUntil(tester, find.text('REACHABLE'));
    expect(Directory(w.rootPath).existsSync(), isTrue);
  });

  testWidgets('remove app-owned keeps files unless the explicit option is checked', (tester) async {
    final h = await WsHarness.create(tester);
    final w = await h.workspace(tester, name: 'Keep me', files: {'x/y.txt': 'hello'});
    await h.pump(tester, const WorkspaceManagerPage(), size: const Size(1280, 1000));
    await pumpUntil(tester, find.text('REACHABLE'));
    await tapVisible(tester, find.text('Remove'));
    await pumpUntil(tester, find.textContaining('1 file, 5 B'));
    final box = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(box.value, isFalse, reason: 'deleting files is opt-in');
    await tester.tap(find.text('Remove record'));
    await pumpUntil(tester, find.text('Nothing here yet'));
    expect(File(p.join(w.rootPath, 'x', 'y.txt')).existsSync(), isTrue);
  });

  testWidgets('import ZIP previews issues and refuses hostile archives', (tester) async {
    final h = await WsHarness.create(tester);
    final zip = writeRawZip(h.env.dir, 'evil.zip', [RawZipEntry('../../evil.txt', utf8.encode('x'))]);
    h.files.queuedPicks.add([PickedLocalFile(name: 'evil.zip', path: zip, size: File(zip).lengthSync())]);
    await h.pump(tester, const WorkspaceManagerPage(), size: const Size(1280, 1000));
    await tapVisible(tester, find.text('Import ZIP'));
    await pumpUntil(tester, find.textContaining('Archive rejected'));
    expect(find.textContaining('parent-directory traversal'), findsWidgets);
    final extract = tester.widget<NeonButton>(find.widgetWithText(NeonButton, 'New workspace'));
    expect(extract.onPressed, isNull, reason: 'extraction is impossible while fatal issues exist');
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(h.container.read(workspacesProvider).workspaces, isEmpty);
    expect(File(p.join(h.env.dir.parent.path, 'evil.txt')).existsSync(), isFalse);
  });

  testWidgets('import ZIP into a new workspace extracts files', (tester) async {
    final h = await WsHarness.create(tester);
    final zip = writeRawZip(h.env.dir, 'mods.zip', [
      RawZipEntry('data/', []),
      RawZipEntry('data/items.csv', utf8.encode('id,name\n1,potion\n'), deflate: true),
    ]);
    h.files.queuedPicks.add([PickedLocalFile(name: 'mods.zip', path: zip, size: File(zip).lengthSync())]);
    await h.pump(tester, const WorkspaceManagerPage(), size: const Size(1280, 1000));
    await tapVisible(tester, find.text('Import ZIP'));
    await pumpUntil(tester, find.textContaining('Safe to extract'));
    await tester.tap(find.text('New workspace'));
    await pumpUntil(tester, find.text('Name the new workspace'));
    await tester.tap(find.text('OK'));
    await pumpUntil(tester, find.textContaining('Extracted 1 file'));
    final w = h.container.read(workspacesProvider).active!;
    expect(w.name, 'mods');
    expect(File(p.join(w.rootPath, 'data', 'items.csv')).readAsStringSync(), contains('potion'));
  });

  testWidgets('link a folder, then removing the record leaves the folder untouched', (tester) async {
    final h = await WsHarness.create(tester);
    final folder = Directory(p.join(h.env.dir.path, 'my game'));
    await tester.runAsync(() async {
      await File(p.join(folder.path, 'game.json')).create(recursive: true);
    });
    h.files.queuedDirectory = folder.path;
    await h.pump(tester, const WorkspaceManagerPage(), size: const Size(1280, 1000));
    await tapVisible(tester, find.text('Link folder'));
    await pumpUntil(tester, find.text('OK'));
    await tester.tap(find.text('OK'));
    await pumpUntil(tester, find.text('LINKED FOLDER'));
    expect(h.container.read(workspacesProvider).active!.rootPath, folder.path);
    await tapVisible(tester, find.text('Remove'));
    await pumpUntil(tester, find.text('Remove linked workspace?'));
    expect(find.textContaining('NOT deleted'), findsOneWidget);
    await tester.tap(find.text('Remove record'));
    await pumpUntil(tester, find.text('Nothing here yet'));
    expect(File(p.join(folder.path, 'game.json')).existsSync(), isTrue);
  });

  testWidgets('import files into the active workspace never overwrites', (tester) async {
    final h = await WsHarness.create(tester);
    final w = await h.workspace(tester, name: 'Target', files: {'notes.txt': 'mine'});
    final picked = File(p.join(h.env.dir.path, 'device', 'notes.txt'));
    await tester.runAsync(() async {
      await picked.create(recursive: true);
      await picked.writeAsString('theirs');
    });
    h.files.queuedPicks.add([PickedLocalFile(name: 'notes.txt', path: picked.path, size: 6)]);
    await h.pump(tester, const WorkspaceManagerPage(), size: const Size(1280, 1000));
    await tapVisible(tester, find.text('Import files'));
    await pumpUntil(tester, find.text('Active workspace "Target"'));
    await tester.pump(const Duration(milliseconds: 600)); // sheet slide-in
    await tester.tap(find.text('Active workspace "Target"'));
    await pumpUntil(tester, find.textContaining('Imported 1 file'));
    expect(File(p.join(w.rootPath, 'notes.txt')).readAsStringSync(), 'mine');
    expect(File(p.join(w.rootPath, 'notes (2).txt')).readAsStringSync(), 'theirs');
    expect(find.textContaining('imported as notes (2).txt'), findsOneWidget);
  });

  testWidgets('export workspace as ZIP hands a valid archive to the save dialog', (tester) async {
    final h = await WsHarness.create(tester);
    await h.workspace(tester, name: 'Exp', files: {'a/b.txt': 'B', 'c.json': '{}'});
    await h.pump(tester, const WorkspaceManagerPage(), size: const Size(1280, 1000));
    await pumpUntil(tester, find.text('REACHABLE'));
    await tapVisible(tester, find.text('Export ZIP'));
    await pumpUntil(tester, find.text('Export...'));
    await tester.pump(const Duration(milliseconds: 600)); // sheet slide-in
    await tester.tap(find.text('Export...'));
    await pumpUntil(tester, find.textContaining('Exported 2 files'));
    final (name, bytes) = h.files.savedBytes.single;
    expect(name, 'Exp.zip');
    expect(bytes.take(2), [0x50, 0x4B]);
    final zip = File(p.join(h.env.dir.path, 'check.zip'));
    await tester.runAsync(() => zip.writeAsBytes(bytes));
    expect(SafeZip.inspect(zip.path).files.map((e) => e.path).toSet(), {'a/b.txt', 'c.json'});
  });

  testWidgets('sample workspace errors are shown, not swallowed', (tester) async {
    final h = await WsHarness.create(tester);
    await h.pump(tester, const WorkspaceManagerPage(), size: const Size(1280, 1000));
    await tapVisible(tester, find.text('Create sample workspace'));
    await settle(tester, rounds: 20);
    // Either the sample feature exists (success banner) or the failure is
    // explained inline - never swallowed.
    final ok = find.textContaining('Sample workspace "').evaluate().isNotEmpty;
    final explained = find.textContaining('ERROR //').evaluate().isNotEmpty;
    expect(ok || explained, isTrue);
  });

  testWidgets('mobile shows the link-folder alternative instead of the button', (tester) async {
    final h = await WsHarness.create(tester, platform: AppPlatform.android);
    await h.pump(tester, const WorkspaceManagerPage(), size: const Size(400, 900));
    expect(find.text('Link folder'), findsNothing);
    expect(find.text('Import folder'), findsNothing);
    expect(find.textContaining('Mobile systems do not allow direct access'), findsOneWidget);
  });

  testWidgets('no overflow at 320x568 with 2x text', (tester) async {
    final h = await WsHarness.create(tester);
    await h.workspace(tester, name: 'A very long workspace name that must ellipsize nicely on phones');
    await h.pump(tester, const WorkspacesLandingPage(), size: const Size(320, 568), textScale: 2);
    await pumpUntil(tester, find.text('REACHABLE'));
    await tester.scrollUntilVisible(find.text('Workspace tools'), 400);
    expect(tester.takeException(), isNull);
  });
}

abstract final class WorkspaceKindLabels {
  static const importedExplanation = 'Files were copied into app storage. Export to get results out.';
}
