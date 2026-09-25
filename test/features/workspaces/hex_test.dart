import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/features/workspaces/data/hex_pager.dart';
import 'package:j3nsontop_multitool/features/workspaces/domain/hex_math.dart';
import 'package:path/path.dart' as p;

void main() {
  group('HexLayout paging math', () {
    test('rows, pages and partial tails', () {
      const l = HexLayout(fileSize: 100, bytesPerRow: 16, pageSize: 32);
      expect(l.rowCount, 7);
      expect(l.rowLength(6), 4);
      expect(l.rowLength(7), 0);
      expect(l.pageCount, 4);
      expect(l.pageLength(3), 4);
      expect(l.pageOf(31), 0);
      expect(l.pageOf(32), 1);
      expect(l.rowOf(47), 2);
      expect(l.pagesFor(30, 4), [0, 1]);
      expect(l.pagesFor(96, 100), [3]);
      expect(l.pagesFor(200, 4), isEmpty);
      expect(const HexLayout(fileSize: 0).rowCount, 0);
      expect(const HexLayout(fileSize: 1 << 33).offsetDigits, 9);
      expect(const HexLayout(fileSize: 1000).offsetDigits, 8);
    });

    test('row formatting pads short rows and masks non-printables', () {
      final row = HexFormat.row(0x10, [0x48, 0x69, 0x00, 0x7F], 8);
      expect(row, '00000010 | 48 69 00 7F             | Hi..');
      expect(HexFormat.hexColumn(List.generate(16, (i) => i), 16).length, 16 * 3 - 1 + 1);
    });

    test('offset parsing: decimal, hex prefixes and errors', () {
      expect(HexFormat.parseOffset('4096'), 4096);
      expect(HexFormat.parseOffset('0x1000'), 4096);
      expect(HexFormat.parseOffset('1000h'), 4096);
      expect(HexFormat.parseOffset(r'$1F'), 31);
      expect(HexFormat.parseOffset('ff'), 255);
      expect(HexFormat.parseOffset('1_000'), 1000);
      expect(() => HexFormat.parseOffset(''), throwsFormatException);
      expect(() => HexFormat.parseOffset('0xZZ'), throwsFormatException);
      expect(() => HexFormat.parseOffset('12g'), throwsFormatException);
    });

    test('byte pattern parsing and matching with wildcards and ASCII case folding', () {
      final pat = BytePattern.parseHex('DE AD ?? ef');
      expect(pat.bytes, [0xDE, 0xAD, null, 0xEF]);
      expect(BytePattern.parseHex('0xDE,0xAD').bytes, [0xDE, 0xAD]);
      expect(() => BytePattern.parseHex('ABC'), throwsFormatException);
      expect(() => BytePattern.parseHex('?? ??'), throwsFormatException);
      expect(() => BytePattern.parseHex('GG'), throwsFormatException);
      final data = Uint8List.fromList([0, 0xDE, 0xAD, 0x01, 0xEF, 0xDE, 0xAD, 0x02, 0xEF]);
      expect(pat.indexIn(data), 1);
      expect(pat.indexIn(data, 2), 5);
      expect(pat.lastIndexIn(data, 8), 5);
      expect(pat.lastIndexIn(data, 4), 1);
      final text = BytePattern.text('neon', caseSensitive: false);
      expect(text.indexIn(Uint8List.fromList('xxNEONx'.codeUnits)), 2);
      expect(BytePattern.text('neon').indexIn(Uint8List.fromList('xxNEONx'.codeUnits)), -1);
    });

    test('scan windows overlap by pattern length - 1', () {
      final w = forwardWindows(from: 0, fileSize: 100, chunk: 40, patternLength: 5);
      expect(w.map((e) => (e.start, e.length)), [(0, 40), (36, 40), (72, 28)]);
      final b = backwardWindows(from: 95, fileSize: 100, chunk: 40, patternLength: 5);
      expect(b.first.end, 100);
      for (var i = 1; i < b.length; i++) {
        expect(b[i].end - b[i - 1].start, 4, reason: 'overlap');
      }
      expect(b.last.start, 0);
    });
  });

  group('HexPager and search on disk', () {
    late Directory tmp;
    late String path;
    const size = 300 * 1024 + 7;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('j3_hex_');
      path = p.join(tmp.path, 'data.bin');
      final bytes = Uint8List(size);
      for (var i = 0; i < size; i++) {
        bytes[i] = (i * 7) & 0x7F;
      }
      // Markers straddling page boundaries (64 KiB pages) and search chunks.
      const marker = [0xCA, 0xFE, 0xBA, 0xBE];
      for (final at in [65536 - 2, 3 * 65536 - 1, size - 4]) {
        bytes.setRange(at, at + 4, marker);
      }
      File(path).writeAsBytesSync(bytes);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('reads across page boundaries with a bounded LRU cache', () async {
      final pager = await HexPager.open(path, maxPages: 2);
      expect(pager.length, size);
      final bytes = await pager.read(65536 - 2, 4);
      expect(bytes, [0xCA, 0xFE, 0xBA, 0xBE]);
      await pager.read(2 * 65536, 10);
      await pager.read(4 * 65536, 10);
      expect(pager.cachedPages, 2);
      expect(pager.readCached(0, 4), isNull, reason: 'page 0 was evicted');
      final tail = await pager.read(size - 3, 100);
      expect(tail.length, 3);
      await Future.wait([for (var i = 0; i < 5; i++) pager.page(i)]);
      await pager.close();
      expect(pager.isClosed, isTrue);
    });

    test('finds patterns across chunk boundaries forwards and backwards', () async {
      final pat = BytePattern.parseHex('CA FE BA BE');
      // Small chunks force many window boundaries.
      final first = await HexSearch.findNext(path, pat, from: 0, chunk: 1000);
      expect(first, 65536 - 2);
      final second = await HexSearch.findNext(path, pat, from: first! + 1, chunk: 1000);
      expect(second, 3 * 65536 - 1);
      final last = await HexSearch.findNext(path, pat, from: second! + 1, chunk: 4096);
      expect(last, size - 4);
      expect(await HexSearch.findNext(path, pat, from: last! + 1), isNull);
      expect(await HexSearch.findPrevious(path, pat, from: size, chunk: 1000), size - 4);
      expect(await HexSearch.findPrevious(path, pat, from: size - 5, chunk: 1000), 3 * 65536 - 1);
      expect(await HexSearch.findPrevious(path, pat, from: 65536 - 3, chunk: 1000), isNull);
      expect(await HexSearch.count(path, pat, chunk: 1000), 3);
    });

    test('search is cancellable', () async {
      final token = CancellationToken()..cancel();
      await expectLater(
        HexSearch.findNext(path, BytePattern.parseHex('FF FF FF'), from: 0, token: token, chunk: 1024),
        throwsA(isA<OperationCancelled>()),
      );
    });
  });
}
