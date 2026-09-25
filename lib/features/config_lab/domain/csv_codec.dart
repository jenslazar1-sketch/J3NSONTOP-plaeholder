/// RFC 4180 CSV/TSV parsing with exact positions, delimiter detection,
/// statistics and conversions (CSV <-> TSV, CSV -> JSON, JSON -> CSV).
///
/// Parser rules (documented in docs/CONFIG_LAB.md):
/// * A leading UTF-8 BOM (U+FEFF) is skipped.
/// * Records end at LF, CRLF or CR outside quotes; a final line ending does
///   not create an empty record. Completely empty lines are skipped (and
///   reported); a line holding only spaces is a record with one field.
/// * A field starting with the quote character is quoted: it ends at the
///   next lone quote; a doubled quote is a literal quote; delimiters and
///   line breaks inside are kept verbatim.
/// * Text after a closing quote (before the next delimiter) is appended and
///   reported as a warning; a quote inside an unquoted field is kept
///   literally (warning); a quoted field still open at the end of the input
///   is an error (its content up to the end is kept).
library;

import 'conversion_report.dart';
import 'ini_document.dart' show inferScalar;
import 'json_parser.dart';
import 'json_tools.dart';
import 'json_value.dart';
import 'source_location.dart';

enum CsvSeverity { error, warning }

class CsvDiagnostic {
  const CsvDiagnostic(this.line, this.column, this.severity, this.message);
  final int line;
  final int column;
  final CsvSeverity severity;
  final String message;
}

class CsvTable {
  const CsvTable({
    required this.rows,
    required this.rowLines,
    required this.diagnostics,
    required this.hadBom,
    required this.lineEnding,
    required this.endsWithNewline,
    required this.blankLines,
  });

  final List<List<String>> rows;

  /// Physical 1-based line on which each record starts.
  final List<int> rowLines;
  final List<CsvDiagnostic> diagnostics;
  final bool hadBom;

  /// Dominant record separator of the source (`\n` when none).
  final String lineEnding;
  final bool endsWithNewline;

  /// Skipped empty lines.
  final List<int> blankLines;

  bool get hasErrors => diagnostics.any((d) => d.severity == CsvSeverity.error);
  int get columnCount => rows.fold(0, (m, r) => r.length > m ? r.length : m);
}

/// Delimiters offered in the UI.
enum CsvDelimiter {
  comma('Comma', ','),
  semicolon('Semicolon', ';'),
  tab('Tab', '\t'),
  pipe('Pipe', '|');

  const CsvDelimiter(this.label, this.char);
  final String label;
  final String char;

  static CsvDelimiter? of(String c) {
    for (final d in values) {
      if (d.char == c) return d;
    }
    return null;
  }
}

