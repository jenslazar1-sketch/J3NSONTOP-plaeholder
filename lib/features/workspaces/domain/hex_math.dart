import 'dart:convert';
import 'dart:typed_data';

/// Paging and formatting arithmetic for the hex viewer (pure).
class HexLayout {
  const HexLayout({required this.fileSize, this.bytesPerRow = 16, this.pageSize = 64 * 1024})
    : assert(bytesPerRow > 0),
      assert(pageSize > 0);

  final int fileSize;
  final int bytesPerRow;
  final int pageSize;

  int get rowCount => fileSize == 0 ? 0 : (fileSize + bytesPerRow - 1) ~/ bytesPerRow;
  int get pageCount => fileSize == 0 ? 0 : (fileSize + pageSize - 1) ~/ pageSize;

  int rowOffset(int row) => row * bytesPerRow;
  int rowOf(int offset) => offset ~/ bytesPerRow;
  int pageOf(int offset) => offset ~/ pageSize;
  int pageStart(int page) => page * pageSize;

  /// Length of [page] (the last page may be short).
  int pageLength(int page) {
    final start = pageStart(page);
    if (start >= fileSize) return 0;
    final remaining = fileSize - start;
    return remaining < pageSize ? remaining : pageSize;
  }

  /// Number of bytes in [row] (the last row may be short).
  int rowLength(int row) {
    final start = rowOffset(row);
    if (start >= fileSize) return 0;
    final remaining = fileSize - start;
    return remaining < bytesPerRow ? remaining : bytesPerRow;
  }

  /// Pages touched by the byte range [start, start+length).
  List<int> pagesFor(int start, int length) {
    if (length <= 0 || start >= fileSize) return const [];
    final end = (start + length).clamp(0, fileSize) - 1;
    return [for (var p = pageOf(start); p <= pageOf(end); p++) p];
  }

  /// Hex digits needed for the largest offset (at least 8).
  int get offsetDigits {
    var digits = 8;
    var max = fileSize > 0 ? fileSize - 1 : 0;
    max >>= 32;
    while (max > 0) {
      digits++;
      max >>= 4;
    }
    return digits;
  }
}

abstract final class HexFormat {
  static const String _hex = '0123456789ABCDEF';

  static String byte(int b) => '${_hex[(b >> 4) & 0xF]}${_hex[b & 0xF]}';

  static String offset(int value, [int digits = 8]) => value.toRadixString(16).toUpperCase().padLeft(digits, '0');

  /// `DE AD BE EF` with an extra gap after every 8 bytes; short rows are
  /// padded so columns stay aligned.
  static String hexColumn(List<int> bytes, int bytesPerRow) {
    final b = StringBuffer();
    for (var i = 0; i < bytesPerRow; i++) {
      if (i > 0) b.write(i % 8 == 0 ? '  ' : ' ');
      b.write(i < bytes.length ? byte(bytes[i]) : '  ');
    }
    return b.toString();
  }

  /// Printable ASCII, '.' for everything else.
  static String asciiColumn(List<int> bytes) =>
      String.fromCharCodes([for (final v in bytes) v >= 0x20 && v < 0x7F ? v : 0x2E]);

  /// One text row: `OFFSET | hex | ascii`.
  static String row(int offsetValue, List<int> bytes, int bytesPerRow, [int digits = 8]) =>
      '${offset(offsetValue, digits)} | ${hexColumn(bytes, bytesPerRow)} | ${asciiColumn(bytes)}';

  /// Parses an offset typed by the user: `0x1F`, `1Fh`, `$1F` or any value
  /// containing a-f are hex; plain digits are decimal. Underscores and
  /// spaces are ignored. Throws [FormatException] with a readable reason.
  static int parseOffset(String input) {
    var s = input.trim().replaceAll(RegExp(r'[\s_]'), '').toLowerCase();
    if (s.isEmpty) throw const FormatException('Enter an offset, e.g. 4096 or 0x1000');
    var hex = false;
    if (s.startsWith('0x')) {
      hex = true;
      s = s.substring(2);
    } else if (s.startsWith(r'$')) {
      hex = true;
      s = s.substring(1);
    } else if (s.endsWith('h')) {
      hex = true;
      s = s.substring(0, s.length - 1);
    } else if (RegExp('[a-f]').hasMatch(s)) {
      hex = true;
    }
    if (s.isEmpty || !(hex ? RegExp(r'^[0-9a-f]+$') : RegExp(r'^[0-9]+$')).hasMatch(s)) {
      throw FormatException('"$input" is not a ${hex ? 'hexadecimal' : 'decimal'} offset');
    }
    if (s.length > 15) throw FormatException('"$input" is too large');
    return int.parse(s, radix: hex ? 16 : 10);
  }
}

