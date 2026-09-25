/// INI parser with a lossless line model (see docs/CONFIG_LAB.md, "INI").
///
/// Rules:
/// * Lines end with LF, CRLF or CR; every line keeps its own ending.
/// * `[name]` starts a section (surrounding whitespace ignored; a `;` or `#`
///   comment may follow the closing bracket). Empty names are errors.
/// * Keys before the first section belong to the global section ("").
/// * `key=value` or `key: value`: the first `=` or `:` separates key and
///   value; key and value are trimmed. Empty keys are errors.
/// * Values wrapped in matching `"` or `'` are quoted: the quotes are removed
///   and inner whitespace kept. There are no escape sequences.
/// * Lines whose first non-blank character is `;` or `#` are comments.
///   Inline comments are NOT recognised: `a = 1 ; x` has the value `1 ; x`.
/// * Any other non-blank line is an invalid-line error.
/// * Names are case-sensitive. Duplicate sections (merged in conversions)
///   and duplicate keys (last value wins in conversions) are warnings;
///   names that differ only by case are also flagged.
///
/// Edits rewrite only the affected line(s); every other byte (comments,
/// blank lines, spacing, line endings, order) is preserved.
library;

import 'conversion_report.dart';
import 'json_parser.dart';
import 'json_tools.dart';
import 'json_value.dart';
import 'source_location.dart';

enum IniLineKind { blank, comment, section, entry, invalid }

class IniLine {
  const IniLine({
    required this.index,
    required this.raw,
    required this.eol,
    required this.kind,
    required this.section,
    this.sectionName,
    this.key,
    this.value,
    this.quote,
    this.valueStart = 0,
    this.valueEnd = 0,
    this.error,
  });

  /// 0-based index in the document.
  final int index;

  /// Line content without its line ending.
  final String raw;

  /// The line's own ending: `\n`, `\r\n`, `\r` or '' (last line).
  final String eol;
  final IniLineKind kind;

  /// Section this line belongs to ('' = global).
  final String section;

  /// For section headers.
  final String? sectionName;

  /// For entries.
  final String? key;
  final String? value;

  /// Quote character when the value was quoted.
  final String? quote;

  /// Offsets of the value token (including quotes) inside [raw].
  final int valueStart;
  final int valueEnd;

  /// Why an invalid line is invalid.
  final String? error;

  int get lineNumber => index + 1;
  bool get quoted => quote != null;
}

enum IniSeverity { error, warning }

class IniDiagnostic {
  const IniDiagnostic(this.line, this.severity, this.message);
  final int line;
  final IniSeverity severity;
  final String message;
}

class IniEditError implements Exception {
  const IniEditError(this.message);
  final String message;
  @override
  String toString() => message;
}

final RegExp _sectionRe = RegExp(r'^\s*\[([^\]]*)\]\s*([;#].*)?$');

class IniDocument {
  IniDocument._(this.lines, this.diagnostics);

  final List<IniLine> lines;
  final List<IniDiagnostic> diagnostics;

  bool get hasErrors => diagnostics.any((d) => d.severity == IniSeverity.error);
  List<IniDiagnostic> get errors => [
    for (final d in diagnostics)
      if (d.severity == IniSeverity.error) d,
  ];
  List<IniDiagnostic> get warnings => [
    for (final d in diagnostics)
      if (d.severity == IniSeverity.warning) d,
  ];

  List<IniLine> get entries => [
    for (final l in lines)
      if (l.kind == IniLineKind.entry) l,
  ];

  /// Section names in first-appearance order ('' first when global keys exist).
  List<String> get sectionNames {
    final out = <String>[];
    if (lines.any((l) => l.kind == IniLineKind.entry && l.section.isEmpty)) out.add('');
    for (final l in lines) {
      if (l.kind == IniLineKind.section && !out.contains(l.sectionName)) out.add(l.sectionName!);
    }
    return out;
  }

  /// Reassembles the exact text.
  String toText() {
    final b = StringBuffer();
    for (final l in lines) {
      b
        ..write(l.raw)
        ..write(l.eol);
    }
    return b.toString();
  }

