/// Validator for the documented JSON Schema subset used by save-data
/// schemas (docs/SAMPLES.md): `type` (object, array, string, integer,
/// number, boolean, null), `title`, `description`, `properties`, `required`,
/// `additionalProperties` (boolean), `items` (single schema), `minimum`,
/// `maximum`, `minLength`, `maxLength`, `pattern`, `enum`, `default`.
/// `$schema`, `$id` and `$comment` are accepted as metadata. Any other
/// keyword is reported as ignored, never silently guessed.
///
/// Violations carry RFC 6901 JSON Pointer paths into the validated data.
library;

import 'json_value.dart';

const Set<String> kSchemaTypes = {'object', 'array', 'string', 'integer', 'number', 'boolean', 'null'};
const Set<String> _metadata = {r'$schema', r'$id', r'$comment'};
const Set<String> _supported = {
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

class SchemaNode {
  const SchemaNode({
    required this.pointer,
    this.type,
    this.title,
    this.description,
    this.properties = const {},
    this.required = const [],
    this.additionalProperties = true,
    this.items,
    this.minimum,
    this.maximum,
    this.minLength,
    this.maxLength,
    this.pattern,
    this.patternRe,
    this.enumValues,
    this.hasDefault = false,
    this.defaultValue,
  });

  /// Location of this node inside the schema document.
  final String pointer;
  final String? type;
  final String? title;
  final String? description;
  final Map<String, SchemaNode> properties;
  final List<String> required;
  final bool additionalProperties;
  final SchemaNode? items;
  final num? minimum;
  final num? maximum;
  final int? minLength;
  final int? maxLength;
  final String? pattern;
  final RegExp? patternRe;
  final List<Object?>? enumValues;
  final bool hasDefault;
  final Object? defaultValue;

  bool isRequired(String key) => required.contains(key);
}

class SchemaParseResult {
  const SchemaParseResult({this.root, this.errors = const [], this.warnings = const []});
  final SchemaNode? root;
  final List<String> errors;

  /// Ignored keywords and other non-fatal notes.
  final List<String> warnings;

  bool get ok => root != null && errors.isEmpty;
}

SchemaParseResult parseSchema(Object? json) {
  final errors = <String>[];
  final warnings = <String>[];

  SchemaNode? node(Object? j, List<Object> at) {
    final ptr = formatJsonPointer(at);
    final where = ptr.isEmpty ? 'schema root' : 'schema $ptr';
    if (j is! Map<String, Object?>) {
      errors.add('$where: a schema must be an object');
      return null;
    }
    for (final k in j.keys) {
      if (!_supported.contains(k) && !_metadata.contains(k)) {
        warnings.add('$where: keyword "$k" is not supported and is ignored');
      }
    }
    String? type;
    final rawType = j['type'];
    if (rawType is String) {
      if (kSchemaTypes.contains(rawType)) {
        type = rawType;
      } else {
        errors.add('$where: unknown type "$rawType"');
      }
    } else if (rawType != null) {
      warnings.add('$where: "type" must be a single string in this subset; type check skipped');
    }
    String? str(String k) {
      final v = j[k];
      if (v == null) return null;
      if (v is String) return v;
      errors.add('$where: "$k" must be a string');
      return null;
    }

    num? number(String k) {
      final v = j[k];
      if (v == null) return null;
      if (v is num) return v;
      errors.add('$where: "$k" must be a number');
      return null;
    }

    int? count(String k) {
      final v = j[k];
      if (v == null) return null;
      if (v is int && v >= 0) return v;
      if (v is double && v >= 0 && v == v.truncateToDouble()) return v.toInt();
      errors.add('$where: "$k" must be a non-negative integer');
      return null;
    }

    final props = <String, SchemaNode>{};
    final rawProps = j['properties'];
    if (rawProps is Map<String, Object?>) {
      for (final e in rawProps.entries) {
        final child = node(e.value, [...at, 'properties', e.key]);
        if (child != null) props[e.key] = child;
      }
    } else if (rawProps != null) {
      errors.add('$where: "properties" must be an object');
    }
    final req = <String>[];
    final rawReq = j['required'];
    if (rawReq is List<Object?>) {
      for (final r in rawReq) {
        if (r is String) {
          req.add(r);
        } else {
          errors.add('$where: "required" must list property names');
        }
      }
    } else if (rawReq != null) {
      errors.add('$where: "required" must be an array of strings');
    }
    var additional = true;
    final rawAdd = j['additionalProperties'];
    if (rawAdd is bool) {
      additional = rawAdd;
    } else if (rawAdd != null) {
      warnings.add(
        '$where: only boolean "additionalProperties" is supported; schema form ignored (extra keys allowed)',
      );
    }
    SchemaNode? items;
    final rawItems = j['items'];
    if (rawItems is Map<String, Object?>) {
      items = node(rawItems, [...at, 'items']);
    } else if (rawItems != null) {
      errors.add('$where: "items" must be a single schema object in this subset');
    }
    final pattern = str('pattern');
    RegExp? re;
    if (pattern != null) {
      try {
        re = RegExp(pattern, unicode: true);
      } on FormatException catch (e) {
        errors.add('$where: invalid "pattern": ${e.message}');
      }
    }
    List<Object?>? enumValues;
    final rawEnum = j['enum'];
    if (rawEnum is List<Object?>) {
      if (rawEnum.isEmpty) errors.add('$where: "enum" must not be empty');
      enumValues = rawEnum;
    } else if (rawEnum != null) {
      errors.add('$where: "enum" must be an array');
    }
    return SchemaNode(
      pointer: ptr,
      type: type,
      title: str('title'),
      description: str('description'),
      properties: props,
      required: req,
      additionalProperties: additional,
      items: items,
      minimum: number('minimum'),
      maximum: number('maximum'),
      minLength: count('minLength'),
      maxLength: count('maxLength'),
      pattern: pattern,
      patternRe: re,
      enumValues: enumValues,
      hasDefault: j.containsKey('default'),
      defaultValue: j['default'],
    );
  }

  final root = node(json, const []);
  return SchemaParseResult(root: errors.isEmpty ? root : null, errors: errors, warnings: warnings);
}

class SchemaViolation {
  const SchemaViolation({required this.pointer, required this.keyword, required this.message});

  /// JSON Pointer into the data ('' = root).
  final String pointer;
  final String keyword;
  final String message;

  String describe() => '${pointer.isEmpty ? '(root)' : pointer}: $message';
}

bool _matchesType(String type, Object? v) => switch (type) {
  'object' => v is Map<String, Object?>,
  'array' => v is List<Object?>,
  'string' => v is String,
  'integer' => v is int || (v is double && v.isFinite && v == v.truncateToDouble()),
  'number' => v is num,
  'boolean' => v is bool,
  'null' => v == null,
  _ => true,
};

String _typeName(Object? v) => switch (v) {
  int() => 'integer',
  double() => 'number',
  _ => jsonTypeOf(v).label,
};

/// Validates [value] against [schema]. Stops after [limit] violations.
List<SchemaViolation> validateAgainstSchema(Object? value, SchemaNode schema, {int limit = 1000}) {
  final out = <SchemaViolation>[];

  void add(List<Object> path, String keyword, String message) {
    if (out.length < limit) {
      out.add(SchemaViolation(pointer: formatJsonPointer(path), keyword: keyword, message: message));
    }
  }

  void check(Object? v, SchemaNode s, List<Object> path) {
    if (out.length >= limit) return;
    final type = s.type;
    if (type != null && !_matchesType(type, v)) {
      add(path, 'type', 'expected $type, found ${_typeName(v)}');
      return;
    }
    final allowed = s.enumValues;
    if (allowed != null && !allowed.any((a) => jsonDeepEquals(a, v, strictNumbers: false))) {
      add(path, 'enum', 'must be one of ${allowed.map(jsonPreview).join(', ')}');
    }
    if (v is num) {
      final min = s.minimum, max = s.maximum;
      if (min != null && v < min) add(path, 'minimum', 'must be >= $min (is $v)');
      if (max != null && v > max) add(path, 'maximum', 'must be <= $max (is $v)');
    }
    if (v is String) {
      final len = v.runes.length;
      final minL = s.minLength, maxL = s.maxLength;
      if (minL != null && len < minL) add(path, 'minLength', 'must have at least $minL characters (has $len)');
      if (maxL != null && len > maxL) add(path, 'maxLength', 'must have at most $maxL characters (has $len)');
      final re = s.patternRe;
      if (re != null && !re.hasMatch(v)) add(path, 'pattern', 'must match the pattern ${s.pattern}');
    }
    if (v is Map<String, Object?>) {
      for (final r in s.required) {
        if (!v.containsKey(r)) add([...path, r], 'required', 'required property "$r" is missing');
      }
      for (final e in v.entries) {
        final ps = s.properties[e.key];
        if (ps != null) {
          check(e.value, ps, [...path, e.key]);
        } else if (!s.additionalProperties) {
          add([...path, e.key], 'additionalProperties', 'property "${e.key}" is not allowed by the schema');
        }
      }
    }
    if (v is List<Object?>) {
      final itemSchema = s.items;
      if (itemSchema != null) {
        for (var i = 0; i < v.length; i++) {
          check(v[i], itemSchema, [...path, i]);
        }
      }
    }
  }

  check(value, schema, const []);
  return out;
}

/// Parses [schemaJson] and validates [value]. Top-level and free of
/// non-sendable captures so it can run in `runBounded` (user patterns could
/// backtrack catastrophically).
List<SchemaViolation> validateWithSchemaJson(Object? value, Object? schemaJson) {
  final parsed = parseSchema(schemaJson);
  final root = parsed.root;
  if (root == null) {
    return [
      for (final e in parsed.errors) SchemaViolation(pointer: '', keyword: 'schema', message: 'Schema error: $e'),
    ];
  }
  return validateAgainstSchema(value, root);
}

/// A sensible new value for [s]: its `default`, else the first enum value,
/// else a type default (objects get their required properties).
Object? defaultForSchema(SchemaNode s) {
  if (s.hasDefault) return jsonDeepCopy(s.defaultValue);
  final e = s.enumValues;
  if (e != null && e.isNotEmpty) return jsonDeepCopy(e.first);
  switch (s.type) {
    case 'object':
      return <String, Object?>{
        for (final r in s.required)
          if (s.properties[r] != null) r: defaultForSchema(s.properties[r]!) else r: null,
      };
    case 'array':
      return <Object?>[];
    case 'string':
      return '';
    case 'integer':
      final min = s.minimum;
      final base = min == null ? 0 : min.ceil();
      final max = s.maximum;
      return max != null && base > max ? max.floor() : base;
    case 'number':
      final min = s.minimum;
      return min ?? 0;
    case 'boolean':
      return false;
    default:
      return null;
  }
}
