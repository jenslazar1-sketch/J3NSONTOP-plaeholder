import 'dart:isolate';

import '../../../core/text/diff.dart';
import 'common.dart';

/// Outcome of comparing two texts.
class TextDiffOutcome {
  const TextDiffOutcome({required this.result, required this.a, required this.b, required this.editBudget});

  final DiffResult result;

  /// The split input lines (originals, before whitespace/case folding).
  final List<String> a;
  final List<String> b;

  int get linesA => a.length;
  int get linesB => b.length;

  /// Original text of a line on the left side (1-based line number).
  String oldText(DiffLine l) => l.oldLine == null ? l.text : a[l.oldLine! - 1];

  /// Maximum edit distance explored before falling back to a coarse diff.
  final int editBudget;

  int get unchanged => result.lines.length - result.insertions - result.deletions;

  String unified({String oldName = 'a', String newName = 'b', int context = 3}) =>
      LineDiff.unified(result, oldName: oldName, newName: newName, context: context);
}

/// Display row of the unified view: a diff line or a collapsed gap.
class DiffRow {
  const DiffRow.line(DiffLine this.line) : hidden = 0;
  const DiffRow.gap(this.hidden) : line = null;
  final DiffLine? line;

  /// Number of unchanged lines collapsed into this row.
  final int hidden;
}

/// Row of the side-by-side view.
class SideBySideRow {
  const SideBySideRow({this.left, this.right, this.hidden = 0});
  final DiffLine? left;
  final DiffLine? right;
  final int hidden;

  bool get isGap => hidden > 0;

  /// Both sides present and different: a modified line (word diff applies).
  bool get isChangedPair => left != null && right != null && left!.op == DiffOp.delete && right!.op == DiffOp.insert;
}

/// A span of a line for word-level highlighting.
class WordSpan {
  const WordSpan(this.text, this.changed);
  final String text;
  final bool changed;
}

abstract final class TextDiff {
  /// Per-side size guard.
  static const int maxBytes = 8 * 1024 * 1024;
  static const int maxLines = 200000;

  /// Myers keeps one vector of 2(N+M) entries per explored edit step; this
  /// bounds entries (~8 bytes each) so worst cases stay around 32 MB.
  static const int budgetEntries = 4000000;

  /// Inputs up to this many lines (total) are diffed synchronously.
  static const int syncLineLimit = 600;

  static List<String> splitLines(String s) {
    if (s.isEmpty) return const [];
    final lines = s.split(RegExp(r'\r\n|\r|\n'));
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    return lines;
  }

  /// Throws [InputError] when a side exceeds the size guard.
  static void checkSize(String a, String b) {
    for (final (name, s) in [('Left', a), ('Right', b)]) {
      if (s.length > maxBytes) {
        throw InputError('$name text is too large (${s.length} characters; limit $maxBytes)');
      }
    }
  }

  static String _norm(String s, DiffOptions o) {
    var t = s;
    if (o.ignoreWhitespace) t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (o.ignoreCase) t = t.toLowerCase();
    return t;
  }

  /// Edit budget from the size of the differing middle block.
  static int editBudgetFor(List<String> a, List<String> b, DiffOptions o) {
    var start = 0;
    while (start < a.length && start < b.length && _norm(a[start], o) == _norm(b[start], o)) {
      start++;
    }
    var ea = a.length, eb = b.length;
    while (ea > start && eb > start && _norm(a[ea - 1], o) == _norm(b[eb - 1], o)) {
      ea--;
      eb--;
    }
    final middle = (ea - start) + (eb - start);
    if (middle == 0) return 0;
    final budget = budgetEntries ~/ (2 * middle + 2);
    return budget.clamp(16, 20000);
  }

  /// Pure computation; safe to run in an isolate.
  static TextDiffOutcome compute(String a, String b, {bool ignoreWhitespace = false, bool ignoreCase = false}) {
    checkSize(a, b);
    final la = splitLines(a), lb = splitLines(b);
    if (la.length > maxLines || lb.length > maxLines) {
      throw InputError('Too many lines (limit $maxLines per side; got ${la.length} and ${lb.length})');
    }
    final base = DiffOptions(ignoreWhitespace: ignoreWhitespace, ignoreCase: ignoreCase);
    final budget = editBudgetFor(la, lb, base);
    final options = DiffOptions(
      ignoreWhitespace: ignoreWhitespace,
      ignoreCase: ignoreCase,
      maxEditDistance: budget == 0 ? 1 : budget,
    );
    final r = LineDiff.diffLines(la, lb, options: options);
    return TextDiffOutcome(result: r, a: la, b: lb, editBudget: budget);
  }