  /// Most common line ending (LF when there are none).
  String get dominantEol {
    final counts = <String, int>{};
    for (final l in lines) {
      if (l.eol.isNotEmpty) counts[l.eol] = (counts[l.eol] ?? 0) + 1;
    }
    if (counts.isEmpty) return '\n';
    return counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  }

  static List<(String, String)> _split(String text) {
    final out = <(String, String)>[];
    var start = 0;
    var i = 0;
    while (i < text.length) {
      final c = text.codeUnitAt(i);
      if (c == 10) {
        out.add((text.substring(start, i), '\n'));
        i++;
        start = i;
      } else if (c == 13) {
        final crlf = i + 1 < text.length && text.codeUnitAt(i + 1) == 10;
        out.add((text.substring(start, i), crlf ? '\r\n' : '\r'));
        i += crlf ? 2 : 1;
        start = i;
      } else {
        i++;
      }
    }
    if (start < text.length) out.add((text.substring(start), ''));
    return out;
  }

  static IniDocument parse(String text) {
    final parts = _split(text);
    final lines = <IniLine>[];
    final diags = <IniDiagnostic>[];
    var section = '';
    for (var n = 0; n < parts.length; n++) {
      final (raw, eol) = parts[n];
      final line = _parseLine(n, raw, eol, section);
      if (line.kind == IniLineKind.section) section = line.sectionName!;
      if (line.kind == IniLineKind.invalid) diags.add(IniDiagnostic(n + 1, IniSeverity.error, line.error!));
      if (line.kind == IniLineKind.entry && line.quote == null && _unbalancedQuote(line.value!)) {
        diags.add(
          IniDiagnostic(n + 1, IniSeverity.warning, 'Value starts or ends with an unmatched quote; kept verbatim'),
        );
      }
      lines.add(line);
    }
    diags.addAll(_duplicates(lines));
    diags.sort((a, b) => a.line.compareTo(b.line));
    return IniDocument._(lines, diags);
  }

  static bool _unbalancedQuote(String v) {
    if (v.isEmpty) return false;
    final f = v[0], l = v[v.length - 1];
    return (f == '"' || f == "'") != (l == '"' || l == "'") || (v.length == 1 && (f == '"' || f == "'"));
  }

