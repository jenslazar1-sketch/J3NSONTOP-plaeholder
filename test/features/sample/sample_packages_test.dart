import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:j3nsontop_multitool/core/archive/safe_zip.dart';
import 'package:j3nsontop_multitool/core/utils/safe_path.dart';
import 'package:j3nsontop_multitool/features/sample/sample_content.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

/// Expected packages exactly as specified in docs/SAMPLES.md (the Mods
/// feature is built against these ids, versions and relations).
const _expected = <String, ({String version, Map<String, String> deps, Set<String> targets})>{
  'core-patch': (version: '1.0.0', deps: {}, targets: {'data/core_patch.json', 'data/localization/en.json'}),
  'neon-hud': (version: '1.2.0', deps: {}, targets: {'data/ui/hud.json'}),
  'hardcore-balance': (
    version: '2.0.1',
    deps: {'core-patch': '^1.0.0'},
    targets: {'config/balance.toml', 'data/items.csv'},
  ),
  'brutal-mode': (version: '0.9.0', deps: {}, targets: {'config/balance.toml'}),
  'legacy-skin': (version: '0.3.0', deps: {'retro-core': '^1.0.0'}, targets: {'sprites/hero_walk.png'}),
  'cycle-a': (version: '1.0.0', deps: {'cycle-b': '^1.0.0'}, targets: {'data/cycle_a.json'}),
  'cycle-b': (version: '1.0.0', deps: {'cycle-a': '^1.0.0'}, targets: {'data/cycle_b.json'}),
};

