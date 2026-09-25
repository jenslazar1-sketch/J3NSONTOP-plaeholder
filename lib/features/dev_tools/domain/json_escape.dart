import 'common.dart';

class JsonEscapeOptions {
  const JsonEscapeOptions({this.quotes = true, this.asciiOnly = false, this.escapeSlash = false});

  /// Wrap the result in double quotes (a complete JSON string literal).
  final bool quotes;

  /// Escape every non-ASCII character as `\uXXXX` (surrogate pairs for
  /// characters outside the BMP).
  final bool asciiOnly;

  /// Escape `/` as `\/` (safe inside an HTML `<script>` block).
  final bool escapeSlash;
}

class JsonUnescaped {
  const JsonUnescaped({required this.text, required this.hadQuotes, this.warnings = const []});
  final String text;
  final bool hadQuotes;
  final List<String> warnings;
}

abstract final class JsonEscape {
  static String _u(int unit) => '\\u${unit.toRadixString(16).padLeft(4, '0')}';

  /// Escapes [text] as JSON string content. U+2028/U+2029 are always
  /// escaped so the result is also safe inside JavaScript source.
  static String escape(String text, [JsonEscapeOptions options = const JsonEscapeOptions()]) {
    final out = StringBuffer();
    if (options.quotes) out.write('"');
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      switch (c) {
        case 0x22:
          out.write(r'\"');
        case 0x5C:
          out.write(r'\\');
        case 0x08:
          out.write(r'\b');
        case 0x0C:
          out.write(r'\f');
        case 0x0A:
          out.write(r'\n');
        case 0x0D:
          out.write(r'\r');
        case 0x09:
          out.write(r'\t');
        case 0x2F when options.escapeSlash:
          out.write(r'\/');
        default:
          if (c < 0x20 || c == 0x2028 || c == 0x2029 || (c >= 0x7F && options.asciiOnly)) {
            out.write(_u(c));
          } else if (c >= 0xD800 && c <= 0xDFFF) {
            // Lone surrogates are not valid Unicode text; escape them so the
            // output stays valid (and visible).
            final pair =
                c <= 0xDBFF &&
                i + 1 < text.length &&
                text.codeUnitAt(i + 1) >= 0xDC00 &&
                text.codeUnitAt(i + 1) <= 0xDFFF;
            if (pair && !options.asciiOnly) {
              out.writeCharCode(c);
              out.writeCharCode(text.codeUnitAt(++i));
            } else {
              out.write(_u(c));
            }
          } else {
            out.writeCharCode(c);
          }
      }
    }
    if (options.quotes) out.write('"');
    return out.toString();
  }

  static int _hex(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
    return -1;
  }

  /// Unescapes a JSON string literal, with or without its surrounding
  /// quotes. Strict: raw control characters, unknown escapes, short `\u`
  /// escapes and (when quoted) unescaped inner quotes are errors with the
  /// exact position.
  static JsonUnescaped unescape(String input) {
    var start = 0, end = input.length;
    while (start < end && _isWs(input.codeUnitAt(start))) {
      start++;
    }
    while (end > start && _isWs(input.codeUnitAt(end - 1))) {
      end--;
    }
    var quoted = false;
    if (end - start >= 1 && input.codeUnitAt(start) == 0x22) {
      if (end - start < 2 || input.codeUnitAt(end - 1) != 0x22 || _escapedAt(input, start, end - 1)) {
        throw InputError(
          'Opening quote without a matching closing quote',
          offset: start,
          source: input,
          hint: 'Paste the whole literal including both quotes, or remove the opening quote.',
        );
      }
      quoted = true;
      start++;
      end--;
    }
    final out = StringBuffer();
    final warnings = <String>[];
    var lastUnit = -1;
    for (var i = start; i < end; i++) {
      final c = input.codeUnitAt(i);
      if (c == 0x5C) {
        if (i + 1 >= end) {
          throw InputError('Backslash at the end of the string (incomplete escape)', offset: i, source: input);
        }
        final e = input.codeUnitAt(i + 1);
        switch (e) {
          case 0x22:
            out.write('"');
          case 0x5C:
            out.write(r'\');
          case 0x2F:
            out.write('/');
          case 0x62:
            out.writeCharCode(0x08);
          case 0x66:
            out.writeCharCode(0x0C);
          case 0x6E:
            out.writeCharCode(0x0A);
          case 0x72:
            out.writeCharCode(0x0D);
          case 0x74:
            out.writeCharCode(0x09);
          case 0x75:
            var v = 0;
            for (var k = 0; k < 4; k++) {
              final at = i + 2 + k;
              final h = at < end ? _hex(input.codeUnitAt(at)) : -1;
              if (h < 0) {
                throw InputError(
                  at < end
                      ? r'Invalid \u escape: expected 4 hex digits, found '
                            '${describeCharAt(input, at)}'
                      : r'Incomplete \u escape: expected 4 hex digits',
                  offset: i,
                  source: input,
                );
              }
              v = v * 16 + h;
            }
            if (v >= 0xD800 && v <= 0xDBFF) {
              final lowOk =
                  i + 7 < end &&
                  input.codeUnitAt(i + 6) == 0x5C &&
                  input.codeUnitAt(i + 7) == 0x75 &&
                  _lowSurrogateAt(input, i + 8, end);
              if (!lowOk) warnings.add('Lone high surrogate \\u${v.toRadixString(16)} at offset $i.');
            } else if (v >= 0xDC00 && v <= 0xDFFF) {
              final prevHigh = lastUnit >= 0xD800 && lastUnit <= 0xDBFF;
              if (!prevHigh) warnings.add('Lone low surrogate \\u${v.toRadixString(16)} at offset $i.');
            }
            out.writeCharCode(v);
            lastUnit = v;
            i += 5; // "u" + 4 hex digits; the loop skips the backslash
            continue;
          default:
            throw InputError(
              'Invalid escape sequence "\\${String.fromCharCode(e)}"',
              offset: i,
              source: input,
              hint: r'JSON only allows \" \\ \/ \b \f \n \r \t and \uXXXX.',
            );
        }
        lastUnit = -1;
        i++;
        continue;
      }
      if (c < 0x20) {
        throw InputError(
          'Unescaped control character ${describeCharAt(input, i)}',
          offset: i,
          source: input,
          hint: r'JSON strings must escape control characters, e.g. a line break as \n.',
        );
      }
      if (c == 0x22 && quoted) {
        throw InputError(
          'Unescaped double quote inside the string',
          offset: i,
          source: input,
          hint: r'Write \" instead.',
        );
      }
      out.writeCharCode(c);
      lastUnit = c;
    }
    return JsonUnescaped(text: out.toString(), hadQuotes: quoted, warnings: warnings);
  }

  static bool _isWs(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

  /// Whether the quote at [quoteAt] is escaped by an odd run of backslashes.
  static bool _escapedAt(String s, int from, int quoteAt) {
    var n = 0;
    for (var i = quoteAt - 1; i > from && s.codeUnitAt(i) == 0x5C; i--) {
      n++;
    }
    return n.isOdd;
  }

  static bool _lowSurrogateAt(String s, int at, int end) {
    if (at + 4 > end) return false;
    var v = 0;
    for (var k = 0; k < 4; k++) {
      final h = _hex(s.codeUnitAt(at + k));
      if (h < 0) return false;
      v = v * 16 + h;
    }
    return v >= 0xDC00 && v <= 0xDFFF;
  }
}