  static IniLine _parseLine(int n, String raw, String eol, String section) {
    // A BOM at the very start is not part of the content.
    final offset = (n == 0 && raw.isNotEmpty && raw.codeUnitAt(0) == 0xFEFF) ? 1 : 0;
    final content = raw.substring(offset);
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      return IniLine(index: n, raw: raw, eol: eol, kind: IniLineKind.blank, section: section);
    }
    if (trimmed.startsWith(';') || trimmed.startsWith('#')) {
      return IniLine(index: n, raw: raw, eol: eol, kind: IniLineKind.comment, section: section);
    }
    if (trimmed.startsWith('[')) {
      final m = _sectionRe.firstMatch(content);
      if (m == null) {
        return IniLine(
          index: n,
          raw: raw,
          eol: eol,
          kind: IniLineKind.invalid,
          section: section,
          error: trimmed.contains(']')
              ? 'Unexpected text after section header'
              : 'Unterminated section header (missing "]")',
        );
      }
      final name = m.group(1)!.trim();
      if (name.isEmpty) {
        return IniLine(
          index: n,
          raw: raw,
          eol: eol,
          kind: IniLineKind.invalid,
          section: section,
          error: 'Empty section name',
        );
      }
      return IniLine(index: n, raw: raw, eol: eol, kind: IniLineKind.section, section: name, sectionName: name);
    }
    final eq = content.indexOf('=');
    final colon = content.indexOf(':');
    final sep = eq < 0 ? colon : (colon < 0 ? eq : (eq < colon ? eq : colon));
    if (sep < 0) {
      return IniLine(
        index: n,
        raw: raw,
        eol: eol,
        kind: IniLineKind.invalid,
        section: section,
        error: 'Not a section, comment or key=value line',
      );
    }
    final key = content.substring(0, sep).trim();
    if (key.isEmpty) {
      return IniLine(
        index: n,
        raw: raw,
        eol: eol,
        kind: IniLineKind.invalid,
        section: section,
        error: 'Missing key before "${content[sep]}"',
      );
    }
    var vs = offset + sep + 1;
    while (vs < raw.length && (raw.codeUnitAt(vs) == 0x20 || raw.codeUnitAt(vs) == 0x09)) {
      vs++;
    }
    var ve = raw.length;
    while (ve > vs && (raw.codeUnitAt(ve - 1) == 0x20 || raw.codeUnitAt(ve - 1) == 0x09)) {
      ve--;
    }
    final token = raw.substring(vs, ve);
    String? quote;
    var value = token;
    if (token.length >= 2) {
      final f = token[0];
      if ((f == '"' || f == "'") && token.endsWith(f)) {
        quote = f;
        value = token.substring(1, token.length - 1);
      }
    }
    return IniLine(
      index: n,
      raw: raw,
      eol: eol,
      kind: IniLineKind.entry,
      section: section,
      key: key,
      value: value,
      quote: quote,
      valueStart: vs,
      valueEnd: ve,
    );
  }

  static List<IniDiagnostic> _duplicates(List<IniLine> lines) {
    final out = <IniDiagnostic>[];
    final sectionFirst = <String, int>{};
    final sectionLower = <String, (String, int)>{};
    final keyFirst = <String, int>{};
    final keyLower = <String, (String, int)>{};
    for (final l in lines) {
      if (l.kind == IniLineKind.section) {
        final name = l.sectionName!;
        final first = sectionFirst[name];
        if (first != null) {
          out.add(
            IniDiagnostic(
              l.lineNumber,
              IniSeverity.warning,
              'Section [$name] is also defined at line $first; conversions merge both',
            ),
          );
        } else {
          sectionFirst[name] = l.lineNumber;
          final lower = sectionLower[name.toLowerCase()];
          if (lower != null && lower.$1 != name) {
            out.add(
              IniDiagnostic(
                l.lineNumber,
                IniSeverity.warning,
                'Section [$name] differs only by case from [${lower.$1}] (line ${lower.$2}); many INI readers treat them as the same',
              ),
            );
          }
          sectionLower.putIfAbsent(name.toLowerCase(), () => (name, l.lineNumber));
        }
      } else if (l.kind == IniLineKind.entry) {
        final id = '${l.section}\u0000${l.key}';
        final first = keyFirst[id];
        final where = l.section.isEmpty ? 'the global section' : '[${l.section}]';
        if (first != null) {
          out.add(
            IniDiagnostic(
              l.lineNumber,
              IniSeverity.warning,
              'Duplicate key "${l.key}" in $where (first at line $first); the last value wins in conversions',
            ),
          );
        } else {
          keyFirst[id] = l.lineNumber;
          final lowerId = '${l.section}\u0000${l.key!.toLowerCase()}';
          final lower = keyLower[lowerId];
          if (lower != null && lower.$1 != l.key) {
            out.add(
              IniDiagnostic(
                l.lineNumber,
                IniSeverity.warning,
                'Key "${l.key}" differs only by case from "${lower.$1}" (line ${lower.$2}) in $where',
              ),
            );
          }
          keyLower.putIfAbsent(lowerId, () => (l.key!, l.lineNumber));
        }
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------
  // Lossless edits
  // ---------------------------------------------------------------------

  IniDocument _withLines(List<(String, String)> parts) {
    final b = StringBuffer();
    for (final (raw, eol) in parts) {
      b
        ..write(raw)
        ..write(eol);
    }
    return IniDocument.parse(b.toString());
  }

  List<(String, String)> get _parts => [for (final l in lines) (l.raw, l.eol)];

  /// Encodes [value] as a value token. A value that was quoted stays quoted
  /// with the same quote character. Unquoted values get `"` quotes only when
  /// they would otherwise be read back differently (leading/trailing
  /// whitespace, or a leading/trailing quote character). Because only the
  /// first and last character mark quotes, inner quotes never need escaping.
  static String encodeValue(String value, {String? quote}) {
    if (value.contains('\n') || value.contains('\r')) {
      throw const IniEditError('Values cannot contain line breaks');
    }
    bool isQuote(String c) => c == '"' || c == "'";
    final needsQuotes =
        value != value.trim() || (value.isNotEmpty && (isQuote(value[0]) || isQuote(value[value.length - 1])));
    final q = quote ?? (needsQuotes ? '"' : null);
    return q == null ? value : '$q$value$q';
  }

  /// Replaces the value of the entry at [lineIndex]; only that line changes.
  IniDocument setValue(int lineIndex, String value) {
    final l = lines[lineIndex];
    if (l.kind != IniLineKind.entry) throw const IniEditError('Only key=value lines have values');
    final token = encodeValue(value, quote: l.quote);
    final raw = l.raw.substring(0, l.valueStart) + token + l.raw.substring(l.valueEnd);
    final parts = _parts;
    parts[lineIndex] = (raw, l.eol);
    return _withLines(parts);
  }

  static String? validateKey(String key) {
    if (key.isEmpty) return 'Key cannot be empty';
    if (key != key.trim()) return 'Key cannot start or end with whitespace';
    if (key.contains('=') || key.contains(':')) return 'Key cannot contain "=" or ":"';
    if (key.contains('\n') || key.contains('\r')) return 'Key cannot contain line breaks';
    if (key.startsWith('[') || key.startsWith(';') || key.startsWith('#')) {
      return 'Key cannot start with "[", ";" or "#"';
    }
    return null;
  }

  static String? validateSectionName(String name) {
    if (name.trim().isEmpty) return 'Section name cannot be empty';
    if (name != name.trim()) return 'Section name cannot start or end with whitespace';
    if (name.contains(']') || name.contains('\n') || name.contains('\r')) {
      return 'Section name cannot contain "]" or line breaks';
    }
    return null;
  }

  /// The separator style (`" = "`, `"="`, `": "`) used near [lineIndex].
  String _separatorStyle(int nearIndex) {
    IniLine? best;
    for (final l in lines) {
      if (l.kind != IniLineKind.entry) continue;
      if (best == null || (l.index - nearIndex).abs() < (best.index - nearIndex).abs()) best = l;
    }
    if (best == null) return ' = ';
    final start = best.raw.indexOf(best.key!) + best.key!.length;
    final sep = best.raw.substring(start, best.valueStart);
    return sep.trim().isEmpty ? ' = ' : sep;
  }

  /// Inserts `key = value` at the end of [section] (created when missing).
  IniDocument addEntry(String section, String key, String value) {
    final keyError = validateKey(key);
    if (keyError != null) throw IniEditError(keyError);
    final token = encodeValue(value);
    if (entries.any((e) => e.section == section && e.key == key)) {
      throw IniEditError('Key "$key" already exists in ${section.isEmpty ? 'the global section' : '[$section]'}');
    }
    final sectionExists =
        section.isEmpty || lines.any((l) => l.kind == IniLineKind.section && l.sectionName == section);
    if (!sectionExists) return addSection(section).addEntry(section, key, value);

    // Insert after the last entry of the section (or after its last header,
    // or before the first section header for the global section).
    int insertAfter = -1;
    for (final l in lines) {
      if (l.kind == IniLineKind.entry && l.section == section) insertAfter = l.index;
    }
    if (insertAfter < 0) {
      if (section.isEmpty) {
        final firstHeader = lines.indexWhere((l) => l.kind == IniLineKind.section);
        insertAfter = firstHeader < 0 ? lines.length - 1 : firstHeader - 1;
        // Keep the new global key above the comment block that is attached
        // to the first section header (comments directly above it).
        if (firstHeader >= 0) {
          while (insertAfter >= 0 && lines[insertAfter].kind == IniLineKind.comment) {
            insertAfter--;
          }
        }
      } else {
        insertAfter = lines.lastWhere((l) => l.kind == IniLineKind.section && l.sectionName == section).index;
      }
    }
    final line = '$key${_separatorStyle(insertAfter)}$token';
    return _insertLine(insertAfter, line);
  }

  IniDocument _insertLine(int afterIndex, String raw) {
    final parts = _parts;
    final eol = dominantEol;
    if (afterIndex >= 0 && afterIndex < parts.length && parts[afterIndex].$2.isEmpty) {
      // The line we insert after was the unterminated last line: it gains a
      // line ending and the new line becomes the unterminated last line.
      parts[afterIndex] = (parts[afterIndex].$1, eol);
      parts.insert(afterIndex + 1, (raw, ''));
    } else {
      parts.insert(afterIndex + 1, (raw, eol));
    }
    return _withLines(parts);
  }

  /// Appends a `[name]` header at the end of the document.
  IniDocument addSection(String name) {
    final err = validateSectionName(name);
    if (err != null) throw IniEditError(err);
    if (lines.any((l) => l.kind == IniLineKind.section && l.sectionName == name)) {
      throw IniEditError('Section [$name] already exists');
    }
    final parts = _parts;
    final eol = dominantEol;
    final endsWithNewline = parts.isEmpty || parts.last.$2.isNotEmpty;
    if (parts.isNotEmpty && !endsWithNewline) {
      parts[parts.length - 1] = (parts.last.$1, eol);
    }
    if (parts.isNotEmpty && parts.last.$1.trim().isNotEmpty) parts.add(('', eol));
    parts.add(('[$name]', endsWithNewline ? eol : ''));
    return _withLines(parts);
  }

  /// Removes the entry at [lineIndex]; every other line is untouched.
  IniDocument removeEntry(int lineIndex) {
    final l = lines[lineIndex];
    if (l.kind != IniLineKind.entry) throw const IniEditError('Only key=value lines can be removed here');
    final parts = _parts..removeAt(lineIndex);
    if (l.eol.isEmpty && parts.isNotEmpty && lineIndex == parts.length) {
      // Removing the unterminated last line: keep the file without a final
      // line ending, as it was.
      parts[parts.length - 1] = (parts.last.$1, '');
    }
    return _withLines(parts);
  }
}

// -------------------------------------------------------------------------
// Conversions
// -------------------------------------------------------------------------

final RegExp _intRe = RegExp(r'^-?(0|[1-9][0-9]*)$');
final RegExp _floatRe = RegExp(r'^-?(0|[1-9][0-9]*)\.[0-9]+([eE][+-]?[0-9]+)?$');

/// Converts an INI document to JSON: global keys at the top level, each
/// section an object of string values. With [inferTypes], unquoted values
/// that look like integers, decimals or booleans become JSON numbers and
/// booleans (reported item by item).
ConversionResult iniToJson(IniDocument doc, {bool inferTypes = false, JsonIndent indent = JsonIndent.two}) {
  const from = 'INI', to = 'JSON';
  final issues = <ConversionIssue>[];
  if (doc.hasErrors) {
    return ConversionResult.failed(
      ConversionReport(
        from: from,
        to: to,
        issues: [for (final e in doc.errors) ConversionIssue.error(IssueKind.syntax, e.message, line: e.line)],
      ),
    );
  }
  final out = <String, Object?>{};
  final sectionLines = <String, int>{};
  final globalLines = <String, int>{};
  for (final l in doc.lines) {
    if (l.kind == IniLineKind.comment) {
      issues.add(ConversionIssue.loss(IssueKind.commentsDropped, 'Comment dropped', line: l.lineNumber));
    } else if (l.kind == IniLineKind.section) {
      final name = l.sectionName!;
      if (globalLines.containsKey(name)) {
        issues.add(
          ConversionIssue.error(
            IssueKind.duplicateKeys,
            'Section [$name] has the same name as the global key "$name" (line ${globalLines[name]}); both cannot be top-level JSON properties',
            line: l.lineNumber,
          ),
        );
        continue;
      }
      if (sectionLines.containsKey(name)) {
        issues.add(
          ConversionIssue.loss(
            IssueKind.duplicateKeys,
            'Section [$name] repeats line ${sectionLines[name]}; both are merged into one object',
            path: formatJsonPath([name]),
            line: l.lineNumber,
          ),
        );
      } else {
        sectionLines[name] = l.lineNumber;
        out[name] = <String, Object?>{};
      }
    } else if (l.kind == IniLineKind.entry) {
      final key = l.key!;
      final Map<String, Object?> target;
      final List<Object> path;
      if (l.section.isEmpty) {
        if (sectionLines.containsKey(key)) {
          issues.add(
            ConversionIssue.error(
              IssueKind.duplicateKeys,
              'Global key "$key" collides with section [$key]',
              line: l.lineNumber,
            ),
          );
          continue;
        }
        globalLines[key] = l.lineNumber;
        target = out;
        path = [key];
      } else {
        final section = out[l.section];
        if (section is! Map<String, Object?>) continue; // header already reported as an error
        target = section;
        path = [l.section, key];
      }
      if (target.containsKey(key)) {
        issues.add(
          ConversionIssue.loss(
            IssueKind.duplicateKeys,
            'Duplicate key "$key": the value from this line replaces the earlier one',
            path: formatJsonPath(path),
            line: l.lineNumber,
          ),
        );
      }
      Object? value = l.value!;
      if (l.quoted) {
        issues.add(
          ConversionIssue.note(
            IssueKind.quotesRemoved,
            'Quotes ${l.quote}…${l.quote} removed (the string content is kept)',
            path: formatJsonPath(path),
            line: l.lineNumber,
          ),
        );
      } else if (inferTypes) {
        final inferred = _infer(l.value!);
        if (inferred != null) {
          value = inferred.$1;
          issues.add(
            ConversionIssue.loss(
              IssueKind.typesInferred,
              '"${l.value}" became ${jsonDetailedType(value)} ${jsonPreview(value)}${inferred.$2}',
              path: formatJsonPath(path),
              line: l.lineNumber,
            ),
          );
        }
      }
      target[key] = value;
    }
  }
  if (issues.any((i) => i.severity == IssueSeverity.error)) {
    return ConversionResult.failed(ConversionReport(from: from, to: to, issues: issues));
  }
  return ConversionResult(encodeJson(out, indent: indent), ConversionReport(from: from, to: to, issues: issues));
}

/// Inference used by INI and CSV conversions. Returns the value and a note
/// about formatting that the JSON value does not keep.
(Object?, String)? _infer(String s) {
  if (_intRe.hasMatch(s)) {
    final v = int.tryParse(s);
    if (v == null || v > kJsSafeInteger || v < -kJsSafeInteger) return null;
    return (v, '');
  }
  if (_floatRe.hasMatch(s)) {
    final d = double.parse(s);
    final canonical = jsonPreview(d);
    return (d, canonical == s ? '' : ' (written as $canonical: formatting of "$s" is not kept)');
  }
  final lower = s.toLowerCase();
  if (lower == 'true' || lower == 'false') {
    return (lower == 'true', s == lower ? '' : ' (spelling "$s" is not kept)');
  }
  return null;
}

/// Public wrapper of the shared inference rules (also used by CSV).
(Object?, String)? inferScalar(String s) => _infer(s);

/// Converts a JSON object to INI: top-level scalars become global keys,
/// objects become sections whose values must be scalars.
ConversionResult jsonToIni(String jsonText) {
  const from = 'JSON', to = 'INI';
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
            'INI needs a JSON object of sections, not ${jsonTypeOf(root).label}',
            path: r'$',
          ),
        ],
      ),
    );
  }
  final issues = <ConversionIssue>[
    for (final d in parsed.duplicates)
      ConversionIssue.loss(
        IssueKind.duplicateKeys,
        'Duplicate JSON key "${d.key}": only the last value is written',
        path: formatJsonPath(d.path),
      ),
  ];
  final typed = <String>[];

  String? scalar(Object? v, List<Object> path) {
    if (v == null) {
      issues.add(
        ConversionIssue.error(IssueKind.nullsUnsupported, 'INI has no null value', path: formatJsonPath(path)),
      );
      return null;
    }
    if (v is Map<Object?, Object?> || v is List<Object?>) {
      issues.add(
        ConversionIssue.error(
          IssueKind.nestedUnsupported,
          '${jsonTypeOf(v).label} values are not supported here (INI only has sections of key=value pairs)',
          path: formatJsonPath(path),
        ),
      );
      return null;
    }
    if (v is! String) typed.add(formatJsonPath(path));
    final text = v is String ? v : jsonPreview(v, max: 1 << 20);
    if (text.contains('\n') || text.contains('\r')) {
      issues.add(
        ConversionIssue.error(
          IssueKind.unsupportedValue,
          'Multi-line strings cannot be written to INI',
          path: formatJsonPath(path),
        ),
      );
      return null;
    }
    try {
      final token = IniDocument.encodeValue(text);
      if (token != text) {
        issues.add(
          ConversionIssue.note(
            IssueKind.quotingAdded,
            'Value quoted to keep leading/trailing whitespace or quote characters',
            path: formatJsonPath(path),
          ),
        );
      }
      return token;
    } on IniEditError catch (e) {
      issues.add(ConversionIssue.error(IssueKind.unsupportedValue, e.message, path: formatJsonPath(path)));
      return null;
    }
  }

  void checkKey(String key, List<Object> path) {
    final err = IniDocument.validateKey(key);
    if (err != null) issues.add(ConversionIssue.error(IssueKind.invalidName, err, path: formatJsonPath(path)));
  }

  final global = StringBuffer();
  final blocks = <String>[];
  var sawSection = false;
  var reordered = false;
  for (final e in root.entries) {
    final value = e.value;
    if (value is Map<String, Object?>) {
      sawSection = true;
      final err = IniDocument.validateSectionName(e.key);
      if (err != null) {
        issues.add(ConversionIssue.error(IssueKind.invalidName, err, path: formatJsonPath([e.key])));
        continue;
      }
      final block = StringBuffer('[${e.key}]\n');
      for (final kv in value.entries) {
        final path = [e.key, kv.key];
        checkKey(kv.key, path);
        final token = scalar(kv.value, path);
        if (token != null) block.write('${kv.key} = $token\n');
      }
      blocks.add(block.toString());
    } else {
      if (sawSection) reordered = true;
      checkKey(e.key, [e.key]);
      final token = scalar(value, [e.key]);
      if (token != null) global.write('${e.key} = $token\n');
    }
  }
  if (reordered) {
    issues.add(
      const ConversionIssue.loss(
        IssueKind.keyOrderChanged,
        'Top-level scalar values are written as global keys before the first section, so their order relative to sections changes',
        path: r'$',
      ),
    );
  }
  if (typed.isNotEmpty) {
    issues.add(
      ConversionIssue.loss(
        IssueKind.typesToText,
        '${typed.length} number/boolean value(s) become text (INI values are untyped): ${typed.take(8).join(', ')}${typed.length > 8 ? ', …' : ''}',
      ),
    );
  }
  if (issues.any((i) => i.severity == IssueSeverity.error)) {
    return ConversionResult.failed(ConversionReport(from: from, to: to, issues: issues));
  }
  final ini = [if (global.isNotEmpty) global.toString(), ...blocks].join('\n');
  // Verify: parse back and compare with the stringified input.
  final back = IniDocument.parse(ini);
  final backJson = iniToJson(back, indent: JsonIndent.two);
  Object? stringified(Object? v) {
    if (v is Map<String, Object?>) return <String, Object?>{for (final e in v.entries) e.key: stringified(e.value)};
    return v is String ? v : jsonPreview(v, max: 1 << 20);
  }

  final expected = stringified(root);
  final actual = backJson.ok ? decodeJsonStrict(backJson.output!) : null;
  if (!jsonDeepEquals(expected, actual)) {
    final where = firstDifference(expected, actual);
    return ConversionResult.failed(
      ConversionReport(
        from: from,
        to: to,
        issues: [
          ...issues,
          ConversionIssue.error(
            IssueKind.verification,
            'Emitted INI does not re-parse to the same data (first difference at ${where == null ? r'$' : formatJsonPath(where)}); output withheld',
          ),
        ],
      ),
    );
  }
  return ConversionResult(ini, ConversionReport(from: from, to: to, issues: issues, verified: true));
}
