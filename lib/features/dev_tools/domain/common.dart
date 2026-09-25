import 'dart:typed_data';

import '../../../core/utils/text_codec.dart';

/// Malformed user input with a precise location.
///
/// [offset] is a 0-based UTF-16 index into [source]; the UI turns it into a
/// 1-based line/column and can move the caret there.
class InputError implements Exception {
  const InputError(this.message, {this.offset, this.source, this.hint});

  final String message;
  final int? offset;
  final String? source;

  /// Optional advice on how to fix the input.
  final String? hint;

  /// 1-based (line, column) of [offset] inside [source].
  (int, int)? get lineColumn {
    final o = offset, s = source;
    if (o == null || s == null) return null;
    return TextCodec.lineColumn(s, o);
  }

  /// "line 2, column 5 (offset 17)" or "offset 17" or "".
  String get position {
    final o = offset;
    if (o == null) return '';
    final lc = lineColumn;
    if (lc == null) return 'offset $o';
    return 'line ${lc.$1}, column ${lc.$2} (offset $o)';
  }

  @override
  String toString() => offset == null ? message : '$message at $position';
}

/// Human description of the character (code point) at [offset]:
/// `'x' (U+0078)` or `U+000A LINE FEED`.
String describeCharAt(String s, int offset) {
  if (offset < 0 || offset >= s.length) return 'end of input';
  var cp = s.codeUnitAt(offset);
  if (cp >= 0xD800 && cp <= 0xDBFF && offset + 1 < s.length) {
    final lo = s.codeUnitAt(offset + 1);
    if (lo >= 0xDC00 && lo <= 0xDFFF) cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
  }
  return describeCodePoint(cp);
}

String describeCodePoint(int cp) {
  final hex = 'U+${cp.toRadixString(16).toUpperCase().padLeft(4, '0')}';
  const names = {
    0x00: 'NUL',
    0x09: 'TAB',
    0x0A: 'LINE FEED',
    0x0D: 'CARRIAGE RETURN',
    0x20: 'SPACE',
    0xA0: 'NO-BREAK SPACE',
    0xFEFF: 'BYTE ORDER MARK',
    0x200B: 'ZERO WIDTH SPACE',
  };
  final name = names[cp];
  if (name != null) return '$hex $name';
  if (cp < 0x20 || cp == 0x7F || (cp >= 0x80 && cp < 0xA0)) return '$hex (control character)';
  if (cp >= 0xD800 && cp <= 0xDFFF) return '$hex (lone surrogate)';
  return "'${String.fromCharCode(cp)}' ($hex)";
}

/// Validates UTF-8 and returns the byte offset where the first invalid
/// sequence starts, or null when [bytes] are valid UTF-8. Rejects overlong
/// forms, UTF-16 surrogates and code points above U+10FFFF.
int? firstInvalidUtf8(List<int> bytes) {
  var i = 0;
  final n = bytes.length;
  while (i < n) {
    final b = bytes[i];
    if (b < 0x80) {
      i++;
      continue;
    }
    int need;
    int min;
    int cp;
    if (b >= 0xC2 && b <= 0xDF) {
      need = 1;
      min = 0x80;
      cp = b & 0x1F;
    } else if (b >= 0xE0 && b <= 0xEF) {
      need = 2;
      min = 0x800;
      cp = b & 0x0F;
    } else if (b >= 0xF0 && b <= 0xF4) {
      need = 3;
      min = 0x10000;
      cp = b & 0x07;
    } else {
      return i;
    }
    for (var k = 1; k <= need; k++) {
      if (i + k >= n) return i;
      final c = bytes[i + k];
      if (c & 0xC0 != 0x80) return i;
      cp = (cp << 6) | (c & 0x3F);
    }
    if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return i;
    i += need + 1;
  }
  return null;
}

/// Classic hex dump: offset, 16 hex bytes, ASCII column.
String hexDump(List<int> bytes, {int maxBytes = 512, int width = 16}) {
  final n = bytes.length < maxBytes ? bytes.length : maxBytes;
  final buf = StringBuffer();
  for (var row = 0; row < n; row += width) {
    buf.write(row.toRadixString(16).padLeft(8, '0'));
    buf.write('  ');
    final ascii = StringBuffer();
    for (var i = 0; i < width; i++) {
      final idx = row + i;
      if (idx < n) {
        final b = bytes[idx];
        buf.write(b.toRadixString(16).padLeft(2, '0'));
        ascii.writeCharCode(b >= 0x20 && b < 0x7F ? b : 0x2E);
      } else {
        buf.write('  ');
      }
      buf.write(i == width ~/ 2 - 1 ? '  ' : ' ');
    }
    buf.write('|$ascii|');
    if (row + width < n) buf.writeln();
  }
  if (bytes.length > n) {
    buf.writeln();
    buf.write('... ${bytes.length - n} more bytes');
  }
  return buf.toString();
}