/// Parses [text]. Top-level so it can run in `Isolate.run`.
CsvTable parseCsv(String text, {String delimiter = ',', String quote = '"'}) {
  if (delimiter.length != 1) throw ArgumentError('Delimiter must be one character');
  if (quote.length != 1) throw ArgumentError('Quote must be one character');
  if (delimiter == quote) throw ArgumentError('Delimiter and quote must differ');
  final d = delimiter.codeUnitAt(0);
  final q = quote.codeUnitAt(0);
  final rows = <List<String>>[];
  final rowLines = <int>[];
  final diags = <CsvDiagnostic>[];
  final blank = <int>[];
  var i = 0;
  var hadBom = false;
  if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
    hadBom = true;
    i = 1;
  }
  var line = 1;
  var lineStart = i;
  var lf = 0, crlf = 0, cr = 0;
  final n = text.length;

  int col(int at) => at - lineStart + 1;

  // Consumes a line break at i (if any); returns true when one was consumed.
  bool consumeBreak() {
    if (i >= n) return false;
    final c = text.codeUnitAt(i);
    if (c == 10) {
      lf++;
      i++;
    } else if (c == 13) {
      if (i + 1 < n && text.codeUnitAt(i + 1) == 10) {
        crlf++;
        i += 2;
      } else {
        cr++;
        i++;
      }
    } else {
      return false;
    }
    line++;
    lineStart = i;
    return true;
  }

  while (i < n) {
    // Empty line?
    final c0 = text.codeUnitAt(i);
    if (c0 == 10 || c0 == 13) {
      blank.add(line);
      consumeBreak();
      continue;
    }
    final record = <String>[];
    final recordLine = line;
    while (true) {
      // Parse one field.
      final buf = StringBuffer();
      if (i < n && text.codeUnitAt(i) == q) {
        final openLine = line, openCol = col(i);
        i++;
        var closed = false;
        var runStart = i;
        while (i < n) {
          final c = text.codeUnitAt(i);
          if (c == q) {
            buf.write(text.substring(runStart, i));
            if (i + 1 < n && text.codeUnitAt(i + 1) == q) {
              buf.write(quote);
              i += 2;
              runStart = i;
              continue;
            }
            i++;
            closed = true;
            break;
          }
          if (c == 10 || (c == 13)) {
            // Line break inside quotes: keep verbatim, track line numbers.
            buf.write(text.substring(runStart, i));
            if (c == 13 && i + 1 < n && text.codeUnitAt(i + 1) == 10) {
              buf.write('\r\n');
              i += 2;
            } else {
              buf.writeCharCode(c);
              i++;
            }
            line++;
            lineStart = i;
            runStart = i;
            continue;
          }
          i++;
        }
        if (!closed) {
          buf.write(text.substring(runStart, i));
          diags.add(
            CsvDiagnostic(openLine, openCol, CsvSeverity.error, 'Quoted field is never closed (missing $quote)'),
          );
        } else if (i < n && text.codeUnitAt(i) != d && text.codeUnitAt(i) != 10 && text.codeUnitAt(i) != 13) {
          diags.add(
            CsvDiagnostic(line, col(i), CsvSeverity.warning, 'Text after a closing quote was appended to the field'),
          );
          final s = i;
          while (i < n && text.codeUnitAt(i) != d && text.codeUnitAt(i) != 10 && text.codeUnitAt(i) != 13) {
            i++;
          }
          buf.write(text.substring(s, i));
        }
      } else {
        final s = i;
        var warned = false;
        while (i < n) {
          final c = text.codeUnitAt(i);
          if (c == d || c == 10 || c == 13) break;
          if (c == q && !warned) {
            warned = true;
            diags.add(
              CsvDiagnostic(
                line,
                col(i),
                CsvSeverity.warning,
                'Quote character inside an unquoted field (kept as text)',
              ),
            );
          }
          i++;
        }
        buf.write(text.substring(s, i));
      }
      record.add(buf.toString());
      if (i < n && text.codeUnitAt(i) == d) {
        i++;
        continue;
      }
      break;
    }
    rows.add(record);
    rowLines.add(recordLine);
    if (!consumeBreak()) break;
  }
  final endsWithNewline = n > 0 && (text.codeUnitAt(n - 1) == 10 || text.codeUnitAt(n - 1) == 13);
  final String eol;
  if (crlf >= lf && crlf >= cr && crlf > 0) {
    eol = '\r\n';
  } else if (cr > lf) {
    eol = '\r';
  } else {
    eol = '\n';
  }
  return CsvTable(
    rows: rows,
    rowLines: rowLines,
    diagnostics: diags,
    hadBom: hadBom,
    lineEnding: eol,
    endsWithNewline: endsWithNewline,
    blankLines: blank,
  );
}

/// Picks the delimiter (comma, semicolon, tab or pipe) that splits the first
/// lines into the most consistent number of fields (quotes respected).
CsvDelimiter detectDelimiter(String text, {String quote = '"'}) {
  final sample = text.length > 64 * 1024 ? text.substring(0, 64 * 1024) : text;
  CsvDelimiter best = CsvDelimiter.comma;
  var bestScore = -1.0;
  for (final cand in CsvDelimiter.values) {
    final counts = <int>[];
    var inQuotes = false;
    var count = 0;
    var lines = 0;
    for (var i = 0; i < sample.length && lines < 30; i++) {
      final c = sample[i];
      if (c == quote) {
        inQuotes = !inQuotes;
      } else if (!inQuotes && c == cand.char) {
        count++;
      } else if (!inQuotes && (c == '\n' || c == '\r')) {
        if (c == '\r' && i + 1 < sample.length && sample[i + 1] == '\n') i++;
        counts.add(count);
        count = 0;
        lines++;
      }
    }
    if (count > 0 || (sample.isNotEmpty && !sample.endsWith('\n') && !sample.endsWith('\r'))) counts.add(count);
    final nonEmpty = counts.where((c) => c > 0).toList();
    if (nonEmpty.isEmpty) continue;
    final mode = _mode(counts);
    final consistent = counts.where((c) => c == mode).length / counts.length;
    final score = consistent * 10 + (mode > 0 ? 1 : 0) + mode * 0.01;
    if (mode > 0 && score > bestScore) {
      bestScore = score;
      best = cand;
    }
  }
  return best;
}

