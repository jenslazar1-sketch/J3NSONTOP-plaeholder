/// Format detection and "parse anything to a JSON-like value" for the
/// Compare tool.
library;

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'ini_document.dart';
import 'json_parser.dart';
import 'source_location.dart';
import 'toml_codec.dart';
import 'yaml_codec.dart';

enum ConfigFormat {
  json('JSON', ['json']),
  yaml('YAML', ['yaml', 'yml']),
  toml('TOML', ['toml']),
  ini('INI', ['ini', 'cfg', 'conf']);

  const ConfigFormat(this.label, this.extensions);
  final String label;
  final List<String> extensions;

  static ConfigFormat? fromFileName(String name) {
    final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
    for (final f in values) {
      if (f.extensions.contains(ext)) return f;
    }
    return null;
  }
}

final RegExp _iniSection = RegExp(r'^\s*\[[^\]\[]+\]\s*$', multiLine: true);

/// Guesses the format of [text] (the file extension wins when known).
/// Order: JSON (strict), TOML, INI (section headers), YAML (only when it
/// parses to a mapping or sequence).
ConfigFormat detectConfigFormat(String text, {String? fileName}) {
  if (fileName != null) {
    final byName = ConfigFormat.fromFileName(fileName);
    if (byName != null) return byName;
  }
  final t = text.trimLeft();
  if (t.startsWith('{') || t.startsWith('[')) {
    try {
      parseJsonStrict(text);
      return ConfigFormat.json;
    } on JsonSyntaxError {
      // fall through
    }
  }
  if (checkToml(text).valid) return ConfigFormat.toml;
  final ini = IniDocument.parse(text);
  if (!ini.hasErrors && ini.lines.any((l) => l.kind == IniLineKind.section || l.kind == IniLineKind.entry)) {
    if (_iniSection.hasMatch(text) || !_parsesAsYamlCollection(text)) return ConfigFormat.ini;
  }
  if (_parsesAsYamlCollection(text)) return ConfigFormat.yaml;
  if (t.startsWith('{') || t.startsWith('[')) return ConfigFormat.json;
  return ConfigFormat.yaml;
}

bool _parsesAsYamlCollection(String text) {
  try {
    final n = loadYamlNode(text);
    return n is YamlMap || n is YamlList;
  } on YamlException {
    return false;
  }
}

class ParsedConfig {
  const ParsedConfig({required this.format, this.value, this.error, this.notes = const []});
  final ConfigFormat format;
  final Object? value;
  final LocatedError? error;

  /// Representation notes (e.g. TOML date-times compared as strings).
  final List<String> notes;

  bool get ok => error == null;
}

/// Parses [text] as [format] into a JSON-like value for comparison.
ParsedConfig parseConfigValue(String text, ConfigFormat format) {
  switch (format) {
    case ConfigFormat.json:
      try {
        return ParsedConfig(format: format, value: parseJsonStrict(text).value);
      } on JsonSyntaxError catch (e) {
        return ParsedConfig(
          format: format,
          error: LocatedError.at(text, e.message, SourceLocation.fromOffset(text, e.offset)),
        );
      }
    case ConfigFormat.yaml:
      final check = checkYaml(text);
      if (check.empty) return ParsedConfig(format: format, value: null, notes: const ['Empty YAML document']);
      if (!check.valid) return ParsedConfig(format: format, error: check.error);
      final docs = loadYamlDocuments(text);
      final values = [for (final d in docs) yamlNodeToJsonLike(d.contents)];
      return ParsedConfig(
        format: format,
        value: values.length == 1 ? values.first : values,
        notes: [
          if (values.length > 1) '${values.length} YAML documents compared as an array',
          'YAML keys are compared as strings',
        ],
      );
    case ConfigFormat.toml:
      final check = checkToml(text);
      if (check.empty) return ParsedConfig(format: format, value: const <String, Object?>{});
      if (!check.valid) return ParsedConfig(format: format, error: check.error);
      final (value, issues) = tomlToJsonValue(check.value!);
      return ParsedConfig(
        format: format,
        value: value,
        notes: [if (issues.isNotEmpty) 'TOML date-times and special floats are compared as strings'],
      );
    case ConfigFormat.ini:
      final doc = IniDocument.parse(text);
      if (doc.hasErrors) {
        final e = doc.errors.first;
        return ParsedConfig(
          format: format,
          error: LocatedError.at(text, e.message, SourceLocation.fromLineColumn(text, e.line, 1)),
        );
      }
      final out = <String, Object?>{};
      for (final l in doc.entries) {
        if (l.section.isEmpty) {
          out[l.key!] = l.value;
        } else {
          final section = out.putIfAbsent(l.section, () => <String, Object?>{});
          if (section is Map<String, Object?>) section[l.key!] = l.value;
        }
      }
      for (final name in doc.sectionNames) {
        if (name.isNotEmpty) out.putIfAbsent(name, () => <String, Object?>{});
      }
      return ParsedConfig(format: format, value: out, notes: const ['INI values are compared as strings']);
  }
}
