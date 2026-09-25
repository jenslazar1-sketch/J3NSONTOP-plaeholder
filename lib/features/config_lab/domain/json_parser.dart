/// Strict RFC 8259 JSON parser.
///
/// Unlike `jsonDecode` it reports *why* input is invalid with an exact
/// offset (trailing commas, comments, single quotes, unquoted keys, leading
/// zeros, raw line breaks in strings...), detects duplicate object keys and
/// flags numbers that cannot be represented exactly. Values are produced as
/// `Map<String, Object?>` (insertion ordered), `List<Object?>`, `String`,
/// `int`, `double`, `bool` and `null`, matching `jsonDecode` for valid input
/// (duplicate keys: the last value wins, at the position of the first key).
library;

import 'json_value.dart';

/// A syntax error. [offset] is the character offset of the problem.
class JsonSyntaxError extends FormatException {
  const JsonSyntaxError(super.message, String super.source, int super.offset);

  @override
  int get offset => super.offset!;
}

/// A key that appeared more than once in the same object.
class JsonDuplicateKey {
  const JsonDuplicateKey({required this.path, required this.key, required this.offset, required this.firstOffset});

  /// Path of the duplicated property (parent path + key).
  final List<Object> path;
  final String key;

  /// Offset of the later (winning) occurrence.
  final int offset;

  /// Offset of the first occurrence.
  final int firstOffset;
}

/// A number whose value is not represented exactly.
class JsonNumberNote {
  const JsonNumberNote({required this.path, required this.literal, required this.message, required this.offset});
  final List<Object> path;
  final String literal;
  final String message;
  final int offset;
}

class JsonParseOutput {
  const JsonParseOutput({
    required this.value,
    this.duplicates = const [],
    this.numberNotes = const [],
    this.hadBom = false,
    this.positions,
  });

  /// JSON Pointer -> offset of each value (only when requested).
  final Map<String, int>? positions;

  final Object? value;
  final List<JsonDuplicateKey> duplicates;
  final List<JsonNumberNote> numberNotes;

  /// The text started with U+FEFF, which was skipped.
  final bool hadBom;
}

/// Maximum nesting depth accepted by [parseJsonStrict].
const int kJsonMaxDepth = 512;

/// 2^53: integers above this lose precision in JavaScript-based tools.
const int kJsSafeInteger = 9007199254740991;

/// Parses [text] or throws [JsonSyntaxError]. With [recordPositions], the
/// output maps every value's JSON Pointer to its offset.
JsonParseOutput parseJsonStrict(String text, {int maxDepth = kJsonMaxDepth, bool recordPositions = false}) =>
    _JsonParser(text, maxDepth, recordPositions ? <String, int>{} : null).parse();

/// Parses and returns only the value (throws [JsonSyntaxError]).
Object? decodeJsonStrict(String text) => parseJsonStrict(text).value;

class _JsonParser {
  _JsonParser(this.s, this.maxDepth, this._positions);

  final String s;
  final int maxDepth;
  final Map<String, int>? _positions;
  int i = 0;
  final List<Object> _path = [];
  final List<JsonDuplicateKey> _dups = [];
  final List<JsonNumberNote> _notes = [];

  Never _fail(String message, [int? at]) => throw JsonSyntaxError(message, s, at ?? i);

