/// Glob patterns for file filters.
///
/// Supported syntax:
/// * `*` any run of characters except `/`
/// * `?` one character except `/`
/// * `**/` zero or more whole folders, `**` anything including `/`
/// * `[abc]`, `[a-z]`, `[!a-z]` / `[^a-z]` character classes
/// * `{a,b,c}` alternatives (nestable, at most [Glob.maxAlternatives])
/// * `\x` escapes a special character
///
/// A pattern without `/` matches the file **name** at any depth (`*.json`),
/// a pattern with `/` matches the whole relative path (`data/*.csv`,
/// `**/save*.json`). A leading `/` anchors to the root and is ignored.
///
/// Matching is a non-backtracking state-set simulation, so it runs in
/// O(pattern x name) time for any input: no pattern can freeze the app.
library;

class Glob {
  Glob(this.pattern, {this.caseSensitive = true}) {
    var src = pattern.trim().replaceAll('\\/', '/');
    if (src.isEmpty) throw const FormatException('Empty glob pattern');
    if (src.startsWith('/')) {
      src = src.substring(1);
      matchesPath = true;
    } else {
      matchesPath = _containsUnescapedSlash(src);
    }
    final alternatives = _expandBraces(src);
    _programs = [for (final alt in alternatives) _compile(caseSensitive ? alt : alt.toLowerCase())];
  }

  static const int maxAlternatives = 256;

  final String pattern;
  final bool caseSensitive;

  /// True when the pattern is matched against the whole relative path.
  late final bool matchesPath;
  late final List<List<_Tok>> _programs;

  /// Matches a relative path using forward slashes (e.g. `game/data/a.csv`).
  bool matches(String relativePath) {
    var subject = relativePath.replaceAll('\\', '/');
    if (!matchesPath) {
      final slash = subject.lastIndexOf('/');
      if (slash >= 0) subject = subject.substring(slash + 1);
    }
    if (!caseSensitive) subject = subject.toLowerCase();
    for (final prog in _programs) {
      if (_run(prog, subject)) return true;
    }
    return false;
  }

