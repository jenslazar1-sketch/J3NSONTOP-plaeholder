import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/utils/hashing.dart';
import 'package:j3nsontop_multitool/features/file_tools/domain/checksums.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('j3_sums_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File write(String rel, String content) {
    final f = File(p.join(tmp.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    return f;
  }

  final abc256 = Hashing.text('abc');
  final abcMd5 = Hashing.text('abc', HashAlgorithm.md5);

  group('parseChecksums', () {
    test('GNU text and binary lines, spaces and Unicode in names', () {
      final r = parseChecksums(
        '$abc256  plain.txt\n'
        '$abc256 *bin/data.bin\n'
        '$abc256  my file  with spaces.txt\n'
        '$abc256  notes/unicode-名前-ünïcødé.txt\r\n',
      );
      expect(r.issues, isEmpty);
      expect(r.entries.map((e) => e.path), [
        'plain.txt',
        'bin/data.bin',
        'my file  with spaces.txt',
        'notes/unicode-名前-ünïcødé.txt',
      ]);
      expect(r.entries[0].format, ChecksumLineFormat.gnuText);
      expect(r.entries[1].format, ChecksumLineFormat.gnuBinary);
      expect(r.entries.every((e) => e.algorithm == HashAlgorithm.sha256), isTrue);
    });

    test('BSD tag format with parentheses in the name', () {
      final r = parseChecksums('SHA256 (a (copy).txt) = $abc256\nMD5 (b.txt) = $abcMd5\n');
      expect(r.issues, isEmpty);
      expect(r.entries[0].path, 'a (copy).txt');
      expect(r.entries[0].format, ChecksumLineFormat.bsd);
      expect(r.entries[0].algorithm, HashAlgorithm.sha256);
      expect(r.entries[1].algorithm, HashAlgorithm.md5);
    });

    test('GNU escaped names, comments, BOM, upper-case hex and bad lines', () {
      final r = parseChecksums(
        '﻿# generated\n'
        '\\$abc256  back\\\\slash\\nnewline.txt\n'
        '${abc256.toUpperCase()}  upper.txt\n'
        '\n'
        'nothex  x.txt\n'
        'abcd  short.txt\n'
        'SHA384 (x) = ${'a' * 96}\n'
        'SHA256 (x) = abcd\n'
        'justonetoken\n',
      );
      expect(r.entries.map((e) => e.path), ['back\\slash\nnewline.txt', 'upper.txt']);
      expect(r.entries[1].digest, abc256);
      expect(r.issues.map((i) => i.lineNumber), [5, 6, 7, 8, 9]);
      expect(r.issues[2].message, contains('unsupported'));
    });

    test('single-space separator is accepted leniently', () {
      final r = parseChecksums('$abc256 loose.txt');
      expect(r.entries.single.path, 'loose.txt');
    });
  });

  group('build and verify', () {
    test('generated file is stably sorted and round-trips through the parser', () {
      final text = buildChecksumFile([
        ('z/last.txt', abc256),
        ('a b.txt', abc256),
        (r'dir\win.txt', abc256),
        ('Ä.txt', abc256),
        ('B.txt', abc256),
      ]);
      final lines = text.trimRight().split('\n');
      expect(lines.map((l) => l.substring(66)), ['B.txt', 'a b.txt', 'dir/win.txt', 'z/last.txt', 'Ä.txt']);
      expect(text.endsWith('\n'), isTrue);
      // Same input in another order gives identical bytes.
      final again = buildChecksumFile([
        ('Ä.txt', abc256),
        ('B.txt', abc256),
        ('a b.txt', abc256),
        ('z/last.txt', abc256),
        (r'dir\win.txt', abc256),
      ]);
      expect(again, text);
      expect(parseChecksums(text).entries.length, 5);
    });

    test('escapes backslash/newline names and supports BSD style', () {
      final text = buildChecksumFile([('we\nird', abc256)]);
      expect(text, '\\$abc256  we\\nird\n');
      expect(parseChecksums(text).entries.single.path, 'we\nird');
      final bsd = buildChecksumFile([('x.txt', abcMd5)], algorithm: HashAlgorithm.md5, bsdStyle: true);
      expect(bsd, 'MD5 (x.txt) = $abcMd5\n');
    });

    test('verify reports OK, FAILED, MISSING and INVALID relative to the folder', () async {
      write('ok.txt', 'abc');
      write('sub/名前.txt', 'abc');
      write('changed.txt', 'abd');
      final outside = Directory.systemTemp.createTempSync('j3_out_');
      addTearDown(() => outside.deleteSync(recursive: true));
      File(p.join(outside.path, 'secret.txt')).writeAsStringSync('abc');
      if (!Platform.isWindows) Link(p.join(tmp.path, 'link')).createSync(outside.path);
      final parsed = parseChecksums(
        '$abc256  ok.txt\n'
        '$abc256  ./sub/名前.txt\n'
        '$abc256  changed.txt\n'
        '$abc256  gone.txt\n'
        '$abc256  ../escape.txt\n'
        '$abc256  /etc/passwd\n'
        '${Platform.isWindows ? '' : '$abc256  link/secret.txt\n'}'
        '$abcMd5  ok.txt\n'
        'garbage line\n',
      );
      final r = await verifyChecksums(parsed, tmp.path, fileNameAlgorithm: HashAlgorithm.sha256);
      final byPath = {for (final x in r.results) '${x.entry.lineNumber}:${x.entry.path}': x.status};
      expect(byPath['1:ok.txt'], VerifyStatus.ok);
      expect(byPath['2:./sub/名前.txt'], VerifyStatus.ok);
      expect(byPath['3:changed.txt'], VerifyStatus.failed);
      expect(byPath['4:gone.txt'], VerifyStatus.missing);
      expect(byPath['5:../escape.txt'], VerifyStatus.invalid);
      expect(byPath['6:/etc/passwd'], VerifyStatus.invalid);
      if (!Platform.isWindows) expect(byPath['7:link/secret.txt'], VerifyStatus.invalid);
      // SHA256SUMS name forces SHA-256: a 32-char digest cannot be checked.
      final md5Line = r.results.firstWhere((x) => x.entry.digest == abcMd5);
      expect(md5Line.status, VerifyStatus.invalid);
      expect(md5Line.detail, contains('SHA-256'));
      expect(r.parseIssues, hasLength(1));
      expect(r.count(VerifyStatus.ok), 2);
      expect(r.allOk, isFalse);
      expect(r.toText(), contains('changed.txt: FAILED'));
      expect(r.toText(), contains('2 OK, 1 FAILED, 1 MISSING'));
    });

    test('auto detection uses digest length; forced algorithm overrides', () async {
      write('a.txt', 'abc');
      final parsed = parseChecksums('$abcMd5  a.txt\nSHA256 (a.txt) = $abc256\n');
      final auto = await verifyChecksums(parsed, tmp.path);
      expect(auto.results.map((r) => r.status), [VerifyStatus.ok, VerifyStatus.ok]);
      expect(auto.allOk, isTrue);
      final forced = await verifyChecksums(parsed, tmp.path, forceAlgorithm: HashAlgorithm.md5);
      expect(forced.results.map((r) => r.status), [VerifyStatus.ok, VerifyStatus.invalid]);
    });

    test('verification can be cancelled', () async {
      write('a.txt', 'abc');
      final token = CancellationToken()..cancel();
      await expectLater(
        verifyChecksums(parseChecksums('$abc256  a.txt'), tmp.path, token: token),
        throwsA(isA<OperationCancelled>()),
      );
    });
  });

  group('hashFiles', () {
    test('per-file and overall progress, errors recorded per file', () async {
      final a = write('a.bin', 'a' * 3000);
      final b = write('b.bin', 'b' * 1000);
      final progress = <(int, double, double)>[];
      final r = await hashFiles(
        [
          HashTarget(path: a.path, label: 'a.bin', size: 3000),
          HashTarget(path: p.join(tmp.path, 'missing.bin'), label: 'missing.bin', size: 0),
          HashTarget(path: b.path, label: 'b.bin', size: 1000),
        ],
        HashAlgorithm.sha512,
        onProgress: (i, f, o) => progress.add((i, f, o)),
      );
      expect(r[0].digest, Hashing.text('a' * 3000, HashAlgorithm.sha512));
      expect(r[1].ok, isFalse);
      expect(r[1].error, isNotNull);
      expect(r[2].digest, Hashing.text('b' * 1000, HashAlgorithm.sha512));
      expect(progress.last.$3, 1.0);
      expect(progress.map((e) => e.$1).toSet(), {0, 1, 2});
      final overall = progress.map((e) => e.$3).toList();
      for (var i = 1; i < overall.length; i++) {
        expect(overall[i], greaterThanOrEqualTo(overall[i - 1]));
      }
    });

    test('helpers: common base, algorithm guesses, default names', () {
      final base = commonBaseFolder([p.join(tmp.path, 'x', 'a.txt'), p.join(tmp.path, 'x', 'y', 'b.txt')]);
      expect(base, p.join(tmp.path, 'x'));
      expect(algorithmFromFileName('SHA256SUMS'), HashAlgorithm.sha256);
      expect(algorithmFromFileName('release.sha512'), HashAlgorithm.sha512);
      expect(algorithmFromFileName('MD5SUMS.txt'), HashAlgorithm.md5);
      expect(algorithmFromFileName('sha1sum.txt'), HashAlgorithm.sha1);
      expect(algorithmFromFileName('checksums.txt'), isNull);
      expect(algorithmForHexLength(40), HashAlgorithm.sha1);
      expect(defaultChecksumFileName(HashAlgorithm.sha512), 'SHA512SUMS');
    });
  });
}
