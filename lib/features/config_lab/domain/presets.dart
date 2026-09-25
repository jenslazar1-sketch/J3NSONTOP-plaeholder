/// JSON Merge Patch presets: model, built-in examples and the versioned
/// storage payload kept in feature data under [kPresetsKey].
library;

import 'json_parser.dart';
import 'json_tools.dart';

const String kPresetsKey = 'config_lab.presets';
const int kPresetsVersion = 1;

class ConfigPreset {
  const ConfigPreset({
    required this.id,
    required this.name,
    required this.patch,
    this.description = '',
    this.target,
    this.builtIn = false,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String description;

  /// RFC 7386 merge patch (any JSON value; usually an object).
  final Object? patch;

  /// Workspace-relative file the preset was written for (a hint only).
  final String? target;

  /// Shipped with the app; cannot be edited or deleted (duplicate instead).
  final bool builtIn;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  ConfigPreset copyWith({String? id, String? name, String? description, Object? patch, String? target}) => ConfigPreset(
    id: id ?? this.id,
    name: name ?? this.name,
    description: description ?? this.description,
    patch: patch ?? this.patch,
    target: target ?? this.target,
    builtIn: false,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (description.isNotEmpty) 'description': description,
    if (target != null) 'target': target,
    'patch': patch,
    if (createdAt != null) 'createdAt': createdAt!.toUtc().toIso8601String(),
    if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
  };

  /// Parses one stored/imported preset; returns an error message instead of
  /// throwing so imports can report every bad item.
  static (ConfigPreset?, String?) fromJson(Object? j, {String? fallbackId}) {
    if (j is! Map<String, Object?>) return (null, 'preset must be an object');
    final name = j['name'];
    if (name is! String || name.trim().isEmpty) return (null, 'preset needs a non-empty "name"');
    if (!j.containsKey('patch')) return (null, 'preset "$name" has no "patch"');
    final id = j['id'] is String && (j['id']! as String).isNotEmpty ? j['id']! as String : fallbackId;
    if (id == null) return (null, 'preset "$name" has no "id"');
    final description = j['description'] is String ? j['description']! as String : '';
    final target = j['target'] is String ? j['target']! as String : null;
    DateTime? date(Object? v) => v is String ? DateTime.tryParse(v) : null;
    return (
      ConfigPreset(
        id: id,
        name: name.trim(),
        description: description,
        target: target,
        patch: j['patch'],
        createdAt: date(j['createdAt']),
        updatedAt: date(j['updatedAt']),
      ),
      null,
    );
  }
}

/// Target of the built-in example presets.
const String kSampleGraphicsPath = 'game/config/graphics.json';

/// Example presets shipped with the app, written for the sample game's
/// `game/config/graphics.json`. They are ordinary merge patches: applying
/// them to another file adds/overwrites exactly the listed keys, which the
/// preview shows before anything is saved.
final List<ConfigPreset> builtInPresets = [
  const ConfigPreset(
    id: 'builtin.potato',
    name: 'Potato mode',
    builtIn: true,
    target: kSampleGraphicsPath,
    description:
        'EXAMPLE for the sample game (Neon Dungeon) graphics.json: lowest quality, no post effects, '
        'half render scale, 30 FPS cap.',
    patch: {
      'quality': 'low',
      'vsync': false,
      'fov': 75,
      'maxFps': 30,
      'resolution': {'scale': 0.5},
      'shadows': {'enabled': false, 'resolution': 256},
      'postfx': {'bloom': false, 'motionBlur': false, 'chromaticAberration': false, 'scanlines': false, 'ssao': false},
    },
  ),
  const ConfigPreset(
    id: 'builtin.ultra',
    name: 'Ultra',
    builtIn: true,
    target: kSampleGraphicsPath,
    description:
        'EXAMPLE for the sample game (Neon Dungeon) graphics.json: maximum quality, all post effects on, '
        'native render scale, uncapped frame rate with vsync.',
    patch: {
      'quality': 'ultra',
      'vsync': true,
      'fov': 100,
      'maxFps': 0,
      'resolution': {'scale': 1.0},
      'shadows': {'enabled': true, 'resolution': 4096},
      'postfx': {'bloom': true, 'motionBlur': true, 'chromaticAberration': true, 'scanlines': true, 'ssao': true},
    },
  ),
];

/// Storage payload `{"v": 1, "items": [...]}` for user presets.
Map<String, Object?> presetsPayload(List<ConfigPreset> userPresets) => {
  'v': kPresetsVersion,
  'items': [for (final p in userPresets) p.toJson()],
};

class PresetLoad {
  const PresetLoad(this.presets, this.problems);
  final List<ConfigPreset> presets;
  final List<String> problems;
}

/// Reads the stored payload. Unknown future versions are not guessed.
PresetLoad readPresetsPayload(Object? stored) {
  if (stored == null) return const PresetLoad([], []);
  if (stored is! Map<String, Object?>) return const PresetLoad([], ['Stored presets are not an object; ignored']);
  final v = stored['v'];
  if (v != kPresetsVersion) {
    return PresetLoad(const [], [
      'Stored presets use format version $v; this app understands version $kPresetsVersion',
    ]);
  }
  final items = stored['items'];
  if (items is! List<Object?>) return const PresetLoad([], ['Stored presets have no "items" list']);
  final out = <ConfigPreset>[];
  final problems = <String>[];
  for (var i = 0; i < items.length; i++) {
    final (preset, error) = ConfigPreset.fromJson(items[i]);
    if (preset != null) {
      out.add(preset);
    } else {
      problems.add('Item ${i + 1}: $error');
    }
  }
  return PresetLoad(out, problems);
}

/// Parses an import file: a payload `{"v":1,"items":[...]}`, a list of
/// presets or a single preset object. New ids are assigned with [newId].
PresetLoad parsePresetImport(String text, {required String Function() newId}) {
  final Object? json;
  try {
    json = decodeJsonStrict(text);
  } on JsonSyntaxError catch (e) {
    return PresetLoad(const [], ['Not valid JSON: ${e.message} (offset ${e.offset})']);
  }
  List<Object?> items;
  if (json is Map<String, Object?> && json.containsKey('items')) {
    if (json['v'] != kPresetsVersion) {
      return PresetLoad(const [], ['Preset file version ${json['v']} is not supported (expected $kPresetsVersion)']);
    }
    final raw = json['items'];
    if (raw is! List<Object?>) return const PresetLoad([], ['"items" must be a list']);
    items = raw;
  } else if (json is List<Object?>) {
    items = json;
  } else if (json is Map<String, Object?> && json.containsKey('patch')) {
    items = [json];
  } else {
    return const PresetLoad([], [
      'Not a preset file. Expected {"v":1,"items":[...]}, a list of presets, or {"name":..., "patch":...}',
    ]);
  }
  final out = <ConfigPreset>[];
  final problems = <String>[];
  for (var i = 0; i < items.length; i++) {
    final (preset, error) = ConfigPreset.fromJson(items[i], fallbackId: newId());
    if (preset == null) {
      problems.add('Item ${i + 1}: $error');
    } else {
      out.add(
        ConfigPreset(
          id: newId(),
          name: preset.name,
          description: preset.description,
          target: preset.target,
          patch: preset.patch,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
    }
  }
  return PresetLoad(out, problems);
}

/// Export text for [presets] (versioned payload, 2-space indent).
String exportPresets(List<ConfigPreset> presets) => encodeJson(presetsPayload(presets));
