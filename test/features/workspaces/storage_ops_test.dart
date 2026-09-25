import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/archive/safe_zip.dart';
import 'package:j3nsontop_multitool/core/platform/file_access.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/workspaces/data/file_ops.dart';
import 'package:j3nsontop_multitool/features/workspaces/data/fs_listing.dart';
import 'package:j3nsontop_multitool/features/workspaces/data/trash_store.dart';
import 'package:j3nsontop_multitool/features/workspaces/data/workspace_transfer.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';
import '../../helpers/raw_zip.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('j3_ops_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File write(String path, String content) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  group('trash', () {
    late String root;
    late TrashStore trash;
    setUp(() {
      root = p.join(tmp.path, 'root');
      trash = TrashStore(rootPath: root, metaDir: p.join(tmp.path, 'meta'));
      write(p.join(root, 'game', 'config', 'settings.ini'), 'volume=80');
      write(p.join(root, 'game', 'saves', 'slot1.json'), '{}');
      write(p.join(root, 'game', 'saves', 'slot2.json'), '{"x":1}');
    });

    test('move file to trash keeps the relative path and restores it', () async {
      final target = p.join(root, 'game', 'config', 'settings.ini');
      final item = await trash.moveToTrash(target);
      expect(File(target).existsSync(), isFalse);
      expect(item.relativePath, 'game/config/settings.ini');
      expect(item.bytes, 9);
      expect(File(p.join(trash.trashDir, item.id, 'game', 'config', 'settings.ini')).existsSync(), isTrue);
      final listed = await trash.list();
      expect(listed.single.relativePath, item.relativePath);
      final back = await trash.restore(listed.single);
      expect(back, target);
      expect(File(target).readAsStringSync(), 'volume=80');
      expect(await trash.list(), isEmpty);
      expect(Directory(p.join(trash.trashDir, item.id)).existsSync(), isFalse, reason: 'skeleton removed');
    });

    test('folders go to trash whole; restore refuses to overwrite unless as copy', () async {
      final saves = p.join(root, 'game', 'saves');
      final item = await trash.moveToTrash(saves);
      expect(item.isDirectory, isTrue);
      expect(item.files, 2);
      write(p.join(saves, 'new.json'), 'new');
      await expectLater(trash.restore(item), throwsA(isA<FileSystemException>()));
      final copy = await trash.restore(item, asCopy: true);
      expect(p.basename(copy), 'saves (2)');
      expect(File(p.join(copy, 'slot2.json')).readAsStringSync(), '{"x":1}');
      expect(File(p.join(saves, 'new.json')).readAsStringSync(), 'new');
    });

    test('empty trash deletes permanently; refuses paths outside the workspace', () async {
      await trash.moveToTrash(p.join(root, 'game', 'saves', 'slot1.json'));
      await trash.moveToTrash(p.join(root, 'game', 'saves', 'slot2.json'));
      expect((await trash.list()).length, 2);
      final (n, bytes) = await trash.empty();
      expect(n, 2);
      expect(bytes, 9);
      expect(await trash.list(), isEmpty);
      final outside = write(p.join(tmp.path, 'outside.txt'), 'x');
      await expectLater(trash.moveToTrash(outside.path), throwsA(isA<FileSystemException>()));
      await expectLater(trash.moveToTrash(root), throwsA(isA<FileSystemException>()));
      expect(outside.existsSync(), isTrue);
    });
  });

  group('import / export', () {
    test('import ZIP rejects hostile archives and writes nothing', () async {
      final target = p.join(tmp.path, 'ws');
      final hostile = {
        'traversal': [RawZipEntry('../../evil.txt', utf8.encode('x'))],
        'absolute': [RawZipEntry('/etc/passwd', utf8.encode('x'))],
        'symlink': [RawZipEntry('link', utf8.encode('/etc'), unixMode: 0xA1FF)],
        'duplicate': [RawZipEntry('A.txt', utf8.encode('1')), RawZipEntry('a.TXT', utf8.encode('2'))],
        'crc': [RawZipEntry('bad.txt', utf8.encode('hello'), crcOverride: 1)],
      };
      for (final entry in hostile.entries) {
        final zip = writeRawZip(tmp, '${entry.key}.zip', entry.value);
        final inspection = await WorkspaceTransfer.inspectZip(zip);
        if (entry.key == 'crc') {
          expect(inspection.isSafe, isTrue, reason: 'CRC is only verified while extracting');
          await expectLater(WorkspaceTransfer.extractZip(zip, target), throwsFormatException);
          expect(File(p.join(target, 'bad.txt')).existsSync(), isFalse, reason: 'partial file removed');
          continue;
        }
        expect(inspection.isSafe, isFalse, reason: entry.key);
        await expectLater(WorkspaceTransfer.extractZip(zip, target), throwsA(isA<UnsafeArchiveException>()));
      }
      expect(File(p.join(tmp.path, 'evil.txt')).existsSync(), isFalse);
      final leftovers = Directory(target).existsSync()
          ? Directory(target).listSync(recursive: true).whereType<File>().toList()
          : <File>[];
      expect(leftovers, isEmpty);
    });

    test('import ZIP extracts safe archives and skips existing files', () async {
      final target = p.join(tmp.path, 'ws');
      write(p.join(target, 'keep.txt'), 'mine');
      final zip = writeRawZip(tmp, 'ok.zip', [
        RawZipEntry('dir/', []),
        RawZipEntry('dir/a.txt', utf8.encode('hello'), deflate: true),
        RawZipEntry('keep.txt', utf8.encode('theirs')),
      ]);
      final r = await WorkspaceTransfer.extractZip(zip, target);
      expect(r.written.map((w) => p.relative(w, from: target).replaceAll(r'\', '/')), ['dir/a.txt']);
      expect(r.skipped, ['keep.txt']);
      expect(File(p.join(target, 'keep.txt')).readAsStringSync(), 'mine');
    });

    test('export ZIP round-trips files and reports links and unportable names', () async {
      final root = p.join(tmp.path, 'root');
      write(p.join(root, 'a', 'b.txt'), 'B');
      write(p.join(root, 'notes', 'unicode-名前-ünïcødé.txt'), 'U');
      write(p.join(root, 'aux.txt'), 'reserved on Windows');
      Link(p.join(root, 'link')).createSync(p.join(root, 'a'));
      final out = p.join(tmp.path, 'out', 'ws.zip');
      final r = await WorkspaceTransfer.exportZip(root, out);
      expect(r.files, 2);
      expect(r.skipped.join('\n'), contains('aux.txt'));
      expect(r.skipped.join('\n'), contains('symbolic link'));
      final inspection = SafeZip.inspect(out);
      expect(inspection.isSafe, isTrue);
      expect(inspection.files.map((e) => e.path).toSet(), {'a/b.txt', 'notes/unicode-名前-ünïcødé.txt'});
      expect(SafeZip.readText(out, 'a/b.txt'), 'B');
    });

    test('import folder copies recursively, skips symlinks and never overwrites', () async {
      final src = p.join(tmp.path, 'src');
      write(p.join(src, 'x', 'y.txt'), 'Y');
      write(p.join(src, 'z.txt'), 'Z');
      Link(p.join(src, 'x', 'loop')).createSync(src);
      final dst = p.join(tmp.path, 'dst');
      write(p.join(dst, 'z.txt'), 'existing');
      var progressCalls = 0;
      final r = await WorkspaceTransfer.importFolder(src, dst, onProgress: (_, _, _) => progressCalls++);
      expect(r.files, 2);
      expect(File(p.join(dst, 'x', 'y.txt')).readAsStringSync(), 'Y');
      expect(File(p.join(dst, 'z.txt')).readAsStringSync(), 'existing');
      expect(File(p.join(dst, 'z (2).txt')).readAsStringSync(), 'Z');
      expect(r.skipped.join('\n'), contains('symbolic link'));
      expect(r.skipped.join('\n'), contains('z (2).txt'));
      expect(progressCalls, greaterThan(0));
      expect(Directory(dst).listSync(recursive: true).where((e) => e.path.endsWith('.j3part')), isEmpty);
    });

    test('import picked files moves staged copies and cleans the staging folder', () async {
      final staging = p.join(tmp.path, 'staging');
      final a = write(p.join(staging, 'a.txt'), 'A');
      final outsideFile = write(p.join(tmp.path, 'device', 'b.txt'), 'B');
      final dst = p.join(tmp.path, 'ws');
      final r = await WorkspaceTransfer.importPicked(
        [
          PickedLocalFile(name: 'a.txt', path: a.path, size: 1),
          PickedLocalFile(name: 'b.txt', path: outsideFile.path, size: 1),
        ],
        dst,
        stagingDir: staging,
      );
      expect(r.files, 2);
      expect(r.bytes, 2);
      expect(Directory(staging).existsSync(), isFalse);
      expect(outsideFile.existsSync(), isTrue, reason: 'files we did not stage are copied, never moved');
      expect(File(p.join(dst, 'b.txt')).readAsStringSync(), 'B');
    });

    test('moves across drives by copy + delete, never losing links', () async {
      // Needs a second file system (tmpfs); skipped where there is none.
      final shm = Directory('/dev/shm');
      if (!shm.existsSync() || FileStat.statSync(shm.path).type != FileSystemEntityType.directory) {
        markTestSkipped('no second file system available');
        return;
      }
      final other = shm.createTempSync('j3_xdev_');
      addTearDown(() => other.deleteSync(recursive: true));
      final plain = p.join(tmp.path, 'plain');
      write(p.join(plain, 'a', 'b.txt'), 'B');
      await FileOps.move(plain, p.join(other.path, 'plain'));
      expect(File(p.join(other.path, 'plain', 'a', 'b.txt')).readAsStringSync(), 'B');
      expect(Directory(plain).existsSync(), isFalse);

      final linked = p.join(tmp.path, 'linked');
      write(p.join(linked, 'x.txt'), 'X');
      Link(p.join(linked, 'ln')).createSync(p.join(linked, 'x.txt'));
      await expectLater(FileOps.move(linked, p.join(other.path, 'linked')), throwsA(isA<FileSystemException>()));
      expect(Link(p.join(linked, 'ln')).existsSync(), isTrue, reason: 'source kept intact');
      expect(Directory(p.join(other.path, 'linked')).existsSync(), isFalse, reason: 'partial copy removed');
    });

    test('copy is cancellable and leaves no partial file', () async {
      final big = File(p.join(tmp.path, 'big.bin'))..writeAsBytesSync(List.filled(3 << 20, 7));
      final token = CancellationToken();
      final target = p.join(tmp.path, 'copy.bin');
      await expectLater(
        FileOps.copyFile(big.path, target, token: token, onBytes: (_) => token.cancel()),
        throwsA(isA<OperationCancelled>()),
      );
      expect(File(target).existsSync(), isFalse);
      expect(File('$target.j3part').existsSync(), isFalse);
    });
  });

  group('workspace records', () {
    test('removing a linked workspace never touches its folder', () async {
      final env = await TestEnv.create();
      addTearDown(env.dispose);
      final c = env.container();
      addTearDown(c.dispose);
      final folder = p.join(tmp.path, 'my game');
      write(p.join(folder, 'game.json'), '{}');
      final w = await c.read(workspacesProvider.notifier).addLinked('Game', folder);
      await c.read(workspacesProvider.notifier).remove(w.id, deleteAppOwnedFiles: true);
      expect(c.read(workspacesProvider).workspaces, isEmpty);
      expect(File(p.join(folder, 'game.json')).existsSync(), isTrue);
    });

    test('app-owned files are deleted only with the explicit flag', () async {
      final env = await TestEnv.create();
      addTearDown(env.dispose);
      final c = env.container();
      addTearDown(c.dispose);
      final ctrl = c.read(workspacesProvider.notifier);
      final keep = await ctrl.addAppOwned('Keep');
      write(p.join(keep.rootPath, 'a.txt'), 'A');
      await ctrl.remove(keep.id);
      expect(File(p.join(keep.rootPath, 'a.txt')).existsSync(), isTrue);
      final orphans = await WorkspaceTransfer.findOrphans(env.paths.workspacesDir, {
        for (final w in c.read(workspacesProvider).workspaces) w.id,
      });
      expect(orphans.single.id, keep.id);
      expect(orphans.single.files, 1);

      final drop = await ctrl.addAppOwned('Drop');
      write(p.join(drop.rootPath, 'b.txt'), 'B');
      await ctrl.remove(drop.id, deleteAppOwnedFiles: true);
      expect(Directory(p.join(env.paths.workspacesDir, drop.id)).existsSync(), isFalse);
    });

    test('health reports missing folders and files in place of folders', () async {
      final now = DateTime.now();
      Workspace ws(String root) =>
          Workspace(id: 'x', name: 'x', kind: WorkspaceKind.linked, rootPath: root, createdAt: now, lastOpenedAt: now);
      expect(await WorkspaceController.checkHealth(ws(tmp.path)), WorkspaceHealth.ok);
      expect(await WorkspaceController.checkHealth(ws(p.join(tmp.path, 'gone'))), WorkspaceHealth.missing);
      final f = write(p.join(tmp.path, 'file.txt'), 'x');
      expect(await WorkspaceController.checkHealth(ws(f.path)), WorkspaceHealth.notADirectory);
    });

    test('meta migration moves the library to a relinked record', () async {
      final from = p.join(tmp.path, 'old', 'meta');
      final to = p.join(tmp.path, 'new', 'meta');
      write(p.join(from, 'mods', 'x.j3mod'), 'm');
      Directory(to).createSync(recursive: true);
      await WorkspaceTransfer.migrateMeta(from, to);
      expect(File(p.join(to, 'mods', 'x.j3mod')).existsSync(), isTrue);
      expect(Directory(from).existsSync(), isFalse);
    });
  });

  group('listing and inspection', () {
    test('sorts folders first with natural order; hidden filter; unicode and long names', () async {
      final dir = p.join(tmp.path, 'list');
      final long = '${'very_long_name_' * 14}end.txt';
      write(p.join(dir, 'img10.png'), '1234567890');
      write(p.join(dir, 'img2.png'), '12');
      write(p.join(dir, '.hidden'), '');
      write(p.join(dir, 'ünï.txt'), 'x');
      write(p.join(dir, long), 'x');
      Directory(p.join(dir, 'zfolder')).createSync();
      final entries = await FsListing.list(dir);
      final visible = FsListing.filter(entries);
      expect(visible.any((e) => e.name == '.hidden'), isFalse);
      final sorted = FsListing.sort(visible, SortField.name);
      expect(sorted.first.name, 'zfolder');
      expect(
        sorted.map((e) => e.name).toList().indexOf('img2.png') <
            sorted.map((e) => e.name).toList().indexOf('img10.png'),
        isTrue,
      );
      expect(sorted.any((e) => e.name == long), isTrue);
      final bySize = FsListing.sort(visible, SortField.size, ascending: false);
      expect(bySize[1].name, 'img10.png');
      expect(FsListing.filter(entries, query: 'ÜNÏ').single.name, 'ünï.txt');
    });

    test('inspector detects encodings, line endings and binaries', () async {
      final crlf = write(p.join(tmp.path, 'a.ini'), 'a=1\r\nb=2\r\n');
      final facts = await FileInspector.inspect(crlf.path);
      expect(facts.isBinary, isFalse);
      expect(facts.encodingLabel, 'UTF-8');
      expect(facts.lineEndings, startsWith('CRLF'));
      final bin = File(p.join(tmp.path, 'b.bin'))..writeAsBytesSync([0, 1, 2, 3]);
      expect((await FileInspector.inspect(bin.path)).isBinary, isTrue);
      // A truncated sample that cuts a multi-byte character is not malformed.
      final cut = FileInspector.trimIncompleteUtf8(Uint8List.fromList([0x61, 0xE2, 0x82]));
      expect(cut, [0x61]);
    });
  });
}
