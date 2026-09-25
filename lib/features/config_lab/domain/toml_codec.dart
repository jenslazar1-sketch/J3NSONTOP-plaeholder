/// TOML validation, TOML -> JSON and JSON -> TOML with itemised reports and
/// round-trip verification. Parsing/encoding uses `package:toml`.
library;

import 'package:toml/toml.dart';

import 'conversion_report.dart';
import 'json_parser.dart';
import 'json_tools.dart';
import 'json_value.dart';
import 'source_location.dart';

class TomlCheck {
  const TomlCheck({required this.valid, required this.empty, this.error, this.value});
  final bool valid;
  final bool empty;
  final LocatedError? error;

  /// Decoded table. Date-time values stay [TomlDateTime] objects so the tree
  /// can label them; convert with [tomlToJsonValue] for JSON.
  final Map<String, Object?>? value;
}

/// ISO-8601 text for a TOML date/time value (`T` separator, seconds always
/// present, fractional seconds kept, `Z` or `+hh:mm` offsets).
String tomlDateTimeToIso(TomlDateTime v) {
  String two(int n) => n.toString().padLeft(2, '0');
  String date(TomlFullDate d) => '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
  String time(TomlPartialTime t) {
    final frac = t.secondFractions.isEmpty
        ? ''
        : '.${t.secondFractions.map((f) => f.toString().padLeft(3, '0')).join()}';
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}$frac';
  }

  String offset(TomlTimeZoneOffset o) => o.isUtc ? 'Z' : '${o.isNegative ? '-' : '+'}${two(o.hours)}:${two(o.minutes)}';
  return switch (v) {
    TomlOffsetDateTime() => '${date(v.date)}T${time(v.time)}${offset(v.offset)}',
    TomlLocalDateTime() => '${date(v.date)}T${time(v.time)}',
    TomlLocalDate() => date(v.date),
    TomlLocalTime() => time(v.time),
    _ => v.toString(),
  };
}

String tomlDateTimeKind(TomlDateTime v) => switch (v) {
  TomlOffsetDateTime() => 'offset date-time',
  TomlLocalDateTime() => 'local date-time',
  TomlLocalDate() => 'local date',
  TomlLocalTime() => 'local time',
  _ => 'date-time',
};

/// Best-effort location of a semantic error (redefinition / not a table).
SourceLocation? _locateName(String text, String name) {
  final lines = text.split(RegExp(r'\r\n|\r|\n'));
  final bare = name.replaceAll('"', '').replaceAll("'", '');
  final last = bare.split('.').last;
  final header = RegExp(r'^\s*\[\[?\s*' + RegExp.escape(bare) + r'\s*\]\]?');
  final key = RegExp(r'^\s*("?' + RegExp.escape(last) + r'"?)\s*=');
  int? firstHit;
  for (var i = 0; i < lines.length; i++) {
    if (header.hasMatch(lines[i]) || key.hasMatch(lines[i])) {
      if (firstHit != null) return SourceLocation.fromLineColumn(text, i + 1, 1);
      firstHit = i;
    }
  }
  return firstHit == null ? null : SourceLocation.fromLineColumn(text, firstHit + 1, 1);
}

LocatedError _tomlError(String text, Object e) {
  if (e is TomlParserException) {
    return LocatedError.at(text, e.message, SourceLocation.fromOffset(text, e.offset));
  }
  if (e is TomlRedefinitionException) {
    return LocatedError.at(text, e.message, _locateName(text, e.name.toString()));
  }
  if (e is TomlNotATableException) {
    return LocatedError.at(text, e.message, _locateName(text, e.name.toString()));
  }
  if (e is TomlException) return LocatedError(e.message);
  return LocatedError('$e');
}

/// Validates [text]. Top-level so it can run in `Isolate.run`.
TomlCheck checkToml(String text) {
  if (text.trim().isEmpty) return const TomlCheck(valid: false, empty: true);
  try {
    final map = TomlDocument.parse(text).toMap();
    return TomlCheck(valid: true, empty: false, value: Map<String, Object?>.from(map));
  } on TomlException catch (e) {
    return TomlCheck(valid: false, empty: false, error: _tomlError(text, e));
  } on FormatException catch (e) {
    return TomlCheck(valid: false, empty: false, error: _tomlError(text, e));
  }
}

