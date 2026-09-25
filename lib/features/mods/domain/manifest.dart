import 'dart:convert';

import 'package:pub_semver/pub_semver.dart';

import '../../../core/utils/safe_path.dart';
import 'issues.dart';

/// The only manifest format version this app understands.
const int kManifestFormatVersion = 1;

/// Manifest file name at the archive root.
const String kManifestFileName = 'j3mod.json';

/// Hard size limit for `j3mod.json`.
const int kManifestMaxBytes = 1024 * 1024;

/// Package, profile and game ids: `^[a-z0-9][a-z0-9._-]{1,63}$`.
final RegExp kModIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{1,63}$');

const String kIdRules = "2-64 characters: lowercase letters, digits, '.', '_' or '-', starting with a letter or digit";

/// Validates an id; returns an error message or null.
String? validateModId(String id) => kModIdPattern.hasMatch(id) ? null : '"$id" is not a valid id ($kIdRules)';

/// Parses a version constraint. Returns null and reports through [onError]
/// when the text is not valid pub/semver constraint syntax.
VersionConstraint? tryParseConstraint(String text, void Function(String message) onError) {
  final t = text.trim();
  if (t.isEmpty) {
    onError('empty version constraint (omit the field to allow any version)');
    return null;
  }
  try {
    return VersionConstraint.parse(t);
  } on FormatException catch (e) {
    onError('"$t" is not a valid version constraint (${e.message}). Examples: any, 1.2.3, ^1.2.0, >=1.0.0 <2.0.0');
    return null;
  }
}

/// Parses a semantic version or reports through [onError].
Version? tryParseVersion(String text, void Function(String message) onError) {
  final t = text.trim();
  try {
    return Version.parse(t);
  } on FormatException {
    onError('"$t" is not a semantic version (MAJOR.MINOR.PATCH[-pre][+build], e.g. 1.2.0)');
    return null;
  }
}

/// A reference to another package with an optional version constraint
/// (dependencies and optional dependencies).
class PackageRef {
  PackageRef(this.id, [String constraint = 'any'])
    : constraintText = constraint.trim().isEmpty ? 'any' : constraint.trim(),
      constraint = VersionConstraint.parse(constraint.trim().isEmpty ? 'any' : constraint.trim());

  const PackageRef._(this.id, this.constraintText, this.constraint);

  final String id;

  /// The constraint as written (`any` when omitted).
  final String constraintText;
  final VersionConstraint constraint;

  bool get isAny => constraint.isAny;
  bool allows(Version v) => constraint.allows(v);

  Map<String, dynamic> toJson() => {'id': id, if (!isAny) 'version': constraintText};

  @override
  String toString() => isAny ? id : '$id $constraintText';
}

/// A declared conflict with another package.
class ModConflict {
  const ModConflict({required this.id, required this.constraintText, required this.constraint, this.reason});

  final String id;
  final String constraintText;
  final VersionConstraint constraint;
  final String? reason;

  bool allows(Version v) => constraint.allows(v);

  Map<String, dynamic> toJson() => {
    'id': id,
    if (!constraint.isAny) 'version': constraintText,
    if (reason != null && reason!.isNotEmpty) 'reason': reason,
  };
}

/// One payload file: archive [source] path copied to [target] (relative to
/// the profile's target folder). Both are normalised forward-slash paths.
class FileMapping {
  const FileMapping({required this.source, required this.target});
  final String source;
  final String target;

  Map<String, dynamic> toJson() => {'source': source, 'target': target};

  @override
  String toString() => '$source -> $target';
}

class ModCompatibility {
  const ModCompatibility({this.game, this.gameVersionText, this.gameVersion});

  final String? game;
  final String? gameVersionText;
  final VersionConstraint? gameVersion;

  bool get isEmpty => game == null && gameVersion == null;

  Map<String, dynamic> toJson() => {'game': ?game, 'gameVersion': ?gameVersionText};

  @override
  String toString() {
    if (isEmpty) return 'any game';
    return [game ?? 'any game', ?gameVersionText].join(' ');
  }
}

