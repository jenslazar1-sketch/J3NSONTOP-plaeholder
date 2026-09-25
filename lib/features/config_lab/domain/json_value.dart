/// Shared helpers for JSON-like values used across the Config Lab.
///
/// A "JSON value" is one of: `null`, `bool`, `int`, `double`, `String`,
/// `List<Object?>` (array) or `Map<String, Object?>` (object, insertion
/// ordered). Paths into a value are lists of segments where a `String` is an
/// object key and an `int` is an array index.
library;

import 'dart:convert';

/// Coarse JSON type of a value.
enum JsonType {
  object('object'),
  array('array'),
  string('string'),
  number('number'),
  boolean('boolean'),
  nul('null');

  const JsonType(this.label);
  final String label;
}

JsonType jsonTypeOf(Object? v) => switch (v) {
  null => JsonType.nul,
  bool() => JsonType.boolean,
  num() => JsonType.number,
  String() => JsonType.string,
  List<Object?>() => JsonType.array,
  Map<Object?, Object?>() => JsonType.object,
  _ => JsonType.string,
};

/// Finer label used in reports: distinguishes integers from floats.
String jsonDetailedType(Object? v) => switch (v) {
  int() => 'integer',
  double() => 'float',
  _ => jsonTypeOf(v).label,
};

final RegExp _identifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

/// JSONPath notation for a path: `$.player.stats["max hp"][2]`.
String formatJsonPath(Iterable<Object?> path) {
  final b = StringBuffer(r'$');
  for (final seg in path) {
    if (seg is int) {
      b.write('[$seg]');
    } else {
      final key = '$seg';
      if (_identifier.hasMatch(key)) {
        b.write('.$key');
      } else {
        b.write('[${jsonEncode(key)}]');
      }
    }
  }
  return b.toString();
}

/// RFC 6901 JSON Pointer for a path: `/player/stats/max hp/2`.
String formatJsonPointer(Iterable<Object?> path) {
  final b = StringBuffer();
  for (final seg in path) {
    b.write('/');
    b.write('$seg'.replaceAll('~', '~0').replaceAll('/', '~1'));
  }
  return b.toString();
}

/// Reads the value at [path]; returns [JsonLookup.missing] when absent.
JsonLookup lookupPath(Object? root, List<Object> path) {
  Object? cur = root;
  for (final seg in path) {
    if (seg is int && cur is List<Object?>) {
      if (seg < 0 || seg >= cur.length) return const JsonLookup.missing();
      cur = cur[seg];
    } else if (seg is String && cur is Map<String, Object?>) {
      if (!cur.containsKey(seg)) return const JsonLookup.missing();
      cur = cur[seg];
    } else {
      return const JsonLookup.missing();
    }
  }
  return JsonLookup.found(cur);
}

class JsonLookup {
  const JsonLookup.found(this.value) : exists = true;
  const JsonLookup.missing() : exists = false, value = null;
  final bool exists;
  final Object? value;
}

/// Deep equality. With [strictNumbers], `1` (int) and `1.0` (double) differ.
/// With [orderedKeys], objects must also list their keys in the same order.
bool jsonDeepEquals(Object? a, Object? b, {bool strictNumbers = true, bool orderedKeys = false}) {
  if (a is Map<Object?, Object?> && b is Map<Object?, Object?>) {
    if (a.length != b.length) return false;
    if (orderedKeys) {
      final ka = a.keys.toList();
      final kb = b.keys.toList();
      for (var i = 0; i < ka.length; i++) {
        if (ka[i] != kb[i]) return false;
      }
    }
    for (final e in a.entries) {
      if (!b.containsKey(e.key)) return false;
      if (!jsonDeepEquals(e.value, b[e.key], strictNumbers: strictNumbers, orderedKeys: orderedKeys)) {
        return false;
      }
    }
    return true;
  }
  if (a is List<Object?> && b is List<Object?>) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonDeepEquals(a[i], b[i], strictNumbers: strictNumbers, orderedKeys: orderedKeys)) return false;
    }
    return true;
  }
  if (a is num && b is num) {
    if (strictNumbers && (a is int) != (b is int)) return false;
    if (a is double && b is double && a.isNaN && b.isNaN) return true;
    return a == b;
  }
  return a == b;
}

/// First path at which [a] and [b] differ (null when equal). Used to explain
/// failed round-trip verifications.
List<Object>? firstDifference(Object? a, Object? b, {bool strictNumbers = true}) {
  List<Object>? walk(Object? x, Object? y, List<Object> path) {
    if (x is Map<Object?, Object?> && y is Map<Object?, Object?>) {
      for (final k in x.keys) {
        if (!y.containsKey(k)) return [...path, '$k'];
        final d = walk(x[k], y[k], [...path, '$k']);
        if (d != null) return d;
      }
      for (final k in y.keys) {
        if (!x.containsKey(k)) return [...path, '$k'];
      }
      return null;
    }
    if (x is List<Object?> && y is List<Object?>) {
      final n = x.length < y.length ? x.length : y.length;
      for (var i = 0; i < n; i++) {
        final d = walk(x[i], y[i], [...path, i]);
        if (d != null) return d;
      }
      return x.length == y.length ? null : [...path, n];
    }
    return jsonDeepEquals(x, y, strictNumbers: strictNumbers) ? null : path;
  }

  return walk(a, b, const []);
}

/// Deep copy of a JSON value (containers are copied, scalars shared).
Object? jsonDeepCopy(Object? v) {
  if (v is Map<Object?, Object?>) {
    return <String, Object?>{for (final e in v.entries) '${e.key}': jsonDeepCopy(e.value)};
  }
  if (v is List<Object?>) return <Object?>[for (final x in v) jsonDeepCopy(x)];
  return v;
}

/// Short single-line preview used in trees, search results and reports.
String jsonPreview(Object? v, {int max = 80}) {
  String s;
  if (v is Map<Object?, Object?>) {
    s = v.isEmpty ? '{}' : '{${v.length} ${v.length == 1 ? 'key' : 'keys'}}';
  } else if (v is List<Object?>) {
    s = v.isEmpty ? '[]' : '[${v.length} ${v.length == 1 ? 'item' : 'items'}]';
  } else if (v is double && !v.isFinite) {
    s = v.isNaN ? 'NaN' : (v > 0 ? 'Infinity' : '-Infinity');
  } else {
    try {
      s = jsonEncode(v);
    } catch (_) {
      s = '$v';
    }
  }
  s = s.replaceAll('\n', r'\n');
  return s.length > max ? '${s.substring(0, max - 1)}…' : s;
}

/// Canonical scalar text used for searching values: strings raw, other
/// scalars JSON-encoded.
String scalarText(Object? v) => v is String ? v : (v is double && !v.isFinite ? '$v' : jsonEncode(v));

/// Whether [v] is a container (object or array).
bool isContainer(Object? v) => v is Map<Object?, Object?> || v is List<Object?>;