int _mode(List<int> xs) {
  final m = <int, int>{};
  for (final x in xs) {
    m[x] = (m[x] ?? 0) + 1;
  }
  var best = 0, bestCount = -1;
  m.forEach((k, v) {
    if (v > bestCount || (v == bestCount && k > best)) {
      best = k;
      bestCount = v;
    }
  });
  return best;
}

class CsvStats {
  const CsvStats({
    required this.rows,
    required this.columns,
    required this.expectedColumns,
    required this.raggedRows,
    required this.emptyCells,
    required this.totalCells,
  });

  /// Records (including a header row when present).
  final int rows;

  /// Widest record.
  final int columns;

  /// Field count of the first record (the reference for raggedness).
  final int expectedColumns;

  /// (record index, physical line, field count) of records whose field count
  /// differs from [expectedColumns].
  final List<(int, int, int)> raggedRows;
  final int emptyCells;
  final int totalCells;
}

CsvStats computeCsvStats(CsvTable t) {
  final expected = t.rows.isEmpty ? 0 : t.rows.first.length;
  final ragged = <(int, int, int)>[];
  var empty = 0, total = 0;
  for (var r = 0; r < t.rows.length; r++) {
    final row = t.rows[r];
    if (row.length != expected) ragged.add((r, t.rowLines[r], row.length));
    total += row.length;
    for (final c in row) {
      if (c.isEmpty) empty++;
    }
  }
  return CsvStats(
    rows: t.rows.length,
    columns: t.columnCount,
    expectedColumns: expected,
    raggedRows: ragged,
    emptyCells: empty,
    totalCells: total,
  );
}

bool _needsQuoting(String field, String delimiter, String quote) =>
    field.contains(delimiter) || field.contains(quote) || field.contains('\n') || field.contains('\r');

/// Encodes rows with RFC 4180 quoting (only where needed). When [quotedCells]
/// is given, (row, column) of every quoted cell is added to it.
String encodeCsv(
  List<List<String>> rows, {
  String delimiter = ',',
  String quote = '"',
  String eol = '\n',
  bool trailingNewline = true,
  List<(int, int)>? quotedCells,
}) {
  final b = StringBuffer();
  for (var r = 0; r < rows.length; r++) {
    final row = rows[r];
    for (var c = 0; c < row.length; c++) {
      if (c > 0) b.write(delimiter);
      final f = row[c];
      // A lone empty field in a single-column row must be quoted, or the
      // record would read back as a skipped blank line.
      if (_needsQuoting(f, delimiter, quote) || (row.length == 1 && f.isEmpty)) {
        quotedCells?.add((r, c));
        b
          ..write(quote)
          ..write(f.replaceAll(quote, '$quote$quote'))
          ..write(quote);
      } else {
        b.write(f);
      }
    }
    if (r < rows.length - 1 || trailingNewline) b.write(eol);
  }
  return b.toString();
}

String _delimName(String d) => CsvDelimiter.of(d)?.label.toLowerCase() ?? '"$d"';

List<ConversionIssue> _parseIssues(CsvTable t) => [
  for (final dg in t.diagnostics)
    dg.severity == CsvSeverity.error
        ? ConversionIssue.error(IssueKind.syntax, 'column ${dg.column}: ${dg.message}', line: dg.line)
        : ConversionIssue.loss(IssueKind.syntax, 'column ${dg.column}: ${dg.message}', line: dg.line),
  if (t.blankLines.isNotEmpty)
    ConversionIssue.loss(
      IssueKind.blankLinesSkipped,
      '${t.blankLines.length} empty line(s) skipped: ${t.blankLines.take(10).join(', ')}${t.blankLines.length > 10 ? ', …' : ''}',
    ),
];

