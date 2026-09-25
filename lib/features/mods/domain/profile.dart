import 'dart:convert';

import 'package:pub_semver/pub_semver.dart';

import '../../../core/utils/safe_path.dart';
import 'issues.dart';
import 'manifest.dart';

const int kProfileFormatVersion = 1;
const String kProfileExtension = '.j3profile.json';

/// One entry of a profile's ordered mod list.
class ProfileMod {
  const ProfileMod(this.id, {this.enabled = true});
  final String id;
  final bool enabled;

  ProfileMod copyWith({bool? enabled}) => ProfileMod(id, enabled: enabled ?? this.enabled);

  Map<String, dynamic> toJson() => {'id': id, 'enabled': enabled};

  @override
  bool operator ==(Object other) => other is ProfileMod && other.id == id && other.enabled == enabled;

  @override
  int get hashCode => Object.hash(id, enabled);

  @override
  String toString() => '${enabled ? '+' : '-'}$id';
}

/// Optional game identity declared by the profile (used when the target
/// folder has no `game.json`).
class ProfileGame {
  const ProfileGame({required this.id, this.version});
  final String id;
  final Version? version;

  Map<String, dynamic> toJson() => {'id': id, if (version != null) 'version': version.toString()};
}

/// A mod profile (`*.j3profile.json`, formatVersion 1). The order of [mods]
/// is the application order: later entries win on overlapping files.
class ModProfile {
  const ModProfile({
    required this.id,
    required this.name,
    this.description = '',
    this.target = '.',
    this.game,
    this.mods = const [],
  });

  final String id;
  final String name;
  final String description;

  /// Folder relative to the workspace root (`.` = the root itself).
  final String target;
  final ProfileGame? game;
  final List<ProfileMod> mods;

  List<String> get enabledIds => [
    for (final m in mods)
      if (m.enabled) m.id,
  ];

  bool contains(String modId) => mods.any((m) => m.id == modId);

  ModProfile copyWith({
    String? id,
    String? name,
    String? description,
    String? target,
    ProfileGame? game,
    bool clearGame = false,
    List<ProfileMod>? mods,
  }) => ModProfile(
    id: id ?? this.id,
    name: name ?? this.name,
    description: description ?? this.description,
    target: target ?? this.target,
    game: clearGame ? null : (game ?? this.game),
    mods: mods ?? this.mods,
  );

  /// Moves the entry at [from] so it ends at index [to] (both in the
  /// current list; [to] is the final position).
  ModProfile moveMod(int from, int to) {
    if (from < 0 || from >= mods.length) return this;
    final list = [...mods];
    final item = list.removeAt(from);
    list.insert(to.clamp(0, list.length), item);
    return copyWith(mods: list);
  }

  ModProfile setEnabled(String modId, bool enabled) =>
      copyWith(mods: [for (final m in mods) m.id == modId ? m.copyWith(enabled: enabled) : m]);

  Map<String, dynamic> toJson() => {
    'format': 'j3profile',
    'formatVersion': kProfileFormatVersion,
    'id': id,
    'name': name,
    if (description.isNotEmpty) 'description': description,
    'target': target,
    if (game != null) 'game': game!.toJson(),
    'mods': [for (final m in mods) m.toJson()],
  };

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}

class ProfileResult {
  const ProfileResult({required this.profile, required this.issues});
  final ModProfile? profile;
  final List<ModIssue> issues;
  bool get isValid => profile != null && !issues.hasErrors;
}

/// Normalises a profile target: `.` for the workspace root, otherwise a
/// validated forward-slash relative path. Throws [UnsafePathException].
String normalizeProfileTarget(String raw) {
  final t = raw.trim().replaceAll('\\', '/');
  if (t.isEmpty || t == '.' || t == './') return '.';
  return SafePath.normalizeRelative(t);
}

/// Turns a display name into an id candidate (`Hardcore run` -> `hardcore-run`).
String slugifyId(String name, {String fallback = 'profile'}) {
  var s = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9._-]+'), '-');
  s = s.replaceAll(RegExp(r'-{2,}'), '-').replaceAll(RegExp(r'^[-._]+|[-._]+$'), '');
  if (s.length > 48) s = s.substring(0, 48).replaceAll(RegExp(r'[-._]+$'), '');
  if (s.length < 2) s = fallback;
  return s;
}

abstract final class ProfileParser {
  static const Set<String> knownFields = {
    'format',
    'formatVersion',
    'id',
    'name',
    'description',
    'target',
    'game',
    'mods',
  };

  static ProfileResult parseText(String text) {
    final clean = text.startsWith('﻿') ? text.substring(1) : text;
    Object? decoded;
    try {
      decoded = jsonDecode(clean);
    } on FormatException catch (e) {
      return ProfileResult(profile: null, issues: [ModIssue.error('profile', 'not valid JSON: ${e.message}')]);
    }
    if (decoded is! Map<String, dynamic>) {
      return const ProfileResult(profile: null, issues: [ModIssue.error('profile', 'must be a JSON object')]);
    }
    return fromMap(decoded);
  }