/// Blanks out strings and records comment lines, returning code-only text.
(String code, List<int> commentLines) _stripTomlStringsAndComments(String text) {
  final b = StringBuffer();
  final comments = <int>[];
  var line = 1;
  var i = 0;
  void emitNl(int c) {
    b.writeCharCode(c);
    if (c == 10) line++;
  }

  while (i < text.length) {
    final c = text.codeUnitAt(i);
    if (c == 0x23) {
      comments.add(line);
      while (i < text.length && text.codeUnitAt(i) != 10) {
        b.write(' ');
        i++;
      }
      continue;
    }
    if (c == 0x22 || c == 0x27) {
      final triple = text.startsWith(c == 0x22 ? '"""' : "'''", i);
      final quote = String.fromCharCode(c);
      final close = triple ? quote * 3 : quote;
      b.write(' ' * close.length);
      i += close.length;
      while (i < text.length && !text.startsWith(close, i)) {
        final d = text.codeUnitAt(i);
        if (d == 0x5C && c == 0x22 && i + 1 < text.length) {
          b.write('  ');
          i += 2;
          continue;
        }
        if (d == 10) {
          if (!triple) break;
          emitNl(d);
        } else {
          b.write(' ');
        }
        i++;
      }
      if (i < text.length && text.startsWith(close, i)) {
        b.write(' ' * close.length);
        i += close.length;
        // Up to two extra quotes may close a multi-line string.
        while (triple && i < text.length && text.codeUnitAt(i) == c) {
          b.write(' ');
          i++;
        }
      }
      continue;
    }
    emitNl(c);
    i++;
  }
  return (b.toString(), comments);
}

class _TomlToJson {
  final issues = <ConversionIssue>[];

  Object? convert(Object? v, List<Object> path) {
    if (v is Map<Object?, Object?>) {
      return <String, Object?>{
        for (final e in v.entries) '${e.key}': convert(e.value, [...path, '${e.key}']),
      };
    }
    if (v is List<Object?>) {
      return <Object?>[
        for (var i = 0; i < v.length; i++) convert(v[i], [...path, i]),
      ];
    }
    if (v is TomlDateTime) {
      final iso = tomlDateTimeToIso(v);
      issues.add(
        ConversionIssue.loss(
          IssueKind.datetimeToString,
          '${tomlDateTimeKind(v)} became the ISO-8601 string "$iso" (JSON has no date type)',
          path: formatJsonPath(path),
        ),
      );
      return iso;
    }
    if (v is double && !v.isFinite) {
      final s = v.isNaN ? 'nan' : (v > 0 ? 'inf' : '-inf');
      issues.add(
        ConversionIssue.loss(
          IssueKind.nonFiniteNumber,
          'Float $s cannot be represented in JSON; written as the string "$s"',
          path: formatJsonPath(path),
        ),
      );
      return s;
    }
    if (v is BigInt) {
      issues.add(
        ConversionIssue.loss(
          IssueKind.numericPrecision,
          'Integer $v does not fit in 64 bits; written as a string',
          path: formatJsonPath(path),
        ),
      );
      return v.toString();
    }
    if (v is int && (v > kJsSafeInteger || v < -kJsSafeInteger)) {
      issues.add(
        ConversionIssue.note(
          IssueKind.numericPrecision,
          'Integer $v is beyond 2^53: exact in this output, but JavaScript-based tools may round it',
          path: formatJsonPath(path),
        ),
      );
    }
    return v;
  }
}

/// Converts a decoded TOML table (as produced by [checkToml]) to a JSON-like
/// value, collecting report issues.
(Object?, List<ConversionIssue>) tomlToJsonValue(Map<String, Object?> table) {
  final c = _TomlToJson();
  final v = c.convert(table, const []);
  return (v, c.issues);
}

void _walkIntegers(TomlValue v, String path, List<ConversionIssue> out) {
  if (v is TomlInteger && v.format.base != 10) {
    final kind = switch (v.format.base) {
      2 => 'Binary',
      8 => 'Octal',
      _ => 'Hexadecimal',
    };
    out.add(
      ConversionIssue.note(
        IssueKind.numberNotation,
        '$kind integer ${v.toString()} is written in decimal as ${v.value}',
        path: path,
      ),
    );
  } else if (v is TomlArray) {
    for (var i = 0; i < v.items.length; i++) {
      _walkIntegers(v.items[i], '$path[$i]', out);
    }
  } else if (v is TomlInlineTable) {
    for (final p in v.pairs) {
      _walkIntegers(p.value, '$path.${p.key}', out);
    }
  }
}

