/// Field search across JSON keys and/or scalar values.
library;

import 'json_value.dart';

enum SearchScope {
  keys('Keys'),
  valuesOnly('Values'),
  both('Keys + values');

  const SearchScope(this.label);
  final String label;
}

class FieldSearchQuery {
  const FieldSearchQuery({
    required this.pattern,
    this.scope = SearchScope.both,
    this.regex = false,
    this.caseSensitive = false,
    this.limit = 500,
  });

  final String pattern;
  final SearchScope scope;
  final bool regex;
  final bool caseSensitive;
  final int limit;
}

class FieldSearchHit {
  const FieldSearchHit({required this.path, required this.keyMatch, required this.valueMatch, required this.preview});

  final List<Object> path;
  final bool keyMatch;
  final bool valueMatch;
  final String preview;

  String get jsonPath => formatJsonPath(path);
}

class FieldSearchResult {
  const FieldSearchResult({required this.hits, required this.truncated, required this.visited});
  final List<FieldSearchHit> hits;

  /// More matches exist than [FieldSearchQuery.limit].
  final bool truncated;

  /// Number of nodes examined.
  final int visited;
}

/// Searches [root]. Throws [FormatException] for an invalid regex.
/// Top-level and free of closures over non-sendable state so it can run in
/// `runBounded` (regex searches are bounded by a time limit).
FieldSearchResult searchJson(Object? root, FieldSearchQuery q) {
  if (q.pattern.isEmpty) return const FieldSearchResult(hits: [], truncated: false, visited: 0);
  final bool Function(String) matches;
  if (q.regex) {
    final re = RegExp(q.pattern, caseSensitive: q.caseSensitive, unicode: true);
    matches = re.hasMatch;
  } else {
    final needle = q.caseSensitive ? q.pattern : q.pattern.toLowerCase();
    matches = q.caseSensitive ? (s) => s.contains(needle) : (s) => s.toLowerCase().contains(needle);
  }
  final checkKeys = q.scope != SearchScope.valuesOnly;
  final checkValues = q.scope != SearchScope.keys;

  final hits = <FieldSearchHit>[];
  var truncated = false;
  var visited = 0;
  // Iterative DFS in document order (children pushed in reverse).
  final stack = <(Object?, List<Object>, String?)>[(root, const [], null)];
  while (stack.isNotEmpty) {
    final (node, path, key) = stack.removeLast();
    visited++;
    final keyMatch = checkKeys && key != null && matches(key);
    var valueMatch = false;
    if (node is Map<String, Object?>) {
      final entries = node.entries.toList();
      for (var i = entries.length - 1; i >= 0; i--) {
        stack.add((entries[i].value, [...path, entries[i].key], entries[i].key));
      }
    } else if (node is List<Object?>) {
      for (var i = node.length - 1; i >= 0; i--) {
        stack.add((node[i], [...path, i], null));
      }
    } else if (checkValues) {
      valueMatch = matches(scalarText(node));
    }
    if (keyMatch || valueMatch) {
      if (hits.length >= q.limit) {
        truncated = true;
        break;
      }
      hits.add(FieldSearchHit(path: path, keyMatch: keyMatch, valueMatch: valueMatch, preview: jsonPreview(node)));
    }
  }
  return FieldSearchResult(hits: hits, truncated: truncated, visited: visited);
}
