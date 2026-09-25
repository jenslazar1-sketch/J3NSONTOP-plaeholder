import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/archive/safe_zip.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/features/file_tools/domain/zip_studio.dart';
import 'package:path/path.dart' as p;

import '../../helpers/raw_zip.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('j3_zipstudio_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File write(String rel, String content) {
    final f = File(p.join(tmp.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    return f;
  }

  group('plan', () {
    test('folder entries keep the folder name; files use their name', () async {
      write('game/config/settings.ini', '[Display]\n');
      write('game/data/名前.json', '{}');
      final solo = write('readme.txt', 'hi');
      final (entries, walk) = await zipEntriesForFolder(p.join(tmp.path, 'game'), origin: 'workspace');
      expect(walk.files, hasLength(2));
      final plan = ZipPlan(entries).adding([await zipEntryForFile(solo.path, origin: 'device')]);
      expect(plan.entries.map((e) => e.archivePath), ['game/config/settings.ini', 'game/data/名前.json', 'readme.txt']);
      expect(plan.canCreate, isTrue);
      expect(plan.totalBytes, 10 + 2 + 2);
      expect(suggestArchiveName(ZipPlan(entries)), 'game.zip');
      expect(suggestArchiveName(plan), 'archive.zip');
    });

    test('case-insensitive collisions and unsafe names block creation', () async {
      final a = write('a/Readme.txt', '1');
      final b = write('b/README.TXT', '2');
      final plan = ZipPlan([
        await zipEntryForFile(a.path, origin: 'x'),
        await zipEntryForFile(b.path, origin: 'x'),
        ZipPlanEntry(archivePath: 'bad:name.txt', sourcePath: a.path, size: 1, origin: 'x'),
      ]);
      expect(plan.canCreate, isFalse);
      expect(plan.problems.keys, containsAll(['Readme.txt', 'README.TXT', 'bad:name.txt']));
      final fixed = plan.without(['README.TXT', 'bad:name.txt']);
      expect(fixed.canCreate, isTrue);
      expect(normalizeArchiveName(' my mods '), 'my mods.zip');
      expect(normalizeArchiveName('x.ZIP'), 'x.ZIP');
    });
  });

  group('create + extract', () {
    test('round trip through the tool service with progress', () async {
      write('src/a.txt', 'alpha');
      write('src/deep/ünï.bin', 'binary-ish \u0001');
      final (entries, _) = await zipEntriesForFolder(p.join(tmp.path, 'src'), origin: 'workspace');
      final out = p.join(tmp.path, 'out.zip');
      final fractions = <double>[];
      final size = await createArchive(out, ZipPlan(entries), onProgress: fractions.add);
      expect(size, File(out).lengthSync());
      expect(fractions.last, 1.0);
      final ins = SafeZip.inspect(out);
      expect(ins.isSafe, isTrue);
      expect(ins.files.map((e) => e.path), containsAll(['src/a.txt', 'src/deep/ünï.bin']));

      final dest = defaultExtractFolder(out, tmp.path);
      expect(p.basename(dest), 'out');
      final r = await extractArchive(out, dest);
      expect(r.written, hasLength(2));
      expect(r.cancelled, isFalse);
      expect(File(p.join(dest, 'src', 'a.txt')).readAsStringSync(), 'alpha');
      expect(File(p.join(dest, 'src', 'deep', 'ünï.bin')).readAsStringSync(), 'binary-ish \u0001');
      // The default folder is made unique when it exists.
      expect(p.basename(defaultExtractFolder(out, tmp.path)), 'out (2)');
    });

    test('hostile archive is blocked and nothing is written', () async {
      final z = writeRawZip(tmp, 'evil.zip', [
        RawZipEntry('ok.txt', utf8.encode('fine')),
        RawZipEntry('../../escape.txt', utf8.encode('pwned')),
        RawZipEntry('link', utf8.encode('/etc/passwd'), unixMode: 0xA1FF),
      ]);
      final ins = SafeZip.inspect(z);
      expect(ins.isSafe, isFalse);
      expect(ins.fatal.map((i) => i.entry), containsAll(['../../escape.txt', 'link']));
      final dest = p.join(tmp.path, 'dest');
      await expectLater(extractArchive(z, dest), throwsA(isA<UnsafeArchiveException>()));
      expect(Directory(dest).existsSync(), isFalse);
      expect(File(p.join(tmp.path, 'escape.txt')).existsSync(), isFalse);
    });

    test('existing-file policies: skip, fail, overwrite with backup', () async {
      final z = writeRawZip(tmp, 'm.zip', [
        RawZipEntry('a.txt', utf8.encode('new a'), deflate: true),
        RawZipEntry('b.txt', utf8.encode('new b')),
      ]);
      final dest = Directory(p.join(tmp.path, 'dest'))..createSync();
      File(p.join(dest.path, 'a.txt')).writeAsStringSync('mine');
      expect(existingTargets(SafeZip.inspect(z), dest.path), ['a.txt']);

      final skipped = await extractArchive(z, dest.path);
      expect(skipped.skipped, ['a.txt']);
      expect(skipped.written, ['b.txt']);
      expect(File(p.join(dest.path, 'a.txt')).readAsStringSync(), 'mine');

      await expectLater(
        extractArchive(z, dest.path, policy: ExistingFilePolicy.fail),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(p.join(dest.path, 'a.txt')).readAsStringSync(), 'mine');

      final backups = p.join(tmp.path, 'backups', 'x');
      final over = await extractArchive(z, dest.path, policy: ExistingFilePolicy.overwrite, backupRoot: backups);
      expect(File(p.join(dest.path, 'a.txt')).readAsStringSync(), 'new a');
      expect(over.backedUp, containsAll(['a.txt', 'b.txt']));
      expect(File(p.join(backups, 'a.txt')).readAsStringSync(), 'mine');
      expect(over.backupDir, backups);
    });

    test('fail policy writes nothing when any target exists', () async {
      final z = writeRawZip(tmp, 'two.zip', [
        RawZipEntry('first.txt', utf8.encode('1')),
        RawZipEntry('second.txt', utf8.encode('2')),
      ]);
      final dest = Directory(p.join(tmp.path, 'd2'))..createSync();
      File(p.join(dest.path, 'second.txt')).writeAsStringSync('mine');
      await expectLater(
        extractArchive(z, dest.path, policy: ExistingFilePolicy.fail),
        throwsA(isA<FileSystemException>().having((e) => e.message, 'message', contains('nothing was extracted'))),
      );
      expect(File(p.join(dest.path, 'first.txt')).existsSync(), isFalse);
      expect(File(p.join(dest.path, 'second.txt')).readAsStringSync(), 'mine');
    });

    test('cancellation keeps a record of files already written', () async {
      final z = writeRawZip(tmp, 'c.zip', [RawZipEntry('a.txt', utf8.encode('x'))]);
      final r = await extractArchive(z, p.join(tmp.path, 'c'), token: CancellationToken()..cancel());
      expect(r.cancelled, isTrue);
      expect(r.written, isEmpty);
    });

    test('ratio labels and limit descriptions', () {
      const e = ZipEntryInfo(
        rawName: 'a',
        path: 'a',
        isDirectory: false,
        size: 1000,
        compressedSize: 100,
        method: 8,
        crc32: 0,
        modified: null,
      );
      expect(ratioLabel(e), '10:1');
      expect(describeZipLimits().first, contains('20000'));
    });
  });
}