/// Space-separated uppercase hex bytes: `DE AD BE EF`.
String hexBytes(List<int> bytes, {String separator = ' '}) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(separator);

/// A recognised binary file type from its leading magic bytes.
class SniffedType {
  const SniffedType(this.label, this.extension, this.mimeType);
  final String label;
  final String extension;
  final String mimeType;
}

/// Magic-byte signatures: (bytes, offset, extra bytes at offset 8, type).
const List<(List<int>, List<int>?, SniffedType)> _signatures = [
  ([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], null, SniffedType('PNG image', 'png', 'image/png')),
  ([0xFF, 0xD8, 0xFF], null, SniffedType('JPEG image', 'jpg', 'image/jpeg')),
  ([0x47, 0x49, 0x46, 0x38], null, SniffedType('GIF image', 'gif', 'image/gif')),
  ([0x52, 0x49, 0x46, 0x46], [0x57, 0x45, 0x42, 0x50], SniffedType('WebP image', 'webp', 'image/webp')),
  ([0x52, 0x49, 0x46, 0x46], [0x57, 0x41, 0x56, 0x45], SniffedType('WAV audio', 'wav', 'audio/wav')),
  ([0x42, 0x4D], null, SniffedType('BMP image', 'bmp', 'image/bmp')),
  ([0x00, 0x00, 0x01, 0x00], null, SniffedType('ICO icon', 'ico', 'image/x-icon')),
  ([0x25, 0x50, 0x44, 0x46], null, SniffedType('PDF document', 'pdf', 'application/pdf')),
  ([0x50, 0x4B, 0x03, 0x04], null, SniffedType('ZIP archive', 'zip', 'application/zip')),
  ([0x50, 0x4B, 0x05, 0x06], null, SniffedType('ZIP archive (empty)', 'zip', 'application/zip')),
  ([0x1F, 0x8B], null, SniffedType('gzip data', 'gz', 'application/gzip')),
  ([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], null, SniffedType('7-Zip archive', '7z', 'application/x-7z-compressed')),
  ([0x4F, 0x67, 0x67, 0x53], null, SniffedType('Ogg media', 'ogg', 'audio/ogg')),
  ([0x49, 0x44, 0x33], null, SniffedType('MP3 audio', 'mp3', 'audio/mpeg')),
  ([0x66, 0x4C, 0x61, 0x43], null, SniffedType('FLAC audio', 'flac', 'audio/flac')),
  ([0x00, 0x61, 0x73, 0x6D], null, SniffedType('WebAssembly module', 'wasm', 'application/wasm')),
  ([0x7F, 0x45, 0x4C, 0x46], null, SniffedType('ELF binary', 'elf', 'application/octet-stream')),
  ([0x4D, 0x5A], null, SniffedType('Windows executable (MZ)', 'exe', 'application/octet-stream')),
  ([0x53, 0x51, 0x4C, 0x69, 0x74, 0x65], null, SniffedType('SQLite database', 'sqlite', 'application/vnd.sqlite3')),
  ([0x44, 0x44, 0x53, 0x20], null, SniffedType('DDS texture', 'dds', 'image/vnd-ms.dds')),
];

/// Identifies common file formats by magic bytes (never by trusting names).
SniffedType? sniffFileType(List<int> b) {
  bool at(List<int> sig, int offset) {
    if (b.length < offset + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (b[offset + i] != sig[i]) return false;
    }
    return true;
  }

  for (final (sig, extra, type) in _signatures) {
    if (at(sig, 0) && (extra == null || at(extra, 8))) return type;
  }
  return null;
}

/// UTF-8 byte length of [s] without allocating the encoded bytes (lone
/// surrogates count as the 3-byte replacement character).
int utf8Length(String s) {
  var n = 0;
  for (final r in s.runes) {
    n += r < 0x80
        ? 1
        : r < 0x800
        ? 2
        : r < 0x10000
        ? 3
        : 4;
  }
  return n;
}

/// Converts [bytes] to a [Uint8List] without copying when possible.
Uint8List asBytes(List<int> bytes) => bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
