import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/mods/domain/issues.dart';
import 'package:j3nsontop_multitool/features/mods/domain/manifest.dart';
import 'package:j3nsontop_multitool/features/mods/domain/profile.dart';
import 'package:pub_semver/pub_semver.dart';

import 'mod_fixtures.dart';

Map<String, dynamic> base() => manifestMap(id: 'neon-hud', targets: ['data/ui/hud.json']);

ManifestResult parse(Map<String, dynamic> m) => ManifestParser.fromMap(m);

List<String> errorFields(ManifestResult r) => [for (final i in r.issues.errors) i.field];

void main() {
  group('valid manifests', () {
    test('the documented example parses with every field', () {
      const text = '''
{
  "format": "j3mod",
  "formatVersion": 1,
  "id": "neon-hud",
  "name": "Neon HUD",
  "version": "1.2.0",
  "description": "Recolours the HUD in neon red.",
  "author": "J3NSONTOP samples",
  "license": "CC0-1.0",
  "compatibility": { "game": "neon-dungeon", "gameVersion": ">=1.4.0 <2.0.0" },
  "files": [ { "source": "files/data/ui/hud.json", "target": "data/ui/hud.json" } ],
  "dependencies": [ { "id": "core-patch", "version": "^1.0.0" } ],
  "optionalDependencies": [ { "id": "hd-icons", "version": ">=2.0.0" } ],
  "conflicts": [ { "id": "classic-hud", "reason": "Both replace the HUD layout." } ],
  "tags": ["ui"]
}''';
      final r = ManifestParser.parseText(text);
      expect(r.isValid, isTrue, reason: r.issues.join('\n'));
      final m = r.manifest!;
      expect(m.id, 'neon-hud');
      expect(m.version, Version(1, 2, 0));
      expect(m.compatibility.game, 'neon-dungeon');
      expect(m.compatibility.gameVersion!.allows(Version(1, 4, 2)), isTrue);
      expect(m.compatibility.gameVersion!.allows(Version(2, 0, 0)), isFalse);
      expect(m.dependencies.single.id, 'core-patch');
      expect(m.dependencies.single.allows(Version(1, 9, 0)), isTrue);
      expect(m.dependencies.single.allows(Version(2, 0, 0)), isFalse);
      expect(m.optionalDependencies.single.constraintText, '>=2.0.0');
      expect(m.conflicts.single.reason, contains('HUD'));
      expect(m.conflicts.single.constraint.isAny, isTrue);
      expect(m.tags, ['ui']);
      expect(r.issues, isEmpty);
    });

    test('dependency version defaults to any', () {
      final m = base()
        ..['dependencies'] = [
          {'id': 'core-patch'},
        ];
      final r = parse(m);
      expect(r.isValid, isTrue);
      expect(r.manifest!.dependencies.single.isAny, isTrue);
      expect(r.manifest!.dependencies.single.constraintText, 'any');
    });

    test('toJson round-trips through the parser', () {
      final m = base()
        ..['dependencies'] = [
          {'id': 'core-patch', 'version': '^1.0.0'},
        ]
        ..['compatibility'] = {'game': 'neon-dungeon', 'gameVersion': '>=1.0.0'};
      final first = parse(m).manifest!;
      final again = ManifestParser.parseText(first.toPrettyJson());
      expect(again.isValid, isTrue);
      expect(again.manifest!.toJson(), first.toJson());
    });

    test('BOM and pre-release versions are accepted', () {
      final m = base()..['version'] = '2.0.0-beta.1+build.7';
      final r = ManifestParser.parseText('\uFEFF${jsonEncode(m)}');
      expect(r.isValid, isTrue);
      expect(r.manifest!.version.isPreRelease, isTrue);
    });

    test('target paths are normalised to forward slashes', () {
      final m = base()
        ..['files'] = [
          {'source': r'files\data\x.txt', 'target': r'data\ui\x.txt'},
        ];
      final r = parse(m);
      expect(r.isValid, isTrue);
      expect(r.manifest!.files.single.target, 'data/ui/x.txt');
      expect(r.manifest!.files.single.source, 'files/data/x.txt');
    });
  });

  group('validation matrix', () {
    final cases = <String, (void Function(Map<String, dynamic>), String)>{
      'wrong format': ((m) => m['format'] = 'zip', 'format'),
      'missing format': ((m) => m.remove('format'), 'format'),
      'formatVersion as string': ((m) => m['formatVersion'] = '1', 'formatVersion'),
      'formatVersion 0': ((m) => m['formatVersion'] = 0, 'formatVersion'),
      'missing id': ((m) => m.remove('id'), 'id'),
      'uppercase id': ((m) => m['id'] = 'Neon-HUD', 'id'),
      'one-char id': ((m) => m['id'] = 'a', 'id'),
      'id with space': ((m) => m['id'] = 'neon hud', 'id'),
      'id starting with dash': ((m) => m['id'] = '-neon', 'id'),
      'too long id': ((m) => m['id'] = 'a' * 65, 'id'),
      'empty name': ((m) => m['name'] = '  ', 'name'),
      'long name': ((m) => m['name'] = 'n' * 81, 'name'),
      'name not string': ((m) => m['name'] = 5, 'name'),
      'bad semver': ((m) => m['version'] = '1.0', 'version'),
      'semver with v prefix': ((m) => m['version'] = 'v1.0.0', 'version'),
      'missing version': ((m) => m.remove('version'), 'version'),
      'long description': ((m) => m['description'] = 'd' * 2001, 'description'),
      'author not string': ((m) => m['author'] = ['x'], 'author'),
      'compatibility not object': ((m) => m['compatibility'] = 'neon', 'compatibility'),
      'bad game id': ((m) => m['compatibility'] = {'game': 'Neon Dungeon'}, 'compatibility.game'),
      'bad gameVersion': ((m) => m['compatibility'] = {'gameVersion': '>=banana'}, 'compatibility.gameVersion'),
      'files missing': ((m) => m.remove('files'), 'files'),
      'files empty': ((m) => m['files'] = <Object>[], 'files'),
      'files not list': ((m) => m['files'] = {'a': 'b'}, 'files'),
      'file item not object': ((m) => m['files'] = ['x'], 'files[0]'),
      'source missing': (
        (m) => m['files'] = [
          {'target': 'a.txt'},
        ],
        'files[0].source',
      ),
      'source traversal': (
        (m) => m['files'] = [
          {'source': '../evil', 'target': 'a.txt'},
        ],
        'files[0].source',
      ),
      'source is manifest': (
        (m) => m['files'] = [
          {'source': 'j3mod.json', 'target': 'a.json'},
        ],
        'files[0].source',
      ),
      'target traversal': (
        (m) => m['files'] = [
          {'source': 'files/a', 'target': '../../outside.txt'},
        ],
        'files[0].target',
      ),
      'absolute target': (
        (m) => m['files'] = [
          {'source': 'files/a', 'target': '/etc/passwd'},
        ],
        'files[0].target',
      ),
      'drive target': (
        (m) => m['files'] = [
          {'source': 'files/a', 'target': r'C:\Windows\x.dll'},
        ],
        'files[0].target',
      ),
      'reserved device target': (
        (m) => m['files'] = [
          {'source': 'files/a', 'target': 'data/con.txt'},
        ],
        'files[0].target',
      ),
      'duplicate targets (case-insensitive)': (
        (m) => m['files'] = [
          {'source': 'files/a', 'target': 'Data/A.txt'},
          {'source': 'files/b', 'target': 'data/a.TXT'},
        ],
        'files[1].target',
      ),
      'dependency not object': ((m) => m['dependencies'] = ['core-patch'], 'dependencies[0]'),
      'dependency bad id': (
        (m) => m['dependencies'] = [
          {'id': 'Core Patch'},
        ],
        'dependencies[0].id',
      ),
      'dependency bad constraint': (
        (m) => m['dependencies'] = [
          {'id': 'core-patch', 'version': '^^1'},
        ],
        'dependencies[0].version',
      ),
      'self dependency': (
        (m) => m['dependencies'] = [
          {'id': 'neon-hud'},
        ],
        'dependencies[0].id',
      ),
      'duplicate dependency': (
        (m) => m['dependencies'] = [
          {'id': 'core-patch'},
          {'id': 'core-patch'},
        ],
        'dependencies[1].id',
      ),
      'optional bad constraint': (
        (m) => m['optionalDependencies'] = [
          {'id': 'hd-icons', 'version': ''},
        ],
        'optionalDependencies[0].version',
      ),
      'conflict with a dependency': (
        (m) => m
          ..['dependencies'] = [
            {'id': 'core-patch'},
          ]
          ..['conflicts'] = [
            {'id': 'core-patch'},
          ],
        'conflicts[0].id',
      ),
      'self conflict': (
        (m) => m['conflicts'] = [
          {'id': 'neon-hud'},
        ],
        'conflicts[0].id',
      ),
      'conflict reason not string': (
        (m) => m['conflicts'] = [
          {'id': 'x-hud', 'reason': 3},
        ],
        'conflicts[0].reason',
      ),
      'tag not string': ((m) => m['tags'] = ['ui', 3], 'tags[1]'),
    };
    cases.forEach((name, spec) {
      test('rejects $name', () {
        final m = base();
        spec.$1(m);
        final r = parse(m);
        expect(r.isValid, isFalse, reason: 'expected an error for $name');
        expect(r.manifest, isNull);
        expect(errorFields(r), contains(spec.$2), reason: r.issues.join('\n'));
      });
    });
  });

  group('formatVersion', () {
    test('formatVersion 2 is rejected with an explanation and nothing else', () {
      final m = base()
        ..['formatVersion'] = 2
        ..['newField'] = {'anything': true};
      final r = parse(m);
      expect(r.isValid, isFalse);
      expect(r.issues, hasLength(1));
      expect(r.issues.single.field, 'formatVersion');
      expect(r.issues.single.message, contains('newer than this app understands'));
      expect(r.issues.single.message, contains('update'));
      expect(r.rawId, 'neon-hud');
    });
  });

  group('warnings do not block', () {
    test('unknown fields, game.json target, required+optional duplicate', () {
      final m = base()
        ..['homepage'] = 'https://example.invalid'
        ..['files'] = [
          {'source': 'files/game.json', 'target': 'game.json'},
        ]
        ..['dependencies'] = [
          {'id': 'core-patch'},
        ]
        ..['optionalDependencies'] = [
          {'id': 'core-patch'},
        ];
      final r = parse(m);
      expect(r.isValid, isTrue, reason: r.issues.join('\n'));
      final fields = [for (final i in r.issues.warnings) i.field];
      expect(fields, containsAll(['homepage', 'files[0].target', 'optionalDependencies']));
      expect(r.manifest!.optionalDependencies, isEmpty);
    });
  });

  group('json errors', () {
    test('not JSON', () {
      final r = ManifestParser.parseText('{nope');
      expect(r.isValid, isFalse);
      expect(r.issues.single.message, contains('not valid JSON'));
    });
    test('not an object', () {
      expect(ManifestParser.parseText('[1,2]').issues.single.message, contains('JSON object'));
    });
  });

  group('helpers', () {
    test('slugifyId', () {
      expect(slugifyId('Hardcore run'), 'hardcore-run');
      expect(slugifyId('  Neon  HUD!! v2 '), 'neon-hud-v2');
      expect(slugifyId('!!'), 'profile');
      expect(kModIdPattern.hasMatch(slugifyId('A' * 100)), isTrue);
    });
    test('validateModId', () {
      expect(validateModId('core-patch'), isNull);
      expect(validateModId('core.patch_2'), isNull);
      expect(validateModId('Core'), isNotNull);
    });
  });
}