void main() {
  late Directory tmp;
  late SampleBundle bundle;
  final manifests = <String, Map<String, dynamic>>{};
  final paths = <String, String>{};

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('j3_sample_pkg_');
    bundle = buildSampleBundle();
    for (final e in bundle.packages.entries) {
      final path = p.join(tmp.path, e.key);
      File(path).writeAsBytesSync(e.value);
      paths[e.key] = path;
      manifests[e.key] = jsonDecode(SafeZip.readText(path, 'j3mod.json')) as Map<String, dynamic>;
    }
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  Map<String, dynamic> manifestOf(String id) => manifests.values.firstWhere((m) => m['id'] == id);

  test('the seven packages exist with the documented file names, in order', () {
    expect(bundle.packages.keys.toList(), [for (final e in _expected.entries) '${e.key}-${e.value.version}.j3mod']);
  });

  test('every package passes SafeZip.inspect without any issue', () {
    for (final e in paths.entries) {
      final inspection = SafeZip.inspect(e.value);
      expect(inspection.isSafe, isTrue, reason: '${e.key}: ${inspection.issues}');
      expect(inspection.issues, isEmpty, reason: e.key);
      for (final entry in inspection.entries) {
        expect(entry.method, anyOf(0, 8), reason: '${e.key}: Stored or Deflate only');
      }
      expect(inspection.find('j3mod.json'), isNotNull);
      expect(inspection.find('README.md'), isNotNull, reason: '${e.key} ships a README');
      expect(inspection.find('j3mod.json')!.size, lessThan(1024 * 1024));
    }
  });

  test('manifests have the required fields and valid values', () {
    final idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{1,63}$');
    for (final e in manifests.entries) {
      final m = e.value;
      expect(m['format'], 'j3mod', reason: e.key);
      expect(m['formatVersion'], 1, reason: e.key);
      expect(m['id'], matches(idPattern), reason: e.key);
      expect((m['name'] as String).length, inInclusiveRange(1, 80), reason: e.key);
      expect(() => Version.parse(m['version'] as String), returnsNormally, reason: e.key);
      expect('${m['id']}-${m['version']}.j3mod', e.key);
      expect((m['description'] as String).length, lessThanOrEqualTo(2000));
      expect(m['author'], isA<String>());
      expect(m['license'], 'CC0-1.0');
      for (final d in [...?m['dependencies'] as List<dynamic>?, ...?m['conflicts'] as List<dynamic>?]) {
        final dep = d as Map<String, dynamic>;
        expect(dep['id'], matches(idPattern));
        if (dep['version'] != null) {
          expect(() => VersionConstraint.parse(dep['version'] as String), returnsNormally);
        }
      }
    }
  });

  test('ids, versions, dependencies and targets are exactly as specified', () {
    _expected.forEach((id, spec) {
      final m = manifestOf(id);
      expect(m['version'], spec.version, reason: id);
      final deps = {
        for (final d in (m['dependencies'] as List<dynamic>?) ?? const [])
          (d as Map<String, dynamic>)['id'] as String: d['version'] as String,
      };
      expect(deps, spec.deps, reason: id);
      final targets = {for (final f in m['files'] as List<dynamic>) (f as Map<String, dynamic>)['target'] as String};
      expect(targets, spec.targets, reason: id);
    });
    expect(manifestOf('neon-hud')['dependencies'], isNull, reason: 'neon-hud depends on nothing');
    for (final id in ['hardcore-balance', 'brutal-mode']) {
      expect(manifestOf(id)['compatibility'], {'game': 'neon-dungeon', 'gameVersion': '>=1.4.0 <2.0.0'}, reason: id);
    }
    expect(bundle.packages.keys.where((k) => k.startsWith('retro-core')), isEmpty, reason: 'retro-core is missing');
  });

  test('compatibility matches the sample game', () {
    final game = jsonDecode(utf8.decode(bundle.files['game/game.json']!)) as Map<String, dynamic>;
    final version = Version.parse(game['version'] as String);
    for (final m in manifests.values) {
      final compat = m['compatibility'] as Map<String, dynamic>;
      expect(compat['game'], game['id']);
      final constraint = compat['gameVersion'] as String?;
      if (constraint != null) {
        expect(VersionConstraint.parse(constraint).allows(version), isTrue, reason: '${m['id']}');
      }
    }
  });

  test('file mappings: sources exist, targets are safe and unique, no unreferenced payload', () {
    for (final e in manifests.entries) {
      final inspection = SafeZip.inspect(paths[e.key]!);
      final files = (e.value['files'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect(files, isNotEmpty);
      final targets = <String>{};
      final sources = <String>{};
      for (final f in files) {
        final source = f['source'] as String;
        final target = f['target'] as String;
        expect(source, isNot('j3mod.json'));
        expect(inspection.find(source), isNotNull, reason: '${e.key}: $source');
        expect(SafePath.normalizeRelative(target), target, reason: '${e.key}: $target');
        expect(targets.add(SafePath.collisionKey(target)), isTrue, reason: 'unique targets');
        sources.add(SafePath.collisionKey(source));
      }
      final payload = inspection.files.where((f) => f.path!.startsWith('files/'));
      for (final f in payload) {
        expect(sources, contains(SafePath.collisionKey(f.path!)), reason: '${e.key}: unreferenced ${f.path}');
      }
    }
  });

  test('targets that overwrite exist in game/; created files do not', () {
    const creates = {'data/core_patch.json', 'data/cycle_a.json', 'data/cycle_b.json'};
    for (final m in manifests.values) {
      for (final f in (m['files'] as List<dynamic>).cast<Map<String, dynamic>>()) {
        final target = f['target'] as String;
        expect(bundle.files.containsKey('game/$target'), !creates.contains(target), reason: '${m['id']}: $target');
      }
    }
  });

  test('payloads are valid and differ from the originals', () {
    Uint8List payload(String id, String target) {
      final name = bundle.packages.keys.firstWhere((k) => k.startsWith('$id-'));
      return SafeZip.readEntry(paths[name]!, 'files/$target');
    }

    final hud = jsonDecode(utf8.decode(payload('neon-hud', 'data/ui/hud.json'))) as Map<String, dynamic>;
    expect(hud['theme'], 'neon');
    final en = utf8.decode(payload('core-patch', 'data/localization/en.json'));
    expect(en, contains('"Quit"'));
    expect(utf8.decode(bundle.files['game/data/localization/en.json']!), contains('"Qiut"'));
    final skin = img.decodePng(payload('legacy-skin', 'sprites/hero_walk.png'))!;
    expect((skin.width, skin.height), (128, 64));
    for (final (id, target) in [
      ('neon-hud', 'data/ui/hud.json'),
      ('hardcore-balance', 'config/balance.toml'),
      ('hardcore-balance', 'data/items.csv'),
      ('brutal-mode', 'config/balance.toml'),
      ('legacy-skin', 'sprites/hero_walk.png'),
    ]) {
      expect(payload(id, target), isNot(bundle.files['game/$target']), reason: '$id changes $target');
    }
    expect(
      payload('hardcore-balance', 'config/balance.toml'),
      isNot(payload('brutal-mode', 'config/balance.toml')),
      reason: 'the overlap has a visible winner',
    );
  });

  test('hardcore-balance and brutal-mode overlap on config/balance.toml', () {
    Set<String> targets(String id) => {
      for (final f in manifestOf(id)['files'] as List<dynamic>) (f as Map<String, dynamic>)['target'] as String,
    };
    expect(targets('hardcore-balance').intersection(targets('brutal-mode')), {'config/balance.toml'});
    expect(manifestOf('brutal-mode')['conflicts'], isNull, reason: 'an overlap, not a declared conflict');
  });

  test('profiles reference existing packages in the specified order', () {
    const expected = {
      'vanilla-plus': ('Vanilla+ HUD', ['neon-hud']),
      'hardcore-run': ('Hardcore run', ['core-patch', 'hardcore-balance', 'neon-hud']),
      'conflict-demo': ('Conflict demo', ['core-patch', 'hardcore-balance', 'brutal-mode']),
      'broken-deps': ('Broken dependencies', ['legacy-skin', 'cycle-a', 'cycle-b']),
    };
    expect(bundle.profiles.keys.toList(), [for (final id in expected.keys) '$id.j3profile.json']);
    final ids = manifests.values.map((m) => m['id']).toSet();
    expected.forEach((id, spec) {
      final profile = jsonDecode(utf8.decode(bundle.profiles['$id.j3profile.json']!)) as Map<String, dynamic>;
      expect(profile['format'], 'j3profile');
      expect(profile['formatVersion'], 1);
      expect(profile['id'], id);
      expect(profile['name'], spec.$1);
      expect(profile['target'], 'game');
      expect(SafePath.normalizeRelative(profile['target'] as String), 'game');
      final mods = (profile['mods'] as List<dynamic>).cast<Map<String, dynamic>>();
      expect([for (final m in mods) m['id']], spec.$2, reason: id);
      for (final m in mods) {
        expect(m['enabled'], isTrue);
        expect(ids, contains(m['id']));
      }
    });
  });

  test('conflict-demo: brutal-mode is the last writer of config/balance.toml', () {
    final profile = jsonDecode(utf8.decode(bundle.profiles['conflict-demo.j3profile.json']!)) as Map<String, dynamic>;
    final order = [for (final m in profile['mods'] as List<dynamic>) (m as Map<String, dynamic>)['id'] as String];
    final writers = [
      for (final id in order)
        if ((manifestOf(id)['files'] as List<dynamic>).any((f) => (f as Map)['target'] == 'config/balance.toml')) id,
    ];
    expect(writers, ['hardcore-balance', 'brutal-mode']);
  });
}
