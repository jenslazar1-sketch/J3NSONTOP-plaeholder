/// JSON Merge Patch (RFC 7386).
library;

import 'json_value.dart';

/// Applies [patch] to [target] and returns the result. Neither input is
/// modified. Implements the algorithm of RFC 7386 section 2:
///
/// ```
/// define MergePatch(Target, Patch):
///   if Patch is an Object:
///     if Target is not an Object: Target = {}
///     for each Name/Value pair in Patch:
///       if Value is null: remove Name from Target (if present)
///       else: Target[Name] = MergePatch(Target[Name], Value)
///     return Target
///   else:
///     return Patch
/// ```
Object? applyMergePatch(Object? target, Object? patch) {
  if (patch is Map<String, Object?>) {
    final result = target is Map<String, Object?> ? <String, Object?>{...target} : <String, Object?>{};
    for (final e in patch.entries) {
      if (e.value == null) {
        result.remove(e.key);
      } else {
        result[e.key] = applyMergePatch(result[e.key], e.value);
      }
    }
    return result;
  }
  return jsonDeepCopy(patch);
}

/// Describes what a patch does, one line per leaf operation (for previews
/// of a preset without a target document).
List<String> describeMergePatch(Object? patch, [List<Object> path = const []]) {
  if (patch is! Map<String, Object?>) return ['${formatJsonPath(path)} = ${jsonPreview(patch)}'];
  final out = <String>[];
  for (final e in patch.entries) {
    final p = [...path, e.key];
    if (e.value == null) {
      out.add('${formatJsonPath(p)} removed');
    } else if (e.value is Map<String, Object?> && (e.value! as Map<String, Object?>).isEmpty) {
      out.add('${formatJsonPath(p)} made an object (existing keys kept)');
    } else if (e.value is Map<String, Object?>) {
      out.addAll(describeMergePatch(e.value, p));
    } else {
      out.add('${formatJsonPath(p)} = ${jsonPreview(e.value)}');
    }
  }
  return out;
}
