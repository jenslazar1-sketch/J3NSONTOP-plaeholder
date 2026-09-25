import 'dart:convert';
import 'dart:typed_data';

import 'common.dart';

enum Base64Alphabet {
  standard('Standard', 'A-Z a-z 0-9 + /'),
  urlSafe('URL-safe', 'A-Z a-z 0-9 - _');

  const Base64Alphabet(this.label, this.characters);
  final String label;
  final String characters;
}

/// Result of decoding Base64 text.
class Base64Decoded {
  const Base64Decoded({
    required this.bytes,
    required this.alphabet,
    required this.hadPadding,
    required this.ignoredWhitespace,
    this.dataUriMime,
    this.warnings = const [],
  });

  final Uint8List bytes;

  /// Alphabet found in the input (standard when neither `+/` nor `-_` occur).
  final Base64Alphabet alphabet;
  final bool hadPadding;

  /// Number of whitespace/line-break characters that were skipped.
  final int ignoredWhitespace;

  /// Media type when the input was a `data:<mime>;base64,` URI.
  final String? dataUriMime;
  final List<String> warnings;

  /// Byte offset of the first invalid UTF-8 sequence, or null if the bytes
  /// are valid UTF-8 text.
  int? get invalidUtf8Offset => firstInvalidUtf8(bytes);

  /// The decoded bytes as text, or null when they are not valid UTF-8.
  String? get text => invalidUtf8Offset == null ? utf8.decode(bytes) : null;
}

/// Base64 encoding/decoding shared by the Base64 tool, the JWT decoder and
/// the `b64` terminal command.
abstract final class Base64Tools {
  /// Maximum file size accepted by "File -> Base64".
  static const int maxFileBytes = 10 * 1024 * 1024;

  static String encodeText(String text, {bool urlSafe = false, bool padding = true, int lineLength = 0}) =>
      encodeBytes(utf8.encode(text), urlSafe: urlSafe, padding: padding, lineLength: lineLength);