/// A byte pattern; `null` elements are wildcards (`??` in hex input).
class BytePattern {
  const BytePattern(this.bytes, {this.caseInsensitiveAscii = false});

  final List<int?> bytes;

  /// Letters A-Z/a-z match either case (text searches).
  final bool caseInsensitiveAscii;

  int get length => bytes.length;

  /// Parses `DE AD ?? EF`, `deadbeef`, `0xDE,0xAD` etc.
  static BytePattern parseHex(String input) {
    final cleaned = input
        .replaceAll(RegExp(r'0x', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'[,;\s]+'), ' ')
        .trim();
    if (cleaned.isEmpty) throw const FormatException('Enter hex bytes, e.g. DE AD BE EF (?? = any byte)');
    final out = <int?>[];
    for (final group in cleaned.split(' ')) {
      if (group.length.isOdd) {
        throw FormatException('"$group" has an odd number of hex digits; write bytes as two digits (0A, not A)');
      }
      for (var i = 0; i < group.length; i += 2) {
        final pair = group.substring(i, i + 2);
        if (pair == '??') {
          out.add(null);
        } else {
          final v = int.tryParse(pair, radix: 16);
          if (v == null) throw FormatException('"$pair" is not a hex byte');
          out.add(v);
        }
      }
    }
    if (out.every((b) => b == null)) throw const FormatException('The pattern needs at least one concrete byte');
    if (out.length > 4096) throw const FormatException('Pattern is longer than 4096 bytes');
    return BytePattern(out);
  }

  /// UTF-8 bytes of [text].
  static BytePattern text(String text, {bool caseSensitive = true}) {
    if (text.isEmpty) throw const FormatException('Enter text to search for');
    final bytes = utf8.encode(text);
    if (bytes.length > 4096) throw const FormatException('Text is longer than 4096 bytes');
    return BytePattern(bytes, caseInsensitiveAscii: !caseSensitive);
  }

  static int _fold(int b) => b >= 0x41 && b <= 0x5A ? b + 32 : b;

  bool _eq(int? p, int h) {
    if (p == null) return true;
    if (p == h) return true;
    return caseInsensitiveAscii && _fold(p) == _fold(h);
  }

  bool matchesAt(Uint8List data, int at) {
    if (at < 0 || at + bytes.length > data.length) return false;
    for (var j = 0; j < bytes.length; j++) {
      if (!_eq(bytes[j], data[at + j])) return false;
    }
    return true;
  }

  /// First index >= [start] where the pattern fully fits in [data], or -1.
  int indexIn(Uint8List data, [int start = 0]) {
    final last = data.length - bytes.length;
    final anchor = bytes.indexWhere((b) => b != null);
    final a = bytes[anchor]!;
    for (var i = start < 0 ? 0 : start; i <= last; i++) {
      final h = data[i + anchor];
      if (h != a && !(caseInsensitiveAscii && _fold(h) == _fold(a))) continue;
      if (matchesAt(data, i)) return i;
    }
    return -1;
  }

  /// Last index <= [start] where the pattern fully fits in [data], or -1.
  int lastIndexIn(Uint8List data, int start) {
    var i = start;
    if (i > data.length - bytes.length) i = data.length - bytes.length;
    for (; i >= 0; i--) {
      if (matchesAt(data, i)) return i;
    }
    return -1;
  }
}

/// Plans chunked reads for a forward/backward scan so that matches that
/// straddle chunk (or page) boundaries are still found: consecutive
/// windows overlap by `patternLength - 1` bytes.
class ScanWindow {
  const ScanWindow(this.start, this.length);
  final int start;
  final int length;
  int get end => start + length;
  @override
  String toString() => 'ScanWindow($start, $length)';
}

List<ScanWindow> forwardWindows({
  required int from,
  required int fileSize,
  required int chunk,
  required int patternLength,
}) {
  assert(chunk >= patternLength);
  final out = <ScanWindow>[];
  var start = from < 0 ? 0 : from;
  while (start + patternLength <= fileSize) {
    final len = (start + chunk > fileSize ? fileSize - start : chunk);
    out.add(ScanWindow(start, len));
    if (start + len >= fileSize) break;
    start += len - (patternLength - 1);
  }
  return out;
}

/// Windows scanning backwards; each window ends at or before [from] +
/// patternLength (so a match starting at [from] is included).
List<ScanWindow> backwardWindows({
  required int from,
  required int fileSize,
  required int chunk,
  required int patternLength,
}) {
  assert(chunk >= patternLength);
  final out = <ScanWindow>[];
  var end = (from + patternLength).clamp(0, fileSize);
  while (end >= patternLength) {
    final start = end - chunk < 0 ? 0 : end - chunk;
    out.add(ScanWindow(start, end - start));
    if (start == 0) break;
    end = start + patternLength - 1;
  }
  return out;
}
