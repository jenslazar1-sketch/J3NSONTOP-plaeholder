import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/archive/safe_zip.dart';
import 'package:j3nsontop_multitool/core/drafts/drafts.dart';
import 'package:j3nsontop_multitool/core/platform/file_access.dart';
import 'package:j3nsontop_multitool/core/widgets/widgets.dart';
import 'package:j3nsontop_multitool/features/file_tools/domain/zip_studio.dart';
import 'package:j3nsontop_multitool/features/file_tools/presentation/shared.dart';
import 'package:j3nsontop_multitool/features/file_tools/presentation/zip/zip_controller.dart';
import 'package:j3nsontop_multitool/features/file_tools/presentation/zip/zip_page.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/raw_zip.dart';
import 'ft_harness.dart';

void main() {
  late FtHarness h;
  setUp(() async => h = await FtHarness.create());
  tearDown(() async => h.dispose());

  void extractMode() => h.container.read(draftValueProvider('files.zip/mode').notifier).set(ZipMode.extract);

  testWidgets('create: entries preview, then archive written into the workspace', (tester) async {
    h.write('mods/neon-hud/hud.json', utf8.encode('{"color":"#FF163B"}'));
    h.write('mods/neon-hud/readme.txt', utf8.encode('hi'));
    await pumpPage(tester, h, const ZipPage());
    expect(find.text('Add files or folders'), findsOneWidget);
    final (entries, _) = await tester.runAsync(
      () => zipEntriesForFolder(p.join(h.root, 'mods', 'neon-hud'), origin: 'workspace'),
    ) as (List<ZipPlanEntry>, dynamic);
    h.container.read(zipCreateProvider.notifier).addEntries(entries);
    await tester.pump();
    expect(find.text('neon-hud/hud.json'), findsOneWidget);
    expect(find.text('2 entries · 21 B'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('zip.name')), 'neon hud');
    await tapVisible(tester, find.byKey(const Key('zip.create')));
    await waitFor(tester, () => h.container.read(zipCreateProvider).created != null);
    final out = File(p.join(h.root, 'neon hud.zip'));
    expect(out.existsSync(), isTrue);
    final ins = SafeZip.inspect(out.path);
    expect(ins.files.map((e) => e.path), ['neon-hud/hud.json', 'neon-hud/readme.txt']);
    expect(find.textContaining('ARCHIVE CREATED'), findsOneWidget);

    // A second archive with the same name never replaces the first.
    await tapVisible(tester, find.byKey(const Key('zip.create')));
    await waitFor(tester, () => h.container.read(zipCreateProvider).created?.label == 'neon hud (2).zip');
    expect(File(p.join(h.root, 'neon hud (2).zip')).existsSync(), isTrue);
  });

  testWidgets('create & export hands the bytes to the save dialog and cleans up', (tester) async {
    final f = h.write('a.txt', utf8.encode('alpha'));
    await pumpPage(tester, h, const ZipPage());
    h.container.read(zipCreateProvider.notifier).addEntries([
      ZipPlanEntry(archivePath: 'a.txt', sourcePath: f.path, size: 5, origin: 'workspace'),
    ]);
    await tester.pump();
    await tapVisible(tester, find.text('Create & export...'));
    await waitFor(tester, () => find.text('Export...').evaluate().isNotEmpty);
    await chooseExport(tester);
    await waitFor(tester, () => h.files.savedBytes.isNotEmpty);
    final (name, bytes) = h.files.savedBytes.single;
    expect(name, 'a.zip');
    expect(bytes.sublist(0, 2), [0x50, 0x4B], reason: 'ZIP magic');
    // The staging copy is removed after the hand-over.
    final staging = Directory(h.env.paths.exportStagingDir);
    List<File> staged() => staging.existsSync() ? staging.listSync(recursive: true).whereType<File>().toList() : [];
    await waitFor(tester, () => staged().isEmpty);
    expect(staged(), isEmpty);
  });

  testWidgets('duplicate archive paths block creation', (tester) async {
    final a = h.write('x/Readme.txt', [1]);
    final b = h.write('y/README.TXT', [2]);
    await pumpPage(tester, h, const ZipPage());
    h.container.read(zipCreateProvider.notifier).addEntries([
      ZipPlanEntry(archivePath: 'Readme.txt', sourcePath: a.path, size: 1, origin: 'w'),
      ZipPlanEntry(archivePath: 'README.TXT', sourcePath: b.path, size: 1, origin: 'w'),
    ]);
    await tester.pump();
    expect(find.text('BLOCKED'), findsNWidgets(2));
    expect(tester.widget<NeonButton>(find.byKey(const Key('zip.create'))).onPressed, isNull);
  });

  testWidgets('extract: preview, destination folder named after the archive, result', (tester) async {
    final zip = writeRawZip(Directory(h.root), 'pack.zip', [
      RawZipEntry('data/', []),
      RawZipEntry('data/items.csv', utf8.encode('id,name\n1,sword\n'), deflate: true),
      RawZipEntry('readme.txt', utf8.encode('hello')),
    ]);
    extractMode();
    await pumpPage(tester, h, const ZipPage());
    expect(find.text('No archive open'), findsOneWidget);
    h.container
        .read(zipExtractProvider.notifier)
        .open(FileItem(path: zip, label: 'pack.zip', inWorkspace: true, size: File(zip).lengthSync()));
    await tester.pump();
    expect(find.textContaining('SAFE TO EXTRACT'), findsOneWidget);
    expect(find.text('data/items.csv'), findsOneWidget);
    expect(find.text('Test WS (workspace root)/'), findsNothing);
    expect(tester.widget<Text>(find.byKey(const Key('zip.dest'))).data, 'pack/');
    await tapVisible(tester, find.byKey(const Key('zip.extract')));
    await waitFor(tester, () => h.container.read(zipExtractProvider).outcome != null);
    expect(File(p.join(h.root, 'pack', 'data', 'items.csv')).readAsStringSync(), 'id,name\n1,sword\n');
    expect(find.textContaining('2 written, 0 skipped'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('zip.dest'))).data, 'pack (2)/');
  });

  testWidgets('extract into an existing folder: skip keeps files, overwrite needs a danger confirmation', (
    tester,
  ) async {
    final zip = writeRawZip(Directory(h.env.dir.path), 'm.zip', [RawZipEntry('a.txt', utf8.encode('from zip'))]);
    h.write('a.txt', utf8.encode('mine'));
    extractMode();
    await pumpPage(tester, h, const ZipPage());
    final ctl = h.container.read(zipExtractProvider.notifier);
    ctl.open(FileItem(path: zip, label: 'm.zip', inWorkspace: false, size: File(zip).lengthSync()));
    ctl.setSubfolder(false);
    await tester.pump();
    expect(find.textContaining('1 file(s) already exist'), findsOneWidget);
    await tapVisible(tester, find.byKey(const Key('zip.extract')));
    await waitFor(tester, () => h.container.read(zipExtractProvider).outcome != null);
    expect(File(p.join(h.root, 'a.txt')).readAsStringSync(), 'mine');
    expect(h.container.read(zipExtractProvider).outcome!.skipped, ['a.txt']);

    await tapVisible(tester, find.text('Overwrite (danger)'));
    await tapVisible(tester, find.byKey(const Key('zip.extract')));
    await tester.pumpAndSettle();
    expect(find.text('Overwrite 1 existing file(s)?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(File(p.join(h.root, 'a.txt')).readAsStringSync(), 'mine');

    await tapVisible(tester, find.byKey(const Key('zip.extract')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Overwrite'));
    await tester.pump();
    await waitFor(tester, () => h.container.read(zipExtractProvider).outcome?.backedUp.isNotEmpty ?? false);
    expect(File(p.join(h.root, 'a.txt')).readAsStringSync(), 'from zip');
  });

  testWidgets('hostile archive is BLOCKED and cannot be extracted', (tester) async {
    final zip = writeRawZip(Directory(h.env.dir.path), 'evil.zip', [
      RawZipEntry('../../escape.txt', utf8.encode('x')),
      RawZipEntry('ok.txt', utf8.encode('y')),
    ]);
    extractMode();
    await pumpPage(tester, h, const ZipPage());
    h.container
        .read(zipExtractProvider.notifier)
        .open(FileItem(path: zip, label: 'evil.zip', inWorkspace: false, size: File(zip).lengthSync()));
    await tester.pump();
    expect(find.textContaining('BLOCKED'), findsWidgets);
    expect(find.textContaining('parent-directory traversal'), findsWidgets);
    expect(tester.widget<NeonButton>(find.byKey(const Key('zip.extract'))).onPressed, isNull);
  });

  testWidgets('not a zip shows a readable error', (tester) async {
    final bogus = File(p.join(h.env.dir.path, 'bogus.zip'))..writeAsStringSync('not a zip at all');
    extractMode();
    await pumpPage(tester, h, const ZipPage());
    // Open through the real picker flow (device source).
    h.files.queuedPicks.add([PickedLocalFile(name: 'bogus.zip', path: bogus.path, size: 16)]);
    await tapVisible(tester, find.byKey(const Key('zip.open')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('From device'));
    await waitFor(tester, () => h.container.read(zipExtractProvider).zip != null);
    expect(h.container.read(zipExtractProvider).inspectError, isNotNull);
    expect(find.textContaining('Not a readable ZIP'), findsWidgets);
  });

  testWidgets('fits 320x568 at 2x text in both modes', (tester) async {
    await pumpPage(tester, h, const ZipPage(), size: const Size(320, 568), textScale: 2);
    expect(tester.takeException(), isNull);
    extractMode();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
