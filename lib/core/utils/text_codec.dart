import 'dart:convert';
import 'dart:typed_data';

/// Line ending styles.
enum LineEnding {
  lf('LF', '\n'),
  crlf('CRLF', '\r\n'),
  cr('CR', '\r'),
  mixed('Mixed', '\n'),
  none('None', '\n');

  const LineEnding(this.label, this.sequence);
  final String label;
  final String sequence;
}

/// Encodings the app can decode/encode losslessly.
enum TextEncodingKind { utf8, utf8Bom, utf16le, utf16be, latin1 }

/// Result of decoding bytes as text.
class DecodedText {
  const DecodedText({required this.text, required this.encoding, required this.hadMalformedBytes});

  final String text;
  final TextEncodingKind encoding;

  /// True when the bytes were not valid in the detected encoding and were
  /// decoded as Latin-1 instead. Saving back as UTF-8 would change bytes.
  final bool hadMalformedBytes;

  String get encodingLabel => switch (encoding) {
    TextEncodingKind.utf8 => 'UTF-8',
    TextEncodingKind.utf8Bom => 'UTF-8 with BOM',
    TextEncodingKind.utf16le => 'UTF-16 LE',
    TextEncodingKind.utf16be => 'UTF-16 BE',
    TextEncodingKind.latin1 => 'Latin-1 (fallback)',
  };
}

abstract final class TextCodec {
  /// Heuristic binary detection: NUL bytes (outside UTF-16) or a high share
  /// of control characters in the first 8 KiB.
  static bool looksBinary(List<int> bytes) {
    if (bytes.isEmpty) return false;
    if (_utf16Bom(bytes) != null) return false;
    final n = bytes.length < 8192 ? bytes.length : 8192;
    var control = 0;
    for (var i = 0; i < n; i++) {
      final b = bytes[i];
      if (b == 0) return true;
      if (b < 7 || (b > 13 && b < 32 && b != 27)) control++;
    }
    return control / n > 0.1;
  }

  static TextEncodingKind? _utf16Bom(List<int> b) {
    if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
      return TextEncodingKind.utf16le;
    }
    if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
      return TextEncodingKind.utf16be;
    }
    return null;
  }

  /// Decodes bytes, detecting BOMs. Invalid UTF-8 falls back to Latin-1 and
  /// sets [DecodedText.hadMalformedBytes] so the UI can warn before saving.
  static DecodedText decode(List<int> bytes) {
    final utf16 = _utf16Bom(bytes);
    if (utf16 != null) {
      final body = bytes.sublist(2);
      final units = <int>[];
      for (var i = 0; i + 1 < body.length; i += 2) {
        units.add(utf16 == TextEncodingKind.utf16le ? body[i] | (body[i + 1] << 8) : (body[i] << 8) | body[i + 1]);
      }
      return DecodedText(text: String.fromCharCodes(units), encoding: utf16, hadMalformedBytes: body.length.isOdd);
    }
    final hasBom = bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
    final body = hasBom ? bytes.sublist(3) : bytes;
    try {
      return DecodedText(
        text: utf8.decode(body),
        encoding: hasBom ? TextEncodingKind.utf8Bom : TextEncodingKind.utf8,
        hadMalformedBytes: false,
      );
    } on FormatException {
      return DecodedText(text: latin1.decode(body), encoding: TextEncodingKind.latin1, hadMalformedBytes: true);
    }
  }

  /// Encodes [text] with [encoding] (Latin-1 falls back to UTF-8 when the
  /// text contains characters outside Latin-1).
  static Uint8List encode(String text, TextEncodingKind encoding) {
    switch (encoding) {
      case TextEncodingKind.utf8:
        return Uint8List.fromList(utf8.encode(text));
      case TextEncodingKind.utf8Bom:
        return Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(text)]);
      case TextEncodingKind.utf16le:
      case TextEncodingKind.utf16be:
        final out = BytesBuilder();
        out.add(encoding == TextEncodingKind.utf16le ? [0xFF, 0xFE] : [0xFE, 0xFF]);
        for (final unit in text.codeUnits) {
          if (encoding == TextEncodingKind.utf16le) {
            out.add([unit & 0xFF, unit >> 8]);
          } else {
            out.add([unit >> 8, unit & 0xFF]);
          }
        }
        return out.toBytes();
      case TextEncodingKind.latin1:
        if (text.codeUnits.every((c) => c < 256)) {
          return Uint8List.fromList(latin1.encode(text));
        }
        return Uint8List.fromList(utf8.encode(text));
    }
  }

  static LineEnding detectLineEnding(String text) {
    var lf = 0, crlf = 0, cr = 0;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c == 13) {
        if (i + 1 < text.length && text.codeUnitAt(i + 1) == 10) {
          crlf++;
          i++;
        } else {
          cr++;
        }
      } else if (c == 10) {
        lf++;
      }
    }
    final kinds = [lf > 0, crlf > 0, cr > 0].where((b) => b).length;
    if (kinds == 0) return LineEnding.none;
    if (kinds > 1) return LineEnding.mixed;
    if (crlf > 0) return LineEnding.crlf;
    if (cr > 0) return LineEnding.cr;
    return LineEnding.lf;
  }

  /// Splits text into lines, accepting LF, CRLF and CR.
  static List<String> splitLines(String text) => text.split(RegExp(r'\r\n|\r|\n'));

  /// 1-based line and column for a character [offset] in [text].
  static (int line, int column) lineColumn(String text, int offset) {
    var line = 1, col = 1;
    final end = offset.clamp(0, text.length);
    for (var i = 0; i < end; i++) {
      final c = text.codeUnitAt(i);
      if (c == 10) {
        line++;
        col = 1;
      } else if (c == 13) {
        if (i + 1 < end && text.codeUnitAt(i + 1) == 10) continue;
        line++;
        col = 1;
      } else {
        col++;
      }
    }
    return (line, col);
  }
}
