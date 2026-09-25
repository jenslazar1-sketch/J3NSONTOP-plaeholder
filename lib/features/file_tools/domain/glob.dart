/// Small, dependency-free glob matching used by the File Tools batch modes
/// (duplicate finder, line endings, whitespace cleanup).
///
/// Syntax:
/// * `*` any characters except `/`, `?` one character except `/`;
/// * `**` any number of path segments (`**/x`, `dir/**`, `a/**/b`);
/// * `[abc]`, `[a-z]`, `[!abc]` character classes;
/// * `{png,jpg}` alternatives.
///
/// A pattern without `/` matches the file or folder NAME at any depth
/// (`*.log`, `node_modules`). A pattern containing `/` matches the path
/// relative to the scanned folder (`game/config/*.ini`); a leading `/` is
/// ignored. Matching is case-insensitive because Windows and default macOS
/// filesystems are.
library;

class GlobPattern {
  GlobPattern(String pattern)
    : source = pattern.trim(),
      _matchesName = !_stripLeadingSlash(pattern.trim()).contains('/'),
      _regex = RegExp('^${_translate(_stripLeadingSlash(pattern.trim()))}\$', caseSensitive: false);

  final String source;
  final bool _matchesName;
  final RegExp _regex;

  static String _stripLeadingSlash(String s) => s.startsWith('/') ? s.substring(1) : s;

  /// [relativePath] uses forward slashes and no leading slash.
  bool matches(String relativePath) {
    final rel = relativePath.replaceAll('\\', '/');
    if (_matchesName) {
      final slash = rel.lastIndexOf('/');
      return _regex.hasMatch(slash < 0 ? rel : rel.substring(slash + 1));
    }
    return _regex.hasMatch(rel);
  }

  /// Translates glob syntax to a regular expression body. Throws
  /// [FormatException] for unbalanced brackets or braces.
  static String _translate(String glob) {
    if (glob.isEmpty) throw const FormatException('Empty glob pattern');
    final out = StringBuffer();
    var i = 0;
    var braceDepth = 0;
    while (i < glob.length) {
      final c = glob[i];
      switch (c) {
        case '*':
          final isDouble = i + 1 < glob.length && glob[i + 1] == '*';
          if (isDouble) {
            final atStart = i == 0 || glob[i - 1] == '/';
            final followedBySlash = i + 2 < glob.length && glob[i + 2] == '/';
            final atEnd = i + 2 == glob.length;
            if (atStart && followedBySlash) {
              // `**/` : zero or more leading segments.
              out.write('(?:.*/)?');
              i += 3;
              continue;
            }
            if (atEnd && i > 0 && glob[i - 1] == '/') {
              // `dir/**` : the folder itself and everything below it. The
              // slash was already written; make it optional together with
              // the rest.
              final s = out.toString();
              out
                ..clear()
                ..write(s.substring(0, s.length - 1))
                ..write('(?:/.*)?');
              i += 2;
              continue;
            }
            out.write('.*');
            i += 2;
            continue;
          }
          out.write('[^/]*');
        case '?':
          out.write('[^/]');
        case '[':
          final close = glob.indexOf(']', i + 2 <= glob.length ? i + 2 : i + 1);
          if (close < 0) throw FormatException('Unclosed "[" in glob "$glob"');
          var body = glob.substring(i + 1, close);
          var negate = false;
          if (body.startsWith('!') || body.startsWith('^')) {
            negate = true;
            body = body.substring(1);
          }
          final escaped = body.replaceAll(r'\', r'\\').replaceAll(']', r'\]').replaceAll('[', r'\[');
          out.write(negate ? '[^/$escaped]' : '[$escaped]');
          i = close + 1;
          continue;
        case '{':
          braceDepth++;
          out.write('(?:');
        case '}':
          if (braceDepth == 0) {
            out.write(r'\}');
          } else {
            braceDepth--;
            out.write(')');
          }
        case ',':
          out.write(braceDepth > 0 ? '|' : ',');
        default:
          out.write(RegExp.escape(c));
      }
      i++;
    }
    if (braceDepth != 0) throw FormatException('Unclosed "{" in glob "$glob"');
    return out.toString();
  }
}

/// Include/exclude filter over relative paths.
class GlobFilter {
  GlobFilter({List<String> include = const [], List<String> exclude = const []})
    : include = [for (final g in include) GlobPattern(g)],
      exclude = [for (final g in exclude) GlobPattern(g)];

  /// Parses user text: patterns separated by commas, semicolons or new
  /// lines (commas inside `{...}` are kept). Throws [FormatException] for an
  /// invalid pattern so the UI can show it inline.
  factory GlobFilter.parse({String include = '', String exclude = ''}) =>
      GlobFilter(include: splitPatterns(include), exclude: splitPatterns(exclude));

  static const GlobFilterAll all = GlobFilterAll._();

  final List<GlobPattern> include;
  final List<GlobPattern> exclude;

  bool get isEmpty => include.isEmpty && exclude.isEmpty;

  /// Whether a file at [relativePath] passes the filter.
  bool acceptsFile(String relativePath) {
    if (exclude.any((g) => g.matches(relativePath))) return false;
    return include.isEmpty || include.any((g) => g.matches(relativePath));
  }

  /// Whether a folder should be descended into (exclusions prune whole
  /// folders; inclusions never prune because they target files).
  bool entersFolder(String relativePath) => !exclude.any((g) => g.matches(relativePath));

  /// Human-readable summary for reports.
  String describe() {
    final parts = <String>[
      if (include.isNotEmpty) 'include ${include.map((g) => g.source).join(', ')}',
      if (exclude.isNotEmpty) 'exclude ${exclude.map((g) => g.source).join(', ')}',
    ];
    return parts.isEmpty ? 'all files' : parts.join('; ');
  }

  static List<String> splitPatterns(String text) {
    final out = <String>[];
    final buf = StringBuffer();
    var depth = 0;
    for (final ch in text.split('')) {
      if (ch == '{') depth++;
      if (ch == '}' && depth > 0) depth--;
      if (depth == 0 && (ch == ',' || ch == ';' || ch == '\n' || ch == '\r')) {
        final t = buf.toString().trim();
        if (t.isNotEmpty) out.add(t);
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    final t = buf.toString().trim();
    if (t.isNotEmpty) out.add(t);
    return out;
  }

  /// Returns an error message for invalid pattern text, or null.
  static String? validate(String text) {
    try {
      for (final p in splitPatterns(text)) {
        GlobPattern(p);
      }
      return null;
    } on FormatException catch (e) {
      return e.message;
    }
  }
}

/// Filter that accepts everything.
class GlobFilterAll implements GlobFilter {
  const GlobFilterAll._();
  @override
  List<GlobPattern> get include => const [];
  @override
  List<GlobPattern> get exclude => const [];
  @override
  bool get isEmpty => true;
  @override
  bool acceptsFile(String relativePath) => true;
  @override
  bool entersFolder(String relativePath) => true;
  @override
  String describe() => 'all files';
}