/// A validated `j3mod.json` (formatVersion 1).
class ModManifest {
  const ModManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.files,
    this.description,
    this.author,
    this.license,
    this.compatibility = const ModCompatibility(),
    this.dependencies = const [],
    this.optionalDependencies = const [],
    this.conflicts = const [],
    this.tags = const [],
  });

  final String id;
  final String name;
  final Version version;
  final String? description;
  final String? author;
  final String? license;
  final ModCompatibility compatibility;
  final List<FileMapping> files;
  final List<PackageRef> dependencies;
  final List<PackageRef> optionalDependencies;
  final List<ModConflict> conflicts;
  final List<String> tags;

  String get versionText => version.toString();

  /// `id@version`, used in messages.
  String get label => '$id@$version';

  Map<String, dynamic> toJson() => {
    'format': 'j3mod',
    'formatVersion': kManifestFormatVersion,
    'id': id,
    'name': name,
    'version': version.toString(),
    if (description != null && description!.isNotEmpty) 'description': description,
    if (author != null && author!.isNotEmpty) 'author': author,
    if (license != null && license!.isNotEmpty) 'license': license,
    if (!compatibility.isEmpty) 'compatibility': compatibility.toJson(),
    'files': [for (final f in files) f.toJson()],
    if (dependencies.isNotEmpty) 'dependencies': [for (final d in dependencies) d.toJson()],
    if (optionalDependencies.isNotEmpty) 'optionalDependencies': [for (final d in optionalDependencies) d.toJson()],
    if (conflicts.isNotEmpty) 'conflicts': [for (final c in conflicts) c.toJson()],
    if (tags.isNotEmpty) 'tags': tags,
  };

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}

/// Outcome of parsing a manifest: the manifest (null when any error was
/// found) plus every issue. [rawId]/[rawName]/[rawVersion] are best-effort
/// values for display even when the manifest is invalid.
class ManifestResult {
  const ManifestResult({required this.manifest, required this.issues, this.rawId, this.rawName, this.rawVersion});

  final ModManifest? manifest;
  final List<ModIssue> issues;
  final String? rawId;
  final String? rawName;
  final String? rawVersion;

  bool get isValid => manifest != null && !issues.hasErrors;
}

/// Parser + validator for `j3mod.json`. Every rule of docs/MOD_FORMAT.md is
/// reported as a typed [ModIssue]; errors make the manifest invalid.
abstract final class ManifestParser {
  static const Set<String> knownFields = {
    'format',
    'formatVersion',
    'id',
    'name',
    'version',
    'description',
    'author',
    'license',
    'compatibility',
    'files',
    'dependencies',
    'optionalDependencies',
    'conflicts',
    'tags',
  };

  /// Parses JSON text (a UTF-8 BOM is tolerated).
  static ManifestResult parseText(String text) {
    final clean = text.startsWith('﻿') ? text.substring(1) : text;
    Object? decoded;
    try {
      decoded = jsonDecode(clean);
    } on FormatException catch (e) {
      return ManifestResult(
        manifest: null,
        issues: [ModIssue.error(kManifestFileName, 'not valid JSON: ${e.message}')],
      );
    }
    if (decoded is! Map<String, dynamic>) {
      return const ManifestResult(
        manifest: null,
        issues: [ModIssue.error(kManifestFileName, 'the manifest must be a JSON object')],
      );
    }
    return fromMap(decoded);
  }