  static bool _containsUnescapedSlash(String s) {
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == '\\') {
        i++;
      } else if (c == '/') {
        return true;
      }
    }
    return false;
  }

  /// Expands `{a,b}` groups into alternatives (depth-first, nestable).
  static List<String> _expandBraces(String s) {
    final open = _findTopBrace(s);
    if (open == null) return [s];
    final (start, end, parts) = open;
    final prefix = s.substring(0, start);
    final suffix = s.substring(end + 1);
    final out = <String>[];
    for (final part in parts) {
      for (final expanded in _expandBraces('$prefix$part$suffix')) {
        out.add(expanded);
        if (out.length > maxAlternatives) {
          throw const FormatException('Too many {a,b} alternatives in the pattern (limit $maxAlternatives)');
        }
      }
    }
    return out;
  }

  /// Finds the first balanced `{...}` containing a top-level comma.
  static (int, int, List<String>)? _findTopBrace(String s) {
    for (var i = 0; i < s.length; i++) {
      if (s[i] == '\\') {
        i++;
        continue;
      }
      if (s[i] != '{') continue;
      var depth = 0;
      final parts = <String>[];
      var partStart = i + 1;
      for (var j = i; j < s.length; j++) {
        final c = s[j];
        if (c == '\\') {
          j++;
          continue;
        }
        if (c == '{') {
          depth++;
        } else if (c == '}') {
          depth--;
          if (depth == 0) {
            parts.add(s.substring(partStart, j));
            if (parts.length > 1) return (i, j, parts);
            break; // `{x}` without comma is literal; keep scanning after it
          }
        } else if (c == ',' && depth == 1) {
          parts.add(s.substring(partStart, j));
          partStart = j + 1;
        }
      }
    }
    return null;
  }

  static List<_Tok> _compile(String s) {
    final toks = <_Tok>[];
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      switch (c) {
        case '\\':
          if (i + 1 < s.length) {
            i++;
            toks.add(_Tok.literal(s.codeUnitAt(i)));
          } else {
            toks.add(_Tok.literal(c.codeUnitAt(0)));
          }
        case '*':
          var j = i;
          while (j < s.length && s[j] == '*') {
            j++;
          }
          final run = j - i;
          final atSegmentStart = i == 0 || s[i - 1] == '/';
          final atSegmentEnd = j >= s.length || s[j] == '/';
          if (run >= 2 && atSegmentStart && atSegmentEnd) {
            if (j < s.length) {
              toks.add(const _Tok(_K.globStarSlash));
              i = j; // consume the '/'
            } else {
              toks.add(const _Tok(_K.globStar));
              i = j - 1;
            }
          } else {
            // `*`, or `**` inside a name, behaves like a single star.
            if (toks.isEmpty || toks.last.kind != _K.star) toks.add(const _Tok(_K.star));
            i = j - 1;
          }
        case '?':
          toks.add(const _Tok(_K.any));
        case '[':
          final parsed = _parseClass(s, i);
          if (parsed == null) {
            toks.add(_Tok.literal('['.codeUnitAt(0)));
          } else {
            toks.add(parsed.$1);
            i = parsed.$2;
          }
        default:
          toks.add(_Tok.literal(s.codeUnitAt(i)));
      }
    }
    return toks;
  }

  static (_Tok, int)? _parseClass(String s, int open) {
    var i = open + 1;
    var negated = false;
    if (i < s.length && (s[i] == '!' || s[i] == '^')) {
      negated = true;
      i++;
    }
    final ranges = <int>[];
    var first = true;
    while (i < s.length) {
      var c = s.codeUnitAt(i);
      if (s[i] == ']' && !first) {
        return (_Tok(_K.cls, ranges: ranges, negated: negated), i);
      }
      first = false;
      if (s[i] == '\\' && i + 1 < s.length) {
        i++;
        c = s.codeUnitAt(i);
      }
      if (i + 2 < s.length && s[i + 1] == '-' && s[i + 2] != ']') {
        var hi = s.codeUnitAt(i + 2);
        var lo = c;
        if (hi < lo) (lo, hi) = (hi, lo);
        ranges
          ..add(lo)
          ..add(hi);
        i += 3;
      } else {
        ranges
          ..add(c)
          ..add(c);
        i++;
      }
    }
    return null; // unterminated: treat '[' literally
  }

  static const int _slash = 0x2F;

  static bool _run(List<_Tok> prog, String subject) {
    final n = prog.length;
    var cur = List<bool>.filled(n + 1, false);
    var curInside = List<bool>.filled(n + 1, false);
    var next = List<bool>.filled(n + 1, false);
    var nextInside = List<bool>.filled(n + 1, false);

    void close(List<bool> set) {
      for (var i = 0; i < n; i++) {
        if (set[i] && prog[i].isZeroWidthCapable) set[i + 1] = true;
      }
    }

    cur[0] = true;
    close(cur);
    for (var pos = 0; pos < subject.length; pos++) {
      final c = subject.codeUnitAt(pos);
      next.fillRange(0, n + 1, false);
      nextInside.fillRange(0, n + 1, false);
      var any = false;
      for (var i = 0; i < n; i++) {
        final t = prog[i];
        if (curInside[i]) {
          // Inside a `**/` segment run: '/' ends the segment.
          if (c == _slash) {
            next[i] = true;
          } else {
            nextInside[i] = true;
          }
          any = true;
        }
        if (!cur[i]) continue;
        switch (t.kind) {
          case _K.literal:
            if (c == t.code) {
              next[i + 1] = true;
              any = true;
            }
          case _K.any:
            if (c != _slash) {
              next[i + 1] = true;
              any = true;
            }
          case _K.cls:
            if (c != _slash && t.classMatches(c)) {
              next[i + 1] = true;
              any = true;
            }
          case _K.star:
            if (c != _slash) {
              next[i] = true;
              any = true;
            }
          case _K.globStar:
            next[i] = true;
            any = true;
          case _K.globStarSlash:
            if (c == _slash) {
              next[i] = true;
            } else {
              nextInside[i] = true;
            }
            any = true;
        }
      }
      if (!any) return false;
      close(next);
      final t1 = cur;
      cur = next;
      next = t1;
      final t2 = curInside;
      curInside = nextInside;
      nextInside = t2;
    }
    return cur[n];
  }
}

enum _K { literal, any, cls, star, globStar, globStarSlash }

class _Tok {
  const _Tok(this.kind, {this.ranges = const [], this.negated = false}) : code = 0;
  const _Tok.literal(this.code) : kind = _K.literal, ranges = const [], negated = false;

  final _K kind;
  final int code;

  /// Flat list of inclusive [lo, hi] pairs.
  final List<int> ranges;
  final bool negated;

  bool get isZeroWidthCapable => kind == _K.star || kind == _K.globStar || kind == _K.globStarSlash;

  bool classMatches(int c) {
    var hit = false;
    for (var i = 0; i + 1 < ranges.length; i += 2) {
      if (c >= ranges[i] && c <= ranges[i + 1]) {
        hit = true;
        break;
      }
    }
    return hit != negated;
  }
}
