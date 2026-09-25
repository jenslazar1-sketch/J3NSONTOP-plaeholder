/// A tiny validator for the JSON Schema subset documented in docs/SAMPLES.md,
/// used only to check the sample save file in tests.
library;

const Set<String> schemaSubsetKeywords = {
  'type',
  'title',
  'description',
  'properties',
  'required',
  'additionalProperties',
  'items',
  'minimum',
  'maximum',
  'minLength',
  'maxLength',
  'pattern',
  'enum',
  'default',
};

/// Every keyword used anywhere in [schema].
Set<String> schemaKeywords(Map<String, dynamic> schema) {
  final out = <String>{...schema.keys};
  final props = schema['properties'];
  if (props is Map) {
    for (final s in props.values) {
      out.addAll(schemaKeywords(s as Map<String, dynamic>));
    }
  }
  final items = schema['items'];
  if (items is Map<String, dynamic>) out.addAll(schemaKeywords(items));
  return out;
}

/// Returns the list of violations (empty when [value] is valid).
List<String> validateSchemaSubset(Object? value, Map<String, dynamic> schema, [String path = r'$']) {
  final errors = <String>[];
  final type = schema['type'];
  final typeOk = switch (type) {
    null => true,
    'object' => value is Map,
    'array' => value is List,
    'string' => value is String,
    'integer' => value is int,
    'number' => value is num,
    'boolean' => value is bool,
    _ => false,
  };
  if (!typeOk) return ['$path: expected $type'];
  final allowed = schema['enum'];
  if (allowed is List && !allowed.contains(value)) errors.add('$path: not one of $allowed');
  if (value is num) {
    final min = schema['minimum'];
    final max = schema['maximum'];
    if (min is num && value < min) errors.add('$path: below minimum $min');
    if (max is num && value > max) errors.add('$path: above maximum $max');
  }
  if (value is String) {
    final minLength = schema['minLength'];
    final maxLength = schema['maxLength'];
    final pattern = schema['pattern'];
    final length = value.runes.length;
    if (minLength is int && length < minLength) errors.add('$path: shorter than $minLength');
    if (maxLength is int && length > maxLength) errors.add('$path: longer than $maxLength');
    if (pattern is String && !RegExp(pattern).hasMatch(value)) errors.add('$path: does not match $pattern');
  }
  if (value is Map) {
    final props = (schema['properties'] as Map<String, dynamic>?) ?? const {};
    for (final r in (schema['required'] as List<dynamic>?) ?? const []) {
      if (!value.containsKey(r)) errors.add('$path: missing required "$r"');
    }
    for (final entry in value.entries) {
      final sub = props[entry.key];
      if (sub is Map<String, dynamic>) {
        errors.addAll(validateSchemaSubset(entry.value, sub, '$path.${entry.key}'));
      } else if (schema['additionalProperties'] == false) {
        errors.add('$path: unexpected property "${entry.key}"');
      }
    }
  }
  if (value is List && schema['items'] is Map<String, dynamic>) {
    for (var i = 0; i < value.length; i++) {
      errors.addAll(validateSchemaSubset(value[i], schema['items'] as Map<String, dynamic>, '$path[$i]'));
    }
  }
  return errors;
}