  static ManifestResult fromMap(Map<String, dynamic> m) {
    final issues = <ModIssue>[];
    void err(String field, String message) => issues.add(ModIssue.error(field, message));
    void warn(String field, String message) => issues.add(ModIssue.warning(field, message));

    final rawId = m['id'] is String ? m['id'] as String : null;
    final rawName = m['name'] is String ? m['name'] as String : null;
    final rawVersion = m['version'] is String ? m['version'] as String : null;

    // format / formatVersion
    final format = m['format'];
    if (format == null) {
      err('format', 'missing; must be "j3mod"');
    } else if (format != 'j3mod') {
      err('format', 'must be "j3mod" (found ${jsonEncode(format)})');
    }
    final fv = m['formatVersion'];
    if (fv == null) {
      err('formatVersion', 'missing; must be $kManifestFormatVersion');
    } else if (fv is! int) {
      err('formatVersion', 'must be the integer $kManifestFormatVersion (found ${jsonEncode(fv)})');
    } else if (fv > kManifestFormatVersion) {
      // A newer format may change any field's meaning: stop here.
      err(
        'formatVersion',
        'formatVersion $fv is newer than this app understands ($kManifestFormatVersion). The package was made '
            'for a newer J3NSONTOP release; update the app or ask the author for a formatVersion '
            '$kManifestFormatVersion build.',
      );
      return ManifestResult(manifest: null, issues: issues, rawId: rawId, rawName: rawName, rawVersion: rawVersion);
    } else if (fv < 1) {
      err('formatVersion', 'must be $kManifestFormatVersion (found $fv)');
    }

    for (final key in m.keys) {
      if (!knownFields.contains(key)) warn(key, 'unknown field is ignored');
    }

    // id
    String? id;
    final idRaw = m['id'];
    if (idRaw == null) {
      err('id', 'missing');
    } else if (idRaw is! String) {
      err('id', 'must be a string');
    } else {
      final msg = validateModId(idRaw);
      if (msg != null) {
        err('id', msg);
      } else {
        id = idRaw;
      }
    }

    // name
    String? name;
    final nameRaw = m['name'];
    if (nameRaw == null) {
      err('name', 'missing');
    } else if (nameRaw is! String) {
      err('name', 'must be a string');
    } else if (nameRaw.trim().isEmpty) {
      err('name', 'must not be empty');
    } else if (nameRaw.trim().length > 80) {
      err('name', 'must be at most 80 characters (has ${nameRaw.trim().length})');
    } else {
      name = nameRaw.trim();
    }

    // version
    Version? version;
    final versionRaw = m['version'];
    if (versionRaw == null) {
      err('version', 'missing');
    } else if (versionRaw is! String) {
      err('version', 'must be a string such as "1.0.0"');
    } else {
      version = tryParseVersion(versionRaw, (msg) => err('version', msg));
    }

    // optional strings
    String? optString(String key, {int? max}) {
      final v = m[key];
      if (v == null) return null;
      if (v is! String) {
        err(key, 'must be a string');
        return null;
      }
      if (max != null && v.length > max) {
        err(key, 'must be at most $max characters (has ${v.length})');
        return null;
      }
      return v;
    }

    final description = optString('description', max: 2000);
    final author = optString('author', max: 200);
    final license = optString('license', max: 200);

    // compatibility
    var compatibility = const ModCompatibility();
    final compatRaw = m['compatibility'];
    if (compatRaw != null) {
      if (compatRaw is! Map<String, dynamic>) {
        err('compatibility', 'must be an object {game, gameVersion}');
      } else {
        String? game;
        String? gvText;
        VersionConstraint? gv;
        for (final key in compatRaw.keys) {
          if (key != 'game' && key != 'gameVersion') warn('compatibility.$key', 'unknown field is ignored');
        }
        final g = compatRaw['game'];
        if (g != null) {
          if (g is! String) {
            err('compatibility.game', 'must be a string');
          } else {
            final msg = validateModId(g);
            if (msg != null) {
              err('compatibility.game', msg);
            } else {
              game = g;
            }
          }
        }
        final v = compatRaw['gameVersion'];
        if (v != null) {
          if (v is! String) {
            err('compatibility.gameVersion', 'must be a version constraint string');
          } else {
            gv = tryParseConstraint(v, (msg) => err('compatibility.gameVersion', msg));
            if (gv != null) gvText = v.trim();
          }
        }
        compatibility = ModCompatibility(game: game, gameVersionText: gvText, gameVersion: gv);
      }
    }

    // files
    final files = <FileMapping>[];
    final filesRaw = m['files'];
    if (filesRaw == null) {
      err('files', 'missing; a package must map at least one file');
    } else if (filesRaw is! List) {
      err('files', 'must be a list of {source, target} objects');
    } else if (filesRaw.isEmpty) {
      err('files', 'must not be empty; a package must map at least one file');
    } else {
      final targets = <String, int>{};
      for (var i = 0; i < filesRaw.length; i++) {
        final item = filesRaw[i];
        final f = 'files[$i]';
        if (item is! Map<String, dynamic>) {
          err(f, 'must be an object {source, target}');
          continue;
        }
        for (final key in item.keys) {
          if (key != 'source' && key != 'target') warn('$f.$key', 'unknown field is ignored');
        }
        String? source;
        final s = item['source'];
        if (s is! String) {
          err('$f.source', s == null ? 'missing' : 'must be a string');
        } else {
          try {
            source = SafePath.normalizeRelative(s);
            if (SafePath.collisionKey(source) == kManifestFileName) {
              err('$f.source', 'the manifest itself cannot be a payload file');
              source = null;
            }
          } on UnsafePathException catch (e) {
            err('$f.source', 'unsafe path "$s": ${e.reason}');
          }
        }
        String? target;
        final t = item['target'];
        if (t is! String) {
          err('$f.target', t == null ? 'missing' : 'must be a string');
        } else {
          try {
            target = SafePath.normalizeRelative(t);
          } on UnsafePathException catch (e) {
            err('$f.target', 'unsafe target path "$t": ${e.reason}');
          }
        }
        if (target != null) {
          final key = SafePath.collisionKey(target);
          final prior = targets[key];
          if (prior != null) {
            err(
              '$f.target',
              'duplicate target "$target" (also files[$prior]); targets are compared case-insensitively',
            );
            target = null;
          } else {
            targets[key] = i;
            if (key == 'game.json') {
              warn('$f.target', 'replaces the target\'s game.json, which identifies the game for compatibility checks');
            }
          }
        }
        if (source != null && target != null) files.add(FileMapping(source: source, target: target));
      }
    }

    // dependencies / optionalDependencies
    List<PackageRef> refs(String key) {
      final out = <PackageRef>[];
      final raw = m[key];
      if (raw == null) return out;
      if (raw is! List) {
        err(key, 'must be a list of {id, version?} objects');
        return out;
      }
      final seen = <String>{};
      for (var i = 0; i < raw.length; i++) {
        final item = raw[i];
        final f = '$key[$i]';
        if (item is! Map<String, dynamic>) {
          err(f, 'must be an object {id, version?}');
          continue;
        }
        final depId = item['id'];
        if (depId is! String) {
          err('$f.id', depId == null ? 'missing' : 'must be a string');
          continue;
        }
        final idMsg = validateModId(depId);
        if (idMsg != null) {
          err('$f.id', idMsg);
          continue;
        }
        if (depId == id) {
          err('$f.id', 'a package cannot depend on itself');
          continue;
        }
        if (!seen.add(depId)) {
          err('$f.id', '"$depId" is listed more than once');
          continue;
        }
        var constraintText = 'any';
        var constraint = VersionConstraint.any;
        final v = item['version'];
        if (v != null) {
          if (v is! String) {
            err('$f.version', 'must be a version constraint string');
            continue;
          }
          final c = tryParseConstraint(v, (msg) => err('$f.version', msg));
          if (c == null) continue;
          constraint = c;
          constraintText = v.trim();
        }
        for (final k in item.keys) {
          if (k != 'id' && k != 'version') warn('$f.$k', 'unknown field is ignored');
        }
        out.add(PackageRef._(depId, constraintText, constraint));
      }
      return out;
    }

    final deps = refs('dependencies');
    final optional = refs('optionalDependencies');
    final requiredIds = {for (final d in deps) d.id};
    final optionalFiltered = <PackageRef>[];
    for (var i = 0; i < optional.length; i++) {
      if (requiredIds.contains(optional[i].id)) {
        warn('optionalDependencies', '"${optional[i].id}" is also a required dependency; the required entry is used');
      } else {
        optionalFiltered.add(optional[i]);
      }
    }

    // conflicts
    final conflicts = <ModConflict>[];
    final conflictsRaw = m['conflicts'];
    if (conflictsRaw != null) {
      if (conflictsRaw is! List) {
        err('conflicts', 'must be a list of {id, version?, reason?} objects');
      } else {
        final seen = <String>{};
        for (var i = 0; i < conflictsRaw.length; i++) {
          final item = conflictsRaw[i];
          final f = 'conflicts[$i]';
          if (item is! Map<String, dynamic>) {
            err(f, 'must be an object {id, version?, reason?}');
            continue;
          }
          final cid = item['id'];
          if (cid is! String) {
            err('$f.id', cid == null ? 'missing' : 'must be a string');
            continue;
          }
          final idMsg = validateModId(cid);
          if (idMsg != null) {
            err('$f.id', idMsg);
            continue;
          }
          if (cid == id) {
            err('$f.id', 'a package cannot conflict with itself');
            continue;
          }
          if (requiredIds.contains(cid) || optionalFiltered.any((o) => o.id == cid)) {
            err('$f.id', '"$cid" is declared both as a dependency and as a conflict');
            continue;
          }
          if (!seen.add(cid)) {
            err('$f.id', '"$cid" is listed more than once');
            continue;
          }
          var constraintText = 'any';
          var constraint = VersionConstraint.any;
          final v = item['version'];
          if (v != null) {
            if (v is! String) {
              err('$f.version', 'must be a version constraint string');
              continue;
            }
            final c = tryParseConstraint(v, (msg) => err('$f.version', msg));
            if (c == null) continue;
            constraint = c;
            constraintText = v.trim();
          }
          final reason = item['reason'];
          if (reason != null && reason is! String) {
            err('$f.reason', 'must be a string');
            continue;
          }
          conflicts.add(
            ModConflict(id: cid, constraintText: constraintText, constraint: constraint, reason: reason as String?),
          );
        }
      }
    }

    // tags
    final tags = <String>[];
    final tagsRaw = m['tags'];
    if (tagsRaw != null) {
      if (tagsRaw is! List) {
        err('tags', 'must be a list of strings');
      } else {
        for (var i = 0; i < tagsRaw.length; i++) {
          final t = tagsRaw[i];
          if (t is! String) {
            err('tags[$i]', 'must be a string');
          } else if (t.trim().isEmpty) {
            warn('tags[$i]', 'empty tag is ignored');
          } else if (!tags.contains(t.trim())) {
            tags.add(t.trim());
          }
        }
      }
    }

    final valid = !issues.hasErrors && id != null && name != null && version != null && files.isNotEmpty;
    return ManifestResult(
      manifest: valid
          ? ModManifest(
              id: id,
              name: name,
              version: version,
              description: description,
              author: author,
              license: license,
              compatibility: compatibility,
              files: files,
              dependencies: deps,
              optionalDependencies: optionalFiltered,
              conflicts: conflicts,
              tags: tags,
            )
          : null,
      issues: issues,
      rawId: rawId,
      rawName: rawName,
      rawVersion: rawVersion,
    );
  }
}
