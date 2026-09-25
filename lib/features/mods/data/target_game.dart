import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../../../core/utils/safe_path.dart';
import '../domain/manifest.dart';
import '../domain/plan.dart';
import '../domain/profile.dart';
import '../domain/resolver.dart';

/// Maximum size of a `game.json` that is read.
const int kGameJsonMaxBytes = 256 * 1024;

/// Identifies the game in a profile's target folder: `<target>/game.json`
/// first, then the profile's `game`, else unknown.
Future<TargetGame> readTargetGame(String workspaceRoot, ModProfile profile) async {
  final notes = <String>[];
  String? root;
  try {
    root = resolveProfileTarget(workspaceRoot, profile.target);
  } on UnsafePathException catch (e) {
    notes.add('Target "${profile.target}" is not usable: ${e.reason}');
  }
  if (root != null) {
    final file = File(p.join(root, 'game.json'));
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      try {
        final len = await file.length();
        if (len > kGameJsonMaxBytes) throw const FormatException('file is too large');
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map<String, dynamic>) throw const FormatException('not a JSON object');
        final id = decoded['id'];
        if (id is! String || validateModId(id) != null) throw const FormatException('"id" is missing or invalid');
        Version? version;
        final v = decoded['version'];
        if (v is String) {
          try {
            version = Version.parse(v.trim());
          } on FormatException {
            notes.add('game.json version "$v" is not a semantic version; version checks are skipped');
          }
        }
        final name = decoded['name'];
        final game = profile.game;
        if (game != null && game.id != id) {
          notes.add('The profile declares game "${game.id}" but the target\'s game.json says "$id"; game.json is used');
        }
        return TargetGame(
          id: id,
          name: name is String ? name : null,
          version: version,
          source: TargetGameSource.gameJson,
          notes: notes,
        );
      } on FormatException catch (e) {
        notes.add('The target\'s game.json could not be used (${e.message})');
      } on FileSystemException catch (e) {
        notes.add('The target\'s game.json could not be read (${e.message})');
      }
    }
  }
  final game = profile.game;
  if (game != null) {
    return TargetGame(id: game.id, version: game.version, source: TargetGameSource.profile, notes: notes);
  }
  return TargetGame(notes: notes);
}
