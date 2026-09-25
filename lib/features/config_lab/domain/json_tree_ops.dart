/// Immutable edit operations on JSON values used by the tree editor and the
/// save-data form. Each operation returns a new root; containers along the
/// edited path are copied, untouched subtrees are shared.
library;

import 'json_value.dart';

class JsonEditError implements Exception {
  const JsonEditError(this.message);
  final String message;
  @override
  String toString() => message;
}

Object? _replaceAt(Object? node, List<Object> path, int depth, Object? Function(Object? current) change) {
  if (depth == path.length) return change(node);
  final seg = path[depth];
  if (seg is String && node is Map<String, Object?>) {
    if (!node.containsKey(seg)) throw JsonEditError('No property "$seg" at ${formatJsonPath(path.sublist(0, depth))}');
    final copy = <String, Object?>{};
    for (final e in node.entries) {
      copy[e.key] = e.key == seg ? _replaceAt(e.value, path, depth + 1, change) : e.value;
    }
    return copy;
  }
  if (seg is int && node is List<Object?>) {
    if (seg < 0 || seg >= node.length) {
      throw JsonEditError('Index $seg is out of range at ${formatJsonPath(path.sublist(0, depth))}');
    }
    final copy = List<Object?>.of(node);
    copy[seg] = _replaceAt(node[seg], path, depth + 1, change);
    return copy;
  }
  throw JsonEditError('Path ${formatJsonPath(path)} does not exist');
}

/// Replaces the value at [path] (the root when [path] is empty).
Object? setValueAt(Object? root, List<Object> path, Object? value) => _replaceAt(root, path, 0, (_) => value);

/// Renames property [oldKey] of the object at [objectPath], keeping its
/// position. Rejects empty-to-duplicate renames.
Object? renameKeyAt(Object? root, List<Object> objectPath, String oldKey, String newKey) {
  return _replaceAt(root, objectPath, 0, (node) {
    if (node is! Map<String, Object?>) throw JsonEditError('${formatJsonPath(objectPath)} is not an object');
    if (!node.containsKey(oldKey)) throw JsonEditError('No property "$oldKey"');
    if (oldKey == newKey) return node;
    if (node.containsKey(newKey)) throw JsonEditError('A property named "$newKey" already exists');
    return <String, Object?>{for (final e in node.entries) (e.key == oldKey ? newKey : e.key): e.value};
  });
}

/// Adds property [key] to the object at [objectPath] (appended at the end).
Object? addPropertyAt(Object? root, List<Object> objectPath, String key, Object? value) {
  return _replaceAt(root, objectPath, 0, (node) {
    if (node is! Map<String, Object?>) throw JsonEditError('${formatJsonPath(objectPath)} is not an object');
    if (node.containsKey(key)) throw JsonEditError('A property named "$key" already exists');
    return <String, Object?>{...node, key: value};
  });
}

/// Inserts [value] into the array at [arrayPath] at [index] (default: end).
Object? insertItemAt(Object? root, List<Object> arrayPath, Object? value, {int? index}) {
  return _replaceAt(root, arrayPath, 0, (node) {
    if (node is! List<Object?>) throw JsonEditError('${formatJsonPath(arrayPath)} is not an array');
    final at = index ?? node.length;
    if (at < 0 || at > node.length) throw JsonEditError('Index $at is out of range');
    return List<Object?>.of(node)..insert(at, value);
  });
}

/// Removes the property or array item at [path] (not the root).
Object? removeAt(Object? root, List<Object> path) {
  if (path.isEmpty) throw const JsonEditError('The root value cannot be deleted');
  final parent = path.sublist(0, path.length - 1);
  final last = path.last;
  return _replaceAt(root, parent, 0, (node) {
    if (last is String && node is Map<String, Object?>) {
      if (!node.containsKey(last)) throw JsonEditError('No property "$last"');
      return <String, Object?>{
        for (final e in node.entries)
          if (e.key != last) e.key: e.value,
      };
    }
    if (last is int && node is List<Object?>) {
      if (last < 0 || last >= node.length) throw JsonEditError('Index $last is out of range');
      return List<Object?>.of(node)..removeAt(last);
    }
    throw JsonEditError('Path ${formatJsonPath(path)} does not exist');
  });
}

/// Moves an array item from [from] to [to] (indices in the original array).
Object? moveItemAt(Object? root, List<Object> arrayPath, int from, int to) {
  return _replaceAt(root, arrayPath, 0, (node) {
    if (node is! List<Object?>) throw JsonEditError('${formatJsonPath(arrayPath)} is not an array');
    if (from < 0 || from >= node.length || to < 0 || to >= node.length) {
      throw const JsonEditError('Index out of range');
    }
    final copy = List<Object?>.of(node);
    final item = copy.removeAt(from);
    copy.insert(to, item);
    return copy;
  });
}

/// Scalar types the tree editor can assign.
enum ScalarKind { string, number, boolean, nul }

final RegExp _jsonNumber = RegExp(r'^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$');

/// Parses user input for a scalar of [kind]; throws [JsonEditError] with a
/// helpful message when the text is not valid for that type.
Object? parseScalarInput(ScalarKind kind, String input) {
  switch (kind) {
    case ScalarKind.string:
      return input;
    case ScalarKind.number:
      final t = input.trim();
      if (!_jsonNumber.hasMatch(t)) {
        throw const JsonEditError('Not a JSON number (examples: 42, -3.5, 1e6)');
      }
      final isInt = !t.contains('.') && !t.contains('e') && !t.contains('E');
      if (isInt) {
        final v = int.tryParse(t);
        if (v != null) return v;
        throw const JsonEditError('Integer is too large');
      }
      final d = double.parse(t);
      if (!d.isFinite) throw const JsonEditError('Number is out of range');
      return d;
    case ScalarKind.boolean:
      final t = input.trim();
      if (t == 'true') return true;
      if (t == 'false') return false;
      throw const JsonEditError('Boolean must be true or false');
    case ScalarKind.nul:
      return null;
  }
}
