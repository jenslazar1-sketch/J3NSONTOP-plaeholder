import 'glob.dart';

/// How a file-name search pattern is interpreted.
enum NameMatchMode {
  substring('Contains', 'Part of the name, e.g. "save"'),
  glob('Glob', 'Wildcards, e.g. *.json or **/save*.json'),
  regex('Regex', 'Regular expression on the relative path');

  const NameMatchMode(this.label, this.hint);
  final String label;
  final String hint;
}

/// A compiled file-name query. Substring and glob matching are linear-time
/// and run on the calling isolate; regex matching must be evaluated inside
/// `runBounded` because a user regex can backtrack catastrophically.
class NameQuery {
  NameQuery._(this.mode, this.pattern, this.caseSensitive, this._glob, this._regex);

  /// Validates and compiles. Throws [FormatException] with a readable
  /// message for an empty pattern, a bad glob or an invalid regex.
  factory NameQuery.compile(String pattern, NameMatchMode mode, {bool caseSensitive = false}) {
    if (pattern.trim().isEmpty) throw const FormatException('Enter a pattern to search for');
    switch (mode) {
      case NameMatchMode.substring:
        return NameQuery._(mode, pattern, caseSensitive, null, null);
      case NameMatchMode.glob:
        return NameQuery._(mode, pattern, caseSensitive, Glob(pattern, caseSensitive: caseSensitive), null);
      case NameMatchMode.regex:
        try {
          return NameQuery._(mode, pattern, caseSensitive, null, RegExp(pattern, caseSensitive: caseSensitive));
        } on FormatException catch (e) {
          throw FormatException('Invalid regular expression: ${e.message}');
        }
    }
  }

  final NameMatchMode mode;
  final String pattern;
  final bool caseSensitive;
  final Glob? _glob;
  final RegExp? _regex;

  bool get needsBoundedEvaluation => mode == NameMatchMode.regex;

  /// [relativePath] uses forward slashes. Substring mode looks at the file
  /// name only; glob follows [Glob] rules; regex searches the relative path.
  bool matches(String relativePath) {
    switch (mode) {
      case NameMatchMode.substring:
        final slash = relativePath.lastIndexOf('/');
        final name = slash < 0 ? relativePath : relativePath.substring(slash + 1);
        return caseSensitive ? name.contains(pattern) : name.toLowerCase().contains(pattern.toLowerCase());
      case NameMatchMode.glob:
        return _glob!.matches(relativePath);
      case NameMatchMode.regex:
        return _regex!.hasMatch(relativePath);
    }
  }
}

/// Top-level so it can run inside `runBounded`: returns the indices of
/// [paths] matching the regex.
List<int> regexMatchIndices(String pattern, bool caseSensitive, List<String> paths) {
  final re = RegExp(pattern, caseSensitive: caseSensitive);
  return [
    for (var i = 0; i < paths.length; i++)
      if (re.hasMatch(paths[i])) i,
  ];
}
