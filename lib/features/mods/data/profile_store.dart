import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/storage/atomic_file.dart';
import '../domain/issues.dart';
import '../domain/profile.dart';

/// A profile file on disk; [profile] is null when the file is damaged.
class StoredProfile {
  const StoredProfile({required this.path, required this.profile, this.issues = const []});
  final String path;
  final ModProfile? profile;
  final List<ModIssue> issues;

  String get id => profile?.id ?? p.basename(path).replaceAll(kProfileExtension, '');
  bool get isValid => profile != null;
}

enum ProfileCollision { ask, replace, keepBoth }

sealed class ProfileImportOutcome {
  const ProfileImportOutcome();
}

class ProfileImportRejected extends ProfileImportOutcome {
  const ProfileImportRejected(this.issues);
  final List<ModIssue> issues;
}

/// A profile with the same id exists; ask the user to replace or keep both.
class ProfileImportConflict extends ProfileImportOutcome {
  const ProfileImportConflict({required this.existing, required this.incoming});
  final ModProfile existing;
  final ModProfile incoming;
}

class ProfileImported extends ProfileImportOutcome {
  const ProfileImported(this.profile, {this.replaced = false, this.warnings = const []});
  final ModProfile profile;
  final bool replaced;
  final List<ModIssue> warnings;
}

/// CRUD for `<meta>/profiles/<id>.j3profile.json` (atomic writes).
class ProfileStore {
  ProfileStore(this.metaDir);

  final String metaDir;

  String get dir => p.join(metaDir, 'profiles');
  String pathFor(String id) => p.join(dir, '$id$kProfileExtension');

  Future<List<StoredProfile>> list() async {
    final d = Directory(dir);
    if (!await d.exists()) return const [];
    final out = <StoredProfile>[];
    await for (final e in d.list(followLinks: false)) {
      if (e is! File || !p.basename(e.path).endsWith(kProfileExtension)) continue;
      out.add(await _read(e.path));
    }
    out.sort((a, b) {
      final an = a.profile?.name.toLowerCase() ?? a.id;
      final bn = b.profile?.name.toLowerCase() ?? b.id;
      return an.compareTo(bn);
    });
    return out;
  }

  Future<StoredProfile> _read(String path) async {
    try {
      final text = await File(path).readAsString();
      final r = ProfileParser.parseText(text);
      final expectedId = p.basename(path).replaceAll(kProfileExtension, '');
      if (r.profile != null && r.profile!.id != expectedId) {
        return StoredProfile(
          path: path,
          profile: null,
          issues: [
            ...r.issues,
            ModIssue.error('id', 'the file name says "$expectedId" but the profile id is "${r.profile!.id}"'),
          ],
        );
      }
      return StoredProfile(path: path, profile: r.profile, issues: r.issues);
    } on FileSystemException catch (e) {
      return StoredProfile(path: path, profile: null, issues: [ModIssue.error('file', 'cannot read: ${e.message}')]);
    } on FormatException catch (e) {
      return StoredProfile(path: path, profile: null, issues: [ModIssue.error('file', 'not UTF-8 text: ${e.message}')]);
    }
  }

  Future<ModProfile?> load(String id) async {
    final f = File(pathFor(id));
    if (!await f.exists()) return null;
    return (await _read(f.path)).profile;
  }

  Future<ModProfile> _require(String id) async {
    final prof = await load(id);
    if (prof == null) throw StateError('Profile "$id" does not exist or is damaged');
    return prof;
  }

  /// Validates and writes [profile] atomically.
  Future<ModProfile> save(ModProfile profile) async {
    final check = ProfileParser.fromMap(profile.toJson());
    if (!check.isValid) {
      throw FormatException('Invalid profile: ${check.issues.errors.map((i) => i.toString()).join('; ')}');
    }
    await Directory(dir).create(recursive: true);
    await atomicWriteString(pathFor(profile.id), '${profile.toPrettyJson()}\n');
    return check.profile!;
  }

