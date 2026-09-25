/// Find/replace primitives shared by text search, replace-in-files and
/// batch rename. Everything here is pure and sendable to isolates.
library;

/// What to look for.
class FindSpec {
  const FindSpec({required this.pattern, this.isRegex = false, this.caseSensitive = false, this.wholeWord = false});

  final String pattern;
  final bool isRegex;
  final bool caseSensitive;
  final bool wholeWord;

  /// Compiles to a [RegExp]. Plain text is escaped, so plain searches are
  /// always linear-time. Throws [FormatException] with a readable message.
  RegExp compile() {
    if (pattern.isEmpty) throw const FormatException('Enter something to find');
    var source = isRegex ? pattern : RegExp.escape(pattern);
    if (wholeWord) source = r'\b(?:' + source + r')\b';
    try {
      return RegExp(source, caseSensitive: caseSensitive, multiLine: true);
    } on FormatException catch (e) {
      throw FormatException('Invalid regular expression: ${e.message}');
    }
  }

  /// Validates without keeping the result; returns an error message or null.
  String? validate() {
    try {
      compile();
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }

  Map<String, Object> toJson() => {
    'pattern': pattern,
    'isRegex': isRegex,
    'caseSensitive': caseSensitive,
    'wholeWord': wholeWord,
  };
}

/// Expands a replacement template for one regex match:
/// `$1`..`$99` groups, `${name}` named groups, `$&` or `$0` whole match,
/// `$$` a literal dollar, and the escapes `\n`, `\t`, `\\`.
/// Unknown `$x` sequences are kept literally. Missing groups expand to ''.
String expandReplacement(Match m, String template) {
  final out = StringBuffer();
  for (var i = 0; i < template.length; i++) {
    final c = template[i];
    if (c == r'\' && i + 1 < template.length) {
      final n = template[i + 1];
      if (n == 'n') {
        out.write('\n');
        i++;
        continue;
      }
      if (n == 't') {
        out.write('\t');
        i++;
        continue;
      }
      if (n == r'\') {
        out.write(r'\');
        i++;
        continue;
      }
      out.write(c);
      continue;
    }
    if (c != r'$' || i + 1 >= template.length) {
      out.write(c);
      continue;
    }
    final n = template[i + 1];
    if (n == r'$') {
      out.write(r'$');
      i++;
    } else if (n == '&') {
      out.write(m.group(0));
      i++;
    } else if (n == '{') {
      final close = template.indexOf('}', i + 2);
      final name = close < 0 ? '' : template.substring(i + 2, close);
      if (close > 0 && name.isNotEmpty) {
        final numeric = int.tryParse(name);
        String? value;
        if (numeric != null) {
          value = numeric <= m.groupCount ? m.group(numeric) : null;
        } else if (m is RegExpMatch && m.groupNames.contains(name)) {
          value = m.namedGroup(name);
        } else {
          out.write(template.substring(i, close + 1));
          i = close;
          continue;
        }
        out.write(value ?? '');
        i = close;
      } else {
        out.write(c);
      }
    } else if (_isDigit(n.codeUnitAt(0))) {
      // Longest group number that exists (like JavaScript): with 3 groups
      // `$12` is group 1 followed by "2".
      final end = i + 2;
      if (end < template.length && _isDigit(template.codeUnitAt(end))) {
        final two = int.parse(template.substring(i + 1, end + 1));
        if (two <= m.groupCount) {
          out.write(m.group(two) ?? '');
          i = end;
          continue;
        }
      }
      final one = int.parse(n);
      if (one <= m.groupCount) {
        out.write(m.group(one) ?? '');
      } else {
        out.write('\$$n');
      }
      i++;
    } else {
      out.write(c);
    }
  }
  return out.toString();
}

bool _isDigit(int c) => c >= 48 && c <= 57;

/// Result of replacing in a string.
class ReplaceOutcome {
  const ReplaceOutcome(this.text, this.count);
  final String text;
  final int count;
}

/// Replaces every match of [find] in [input]. In regex mode the
/// [replacement] is a template ([expandReplacement]); in plain mode it is
/// inserted literally.
ReplaceOutcome replaceAllCounting(String input, FindSpec find, String replacement) {
  final re = find.compile();
  var count = 0;
  final out = StringBuffer();
  var last = 0;
  for (final m in re.allMatches(input)) {
    count++;
    out.write(input.substring(last, m.start));
    out.write(find.isRegex ? expandReplacement(m, replacement) : replacement);
    last = m.end;
  }
  if (count == 0) return ReplaceOutcome(input, 0);
  out.write(input.substring(last));
  return ReplaceOutcome(out.toString(), count);
}

/// One matching line of a text search.
class LineMatch {
  const LineMatch({required this.line, required this.column, required this.snippet, required this.ranges});

  /// 1-based line number and 1-based column of the first match.
  final int line;
  final int column;

  /// The line (or a window of it for very long lines).
  final String snippet;

  /// Match ranges inside [snippet] as flat [start, end) pairs.
  final List<int> ranges;

  Map<String, Object> toJson() => {'line': line, 'column': column, 'snippet': snippet, 'ranges': ranges};
}

/// Searches [text] line by line (matches never span lines, like grep).
/// Returns at most [maxLines] matching lines; [totalMatches] receives the
/// number of individual matches found in those lines.
List<LineMatch> searchLines(
  String text,
  RegExp re, {
  int maxLines = 500,
  int snippetWidth = 240,
  void Function(int matches)? totalMatches,
}) {
  final out = <LineMatch>[];
  var total = 0;
  var lineNo = 0;
  var start = 0;
  while (start <= text.length) {
    lineNo++;
    var end = start;
    while (end < text.length) {
      final c = text.codeUnitAt(end);
      if (c == 10 || c == 13) break;
      end++;
    }
    final line = text.substring(start, end);
    // Zero-length matches (e.g. `^$` for empty lines) still count as hits.
    final ms = re.allMatches(line).toList();
    if (ms.isNotEmpty) {
      total += ms.length;
      if (out.length < maxLines) out.add(_snippet(line, lineNo, ms, snippetWidth));
    }
    if (end >= text.length) break;
    // Skip the line terminator (CRLF counts once).
    start = end + ((text.codeUnitAt(end) == 13 && end + 1 < text.length && text.codeUnitAt(end + 1) == 10) ? 2 : 1);
    if (start == text.length) break; // trailing newline: no extra empty line
  }
  totalMatches?.call(total);
  return out;
}

LineMatch _snippet(String line, int lineNo, List<Match> ms, int width) {
  final first = ms.first;
  var from = 0;
  var to = line.length;
  var prefix = '';
  var suffix = '';
  if (line.length > width) {
    from = (first.start - width ~/ 4).clamp(0, line.length);
    to = (from + width).clamp(0, line.length);
    if (from > 0) prefix = '...';
    if (to < line.length) suffix = '...';
  }
  final ranges = <int>[];
  for (final m in ms) {
    if (m.end <= m.start) continue;
    final s = m.start.clamp(from, to);
    final e = m.end.clamp(from, to);
    if (e > s) {
      ranges
        ..add(s - from + prefix.length)
        ..add(e - from + prefix.length);
    }
  }
  return LineMatch(
    line: lineNo,
    column: first.start + 1,
    snippet: '$prefix${line.substring(from, to)}$suffix',
    ranges: ranges,
  );
}
