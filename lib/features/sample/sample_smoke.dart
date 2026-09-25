import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../app/smoke_steps.dart';
import '../../core/archive/safe_zip.dart';
import '../../core/utils/hashing.dart';
import '../../core/workspace/workspace_controller.dart';
import 'sample_content.dart';
import 'sample_workspace.dart';

/// Packaged-app smoke step: generates the sample content in a worker isolate,
/// writes it into the smoke workspace root (not a new workspace) with the mod
/// library and profiles in its meta folder, then verifies counts, sizes,
/// hashes, JSON documents and every package archive on disk.
final FeatureSmokeStep sampleSmokeStep = FeatureSmokeStep('sample workspace content (generate, write, verify)', (
  ref,
  ws,
) async {
  final bundle = await generateSampleBundle();
  final meta = ref.read(workspacesProvider.notifier).metaDir(ws);
  final stats = await installSampleContent(rootDir: ws.rootPath, metaDir: meta, bundle: bundle);

  if (stats.packages != 7 || stats.profiles != 4) {
    throw StateError('expected 7 packages and 4 profiles, got $stats');
  }
  var checked = 0;
  for (final e in bundle.files.entries) {
    final f = File(p.joinAll([ws.rootPath, ...e.key.split('/')]));
    if (!f.existsSync()) throw StateError('missing ${e.key}');
    if (f.lengthSync() != e.value.length) throw StateError('size mismatch: ${e.key}');
    if (await Hashing.file(f.path) != Hashing.bytes(e.value)) throw StateError('hash mismatch: ${e.key}');
    if (e.key.endsWith('.json')) jsonDecode(utf8.decode(e.value));
    checked++;
  }
  for (final name in bundle.packages.keys) {
    final inspection = SafeZip.inspect(p.join(meta, 'mods', name));
    if (!inspection.isSafe) throw StateError('$name: ${inspection.fatal.join('; ')}');
  }
  for (final name in bundle.profiles.keys) {
    if (!File(p.join(meta, 'profiles', name)).existsSync()) throw StateError('missing profile $name');
  }
  return '$checked files verified ($stats), game $sampleGameId $sampleGameVersion';
});