/// Re-encodes a table with another delimiter (CSV <-> TSV). Lossless unless
/// fields have to be quoted in the target (reported per cell).
ConversionResult convertDelimited(
  CsvTable t, {
  required String fromDelimiter,
  required String toDelimiter,
  String quote = '"',
}) {
  final fromLabel = fromDelimiter == '\t' ? 'TSV' : 'CSV';
  final toLabel = toDelimiter == '\t' ? 'TSV' : 'CSV';
  final issues = _parseIssues(t);
  if (issues.any((i) => i.severity == IssueSeverity.error)) {
    return ConversionResult.failed(ConversionReport(from: fromLabel, to: toLabel, issues: issues));
  }
  final quoted = <(int, int)>[];
  final out = encodeCsv(
    t.rows,
    delimiter: toDelimiter,
    quote: quote,
    eol: t.lineEnding,
    trailingNewline: t.endsWithNewline,
    quotedCells: quoted,
  );
  for (final (r, c) in quoted) {
    final f = t.rows[r][c];
    final why = f.contains(toDelimiter)
        ? 'contains the ${_delimName(toDelimiter)} delimiter'
        : f.contains('\n') || f.contains('\r')
        ? 'contains a line break'
        : f.contains(quote)
        ? 'contains the quote character'
        : 'is an empty single-column record';
    final msg = 'Field quoted because it $why';
    issues.add(
      toDelimiter == '\t'
          ? ConversionIssue.loss(
              IssueKind.quotingAdded,
              '$msg; TSV readers that do not understand quotes will split or misread it',
              path: 'row ${r + 1}, column ${c + 1}',
              line: t.rowLines[r],
            )
          : ConversionIssue.note(
              IssueKind.quotingAdded,
              msg,
              path: 'row ${r + 1}, column ${c + 1}',
              line: t.rowLines[r],
            ),
    );
  }
  if (t.hadBom) {
    issues.add(const ConversionIssue.note(IssueKind.structureNote, 'Byte order mark not written'));
  }
  // Verify.
  final back = parseCsv(out, delimiter: toDelimiter, quote: quote);
  var same = back.rows.length == t.rows.length;
  for (var r = 0; same && r < t.rows.length; r++) {
    if (back.rows[r].length != t.rows[r].length) {
      same = false;
      break;
    }
    for (var c = 0; c < t.rows[r].length; c++) {
      if (back.rows[r][c] != t.rows[r][c]) {
        same = false;
        break;
      }
    }
  }
  if (!same) {
    issues.add(
      const ConversionIssue.error(
        IssueKind.verification,
        'Output does not re-parse to the same cells; output withheld',
      ),
    );
    return ConversionResult.failed(ConversionReport(from: fromLabel, to: toLabel, issues: issues));
  }
  return ConversionResult(out, ConversionReport(from: fromLabel, to: toLabel, issues: issues, verified: true));
}

enum CsvJsonShape {
  objects('Array of objects (header keys)'),
  arrays('Array of arrays (all rows)');

  const CsvJsonShape(this.label);
  final String label;
}

