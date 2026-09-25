import 'dart:convert';
import 'dart:io';

import 'package:j3nsontop_multitool/core/archive/safe_zip.dart';
import 'package:j3nsontop_multitool/features/mods/domain/manifest.dart';
import 'package:j3nsontop_multitool/features/mods/domain/profile.dart';
import 'package:path/path.dart' as p;

/// A manifest map following docs/MOD_FORMAT.md. [files] maps target paths
/// to content; sources are `files/<target>`.
Map<String, dynamic> manifestMap({
  required String id,
  String? name,
  String version = '1.0.0',
  List<String> targets = const ['data/a.txt'],
  List<Map<String, dynamic>> deps = const [],
  List<Map<String, dynamic>> optional = const [],
  List<Map<String, dynamic>> conflicts = const [],
  Map<String, dynamic>? compatibility,
  List<String> tags = const [],
}) => {
  'format': 'j3mod',
  'formatVersion': 1,
  'id': id,
  'name': name ?? id.toUpperCase(),
  'version': version,
  'description': 'Test package $id',
  'author': 'tests',
  'compatibility': ?compatibility,
  'files': [
    for (final t in targets) {'source': 'files/$t', 'target': t},
  ],
  if (deps.isNotEmpty) 'dependencies': deps,
  if (optional.isNotEmpty) 'optionalDependencies': optional,
  if (conflicts.isNotEmpty) 'conflicts': conflicts,
  if (tags.isNotEmpty) 'tags': tags,
};

/// Builds a `.j3mod` in [dir] with SafeZip.create. [contents] maps target
/// path to text; each is stored as `files/<target>`.
Future<String> buildPackage(
  Directory dir, {
  required String id,
  String version = '1.0.0',
  Map<String, String> contents = const {'data/a.txt': 'a'},
  List<Map<String, dynamic>> deps = const [],
  List<Map<String, dynamic>> optional = const [],
  List<Map<String, dynamic>> conflicts = const [],
  Map<String, dynamic>? compatibility,
  Map<String, List<int>> extraEntries = const {},
  String? fileName,
}) async {
  final manifest = manifestMap(
    id: id,
    version: version,
    targets: contents.keys.toList(),
    deps: deps,
    optional: optional,
    conflicts: conflicts,
    compatibility: compatibility,
  );
  final out = p.join(dir.path, fileName ?? '$id-$version.j3mod');
  await SafeZip.create(out, [
    ZipSource.bytes(kManifestFileName, utf8.encode(jsonEncode(manifest))),
    for (final e in contents.entries) ZipSource.bytes('files/${e.key}', utf8.encode(e.value)),
    for (final e in extraEntries.entries) ZipSource.bytes(e.key, e.value),
  ]);
  return out;
}

/// Writes [files] (relative path -> text) under [root].
void writeTree(String root, Map<String, String> files) {
  for (final e in files.entries) {
    final f = File(p.join(root, e.key));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(e.value);
  }
}

/// Snapshot of every file under [root]: relative path -> bytes.
Map<String, List<int>> snapshot(String root) {
  final out = <String, List<int>>{};
  final d = Directory(root);
  if (!d.existsSync()) return out;
  for (final e in d.listSync(recursive: true, followLinks: false)) {
    if (e is File) out[p.relative(e.path, from: root).replaceAll('\\', '/')] = e.readAsBytesSync();
  }
  return out;
}

/// All directories under [root] (relative).
Set<String> dirsUnder(String root) => {
  for (final e in Directory(root).listSync(recursive: true, followLinks: false))
    if (e is Directory) p.relative(e.path, from: root).replaceAll('\\', '/'),
};

ModProfile profileOf(String id, List<String> mods, {String target = 'game', Set<String> disabled = const {}}) =>
    ModProfile(
      id: id,
      name: 'Profile $id',
      target: target,
      mods: [for (final m in mods) ProfileMod(m, enabled: !disabled.contains(m))],
    );

ModManifest manifestOf(
  String id, {
  String version = '1.0.0',
  List<String>? targets,
  List<Map<String, dynamic>> deps = const [],
  List<Map<String, dynamic>> optional = const [],
  List<Map<String, dynamic>> conflicts = const [],
  Map<String, dynamic>? compatibility,
}) {
  final r = ManifestParser.fromMap(
    manifestMap(
      id: id,
      version: version,
      targets: targets ?? ['data/$id.txt'],
      deps: deps,
      optional: optional,
      conflicts: conflicts,
      compatibility: compatibility,
    ),
  );
  if (r.manifest == null) throw StateError('fixture manifest invalid: ${r.issues}');
  return r.manifest!;
}