  /// Small inputs run inline; larger ones in a background isolate.
  static Future<TextDiffOutcome> computeAsync(
    String a,
    String b, {
    bool ignoreWhitespace = false,
    bool ignoreCase = false,
  }) async {
    checkSize(a, b);
    final approxLines = '\n'.allMatches(a).length + '\n'.allMatches(b).length;
    if (approxLines <= syncLineLimit && a.length + b.length < 200000) {
      return compute(a, b, ignoreWhitespace: ignoreWhitespace, ignoreCase: ignoreCase);
    }
    return Isolate.run(
      () => compute(a, b, ignoreWhitespace: ignoreWhitespace, ignoreCase: ignoreCase),
      debugName: 'j3-diff',
    );
  }

  /// Unified rows with at most [context] unchanged lines around changes
  /// (null = show everything).
  static List<DiffRow> unifiedRows(DiffResult r, int? context) {
    final lines = r.lines;
    if (context == null) return [for (final l in lines) DiffRow.line(l)];
    final keep = List<bool>.filled(lines.length, false);
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].op != DiffOp.equal) {
        final from = (i - context).clamp(0, lines.length - 1);
        final to = (i + context).clamp(0, lines.length - 1);
        for (var k = from; k <= to; k++) {
          keep[k] = true;
        }
      }
    }
    final rows = <DiffRow>[];
    var hidden = 0;
    for (var i = 0; i < lines.length; i++) {
      if (keep[i]) {
        if (hidden > 0) {
          rows.add(DiffRow.gap(hidden));
          hidden = 0;
        }
        rows.add(DiffRow.line(lines[i]));
      } else {
        hidden++;
      }
    }
    if (hidden > 0) rows.add(DiffRow.gap(hidden));
    return rows;
  }

  /// Side-by-side rows: deletions and insertions of one change block are
  /// paired line by line.
  static List<SideBySideRow> sideBySideRows(DiffResult r, int? context) {
    final unified = unifiedRows(r, context);
    final rows = <SideBySideRow>[];
    var i = 0;
    while (i < unified.length) {
      final row = unified[i];
      if (row.line == null) {
        rows.add(SideBySideRow(hidden: row.hidden));
        i++;
        continue;
      }
      final l = row.line!;
      if (l.op == DiffOp.equal) {
        rows.add(SideBySideRow(left: l, right: l));
        i++;
        continue;
      }
      final dels = <DiffLine>[];
      final ins = <DiffLine>[];
      while (i < unified.length && unified[i].line != null && unified[i].line!.op != DiffOp.equal) {
        final x = unified[i].line!;
        (x.op == DiffOp.delete ? dels : ins).add(x);
        i++;
      }
      final n = dels.length > ins.length ? dels.length : ins.length;
      for (var k = 0; k < n; k++) {
        rows.add(SideBySideRow(left: k < dels.length ? dels[k] : null, right: k < ins.length ? ins[k] : null));
      }
    }
    return rows;
  }

  static final RegExp _token = RegExp(r'\w+|\s+|[^\w\s]', unicode: true);

  /// Word-level diff of a modified line pair: spans for the old and the
  /// new line, marking changed tokens. Long lines are not tokenised.
  static (List<WordSpan>, List<WordSpan>) wordDiff(String a, String b, {int maxLength = 4000}) {
    if (a.length > maxLength || b.length > maxLength) {
      return ([WordSpan(a, true)], [WordSpan(b, true)]);
    }
    final ta = [for (final m in _token.allMatches(a)) m.group(0)!];
    final tb = [for (final m in _token.allMatches(b)) m.group(0)!];
    final r = LineDiff.diffLines(ta, tb, options: const DiffOptions(maxEditDistance: 400));
    final left = <WordSpan>[], right = <WordSpan>[];
    void add(List<WordSpan> side, String text, bool changed) {
      if (side.isNotEmpty && side.last.changed == changed) {
        side[side.length - 1] = WordSpan(side.last.text + text, changed);
      } else {
        side.add(WordSpan(text, changed));
      }
    }

    for (final t in r.lines) {
      switch (t.op) {
        case DiffOp.equal:
          add(left, t.text, false);
          add(right, t.text, false);
        case DiffOp.delete:
          add(left, t.text, true);
        case DiffOp.insert:
          add(right, t.text, true);
      }
    }
    return (left, right);
  }
}