  static ProfileResult fromMap(Map<String, dynamic> m) {
    final issues = <ModIssue>[];
    void err(String f, String msg) => issues.add(ModIssue.error(f, msg));
    void warn(String f, String msg) => issues.add(ModIssue.warning(f, msg));

    final format = m['format'];
    if (format != 'j3profile') {
      err(
        'format',
        format == null ? 'missing; must be "j3profile"' : 'must be "j3profile" (found ${jsonEncode(format)})',
      );
    }
    final fv = m['formatVersion'];
    if (fv is! int) {
      err('formatVersion', fv == null ? 'missing; must be $kProfileFormatVersion' : 'must be an integer');
    } else if (fv > kProfileFormatVersion) {
      err(
        'formatVersion',
        'formatVersion $fv is newer than this app understands ($kProfileFormatVersion); update J3NSONTOP to use '
            'this profile.',
      );
      return ProfileResult(profile: null, issues: issues);
    } else if (fv < 1) {
      err('formatVersion', 'must be $kProfileFormatVersion');
    }
    for (final k in m.keys) {
      if (!knownFields.contains(k)) warn(k, 'unknown field is ignored');
    }

    String? id;
    final idRaw = m['id'];
    if (idRaw is! String) {
      err('id', idRaw == null ? 'missing' : 'must be a string');
    } else {
      final msg = validateModId(idRaw);
      msg == null ? id = idRaw : err('id', msg);
    }

    String? name;
    final nameRaw = m['name'];
    if (nameRaw is! String) {
      err('name', nameRaw == null ? 'missing' : 'must be a string');
    } else if (nameRaw.trim().isEmpty || nameRaw.trim().length > 80) {
      err('name', 'must be 1-80 characters');
    } else {
      name = nameRaw.trim();
    }

    var description = '';
    final d = m['description'];
    if (d != null) {
      if (d is! String) {
        err('description', 'must be a string');
      } else if (d.length > 2000) {
        err('description', 'must be at most 2000 characters');
      } else {
        description = d;
      }
    }

    String? target;
    final t = m['target'];
    if (t == null) {
      target = '.';
    } else if (t is! String) {
      err('target', 'must be a folder path relative to the workspace ("." for the root)');
    } else {
      try {
        target = normalizeProfileTarget(t);
      } on UnsafePathException catch (e) {
        err('target', 'unsafe folder "$t": ${e.reason}');
      }
    }

    ProfileGame? game;
    final g = m['game'];
    if (g != null) {
      if (g is! Map<String, dynamic>) {
        err('game', 'must be an object {id, version?}');
      } else {
        final gid = g['id'];
        Version? gv;
        var ok = true;
        if (gid is! String || validateModId(gid) != null) {
          err('game.id', gid is String ? validateModId(gid)! : 'missing or not a string');
          ok = false;
        }
        final v = g['version'];
        if (v != null) {
          if (v is! String) {
            err('game.version', 'must be a version string such as "1.4.2"');
            ok = false;
          } else {
            gv = tryParseVersion(v, (msg) => err('game.version', msg));
            if (gv == null) ok = false;
          }
        }
        if (ok) game = ProfileGame(id: gid as String, version: gv);
      }
    }

    final mods = <ProfileMod>[];
    final modsRaw = m['mods'];
    if (modsRaw == null) {
      // An empty profile is allowed.
    } else if (modsRaw is! List) {
      err('mods', 'must be a list of {id, enabled} objects');
    } else {
      final seen = <String>{};
      for (var i = 0; i < modsRaw.length; i++) {
        final item = modsRaw[i];
        if (item is! Map<String, dynamic>) {
          err('mods[$i]', 'must be an object {id, enabled}');
          continue;
        }
        final mid = item['id'];
        if (mid is! String || validateModId(mid) != null) {
          err('mods[$i].id', mid is String ? validateModId(mid)! : 'missing or not a string');
          continue;
        }
        if (!seen.add(mid)) {
          err('mods[$i].id', '"$mid" is listed more than once');
          continue;
        }
        final enabled = item['enabled'];
        if (enabled != null && enabled is! bool) {
          err('mods[$i].enabled', 'must be true or false');
          continue;
        }
        mods.add(ProfileMod(mid, enabled: enabled as bool? ?? true));
      }
    }

    final ok = !issues.hasErrors && id != null && name != null && target != null;
    return ProfileResult(
      profile: ok
          ? ModProfile(id: id, name: name, description: description, target: target, game: game, mods: mods)
          : null,
      issues: issues,
    );
  }
}
