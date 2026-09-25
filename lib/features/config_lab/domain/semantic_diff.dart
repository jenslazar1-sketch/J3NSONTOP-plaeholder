/// Structural (semantic) comparison of two JSON-like values.
///
/// Objects are compared key by key (key order is ignored). Arrays are
/// aligned with a Myers diff over the canonical JSON of their items, so an
/// insertion at the front reports one added item instead of shifting every
/// index; adjacent removed/added items are paired as changes (and compared
/// recursively when both are containers of the same kind).
library;

import 'dart:convert';

import '../../../core/text/diff.dart';
import 'json_value.dart';

enum ChangeKind {
  added('ADDED', '+'),
  removed('REMOVED', '-'),
  changed('CHANGED', '~'),
  typeChanged('TYPE CHANGED', '!');

  const ChangeKind(this.label, this.symbol);
  final String label;
  final String symbol;
}

class SemanticChange {
  const SemanticChange({required this.kind, required this.path, this.oldValue, this.newValue});

  final ChangeKind kind;
  final List<Object> path;
  final Object? oldValue;
  final Object? newValue;

  String get pathLabel => formatJsonPath(path);
  String get oldType => jsonDetailedType(oldValue);
  String get newType => jsonDetailedType(newValue);

  String describe() => switch (kind) {
    ChangeKind.added => '$pathLabel added: ${jsonPreview(newValue)}',
    ChangeKind.removed => '$pathLabel removed (was ${jsonPreview(oldValue)})',
    ChangeKind.changed => '$pathLabel: ${jsonPreview(oldValue)} -> ${jsonPreview(newValue)}',
    ChangeKind.typeChanged => '$pathLabel: $oldType ${jsonPreview(oldValue)} -> $newType ${jsonPreview(newValue)}',
  };
}

class SemanticDiffResult {
  const SemanticDiffResult(this.changes);
  final List<SemanticChange> changes;

  int count(ChangeKind k) => changes.where((c) => c.kind == k).length;
  int get added => count(ChangeKind.added);
  int get removed => count(ChangeKind.removed);
  int get changed => count(ChangeKind.changed);
  int get typeChanged => count(ChangeKind.typeChanged);
  bool get identical => changes.isEmpty;
}

/// Kind used to decide between "changed" and "type changed". Integers and
/// floats are both numbers here: 1 -> 1.5 is a value change.
String _kind(Object? v) => switch (v) {
  num() => 'number',
  _ => jsonTypeOf(v).label,
};

SemanticDiffResult semanticDiff(Object? a, Object? b) {
  final out = <SemanticChange>[];
  _diff(a, b, const [], out);
  return SemanticDiffResult(out);
}

void _diff(Object? a, Object? b, List<Object> path, List<SemanticChange> out) {
  if (a is Map<Object?, Object?> && b is Map<Object?, Object?>) {
    for (final e in a.entries) {
      final key = '${e.key}';
      if (!b.containsKey(e.key)) {
        out.add(SemanticChange(kind: ChangeKind.removed, path: [...path, key], oldValue: e.value));
      } else {
        _diff(e.value, b[e.key], [...path, key], out);
      }
    }
    for (final e in b.entries) {
      if (!a.containsKey(e.key)) {
        out.add(SemanticChange(kind: ChangeKind.added, path: [...path, '${e.key}'], newValue: e.value));
      }
    }
    return;
  }
  if (a is List<Object?> && b is List<Object?>) {
    _diffLists(a, b, path, out);
    return;
  }
  if (jsonDeepEquals(a, b, strictNumbers: false)) return;
  final kind = _kind(a) == _kind(b) ? ChangeKind.changed : ChangeKind.typeChanged;
  out.add(SemanticChange(kind: kind, path: path, oldValue: a, newValue: b));
}

String _canon(Object? v) {
  try {
    return jsonEncode(v);
  } catch (_) {
    return '$v';
  }
}

void _diffLists(List<Object?> a, List<Object?> b, List<Object> path, List<SemanticChange> out) {
  final d = LineDiff.diffLines([for (final x in a) _canon(x)], [for (final x in b) _canon(x)]);
  final lines = d.lines;
  var i = 0;
  while (i < lines.length) {
    if (lines[i].op == DiffOp.equal) {
      i++;
      continue;
    }
    final dels = <DiffLine>[];
    final ins = <DiffLine>[];
    while (i < lines.length && lines[i].op != DiffOp.equal) {
      (lines[i].op == DiffOp.delete ? dels : ins).add(lines[i]);
      i++;
    }
    final pairs = dels.length < ins.length ? dels.length : ins.length;
    for (var k = 0; k < pairs; k++) {
      final oldIdx = dels[k].oldLine! - 1;
      final newIdx = ins[k].newLine! - 1;
      _diff(a[oldIdx], b[newIdx], [...path, newIdx], out);
    }
    for (var k = pairs; k < dels.length; k++) {
      final oldIdx = dels[k].oldLine! - 1;
      out.add(SemanticChange(kind: ChangeKind.removed, path: [...path, oldIdx], oldValue: a[oldIdx]));
    }
    for (var k = pairs; k < ins.length; k++) {
      final newIdx = ins[k].newLine! - 1;
      out.add(SemanticChange(kind: ChangeKind.added, path: [...path, newIdx], newValue: b[newIdx]));
    }
  }
}
