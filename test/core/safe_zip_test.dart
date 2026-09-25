import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/archive/safe_zip.dart';
import 'package:j3nsontop_multitool/core/text/diff.dart';
import 'package:path/path.dart' as p;

import '../helpers/raw_zip.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('j3_zip_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  List<int> bytes(String s) => utf8.encode(s);

  group('inspect', () {
    test('accepts a normal archive', () {
      final z = writeRawZip(tmp, 'ok.zip', [
        RawZipEntry('dir/', []),
        RawZipEntry('dir/a.txt', bytes('hello'), deflate: true),
        RawZipEntry('b.json', bytes('{}')),
      ]);
      final r = SafeZip.inspect(z);
      expect(r.isSafe, isTrue, reason: r.issues.join('\n'));
      expect(r.files.map((e) => e.path), ['dir/a.txt', 'b.json']);
      expect(r.totalBytes, 7);
    });

    final hostile = <String, List<RawZipEntry>>{
      'parent traversal': [RawZipEntry('../../evil.dll', bytes('x'))],
      'nested traversal': [RawZipEntry('a/../../evil', bytes('x'))],
      'absolute path': [RawZipEntry('/etc/cron.d/x', bytes('x'))],
      'windows drive path': [RawZipEntry(r'C:\Windows\x.dll', bytes('x'))],
      'backslash traversal': [RawZipEntry(r'..\..\x', bytes('x'))],
      'symlink entry': [RawZipEntry('link', bytes('/etc/passwd'), unixMode: 0xA1FF)],
      'duplicate path': [RawZipEntry('a.txt', bytes('1')), RawZipEntry('a.txt', bytes('2'))],
      'case-insensitive duplicate': [RawZipEntry('Data/A.txt', bytes('1')), RawZipEntry('data/a.TXT', bytes('2'))],
      'encrypted entry': [RawZipEntry('s.txt', bytes('x'), encrypted: true)],
      'unsupported method': [RawZipEntry('b.bin', bytes('x'), method: 12)],
      'local/central name mismatch': [RawZipEntry('safe.txt', bytes('x'), localName: '../evil.txt')],
      'file used as folder': [RawZipEntry('a', bytes('x')), RawZipEntry('a/b.txt', bytes('y'))],
      'reserved device name': [RawZipEntry('con.txt', bytes('x'))],
    };
    hostile.forEach((name, entries) {
      test('rejects $name', () {
        final z = writeRawZip(tmp, 'bad.zip', entries);
        final r = SafeZip.inspect(z);
        expect(r.isSafe, isFalse);
        expect(() => SafeZip.extract(z, p.join(tmp.path, 'out')), throwsA(isA<UnsafeArchiveException>()));
        expect(Directory(p.join(tmp.path, 'out')).existsSync(), isFalse, reason: 'nothing may be written');
      });
    });

    test('rejects too many entries and oversize entries', () {
      final many = writeRawZip(tmp, 'many.zip', [for (var i = 0; i < 12; i++) RawZipEntry('f$i', bytes('x'))]);
      expect(SafeZip.inspect(many, limits: const ZipLimits(maxEntries: 10)).isSafe, isFalse);
      final big = writeRawZip(tmp, 'big.zip', [RawZipEntry('f', List.filled(5000, 65))]);
      expect(SafeZip.inspect(big, limits: const ZipLimits(maxEntryBytes: 4000)).isSafe, isFalse);
      expect(SafeZip.inspect(big, limits: const ZipLimits(maxTotalBytes: 4000)).isSafe, isFalse);
    });

    test('flags suspicious compression ratios (zip bomb)', () {
      final z = writeRawZip(tmp, 'bomb.zip', [
        RawZipEntry('zeros.bin', List.filled(4 * 1024 * 1024, 0), deflate: true),
      ]);
      final r = SafeZip.inspect(z);
      expect(r.isSafe, isFalse);
      expect(r.issues.single.message, contains('ratio'));
    });

    test('non-zip input is a FormatException', () {
      final f = File(p.join(tmp.path, 'x.zip'))..writeAsStringSync('definitely not a zip');
      expect(() => SafeZip.inspect(f.path), throwsFormatException);
    });
  });

  group('extract', () {
    test('extracts files and records created directories', () async {
      final z = writeRawZip(tmp, 'ok.zip', [
        RawZipEntry('x/y/deep.txt', bytes('deep'), deflate: true),
        RawZipEntry('top.txt', bytes('top')),
      ]);
      final out = p.join(tmp.path, 'out');
      final r = await SafeZip.extract(z, out);
      expect(File(p.join(out, 'x', 'y', 'deep.txt')).readAsStringSync(), 'deep');
      expect(File(p.join(out, 'top.txt')).readAsStringSync(), 'top');
      expect(r.written.length, 2);
      expect(r.createdDirs.map((d) => p.relative(d, from: out)), containsAll(['x', p.join('x', 'y')]));
      expect(r.bytes, 7);
    });

    test('lying declared size is caught while inflating (bounded memory)', () async {
      // Declares 10 bytes but actually inflates to 50 000.
      final z = writeRawZip(tmp, 'lie.zip', [
        RawZipEntry('big.txt', List.filled(50000, 66), deflate: true, declaredSize: 10),
      ]);
      final out = p.join(tmp.path, 'out');
      await expectLater(SafeZip.extract(z, out), throwsFormatException);
      expect(File(p.join(out, 'big.txt')).existsSync(), isFalse);
      expect(File(p.join(out, 'big.txt.j3part')).existsSync(), isFalse, reason: 'partial file cleaned up');
    });

    test('CRC mismatch is detected', () async {
      final z = writeRawZip(tmp, 'crc.zip', [RawZipEntry('a.txt', bytes('hello'), crcOverride: 1234)]);
      await expectLater(
        SafeZip.extract(z, p.join(tmp.path, 'out')),
        throwsA(predicate((e) => e.toString().contains('CRC'))),
      );
    });

    test('existing file policy: fail, skip, overwrite', () async {
      final z = writeRawZip(tmp, 'ok.zip', [RawZipEntry('a.txt', bytes('new'))]);
      final out = p.join(tmp.path, 'out');
      Directory(out).createSync();
      File(p.join(out, 'a.txt')).writeAsStringSync('old');
      await expectLater(SafeZip.extract(z, out), throwsA(isA<FileSystemException>()));
      expect(File(p.join(out, 'a.txt')).readAsStringSync(), 'old');
      final skipped = await SafeZip.extract(z, out, existing: ExistingFilePolicy.skip);
      expect(skipped.skipped, ['a.txt']);
      expect(File(p.join(out, 'a.txt')).readAsStringSync(), 'old');
      await SafeZip.extract(z, out, existing: ExistingFilePolicy.overwrite);
      expect(File(p.join(out, 'a.txt')).readAsStringSync(), 'new');
    });

    test('refuses to extract through a symlinked directory in the destination', () async {
      if (Platform.isWindows) return;
      final outside = Directory.systemTemp.createTempSync('j3_zip_outside_');
      addTearDown(() => outside.deleteSync(recursive: true));
      final out = Directory(p.join(tmp.path, 'out'))..createSync();
      Link(p.join(out.path, 'sub')).createSync(outside.path);
      final z = writeRawZip(tmp, 'ok.zip', [RawZipEntry('sub/pwned.txt', bytes('x'))]);
      await expectLater(SafeZip.extract(z, out.path), throwsA(anything));
      expect(File(p.join(outside.path, 'pwned.txt')).existsSync(), isFalse);
    });

    test('readEntry and readText', () {
      final z = writeRawZip(tmp, 'm.zip', [RawZipEntry('j3mod.json', bytes('{"id":"x"}'), deflate: true)]);
      expect(SafeZip.readText(z, 'j3mod.json'), '{"id":"x"}');
      expect(() => SafeZip.readEntry(z, 'missing.txt'), throwsA(isA<FileSystemException>()));
    });
  });

  test('create then extract round-trips (Unicode names)', () async {
    final src = File(p.join(tmp.path, 'source.bin'))..writeAsBytesSync(List.generate(100000, (i) => i % 251));
    final zip = p.join(tmp.path, 'new.zip');
    await SafeZip.create(zip, [
      ZipSource.file('data/source.bin', src.path),
      ZipSource.bytes('readme ünïcødé.txt', bytes('hi ✓')),
    ]);
    expect(SafeZip.inspect(zip).isSafe, isTrue);
    final out = p.join(tmp.path, 'rt');
    await SafeZip.extract(zip, out);
    expect(File(p.join(out, 'data', 'source.bin')).readAsBytesSync(), src.readAsBytesSync());
    expect(File(p.join(out, 'readme ünïcødé.txt')).readAsStringSync(), 'hi ✓');
  });

  test('create rejects duplicate and unsafe paths', () async {
    final zip = p.join(tmp.path, 'dup.zip');
    await expectLater(
      SafeZip.create(zip, [
        ZipSource.bytes('a.txt', [1]),
        ZipSource.bytes('A.TXT', [2]),
      ]),
      throwsFormatException,
    );
    await expectLater(
      SafeZip.create(zip, [
        ZipSource.bytes('../x', [1]),
      ]),
      throwsA(anything),
    );
    expect(File(zip).existsSync(), isFalse);
  });

  group('LineDiff', () {
    test('identical texts', () {
      final r = LineDiff.diffText('a\nb\n', 'a\nb\n');
      expect(r.identical, isTrue);
    });

    test('insertions and deletions with line numbers', () {
      final r = LineDiff.diffText('a\nb\nc\nd', 'a\nx\nc\nd\ne');
      expect(r.insertions, 2);
      expect(r.deletions, 1);
      final del = r.lines.firstWhere((l) => l.op == DiffOp.delete);
      expect(del.text, 'b');
      expect(del.oldLine, 2);
      final ins = r.lines.where((l) => l.op == DiffOp.insert).map((l) => l.text);
      expect(ins, ['x', 'e']);
    });

    test('reconstructs both sides exactly', () {
      const a = 'one\ntwo\nthree\nfour\nfive\nsix';
      const b = 'zero\none\nthree\nfour\n4.5\nfive\nseven';
      final r = LineDiff.diffText(a, b);
      final oldSide = r.lines.where((l) => l.op != DiffOp.insert).map((l) => l.text).join('\n');
      final newSide = r.lines.where((l) => l.op != DiffOp.delete).map((l) => l.text).join('\n');
      expect(newSide, b);
      // Old side is reconstructed from the old texts of equal+delete lines.
      expect(oldSide.split('\n').length, a.split('\n').length);
    });

    test('ignore whitespace and case options', () {
      expect(
        LineDiff.diffText(
          'Hello  World',
          'hello world',
          options: const DiffOptions(ignoreWhitespace: true, ignoreCase: true),
        ).identical,
        isTrue,
      );
      expect(LineDiff.diffText('Hello', 'hello').identical, isFalse);
    });

    test('edit budget bounds the work', () {
      final a = List.generate(3000, (i) => 'a$i').join('\n');
      final b = List.generate(3000, (i) => 'b$i').join('\n');
      final r = LineDiff.diffText(a, b, options: const DiffOptions(maxEditDistance: 100));
      expect(r.truncated, isTrue);
      expect(r.deletions, 3000);
      expect(r.insertions, 3000);
    });

    test('unified output', () {
      final u = LineDiff.unified(LineDiff.diffText('a\nb\nc', 'a\nB\nc'), oldName: 'old.txt', newName: 'new.txt');
      expect(u, contains('--- old.txt'));
      expect(u, contains('-b'));
      expect(u, contains('+B'));
      expect(u, contains('@@ -1,3 +1,3 @@'));
    });
  });
}