/// Converts TOML [text] to JSON. Top-level so it can run in `Isolate.run`.
ConversionResult tomlToJson(String text, {JsonIndent indent = JsonIndent.two}) {
  const from = 'TOML', to = 'JSON';
  final TomlDocument doc;
  final Map<String, dynamic> map;
  try {
    doc = TomlDocument.parse(text);
    map = doc.toMap();
  } on Object catch (e) {
    final err = _tomlError(text, e);
    return ConversionResult.failed(
      ConversionReport(
        from: from,
        to: to,
        issues: [ConversionIssue.error(IssueKind.syntax, err.message, line: err.location?.line)],
      ),
    );
  }
  final (value, issues) = tomlToJsonValue(Map<String, Object?>.from(map));
  final (code, commentLines) = _stripTomlStringsAndComments(text);
  for (final line in commentLines) {
    issues.add(ConversionIssue.loss(IssueKind.commentsDropped, 'Comment dropped (JSON has no comments)', line: line));
  }
  var table = r'$';
  var hasStructure = false;
  for (final e in doc.expressions) {
    if (e is TomlStandardTable) {
      table = formatJsonPath(e.name.parts.map((p) => p.name));
      hasStructure = true;
    } else if (e is TomlArrayTable) {
      table = '${formatJsonPath(e.name.parts.map((p) => p.name))}[]';
      hasStructure = true;
    } else if (e is TomlKeyValuePair) {
      if (e.key.parts.length > 1) hasStructure = true;
      _walkIntegers(e.value, '$table.${e.key}', issues);
    }
  }
  if (hasStructure) {
    issues.add(
      const ConversionIssue.note(
        IssueKind.structureNote,
        'Table headers, arrays of tables and dotted keys become nested JSON objects and arrays (same data)',
      ),
    );
  }
  final codeLines = code.split('\n');
  final underscore = RegExp(r'(?<![\w.])[+-]?\d[\d_]*_\d');
  final plus = RegExp(r'=\s*\+\d');
  for (var i = 0; i < codeLines.length; i++) {
    if (underscore.hasMatch(codeLines[i]) || plus.hasMatch(codeLines[i])) {
      issues.add(
        ConversionIssue.note(
          IssueKind.numberNotation,
          'Digit separators (_) or a leading + in a number are dropped (same value)',
          line: i + 1,
        ),
      );
    }
  }
  issues.sort((a, b) => (a.line ?? 0).compareTo(b.line ?? 0));
  return ConversionResult(encodeJson(value, indent: indent), ConversionReport(from: from, to: to, issues: issues));
}

bool _isTableValue(Object? v) =>
    v is Map<String, Object?> || (v is List<Object?> && v.isNotEmpty && v.every((x) => x is Map<String, Object?>));

String _typeOfArrayItem(Object? v) => switch (v) {
  Map<Object?, Object?>() => 'table',
  List<Object?>() => 'array',
  int() => 'integer',
  double() => 'float',
  _ => jsonTypeOf(v).label,
};

class _JsonToTomlCheck {
  _JsonToTomlCheck(this.dropNulls);
  final bool dropNulls;
  final issues = <ConversionIssue>[];

  /// Returns the value to encode (nulls possibly removed).
  Object? prepare(Object? v, List<Object> path, {required bool inArray}) {
    if (v is Map<String, Object?>) {
      final out = <String, Object?>{};
      var seenTable = false;
      var reordered = false;
      for (final e in v.entries) {
        final childPath = [...path, e.key];
        if (e.value == null) {
          if (dropNulls) {
            issues.add(
              ConversionIssue.loss(
                IssueKind.nullsUnsupported,
                'null property dropped (TOML has no null)',
                path: formatJsonPath(childPath),
              ),
            );
          } else {
            issues.add(
              ConversionIssue.error(
                IssueKind.nullsUnsupported,
                'TOML has no null value; remove it, give it a value, or enable "Drop null properties"',
                path: formatJsonPath(childPath),
              ),
            );
          }
          continue;
        }
        final table = !inArray && _isTableValue(e.value);
        if (table) {
          seenTable = true;
        } else if (seenTable) {
          reordered = true;
        }
        out[e.key] = prepare(e.value, childPath, inArray: inArray);
      }
      if (reordered) {
        issues.add(
          ConversionIssue.loss(
            IssueKind.keyOrderChanged,
            'Plain keys are written before sub-tables in TOML, so the key order of this object changes',
            path: formatJsonPath(path),
          ),
        );
      }
      return out;
    }
    if (v is List<Object?>) {
      final allTables = v.isNotEmpty && v.every((x) => x is Map<String, Object?>);
      final types = <String>{for (final x in v) _typeOfArrayItem(x)};
      if (types.length > 1) {
        issues.add(
          ConversionIssue.note(
            IssueKind.mixedArray,
            'Mixed-type array (${types.join(', ')}) is valid TOML 1.0 but rejected by TOML 0.5 readers',
            path: formatJsonPath(path),
          ),
        );
      }
      final out = <Object?>[];
      for (var i = 0; i < v.length; i++) {
        if (v[i] == null) {
          issues.add(
            ConversionIssue.error(
              IssueKind.nullsUnsupported,
              'TOML arrays cannot contain null',
              path: formatJsonPath([...path, i]),
            ),
          );
          continue;
        }
        out.add(prepare(v[i], [...path, i], inArray: !(allTables && !inArray)));
      }
      return out;
    }
    return v;
  }
}