/// CSV -> JSON. Values stay strings unless [infer] is set.
ConversionResult csvToJson(
  CsvTable t, {
  bool header = true,
  CsvJsonShape shape = CsvJsonShape.objects,
  bool infer = false,
  JsonIndent indent = JsonIndent.two,
  String fromLabel = 'CSV',
}) {
  final issues = _parseIssues(t);
  if (issues.any((i) => i.severity == IssueSeverity.error)) {
    return ConversionResult.failed(ConversionReport(from: fromLabel, to: 'JSON', issues: issues));
  }
  Object? cell(String s, int r, int c, String path) {
    if (!infer) return s;
    if (s == 'null') {
      issues.add(
        ConversionIssue.loss(IssueKind.typesInferred, '"null" became JSON null', path: path, line: t.rowLines[r]),
      );
      return null;
    }
    final inf = inferScalar(s);
    if (inf == null) {
      if (RegExp(r'^-?0[0-9]+$').hasMatch(s)) {
        issues.add(
          ConversionIssue.note(
            IssueKind.typesInferred,
            '"$s" kept as text to preserve its leading zeros',
            path: path,
            line: t.rowLines[r],
          ),
        );
      } else if (RegExp(r'^-?[0-9]{16,}$').hasMatch(s)) {
        issues.add(
          ConversionIssue.note(
            IssueKind.numericPrecision,
            '"$s" kept as text: beyond 2^53 it would lose precision in many JSON readers',
            path: path,
            line: t.rowLines[r],
          ),
        );
      }
      return s;
    }
    issues.add(
      ConversionIssue.loss(
        IssueKind.typesInferred,
        '"$s" became ${jsonDetailedType(inf.$1)} ${jsonPreview(inf.$1)}${inf.$2}',
        path: path,
        line: t.rowLines[r],
      ),
    );
    return inf.$1;
  }

  Object? value;
  if (shape == CsvJsonShape.arrays) {
    value = <Object?>[
      for (var r = 0; r < t.rows.length; r++)
        <Object?>[
          for (var c = 0; c < t.rows[r].length; c++) cell(t.rows[r][c], r, c, formatJsonPath([r, c])),
        ],
    ];
  } else {
    if (!header) {
      issues.add(
        const ConversionIssue.error(
          IssueKind.structureNote,
          'An array of objects needs a header row: enable "First row is header" or choose array of arrays',
        ),
      );
      return ConversionResult.failed(ConversionReport(from: fromLabel, to: 'JSON', issues: issues));
    }
    if (t.rows.isEmpty) {
      value = <Object?>[];
    } else {
      final names = <String>[];
      final used = <String>{};
      final head = t.rows.first;
      for (var c = 0; c < head.length; c++) {
        var name = head[c].trim().isEmpty ? 'column_${c + 1}' : head[c];
        if (name != head[c]) {
          issues.add(
            ConversionIssue.loss(
              IssueKind.headerRenamed,
              'Empty header in column ${c + 1} named "$name"',
              line: t.rowLines.first,
            ),
          );
        }
        if (used.contains(name)) {
          var k = 2;
          while (used.contains('${name}_$k')) {
            k++;
          }
          final renamed = '${name}_$k';
          issues.add(
            ConversionIssue.loss(
              IssueKind.headerRenamed,
              'Duplicate header "$name" in column ${c + 1} renamed to "$renamed"',
              line: t.rowLines.first,
            ),
          );
          name = renamed;
        }
        used.add(name);
        names.add(name);
      }
      final list = <Object?>[];
      for (var r = 1; r < t.rows.length; r++) {
        final row = t.rows[r];
        final obj = <String, Object?>{};
        for (var c = 0; c < row.length; c++) {
          String key;
          if (c < names.length) {
            key = names[c];
          } else {
            key = 'column_${c + 1}';
            var k = 2;
            while (used.contains(key)) {
              key = 'column_${c + 1}_$k';
              k++;
            }
            issues.add(
              ConversionIssue.loss(
                IssueKind.extraCells,
                'Row has ${row.length} cells but the header has ${names.length}; cell ${c + 1} stored under "$key"',
                path: formatJsonPath([r - 1]),
                line: t.rowLines[r],
              ),
            );
          }
          obj[key] = cell(row[c], r, c, formatJsonPath([r - 1, key]));
        }
        if (row.length < names.length) {
          issues.add(
            ConversionIssue.loss(
              IssueKind.missingCells,
              'Row has ${row.length} of ${names.length} cells; missing keys ${names.sublist(row.length).map((e) => '"$e"').join(', ')} are omitted',
              path: formatJsonPath([r - 1]),
              line: t.rowLines[r],
            ),
          );
        }
        list.add(obj);
      }
      value = list;
    }
  }
  if (t.hadBom) issues.add(const ConversionIssue.note(IssueKind.structureNote, 'Byte order mark not written'));
  return ConversionResult(
    encodeJson(value, indent: indent),
    ConversionReport(from: fromLabel, to: 'JSON', issues: issues),
  );
}

