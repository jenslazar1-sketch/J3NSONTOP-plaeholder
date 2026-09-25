import 'dart:math' as math;

/// Levenshtein edit distance (insert/delete/substitute, each cost 1).
int levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var curr = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    curr[0] = i;
    final ca = a.codeUnitAt(i - 1);
    for (var j = 1; j <= b.length; j++) {
      final cost = ca == b.codeUnitAt(j - 1) ? 0 : 1;
      curr[j] = math.min(math.min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
    }
    final t = prev;
    prev = curr;
    curr = t;
  }
  return prev[b.length];
}

/// "Did you mean" candidates for [input], closest first.
///
/// A candidate qualifies when its edit distance (case-insensitive) is within
/// a length-dependent budget (1 for short words, up to 3), or when it starts
/// with the input (typed a prefix of a longer name).
List<String> didYouMean(String input, Iterable<String> candidates, {int limit = 3}) {
  final q = input.toLowerCase().trim();
  if (q.isEmpty) return const [];
  final budget = (q.length / 3).ceil().clamp(1, 3);
  final scored = <(String, int)>[];
  final seen = <String>{};
  for (final c in candidates) {
    if (!seen.add(c)) continue;
    final lc = c.toLowerCase();
    if (lc == q) continue;
    final d = levenshtein(q, lc);
    final prefix = q.length >= 2 && lc.startsWith(q);
    if (prefix) {
      // Typed the start of a longer name: rank it like a one-letter typo.
      scored.add((c, d < 1 ? d : 1));
    } else if (d <= budget) {
      scored.add((c, d));
    }
  }
  scored.sort((a, b) {
    final c = a.$2.compareTo(b.$2);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [for (final s in scored.take(limit)) s.$1];
}

/// Formats suggestions as `a, b or c`.
String joinAlternatives(List<String> items) {
  if (items.isEmpty) return '';
  if (items.length == 1) return items.first;
  return '${items.sublist(0, items.length - 1).join(', ')} or ${items.last}';
}