  /// Encodes [bytes]. [lineLength] > 0 wraps output lines (76 = MIME,
  /// 64 = PEM); wrapping never splits padding from its group.
  static String encodeBytes(List<int> bytes, {bool urlSafe = false, bool padding = true, int lineLength = 0}) {
    var s = urlSafe ? base64Url.encode(bytes) : base64.encode(bytes);
    if (!padding) {
      var end = s.length;
      while (end > 0 && s.codeUnitAt(end - 1) == 0x3D) {
        end--;
      }
      s = s.substring(0, end);
    }
    if (lineLength <= 0 || s.length <= lineLength) return s;
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i += lineLength) {
      if (i > 0) buf.write('\n');
      buf.write(s.substring(i, i + lineLength > s.length ? s.length : i + lineLength));
    }
    return buf.toString();
  }

  static final RegExp _dataUri = RegExp(r'^\s*data:([^,;]*)((?:;[^,;]*)*);base64,', caseSensitive: false);

  static int _value(int c) {
    if (c >= 0x41 && c <= 0x5A) return c - 0x41; // A-Z
    if (c >= 0x61 && c <= 0x7A) return c - 0x61 + 26; // a-z
    if (c >= 0x30 && c <= 0x39) return c - 0x30 + 52; // 0-9
    if (c == 0x2B || c == 0x2D) return 62; // + or -
    if (c == 0x2F || c == 0x5F) return 63; // / or _
    return -1;
  }

  static bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C || c == 0x0B;

  /// Decodes Base64 in either alphabet, tolerating whitespace and line
  /// breaks anywhere, missing padding and a `data:...;base64,` prefix.
  ///
  /// Throws [InputError] with the exact offset of an invalid character,
  /// data after padding, mixed alphabets, a truncated final group or
  /// incorrect padding.
  static Base64Decoded decode(String input) {
    var start = 0;
    String? mime;
    final m = _dataUri.firstMatch(input);
    if (m != null) {
      start = m.end;
      final t = m.group(1)!.trim();
      mime = t.isEmpty ? 'text/plain' : t;
    }

    int? firstStd, firstUrl;
    int? firstPad;
    var pads = 0;
    var whitespace = 0;
    final values = <int>[];
    final offsets = <int>[];
    for (var i = start; i < input.length; i++) {
      final c = input.codeUnitAt(i);
      if (_isSpace(c)) {
        whitespace++;
        continue;
      }
      if (c == 0x3D) {
        firstPad ??= i;
        pads++;
        continue;
      }
      final v = _value(c);
      if (v < 0) {
        throw InputError(
          'Invalid Base64 character ${describeCharAt(input, i)}',
          offset: i,
          source: input,
          hint: 'Base64 uses A-Z, a-z, 0-9 and either "+ /" (standard) or "- _" (URL-safe), plus "=" padding.',
        );
      }
      if (firstPad != null) {
        throw InputError(
          'Data after padding: ${describeCharAt(input, i)} follows "="',
          offset: i,
          source: input,
          hint: 'Padding "=" may only appear at the very end. Were two Base64 strings concatenated?',
        );
      }
      if (c == 0x2B || c == 0x2F) {
        firstStd ??= i;
        if (firstUrl != null) {
          throw InputError(
            'Mixed alphabets: standard character ${describeCharAt(input, i)} after URL-safe '
            '${describeCharAt(input, firstUrl)}',
            offset: i,
            source: input,
          );
        }
      } else if (c == 0x2D || c == 0x5F) {
        firstUrl ??= i;
        if (firstStd != null) {
          throw InputError(
            'Mixed alphabets: URL-safe character ${describeCharAt(input, i)} after standard '
            '${describeCharAt(input, firstStd)}',
            offset: i,
            source: input,
          );
        }
      }
      values.add(v);
      offsets.add(i);
    }

    final n = values.length;
    final rem = n % 4;
    if (rem == 1) {
      throw InputError(
        'Truncated input: the final group has a single character (${n % 4} of 4)',
        offset: offsets.last,
        source: input,
        hint: 'A Base64 group needs at least 2 characters. Part of the text is probably missing.',
      );
    }
    if (pads > 0) {
      final expected = rem == 0 ? 0 : 4 - rem;
      if (pads != expected) {
        throw InputError('Incorrect padding: expected $expected "=" but found $pads', offset: firstPad, source: input);
      }
    }

    final warnings = <String>[];
    final out = Uint8List(n * 3 ~/ 4);
    var o = 0;
    var i = 0;
    for (; i + 4 <= n; i += 4) {
      final x = (values[i] << 18) | (values[i + 1] << 12) | (values[i + 2] << 6) | values[i + 3];
      out[o++] = (x >> 16) & 0xFF;
      out[o++] = (x >> 8) & 0xFF;
      out[o++] = x & 0xFF;
    }
    if (rem == 2) {
      final x = (values[i] << 18) | (values[i + 1] << 12);
      out[o++] = (x >> 16) & 0xFF;
      if (values[i + 1] & 0x0F != 0) {
        warnings.add(
          'Non-canonical ending: unused bits of ${describeCharAt(input, offsets[i + 1])} '
          'at offset ${offsets[i + 1]} are not zero (ignored).',
        );
      }
    } else if (rem == 3) {
      final x = (values[i] << 18) | (values[i + 1] << 12) | (values[i + 2] << 6);
      out[o++] = (x >> 16) & 0xFF;
      out[o++] = (x >> 8) & 0xFF;
      if (values[i + 2] & 0x03 != 0) {
        warnings.add(
          'Non-canonical ending: unused bits of ${describeCharAt(input, offsets[i + 2])} '
          'at offset ${offsets[i + 2]} are not zero (ignored).',
        );
      }
    }
    return Base64Decoded(
      bytes: out,
      alphabet: firstUrl != null ? Base64Alphabet.urlSafe : Base64Alphabet.standard,
      hadPadding: pads > 0,
      ignoredWhitespace: whitespace,
      dataUriMime: mime,
      warnings: warnings,
    );
  }
}
