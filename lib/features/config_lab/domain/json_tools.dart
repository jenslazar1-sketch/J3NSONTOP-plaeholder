/// JSON Studio operations: validation analysis, formatting, minification,
/// recursive key sorting, ASCII escaping and statistics.
library;

import 'dart:convert';

import 'json_parser.dart';
import 'json_value.dart';
import 'source_location.dart';

/// Inputs larger than this are parsed with `Isolate.run` off the UI thread.
const int kSyncParseLimit = 256 * 1024;

enum JsonIndent {
  two('2 spaces', '  '),
  four('4 spaces', '    '),
  tab('Tab', '\t');

  const JsonIndent(this.label, this.unit);
  final String label;
  final String unit;

  static JsonIndent? parse(String s) => switch (s.toLowerCase()) {
    '2' || 'two' => JsonIndent.two,
    '4' || 'four' => JsonIndent.four,
    'tab' || 't' || '\\t' => JsonIndent.tab,
    _ => null,
  };
}

/// Serialises [value]. `indent == null` produces minified output.
String encodeJson(Object? value, {JsonIndent? indent = JsonIndent.two, bool ensureAscii = false}) {
  final out = indent == null ? jsonEncode(value) : JsonEncoder.withIndent(indent.unit).convert(value);
  return ensureAscii ? escapeNonAscii(out) : out;
}

/// Escapes every non-ASCII code unit as `\uXXXX`. Safe on serialised JSON
/// because non-ASCII characters can only occur inside strings.
String escapeNonAscii(String json) {
  var needs = false;
  for (var i = 0; i < json.length; i++) {
    if (json.codeUnitAt(i) > 0x7E) {
      needs = true;
      break;
    }
  }
  if (!needs) return json;
  final b = StringBuffer();
  for (var i = 0; i < json.length; i++) {
    final c = json.codeUnitAt(i);
    if (c > 0x7E) {
      b.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
    } else {
      b.writeCharCode(c);
    }
  }
  return b.toString();
}

/// Returns a copy of [value] with object keys sorted (code-unit order) at
/// every level. Array order is never changed.
Object? sortKeysDeep(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return <String, Object?>{for (final k in keys) k: sortKeysDeep(value[k])};
  }
  if (value is List<Object?>) return <Object?>[for (final v in value) sortKeysDeep(v)];
  return value;
}

class JsonStats {
  const JsonStats({
    required this.depth,
    required this.objects,
    required this.arrays,
    required this.keys,
    required this.strings,
    required this.numbers,
    required this.booleans,
    required this.nulls,
    required this.bytes,
    required this.lines,
    required this.longestArray,
  });

  /// Maximum nesting depth (a scalar document has depth 0).
  final int depth;
  final int objects;
  final int arrays;

  /// Total number of object properties.
  final int keys;
  final int strings;
  final int numbers;
  final int booleans;
  final int nulls;

  /// UTF-8 size of the text.
  final int bytes;
  final int lines;
  final int longestArray;

  int get scalars => strings + numbers + booleans + nulls;
}

JsonStats computeJsonStats(Object? root, String text) {
  var depth = 0, objects = 0, arrays = 0, keys = 0, strings = 0, numbers = 0, booleans = 0, nulls = 0, longest = 0;
  final stack = <(Object?, int)>[(root, 0)];
  while (stack.isNotEmpty) {
    final (v, d) = stack.removeLast();
    if (d > depth) depth = d;
    switch (v) {
      case Map<String, Object?>():
        objects++;
        keys += v.length;
        for (final c in v.values) {
          stack.add((c, d + 1));
        }
      case List<Object?>():
        arrays++;
        if (v.length > longest) longest = v.length;
        for (final c in v) {
          stack.add((c, d + 1));
        }
      case String():
        strings++;
      case num():
        numbers++;
      case bool():
        booleans++;
      case null:
        nulls++;
    }
  }
  return JsonStats(
    depth: depth,
    objects: objects,
    arrays: arrays,
    keys: keys,
    strings: strings,
    numbers: numbers,
    booleans: booleans,
    nulls: nulls,
    bytes: utf8.encode(text).length,
    lines: text.isEmpty ? 0 : '\n'.allMatches(text).length + 1,
    longestArray: longest,
  );
}

/// A warning attached to a valid document (duplicate keys, number precision).
class JsonWarning {
  const JsonWarning({required this.message, required this.location, required this.path});
  final String message;
  final SourceLocation location;
  final List<Object> path;
}

/// Result of validating a JSON text. Plain data so it can cross isolates.
class JsonAnalysis {
  const JsonAnalysis._({
    required this.valid,
    required this.empty,
    this.value,
    this.error,
    this.warnings = const [],
    this.stats,
    this.hadBom = false,
  });

  final bool valid;

  /// The input was empty or whitespace only.
  final bool empty;
  final Object? value;
  final LocatedError? error;
  final List<JsonWarning> warnings;
  final JsonStats? stats;
  final bool hadBom;
}

/// Validates [text]. Top-level so it can run in `Isolate.run`.
JsonAnalysis analyzeJson(String text) {
  if (text.trim().isEmpty) return const JsonAnalysis._(valid: false, empty: true);
  try {
    final out = parseJsonStrict(text);
    final warnings = <JsonWarning>[
      for (final d in out.duplicates)
        JsonWarning(
          message:
              'Duplicate key "${d.key}" at ${formatJsonPath(d.path)} (first at ${SourceLocation.fromOffset(text, d.firstOffset)}); the last value wins',
          location: SourceLocation.fromOffset(text, d.offset),
          path: d.path,
        ),
      for (final n in out.numberNotes)
        JsonWarning(
          message: '${n.literal} at ${formatJsonPath(n.path)}: ${n.message}',
          location: SourceLocation.fromOffset(text, n.offset),
          path: n.path,
        ),
    ];
    return JsonAnalysis._(
      valid: true,
      empty: false,
      value: out.value,
      warnings: warnings,
      stats: computeJsonStats(out.value, text),
      hadBom: out.hadBom,
    );
  } on JsonSyntaxError catch (e) {
    return JsonAnalysis._(
      valid: false,
      empty: false,
      error: LocatedError.at(text, e.message, SourceLocation.fromOffset(text, e.offset)),
    );
  }
}

/// Guesses the indentation style of a JSON text (2 spaces when unknown).
JsonIndent detectJsonIndent(String text) {
  for (final line in text.split('\n').skip(1)) {
    if (line.startsWith('\t')) return JsonIndent.tab;
    final spaces = line.length - line.trimLeft().length;
    if (line.trim().isEmpty || spaces == 0) continue;
    return spaces == 4 ? JsonIndent.four : JsonIndent.two;
  }
  return JsonIndent.two;
}

/// Serialises [value] in the style of [original]: same indentation (or
/// minified when the original was a single line) and trailing newline.
String encodeLike(Object? value, String original, {bool ensureAscii = false}) {
  final trimmed = original.trimRight();
  final minified = trimmed.isNotEmpty && !trimmed.contains('\n');
  final out = encodeJson(value, indent: minified ? null : detectJsonIndent(original), ensureAscii: ensureAscii);
  return original.endsWith('\n') ? '$out\n' : out;
}
