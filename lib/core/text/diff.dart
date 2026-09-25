/// Line-based diff (Myers O((N+M)D) algorithm) shared by the text diff tool,
/// config comparison, replace previews and mod-apply previews.
library;

enum DiffOp { equal, insert, delete }

class DiffLine {
  const DiffLine(this.op, this.text, {this.oldLine, this.newLine});
  final DiffOp op;
  final String text;

  /// 1-based line numbers in the old/new text (null when not present).
  final int? oldLine;
  final int? newLine;
}

class DiffResult {
  const DiffResult(this.lines, {this.truncated = false});
  final List<DiffLine> lines;

  /// True when inputs exceeded the edit budget and a coarse diff was used.
  final bool truncated;

  int get insertions => lines.where((l) => l.op == DiffOp.insert).length;
  int get deletions => lines.where((l) => l.op == DiffOp.delete).length;
  bool get identical => insertions == 0 && deletions == 0;
}

class DiffOptions {
  const DiffOptions({this.ignoreWhitespace = false, this.ignoreCase = false, this.maxEditDistance = 20000});
  final bool ignoreWhitespace;
  final bool ignoreCase;

  /// Upper bound on D (edit distance) explored before falling back to a
  /// coarse "replace remaining block" diff. Keeps worst cases bounded.
  final int maxEditDistance;
}

abstract final class LineDiff {
  static List<String> _split(String s) {
    if (s.isEmpty) return const [];
    final lines = s.split(RegExp(r'\r\n|\r|\n'));
    if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
    return lines;
  }

  static DiffResult diffText(String a, String b, {DiffOptions options = const DiffOptions()}) =>
      diffLines(_split(a), _split(b), options: options);

  static DiffResult diffLines(List<String> a, List<String> b, {DiffOptions options = const DiffOptions()}) {
    String norm(String s) {
      var t = s;
      if (options.ignoreWhitespace) t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (options.ignoreCase) t = t.toLowerCase();
      return t;
    }

    final na = a.map(norm).toList();
    final nb = b.map(norm).toList();

    // Trim common prefix/suffix (cheap and common).
    var start = 0;
    while (start < na.length && start < nb.length && na[start] == nb[start]) {
      start++;
    }
    var endA = na.length, endB = nb.length;
    while (endA > start && endB > start && na[endA - 1] == nb[endB - 1]) {
      endA--;
      endB--;
    }

    final out = <DiffLine>[];
    for (var i = 0; i < start; i++) {
      out.add(DiffLine(DiffOp.equal, b[i], oldLine: i + 1, newLine: i + 1));
    }
    final (middle, truncated) = _myers(na, nb, a, b, start, endA, start, endB, options.maxEditDistance);
    out.addAll(middle);
    for (var i = 0; i < na.length - endA; i++) {
      out.add(DiffLine(DiffOp.equal, b[endB + i], oldLine: endA + i + 1, newLine: endB + i + 1));
    }
    return DiffResult(out, truncated: truncated);
  }

  static (List<DiffLine>, bool) _myers(
    List<String> na,
    List<String> nb,
    List<String> a,
    List<String> b,
    int a0,
    int a1,
    int b0,
    int b1,
    int maxD,
  ) {
    final n = a1 - a0, m = b1 - b0;
    if (n == 0 && m == 0) return (const [], false);
    final max = n + m;
    final offset = max;
    final v = List<int>.filled(2 * max + 2, 0);
    final trace = <List<int>>[];
    var found = false;
    final limit = max < maxD ? max : maxD;
    outer:
    for (var d = 0; d <= limit; d++) {
      trace.add(List<int>.of(v));
      for (var k = -d; k <= d; k += 2) {
        int x;
        if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) {
          x = v[offset + k + 1];
        } else {
          x = v[offset + k - 1] + 1;
        }
        var y = x - k;
        while (x < n && y < m && na[a0 + x] == nb[b0 + y]) {
          x++;
          y++;
        }
        v[offset + k] = x;
        if (x >= n && y >= m) {
          found = true;
          break outer;
        }
      }
    }

    if (!found) {
      // Budget exceeded: report the block as deleted + inserted.
      return (
        [
          for (var i = a0; i < a1; i++) DiffLine(DiffOp.delete, a[i], oldLine: i + 1),
          for (var j = b0; j < b1; j++) DiffLine(DiffOp.insert, b[j], newLine: j + 1),
        ],
        true,
      );
    }

    // Backtrack.
    final rev = <DiffLine>[];
    var x = n, y = m;
    for (var d = trace.length - 1; d >= 0; d--) {
      final vd = trace[d];
      final k = x - y;
      int prevK;
      if (k == -d || (k != d && vd[offset + k - 1] < vd[offset + k + 1])) {
        prevK = k + 1;
      } else {
        prevK = k - 1;
      }
      final prevX = vd[offset + prevK];
      final prevY = prevX - prevK;
      while (x > prevX && y > prevY) {
        rev.add(DiffLine(DiffOp.equal, b[b0 + y - 1], oldLine: a0 + x, newLine: b0 + y));
        x--;
        y--;
      }
      if (d > 0) {
        if (x == prevX) {
          rev.add(DiffLine(DiffOp.insert, b[b0 + y - 1], newLine: b0 + y));
          y--;
        } else {
          rev.add(DiffLine(DiffOp.delete, a[a0 + x - 1], oldLine: a0 + x));
          x--;
        }
      }
    }
    return (rev.reversed.toList(), false);
  }

  /// Unified diff text (like `diff -u`) with [context] lines of context.
  static String unified(DiffResult r, {String oldName = 'a', String newName = 'b', int context = 3}) {
    final buf = StringBuffer('--- $oldName\n+++ $newName\n');
    final lines = r.lines;
    var i = 0;
    while (i < lines.length) {
      while (i < lines.length && lines[i].op == DiffOp.equal) {
        i++;
      }
      if (i >= lines.length) break;
      final hunkStart = (i - context).clamp(0, lines.length);
      var j = i;
      var lastChange = i;
      while (j < lines.length && (j - lastChange) <= context * 2) {
        if (lines[j].op != DiffOp.equal) lastChange = j;
        j++;
      }
      final hunkEnd = (lastChange + context + 1).clamp(0, lines.length);
      final hunk = lines.sublist(hunkStart, hunkEnd);
      final oldStart =
          hunk
              .firstWhere((l) => l.oldLine != null, orElse: () => const DiffLine(DiffOp.equal, '', oldLine: 0))
              .oldLine ??
          0;
      final newStart =
          hunk
              .firstWhere((l) => l.newLine != null, orElse: () => const DiffLine(DiffOp.equal, '', newLine: 0))
              .newLine ??
          0;
      final oldCount = hunk.where((l) => l.op != DiffOp.insert).length;
      final newCount = hunk.where((l) => l.op != DiffOp.delete).length;
      buf.writeln('@@ -$oldStart,$oldCount +$newStart,$newCount @@');
      for (final l in hunk) {
        final prefix = switch (l.op) {
          DiffOp.equal => ' ',
          DiffOp.insert => '+',
          DiffOp.delete => '-',
        };
        buf.writeln('$prefix${l.text}');
      }
      i = hunkEnd;
    }
    return buf.toString();
  }
}