/// JSON -> CSV/TSV. Accepts an array of flat objects (header = union of keys
/// in first-seen order) or an array of arrays. Nested values are errors
/// unless [flatten] is set (dotted keys, reported).
ConversionResult jsonToCsv(String jsonText, {String delimiter = ',', String quote = '"', bool flatten = false}) {
  final toLabel = delimiter == '\t' ? 'TSV' : 'CSV';
  final JsonParseOutput parsed;
  try {
    parsed = parseJsonStrict(jsonText);
  } on JsonSyntaxError catch (e) {
    final loc = SourceLocation.fromOffset(jsonText, e.offset);
    return ConversionResult.failed(
      ConversionReport(
        from: 'JSON',
        to: toLabel,
        issues: [ConversionIssue.error(IssueKind.syntax, '${loc.label}: ${e.message}', line: loc.line)],
      ),
    );
  }
  final root = parsed.value;
  final issues = <ConversionIssue>[
    for (final d in parsed.duplicates)
      ConversionIssue.loss(
        IssueKind.duplicateKeys,
        'Duplicate JSON key "${d.key}": only the last value is written',
        path: formatJsonPath(d.path),
      ),
  ];
  ConversionResult fail(String msg, {String? path}) => ConversionResult.failed(
    ConversionReport(
      from: 'JSON',
      to: toLabel,
      issues: [
        ...issues,
        ConversionIssue.error(IssueKind.unsupportedValue, msg, path: path),
      ],
    ),
  );
  if (root is! List<Object?>) return fail('Expected a JSON array of objects or arrays, got ${jsonTypeOf(root).label}');
  final nulls = <String>[];
  final typed = <String>[];

  String? text(Object? v, List<Object> path) {
    if (v == null) {
      nulls.add(formatJsonPath(path));
      return '';
    }
    if (v is Map<Object?, Object?> || v is List<Object?>) {
      issues.add(
        ConversionIssue.error(
          IssueKind.nestedUnsupported,
          'Nested ${jsonTypeOf(v).label} cannot be a CSV cell (enable dotted flattening to spread it over columns)',
          path: formatJsonPath(path),
        ),
      );
      return null;
    }
    if (v is! String) typed.add(formatJsonPath(path));
    return v is String ? v : jsonPreview(v, max: 1 << 20);
  }

  final rows = <List<String>>[];
  if (root.every((e) => e is List<Object?>)) {
    for (var r = 0; r < root.length; r++) {
      final item = root[r]! as List<Object?>;
      if (item.isEmpty) {
        issues.add(
          ConversionIssue.error(
            IssueKind.unsupportedValue,
            'An empty array cannot be written as a CSV record (it would read back as a blank line)',
            path: formatJsonPath([r]),
          ),
        );
        continue;
      }
      rows.add([
        for (var c = 0; c < item.length; c++) text(item[c], [r, c]) ?? '',
      ]);
    }
  } else if (root.every((e) => e is Map<String, Object?>)) {
    final flatRows = <Map<String, Object?>>[];
    var flattened = 0;
    for (var r = 0; r < root.length; r++) {
      final obj = root[r]! as Map<String, Object?>;
      if (!flatten) {
        flatRows.add(obj);
        continue;
      }
      final flat = <String, Object?>{};
      void walk(Object? v, String prefix, List<Object> path) {
        if (v is Map<String, Object?> && v.isNotEmpty) {
          flattened++;
          for (final e in v.entries) {
            walk(e.value, '$prefix.${e.key}', [...path, e.key]);
          }
        } else if (v is List<Object?> && v.isNotEmpty) {
          flattened++;
          for (var i = 0; i < v.length; i++) {
            walk(v[i], '$prefix.$i', [...path, i]);
          }
        } else {
          if (flat.containsKey(prefix)) {
            issues.add(
              ConversionIssue.error(
                IssueKind.duplicateKeys,
                'Flattened column "$prefix" collides with an existing key',
                path: formatJsonPath(path),
              ),
            );
          }
          flat[prefix] = v is Map<Object?, Object?>
              ? '{}'
              : v is List<Object?>
              ? '[]'
              : v;
        }
      }

      for (final e in obj.entries) {
        final v = e.value;
        if (v is Map<String, Object?> && v.isNotEmpty || v is List<Object?> && v.isNotEmpty) {
          walk(v, e.key, [r, e.key]);
        } else {
          if (flat.containsKey(e.key)) {
            issues.add(
              ConversionIssue.error(
                IssueKind.duplicateKeys,
                'Key "${e.key}" collides with a flattened column',
                path: formatJsonPath([r, e.key]),
              ),
            );
          }
          flat[e.key] = v is Map<Object?, Object?>
              ? '{}'
              : v is List<Object?>
              ? '[]'
              : v;
        }
      }
      flatRows.add(flat);
    }
    if (flattened > 0) {
      issues.add(
        ConversionIssue.loss(
          IssueKind.structureFlattened,
          '$flattened nested object(s)/array(s) spread over dotted columns (a.b, list.0); converting back does not rebuild the nesting',
        ),
      );
    }
    final header = <String>[];
    final seen = <String>{};
    for (final o in flatRows) {
      for (final k in o.keys) {
        if (seen.add(k)) header.add(k);
      }
    }
    if (header.isEmpty && flatRows.isNotEmpty) {
      return fail('The objects have no keys, so there are no columns to write');
    }
    if (header.isNotEmpty) rows.add(header);
    final missing = <int>[];
    for (var r = 0; r < flatRows.length; r++) {
      final o = flatRows[r];
      if (o.length < header.length) missing.add(r);
      rows.add([
        for (final h in header) o.containsKey(h) ? (text(o[h], [r, h]) ?? '') : '',
      ]);
    }
    if (missing.isNotEmpty) {
      issues.add(
        ConversionIssue.loss(
          IssueKind.missingCells,
          '${missing.length} object(s) lack some columns; their cells are left empty (missing and empty become indistinguishable): items ${missing.take(10).join(', ')}${missing.length > 10 ? ', …' : ''}',
        ),
      );
    }
    final ordered = flatRows.any((o) {
      final keys = o.keys.toList();
      final positions = [for (final k in keys) header.indexOf(k)];
      for (var i = 1; i < positions.length; i++) {
        if (positions[i] < positions[i - 1]) return true;
      }
      return false;
    });
    if (ordered) {
      issues.add(
        const ConversionIssue.loss(
          IssueKind.keyOrderChanged,
          'Some objects list their keys in a different order than the shared header',
        ),
      );
    }
  } else {
    return fail('Items must be all objects or all arrays (mixed or scalar items cannot form a table)');
  }
  if (nulls.isNotEmpty) {
    issues.add(
      ConversionIssue.loss(
        IssueKind.nullsUnsupported,
        '${nulls.length} null value(s) written as empty cells (indistinguishable from empty strings): ${nulls.take(8).join(', ')}${nulls.length > 8 ? ', …' : ''}',
      ),
    );
  }
  if (typed.isNotEmpty) {
    issues.add(
      ConversionIssue.loss(
        IssueKind.typesToText,
        '${typed.length} number/boolean value(s) become text (CSV cells are untyped)',
      ),
    );
  }
  if (issues.any((i) => i.severity == IssueSeverity.error)) {
    return ConversionResult.failed(ConversionReport(from: 'JSON', to: toLabel, issues: issues));
  }
  final quoted = <(int, int)>[];
  final out = encodeCsv(rows, delimiter: delimiter, quote: quote, quotedCells: quoted);
  if (quoted.isNotEmpty && delimiter == '\t') {
    issues.add(
      ConversionIssue.loss(
        IssueKind.quotingAdded,
        '${quoted.length} cell(s) had to be quoted (tabs, quotes or line breaks); TSV readers without quote support will misread them',
      ),
    );
  }
  final back = parseCsv(out, delimiter: delimiter, quote: quote);
  final same =
      back.rows.length == rows.length &&
      [for (var r = 0; r < rows.length; r++) back.rows[r].join('\u0000') == rows[r].join('\u0000')].every((b) => b);
  if (!same) {
    issues.add(
      const ConversionIssue.error(
        IssueKind.verification,
        'Output does not re-parse to the same cells; output withheld',
      ),
    );
    return ConversionResult.failed(ConversionReport(from: 'JSON', to: toLabel, issues: issues));
  }
  return ConversionResult(out, ConversionReport(from: 'JSON', to: toLabel, issues: issues, verified: true));
}