  JsonParseOutput parse() {
    var bom = false;
    if (s.isNotEmpty && s.codeUnitAt(0) == 0xFEFF) {
      bom = true;
      i = 1;
    }
    _skipWs();
    if (i >= s.length) _fail('Empty input: expected a JSON value');
    final value = _value(0);
    _skipWs();
    if (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 0x2C) _fail('Unexpected "," after the JSON value (only one top-level value is allowed)');
      _fail('Unexpected text after the JSON value');
    }
    return JsonParseOutput(value: value, duplicates: _dups, numberNotes: _notes, hadBom: bom, positions: _positions);
  }

  void _skipWs() {
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
        i++;
      } else if (c == 0x2F && i + 1 < s.length && (s.codeUnitAt(i + 1) == 0x2F || s.codeUnitAt(i + 1) == 0x2A)) {
        _fail('Comments are not allowed in JSON');
      } else {
        return;
      }
    }
  }

  Object? _value(int depth) {
    if (depth > maxDepth) _fail('Nesting deeper than $maxDepth levels is not supported');
    if (i >= s.length) _fail('Unexpected end of input: expected a value');
    _positions?[formatJsonPointer(_path)] = i;
    final c = s.codeUnitAt(i);
    switch (c) {
      case 0x7B: // {
        return _object(depth);
      case 0x5B: // [
        return _array(depth);
      case 0x22: // "
        return _string();
      case 0x74: // t
        return _literal('true', true);
      case 0x66: // f
        return _literal('false', false);
      case 0x6E: // n
        return _literal('null', null);
      case 0x2D: // -
        return _number();
      case 0x27: // '
        _fail('Single quotes are not allowed in JSON; use double quotes');
      case 0x2B: // +
        _fail('Numbers must not start with "+"');
      case 0x2E: // .
        _fail('Numbers must start with a digit (write 0.5, not .5)');
      case 0x5D || 0x7D: // ] }
        _fail('Unexpected "${String.fromCharCode(c)}": expected a value');
      case 0x2C: // ,
        _fail('Unexpected ",": expected a value');
    }
    if (c >= 0x30 && c <= 0x39) return _number();
    final word = _wordAt(i);
    switch (word) {
      case 'True' || 'TRUE' || 'False' || 'FALSE' || 'Null' || 'NULL' || 'None':
        _fail('"$word" is not valid JSON: literals are lowercase (true, false, null)');
      case 'NaN' || 'Infinity' || 'undefined':
        _fail('"$word" is not a valid JSON value');
    }
    _fail('Unexpected character ${_describeChar(c)}: expected a value');
  }

  String _wordAt(int at) {
    var e = at;
    while (e < s.length && _isWordChar(s.codeUnitAt(e))) {
      e++;
    }
    return s.substring(at, e);
  }

  static bool _isWordChar(int c) =>
      (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x24;

  static String _describeChar(int c) {
    final hex = c.toRadixString(16).toUpperCase().padLeft(4, '0');
    if (c < 0x20 || c == 0x7F) return 'U+$hex (control character)';
    if (c == 0xA0) return 'U+00A0 (no-break space)';
    if (c == 0xFEFF) return 'U+FEFF (byte order mark)';
    return '"${String.fromCharCode(c)}" (U+$hex)';
  }

  Object? _literal(String word, Object? value) {
    if (s.startsWith(word, i) && (i + word.length >= s.length || !_isWordChar(s.codeUnitAt(i + word.length)))) {
      i += word.length;
      return value;
    }
    final got = _wordAt(i);
    _fail('Invalid literal "${got.isEmpty ? s[i] : got}": expected $word');
  }

  Map<String, Object?> _object(int depth) {
    final open = i;
    i++; // {
    final map = <String, Object?>{};
    final keyOffsets = <String, int>{};
    _skipWs();
    if (i < s.length && s.codeUnitAt(i) == 0x7D) {
      i++;
      return map;
    }
    while (true) {
      _skipWs();
      if (i >= s.length) _fail('Unterminated object (opened at offset $open): expected a property name');
      final c = s.codeUnitAt(i);
      if (c != 0x22) {
        if (c == 0x7D) _fail('Trailing comma is not allowed in JSON', _lastComma(i));
        if (c == 0x27) _fail('Property names must use double quotes, not single quotes');
        if (_isWordChar(c)) _fail('Property names must be double-quoted strings (found unquoted "${_wordAt(i)}")');
        _fail('Unexpected character ${_describeChar(c)}: expected a property name in double quotes');
      }
      final keyOffset = i;
      final key = _string();
      _skipWs();
      if (i >= s.length) _fail('Unexpected end of input: expected ":" after property name');
      if (s.codeUnitAt(i) != 0x3A) {
        if (s.codeUnitAt(i) == 0x3D) _fail('Expected ":" after property name, found "="');
        _fail('Expected ":" after property name');
      }
      i++;
      _skipWs();
      _path.add(key);
      final value = _value(depth + 1);
      _path.removeLast();
      final first = keyOffsets[key];
      if (first != null) {
        _dups.add(JsonDuplicateKey(path: [..._path, key], key: key, offset: keyOffset, firstOffset: first));
      } else {
        keyOffsets[key] = keyOffset;
      }
      map[key] = value;
      _skipWs();
      if (i >= s.length) _fail('Unterminated object (opened at offset $open): expected "," or "}"');
      final d = s.codeUnitAt(i);
      if (d == 0x2C) {
        i++;
        continue;
      }
      if (d == 0x7D) {
        i++;
        return map;
      }
      if (d == 0x22) _fail('Expected "," between properties');
      _fail('Expected "," or "}" after property value, found ${_describeChar(d)}');
    }
  }

  List<Object?> _array(int depth) {
    final open = i;
    i++; // [
    final list = <Object?>[];
    _skipWs();
    if (i < s.length && s.codeUnitAt(i) == 0x5D) {
      i++;
      return list;
    }
    while (true) {
      _skipWs();
      if (i >= s.length) _fail('Unterminated array (opened at offset $open): expected a value');
      if (s.codeUnitAt(i) == 0x5D) _fail('Trailing comma is not allowed in JSON', _lastComma(i));
      _path.add(list.length);
      list.add(_value(depth + 1));
      _path.removeLast();
      _skipWs();
      if (i >= s.length) _fail('Unterminated array (opened at offset $open): expected "," or "]"');
      final d = s.codeUnitAt(i);
      if (d == 0x2C) {
        i++;
        continue;
      }
      if (d == 0x5D) {
        i++;
        return list;
      }
      _fail('Expected "," or "]" after array item, found ${_describeChar(d)}');
    }
  }

  int _lastComma(int from) {
    var j = from - 1;
    while (j >= 0) {
      final c = s.codeUnitAt(j);
      if (c == 0x2C) return j;
      if (c != 0x20 && c != 0x09 && c != 0x0A && c != 0x0D) break;
      j--;
    }
    return from;
  }

  String _string() {
    final start = i;
    i++; // opening quote
    StringBuffer? buf;
    var runStart = i;
    while (true) {
      if (i >= s.length) _fail('Unterminated string', start);
      final c = s.codeUnitAt(i);
      if (c == 0x22) {
        final tail = s.substring(runStart, i);
        i++;
        if (buf == null) return tail;
        buf.write(tail);
        return buf.toString();
      }
      if (c == 0x5C) {
        buf ??= StringBuffer();
        buf.write(s.substring(runStart, i));
        if (i + 1 >= s.length) _fail('Unterminated escape sequence', i);
        final e = s.codeUnitAt(i + 1);
        switch (e) {
          case 0x22:
            buf.writeCharCode(0x22);
          case 0x5C:
            buf.writeCharCode(0x5C);
          case 0x2F:
            buf.writeCharCode(0x2F);
          case 0x62:
            buf.writeCharCode(0x08);
          case 0x66:
            buf.writeCharCode(0x0C);
          case 0x6E:
            buf.writeCharCode(0x0A);
          case 0x72:
            buf.writeCharCode(0x0D);
          case 0x74:
            buf.writeCharCode(0x09);
          case 0x75:
            if (i + 6 > s.length) _fail(r'Invalid \u escape: expected 4 hex digits', i);
            final hex = s.substring(i + 2, i + 6);
            final code = int.tryParse(hex, radix: 16);
            if (code == null || !RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(hex)) {
              _fail(r'Invalid \u escape: expected 4 hex digits', i);
            }
            buf.writeCharCode(code);
            i += 4;
          default:
            _fail('Invalid escape sequence "\\${String.fromCharCode(e)}"', i);
        }
        i += 2;
        runStart = i;
        continue;
      }
      if (c < 0x20) {
        if (c == 0x0A || c == 0x0D) _fail(r'Unescaped line break inside a string (use \n)', i);
        if (c == 0x09) _fail(r'Unescaped tab inside a string (use \t)', i);
        _fail('Control character ${_describeChar(c)} must be escaped inside strings', i);
      }
      i++;
    }
  }

  static bool _digit(int c) => c >= 0x30 && c <= 0x39;

  num _number() {
    final start = i;
    if (s.codeUnitAt(i) == 0x2D) {
      i++;
      if (i >= s.length || !_digit(s.codeUnitAt(i))) {
        if (s.startsWith('Infinity', i)) _fail('"-Infinity" is not a valid JSON value', start);
        _fail('Expected a digit after "-"');
      }
    }
    if (s.codeUnitAt(i) == 0x30) {
      i++;
      if (i < s.length && _digit(s.codeUnitAt(i))) _fail('Leading zeros are not allowed in numbers', start);
    } else {
      while (i < s.length && _digit(s.codeUnitAt(i))) {
        i++;
      }
    }
    var isFloat = false;
    if (i < s.length && s.codeUnitAt(i) == 0x2E) {
      isFloat = true;
      i++;
      if (i >= s.length || !_digit(s.codeUnitAt(i))) _fail('Expected a digit after the decimal point');
      while (i < s.length && _digit(s.codeUnitAt(i))) {
        i++;
      }
    }
    if (i < s.length && (s.codeUnitAt(i) == 0x65 || s.codeUnitAt(i) == 0x45)) {
      isFloat = true;
      i++;
      if (i < s.length && (s.codeUnitAt(i) == 0x2B || s.codeUnitAt(i) == 0x2D)) i++;
      if (i >= s.length || !_digit(s.codeUnitAt(i))) _fail('Expected a digit in the exponent');
      while (i < s.length && _digit(s.codeUnitAt(i))) {
        i++;
      }
    }
    if (i < s.length && _isWordChar(s.codeUnitAt(i))) {
      _fail('Unexpected character ${_describeChar(s.codeUnitAt(i))} in number');
    }
    final lit = s.substring(start, i);
    if (!isFloat) {
      final v = int.tryParse(lit);
      if (v != null) {
        if (lit == '-0') {
          _notes.add(JsonNumberNote(path: [..._path], literal: lit, message: '-0 is read as 0', offset: start));
        } else if (v > kJsSafeInteger || v < -kJsSafeInteger) {
          _notes.add(
            JsonNumberNote(
              path: [..._path],
              literal: lit,
              message: 'Integer beyond 2^53: exact here, but JavaScript-based tools may round it',
              offset: start,
            ),
          );
        }
        return v;
      }
      final d = double.parse(lit);
      _notes.add(
        JsonNumberNote(
          path: [..._path],
          literal: lit,
          message: 'Integer does not fit in 64 bits; stored as floating point ${jsonPreview(d)} (precision lost)',
          offset: start,
        ),
      );
      return d;
    }
    final d = double.parse(lit);
    if (!d.isFinite) _fail('Number $lit is out of range (overflows to infinity)', start);
    final digits = lit.split(RegExp('[eE]')).first.replaceAll(RegExp(r'[-.]'), '').replaceFirst(RegExp('^0+'), '');
    if (digits.length > 17) {
      _notes.add(
        JsonNumberNote(
          path: [..._path],
          literal: lit,
          message: 'More than 17 significant digits: rounded to ${jsonPreview(d)}',
          offset: start,
        ),
      );
    }
    return d;
  }
}