  /// A free id derived from [base] (`base`, `base-2`, `base-3` ...).
  Future<String> uniqueId(String base) async {
    var candidate = base;
    var n = 2;
    while (await File(pathFor(candidate)).exists()) {
      final suffix = '-$n';
      final stem = base.length + suffix.length > 64 ? base.substring(0, 64 - suffix.length) : base;
      candidate = '$stem$suffix';
      n++;
    }
    return candidate;
  }

  Future<ModProfile> create({
    required String name,
    String target = '.',
    String description = '',
    List<ProfileMod> mods = const [],
    ProfileGame? game,
  }) async {
    final id = await uniqueId(slugifyId(name));
    return save(
      ModProfile(
        id: id,
        name: name.trim(),
        description: description,
        target: normalizeProfileTarget(target),
        mods: mods,
        game: game,
      ),
    );
  }

  Future<ModProfile> duplicate(String id) async {
    final src = await _require(id);
    final newId = await uniqueId('${src.id}-copy'.length > 64 ? src.id : '${src.id}-copy');
    var name = '${src.name} (copy)';
    if (name.length > 80) name = name.substring(0, 80);
    return save(src.copyWith(id: newId, name: name));
  }

  Future<ModProfile> rename(String id, String newName) async {
    final src = await _require(id);
    return save(src.copyWith(name: newName.trim()));
  }

  Future<void> delete(String id) async {
    final f = File(pathFor(id));
    if (await f.exists()) await f.delete();
  }

  Future<ModProfile> update(ModProfile profile) => save(profile);

  Future<ModProfile> setEnabled(String id, String modId, bool enabled) async =>
      save((await _require(id)).setEnabled(modId, enabled));

  /// Moves entry [from] to final position [to].
  Future<ModProfile> reorder(String id, int from, int to) async => save((await _require(id)).moveMod(from, to));

  Future<ModProfile> addMod(String id, String modId, {bool enabled = true}) async {
    final prof = await _require(id);
    if (prof.contains(modId)) return prof;
    return save(
      prof.copyWith(
        mods: [
          ...prof.mods,
          ProfileMod(modId, enabled: enabled),
        ],
      ),
    );
  }

  Future<ModProfile> removeMod(String id, String modId) async {
    final prof = await _require(id);
    return save(prof.copyWith(mods: prof.mods.where((m) => m.id != modId).toList()));
  }

  /// Text for exporting a profile (`<id>.j3profile.json`).
  static String exportText(ModProfile profile) => '${profile.toPrettyJson()}\n';

  static String exportFileName(ModProfile profile) => '${profile.id}$kProfileExtension';

  /// Validates and imports profile JSON text.
  Future<ProfileImportOutcome> importText(String text, {ProfileCollision collision = ProfileCollision.ask}) async {
    final r = ProfileParser.parseText(text);
    if (!r.isValid) return ProfileImportRejected(r.issues);
    var incoming = r.profile!;
    final existing = await load(incoming.id);
    final existsOnDisk = await File(pathFor(incoming.id)).exists();
    if (existsOnDisk) {
      switch (collision) {
        case ProfileCollision.ask:
          if (existing != null) return ProfileImportConflict(existing: existing, incoming: incoming);
          // A damaged file with the same id: keep it, import next to it.
          incoming = incoming.copyWith(id: await uniqueId(incoming.id));
        case ProfileCollision.replace:
          await save(incoming);
          return ProfileImported(incoming, replaced: true, warnings: r.issues.warnings);
        case ProfileCollision.keepBoth:
          incoming = incoming.copyWith(id: await uniqueId(incoming.id), name: _importedName(incoming.name));
      }
    }
    await save(incoming);
    return ProfileImported(incoming, warnings: r.issues.warnings);
  }

  static String _importedName(String name) {
    final n = '$name (imported)';
    return n.length > 80 ? n.substring(0, 80) : n;
  }
}