/// Converts JSON text to TOML with verification. When [dropNulls] is set,
/// null object properties are removed (each one reported).
ConversionResult jsonToToml(String jsonText, {bool dropNulls = false}) {
  const from = 'JSON', to = 'TOML';
  final JsonParseOutput parsed;
  try {
    parsed = parseJsonStrict(jsonText);
  } on JsonSyntaxError catch (e) {
    final loc = SourceLocation.fromOffset(jsonText, e.offset);
    return ConversionResult.failed(
      ConversionReport(
        from: from,
        to: to,
        issues: [ConversionIssue.error(IssueKind.syntax, '${loc.label}: ${e.message}', line: loc.line)],
      ),
    );
  }
  final root = parsed.value;
  if (root is! Map<String, Object?>) {
    return ConversionResult.failed(
      ConversionReport(
        from: from,
        to: to,
        issues: [
          ConversionIssue.error(
            IssueKind.unsupportedValue,
            'A TOML document is a table: the top-level JSON value must be an object, not ${jsonTypeOf(root).label}',
            path: r'$',
          ),
        ],
      ),
    );
  }
  final check = _JsonToTomlCheck(dropNulls);
  final prepared = check.prepare(root, const [], inArray: false)! as Map<String, Object?>;
  final issues = <ConversionIssue>[
    for (final d in parsed.duplicates)
      ConversionIssue.loss(
        IssueKind.duplicateKeys,
        'Duplicate JSON key "${d.key}": only the last value is written',
        path: formatJsonPath(d.path),
      ),
    for (final n in parsed.numberNotes)
      ConversionIssue.loss(IssueKind.numericPrecision, '${n.literal}: ${n.message}', path: formatJsonPath(n.path)),
    ...check.issues,
  ];
  if (issues.any((i) => i.severity == IssueSeverity.error)) {
    return ConversionResult.failed(ConversionReport(from: from, to: to, issues: issues));
  }
  final String toml;
  try {
    toml = TomlDocument.fromMap(prepared).toString();
  } on Object catch (e) {
    return ConversionResult.failed(
      ConversionReport(
        from: from,
        to: to,
        issues: [...issues, ConversionIssue.error(IssueKind.unsupportedValue, 'TOML encoder: $e')],
      ),
    );
  }
  try {
    final back = TomlDocument.parse(toml).toMap();
    if (!jsonDeepEquals(back, prepared)) {
      final where = firstDifference(prepared, back);
      return ConversionResult.failed(
        ConversionReport(
          from: from,
          to: to,
          issues: [
            ...issues,
            ConversionIssue.error(
              IssueKind.verification,
              'Emitted TOML does not re-parse to the same data (first difference at ${where == null ? r'$' : formatJsonPath(where)}); output withheld',
            ),
          ],
        ),
      );
    }
  } on Object catch (e) {
    return ConversionResult.failed(
      ConversionReport(
        from: from,
        to: to,
        issues: [...issues, ConversionIssue.error(IssueKind.verification, 'Emitted TOML failed to re-parse: $e')],
      ),
    );
  }
  return ConversionResult(toml, ConversionReport(from: from, to: to, issues: issues, verified: true));
}

/// JSON-like form of any decoded TOML value (date-times as ISO strings,
/// non-finite floats and big integers as strings).
Object? tomlValueToJsonLike(Object? v) => _TomlToJson().convert(v, const []);
