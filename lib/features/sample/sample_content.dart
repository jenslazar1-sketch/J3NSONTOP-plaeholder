/// Pure-Dart generator for the NEON DUNGEON sample workspace
/// (docs/SAMPLES.md). No Flutter imports: it also runs under `dart run`
/// (tool/export_samples.dart) and inside `Isolate.run`.
///
/// Every byte is deterministic: fixed dates (2026-09-01), seeded generators,
/// Stored ZIP entries with fixed timestamps and a pure-Dart PNG encoder.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'domain/sample_art.dart';
import 'domain/sample_logs.dart';
import 'domain/sample_packages.dart';
import 'domain/sample_texts.dart';

export 'domain/sample_packages.dart' show SamplePackage, SampleProfile, samplePackageList, sampleProfileList;
export 'domain/sample_texts.dart' show sampleGameId, sampleGameName, sampleGameVersion, sampleItemIds;

/// Version of the generated content (bump when the output changes).
const int sampleContentVersion = 1;

/// Name of the app-owned sample workspace.
const String sampleWorkspaceName = 'NEON DUNGEON (sample)';

/// Folder (relative to the workspace root) that profiles target.
const String sampleProfileTarget = 'game';

/// Everything the sample workspace needs, generated in one pass.
class SampleBundle {
  const SampleBundle({required this.files, required this.packages, required this.profiles});

  /// Workspace-relative path (forward slashes) -> bytes, in a stable order.
  final Map<String, Uint8List> files;

  /// `<id>-<version>.j3mod` -> package bytes (the mod library).
  final Map<String, Uint8List> packages;

  /// `<id>.j3profile.json` -> profile bytes.
  final Map<String, Uint8List> profiles;

  int get fileBytes => files.values.fold(0, (sum, b) => sum + b.length);
  int get packageBytes => packages.values.fold(0, (sum, b) => sum + b.length);
  int get profileBytes => profiles.values.fold(0, (sum, b) => sum + b.length);
  int get totalBytes => fileBytes + packageBytes + profileBytes;
}

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

/// The seven sample packages (`<id>-<version>.j3mod` -> bytes), in the order
/// listed in docs/SAMPLES.md.
Map<String, Uint8List> buildSamplePackages() => {for (final p in samplePackageList()) p.fileName: p.zip()};

/// The four sample profiles (`<id>.j3profile.json` -> bytes), in order.
Map<String, Uint8List> buildSampleProfiles() => {
  for (final p in sampleProfileList) p.fileName: _utf8(prettyJsonText(p.toJson())),
};

/// Every file of the sample workspace (relative path -> bytes), including
/// the packages under `downloads/`.
Map<String, Uint8List> buildSampleWorkspaceFiles() => _workspaceFiles(buildSamplePackages());

/// Workspace files, packages and profiles (packages are built once).
SampleBundle buildSampleBundle() {
  final packages = buildSamplePackages();
  return SampleBundle(files: _workspaceFiles(packages), packages: packages, profiles: buildSampleProfiles());
}

/// Returns [original] with the first occurrence of [from] replaced by [to]
/// (same length), so the result differs by exactly one byte.
Uint8List _oneByteVariant(Uint8List original, String from, String to) {
  final text = utf8.decode(original);
  final i = text.indexOf(from);
  if (i < 0 || from.length != to.length) throw StateError('near-duplicate marker not found');
  return _utf8(text.replaceFirst(from, to, i));
}

Map<String, Uint8List> _workspaceFiles(Map<String, Uint8List> packages) {
  final logs = buildSampleLogs();
  final hud = _utf8(hudJson());
  final potion = potionIcon();
  final files = <String, Uint8List>{
    'README.txt': _utf8(readmeTxt),
    'game/game.json': _utf8(gameJson()),
    'game/config/settings.ini': _utf8(settingsIni),
    'game/config/graphics.json': _utf8(graphicsJson()),
    'game/config/controls.yaml': _utf8(controlsYaml),
    'game/config/balance.toml': _utf8(balanceToml(BalancePreset.vanilla)),
    'game/data/items.csv': _utf8(itemsCsv()),
    'game/data/enemies.tsv': _utf8(enemiesTsv),
    'game/data/ui/hud.json': hud,
    'game/data/localization/en.json': _utf8(enJson()),
    'game/saves/slot1.json': _utf8(saveSlot1Json()),
    'game/saves/save.schema.json': _utf8(saveSchemaJson()),
    'game/sprites/hero_walk.png': heroWalkSheet(),
    'game/sprites/items/potion.png': potion,
    'game/sprites/items/sword.png': swordIcon(),
    'game/sprites/items/shield.png': shieldIcon(),
    'game/sprites/items/key.png': keyIcon(),
    'game/sprites/items/gem.png': gemIcon(),
    'game/sprites/items/skull.png': skullIcon(),
    'game/textures/logo.png': logoTexture(),
    'game/logs/game.log': _utf8(logs.gameLog),
    'game/logs/crash-2026-09-01.log': _utf8(logs.crashLog),
    for (final e in packages.entries) 'downloads/${e.key}': e.value,
    'duplicates/hud_backup.json': Uint8List.fromList(hud),
    'duplicates/potion (copy).png': Uint8List.fromList(potion),
    'duplicates/hud_backup_old.json': _oneByteVariant(hud, '"x": 16', '"x": 18'),
    for (var i = 0; i < 6; i++) 'rename-demo/IMG_000${i + 1}.png': renameDemoImage(i),
    'rename-demo/Screen Shot 1.txt': _utf8(screenShot1Txt),
    'rename-demo/screen shot 2.TXT': _utf8(screenShot2Txt),
    'notes/todo.md': _utf8(todoMd),
    'notes/unicode-名前-ünïcødé.txt': _utf8(unicodeNoteTxt),
  };
  return files;
}
