/// Config comparison: semantic diff of the parsed data plus a textual line
/// diff, and a plain-text report for export.
library;

import '../../../core/text/diff.dart';
import 'config_format.dart';
import 'json_value.dart';
import 'semantic_diff.dart';

class CompareResult {
  const CompareResult({
    required this.a,
    required this.b,
    required this.text,
    required this.unified,
    this.semantic,
    required this.ignoreWhitespace,
  });

  final ParsedConfig a;
  final ParsedConfig b;

  /// Null when either side failed to parse.
  final SemanticDiffResult? semantic;
  final DiffResult text;
  final String unified;
  final bool ignoreWhitespace;
}

/// Compares two texts. A null format is detected (file name first, then
/// content). Top-level so it can run in `Isolate.run`.
CompareResult compareConfigs(
  String textA,
  String textB, {
  ConfigFormat? formatA,
  ConfigFormat? formatB,
  String? fileNameA,
  String? fileNameB,
  bool ignoreWhitespace = false,
  String nameA = 'A',
  String nameB = 'B',
}) {
  final a = parseConfigValue(textA, formatA ?? detectConfigFormat(textA, fileName: fileNameA));
  final b = parseConfigValue(textB, formatB ?? detectConfigFormat(textB, fileName: fileNameB));
  final text = LineDiff.diffText(textA, textB, options: DiffOptions(ignoreWhitespace: ignoreWhitespace));
  return CompareResult(
    a: a,
    b: b,
    semantic: a.ok && b.ok ? semanticDiff(a.value, b.value) : null,
    text: text,
    unified: LineDiff.unified(text, oldName: nameA, newName: nameB),
    ignoreWhitespace: ignoreWhitespace,
  );
}

/// One row of a side-by-side view (null cells are gaps).
class SideBySideRow {
  const SideBySideRow(this.left, this.right);
  final DiffLine? left;
  final DiffLine? right;
}

/// Pairs deletions with insertions so changed lines sit side by side.
List<SideBySideRow> sideBySide(DiffResult d) {
  final out = <SideBySideRow>[];
  final lines = d.lines;
  var i = 0;
  while (i < lines.length) {
    if (lines[i].op == DiffOp.equal) {
      out.add(SideBySideRow(lines[i], lines[i]));
      i++;
      continue;
    }
    final dels = <DiffLine>[];
    final ins = <DiffLine>[];
    while (i < lines.length && lines[i].op != DiffOp.equal) {
      (lines[i].op == DiffOp.delete ? dels : ins).add(lines[i]);
      i++;
    }
    final n = dels.length > ins.length ? dels.length : ins.length;
    for (var k = 0; k < n; k++) {
      out.add(SideBySideRow(k < dels.length ? dels[k] : null, k < ins.length ? ins[k] : null));
    }
  }
  return out;
}

/// Plain-text report of a comparison.
String compareReport(CompareResult r, {required String nameA, required String nameB}) {
  final b = StringBuffer()
    ..writeln('Config comparison')
    ..writeln('A: $nameA (${r.a.format.label})')
    ..writeln('B: $nameB (${r.b.format.label})')
    ..writeln();
  if (!r.a.ok) b.writeln('A does not parse: ${r.a.error!.describe()}');
  if (!r.b.ok) b.writeln('B does not parse: ${r.b.error!.describe()}');
  final s = r.semantic;
  if (s != null) {
    b.writeln(
      'Semantic differences: ${s.added} added, ${s.removed} removed, ${s.changed} changed, ${s.typeChanged} type changes',
    );
    for (final n in {...r.a.notes, ...r.b.notes}) {
      b.writeln('  note: $n');
    }
    for (final c in s.changes) {
      b.writeln('  ${c.kind.symbol} ${c.describe()}');
    }
    if (s.identical) b.writeln('  The documents contain the same data.');
  }
  b
    ..writeln()
    ..writeln(
      'Text differences: ${r.text.insertions} line(s) added, ${r.text.deletions} line(s) removed'
      '${r.ignoreWhitespace ? ' (whitespace ignored)' : ''}${r.text.truncated ? ' (coarse diff: inputs very different)' : ''}',
    );
  if (!r.text.identical) b.write(r.unified);
  return b.toString();
}

/// Short type/value text for a change cell.
String changeValueText(Object? v) => '${jsonDetailedType(v)} ${jsonPreview(v)}';
