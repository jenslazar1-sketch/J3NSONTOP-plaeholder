import 'package:flutter/material.dart';

import '../../core/tools/tool_definition.dart';
import 'commands/json_command.dart';
import 'presentation/compare/compare_page.dart';
import 'presentation/csv/csv_page.dart';
import 'presentation/ini/ini_page.dart';
import 'presentation/json_studio/json_studio_page.dart';
import 'presentation/presets/presets_page.dart';
import 'presentation/save_editor/save_editor_page.dart';
import 'presentation/toml/toml_page.dart';
import 'presentation/yaml/yaml_page.dart';

/// Config Lab: JSON, YAML, TOML, INI and CSV/TSV editing, validation and
/// conversions with itemised reports, semantic comparison, merge-patch
/// presets and a schema-driven save-data editor.
final FeatureModule configLabModule = FeatureModule(
  id: 'config_lab',
  tools: [
    ToolDefinition(
      id: 'config.json',
      name: 'JSON Studio',
      section: ToolSection.configLab,
      description:
          'Validate with exact line:column, format, minify, sort keys, browse and edit as a tree, search fields.',
      icon: Icons.data_object,
      keywords: const [
        'json',
        'validate',
        'format',
        'pretty',
        'minify',
        'beautify',
        'lint',
        'tree',
        'jsonpath',
        'sort',
      ],
      builder: (_) => const JsonStudioPage(),
    ),
    ToolDefinition(
      id: 'config.yaml',
      name: 'YAML Editor',
      section: ToolSection.configLab,
      description: 'Validate YAML, browse the parsed tree, convert YAML to JSON and JSON to verified YAML.',
      icon: Icons.segment,
      keywords: const ['yaml', 'yml', 'validate', 'convert', 'json', 'anchors', 'aliases', 'tree'],
      builder: (_) => const YamlPage(),
    ),
    ToolDefinition(
      id: 'config.toml',
      name: 'TOML Editor',
      section: ToolSection.configLab,
      description: 'Validate TOML, browse tables, convert TOML to JSON and JSON to verified TOML.',
      icon: Icons.view_list_outlined,
      keywords: const ['toml', 'validate', 'convert', 'json', 'tables', 'cargo', 'pyproject'],
      builder: (_) => const TomlPage(),
    ),
    ToolDefinition(
      id: 'config.ini',
      name: 'INI Editor',
      section: ToolSection.configLab,
      description: 'Lossless INI editing: change values line by line, detect duplicates, convert to and from JSON.',
      icon: Icons.tune,
      keywords: const ['ini', 'cfg', 'settings', 'sections', 'keys', 'config', 'convert', 'json'],
      builder: (_) => const IniPage(),
    ),
    ToolDefinition(
      id: 'config.csv',
      name: 'CSV / TSV Table',
      section: ToolSection.configLab,
      description:
          'Preview delimited tables, detect delimiters, find ragged rows, filter, and convert CSV, TSV and JSON.',
      icon: Icons.table_chart_outlined,
      keywords: const ['csv', 'tsv', 'table', 'spreadsheet', 'delimiter', 'columns', 'convert', 'json'],
      builder: (_) => const CsvPage(),
    ),
    ToolDefinition(
      id: 'config.compare',
      name: 'Config Compare',
      section: ToolSection.configLab,
      description: 'Semantic diff of two configs (JSON, YAML, TOML, INI) plus a unified or side-by-side text diff.',
      icon: Icons.compare_arrows,
      keywords: const ['compare', 'diff', 'semantic', 'before', 'after', 'changes', 'json', 'yaml', 'toml', 'ini'],
      builder: (_) => const ComparePage(),
    ),
    ToolDefinition(
      id: 'config.presets',
      name: 'Config Presets',
      section: ToolSection.configLab,
      description: 'JSON Merge Patch presets: preview the changes on a document, then save with a backup.',
      icon: Icons.auto_fix_high,
      keywords: const ['preset', 'merge patch', 'rfc 7386', 'patch', 'graphics', 'profile', 'apply', 'json'],
      builder: (_) => const PresetsPage(),
    ),
    ToolDefinition(
      id: 'config.save_editor',
      name: 'Save Data Editor',
      section: ToolSection.configLab,
      description: 'Edit JSON save files through a form generated from their JSON schema, with live validation.',
      icon: Icons.save_as_outlined,
      keywords: const ['save', 'savegame', 'schema', 'json schema', 'form', 'validate', 'slot', 'game'],
      builder: (_) => const SaveEditorPage(),
    ),
  ],
  commands: const [JsonCommand()],
);
