import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/sample/sample_export.dart';
import 'package:path/path.dart' as p;

/// Relative path (forward slashes) -> bytes for every file under [root].
Map<String, List<int>> _tree(String root) => {
  for (final f in Directory(root).listSync(recursive: true).whereType<File>())
    p.split(p.relative(f.path, from: root)).join('/'): f.readAsBytesSync(),
};

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('j3_sample_export_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('exporting twice produces identical trees', () async {
    final a = p.join(tmp.path, 'a');
    final b = p.join(tmp.path, 'b');
    final ra = await exportSamples(a);
    await exportSamples(b);
    final ta = _tree(a);
    final tb = _tree(b);
    expect(tb.keys.toSet(), ta.keys.toSet());
    for (final k in ta.keys) {
      expect(tb[k], ta[k], reason: k);
    }
    expect(ta.keys.toSet(), ra.files.keys.toSet());
    expect(ra.totalBytes, lessThan(2 * 1024 * 1024));
    // Re-exporting into the same folder replaces its content deterministically.
    File(p.join(a, 'neon-dungeon', 'stale.txt')).writeAsStringSync('old');
    File(p.join(a, 'keep-me.txt')).writeAsStringSync('not ours');
    await exportSamples(a);
    expect(File(p.join(a, 'neon-dungeon', 'stale.txt')).existsSync(), isFalse);
    expect(File(p.join(a, 'keep-me.txt')).existsSync(), isTrue, reason: 'only exporter folders are replaced');
  });

  test('layout and SHA256SUMS.txt', () async {
    final out = p.join(tmp.path, 'samples');
    final r = await exportSamples(out);
    final keys = r.files.keys.toSet();
    expect(keys, containsAll(['README.md', 'SHA256SUMS.txt', 'neon-dungeon/game/game.json']));
    expect(keys.where((k) => k.startsWith('packages/') && k.endsWith('.j3mod')), hasLength(7));
    expect(keys.where((k) => k.startsWith('profiles/') && k.endsWith('.j3profile.json')), hasLength(4));
    expect(keys.where((k) => k.startsWith('neon-dungeon/downloads/')), hasLength(7));
    final sums = const LineSplitter().convert(File(p.join(out, 'SHA256SUMS.txt')).readAsStringSync());
    final listed = <String>{};
    for (final line in sums) {
      final m = RegExp(r'^([0-9a-f]{64})  (.+)$').firstMatch(line);
      expect(m, isNotNull, reason: line);
      final file = File(p.joinAll([out, ...m!.group(2)!.split('/')]));
      expect(sha256.convert(file.readAsBytesSync()).toString(), m.group(1), reason: m.group(2));
      listed.add(m.group(2)!);
    }
    expect(listed, keys.difference({'SHA256SUMS.txt', '.gitignore', '.gitattributes'}));
    expect(File(p.join(out, 'README.md')).readAsStringSync(), contains('generated'));
  });

  test('the committed samples/ folder matches the generator', () async {
    final committed = Directory('samples');
    if (!committed.existsSync()) {
      markTestSkipped('samples/ not present in this checkout');
      return;
    }
    final fresh = await exportSamples(p.join(tmp.path, 'fresh'));
    final repo = _tree(committed.path);
    expect(
      repo.keys.toSet(),
      fresh.files.keys.toSet(),
      reason: 'run `dart run tool/export_samples.dart` after changing the generator',
    );
    for (final k in fresh.files.keys) {
      expect(repo[k], fresh.files[k], reason: '$k is stale: run `dart run tool/export_samples.dart`');
    }
  });
}
