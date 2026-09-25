import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/mods/domain/issues.dart';
import 'package:j3nsontop_multitool/features/mods/domain/package_inspector.dart';
import 'package:path/path.dart' as p;

import '../../helpers/raw_zip.dart';
import 'mod_fixtures.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('j3_pkg_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  List<int> jsonBytes(Object o) => utf8.encode(jsonEncode(o));

  test('valid package: manifest, mapping table and sizes', () async {
    final path = await buildPackage(
      tmp,
      id: 'neon-hud',
      version: '1.2.0',
      contents: {'data/ui/hud.json': '{"color":"red"}', 'data/ui/icons.txt': 'x'},
      extraEntries: {
        'README.md': utf8.encode('# readme'),
        'preview.png': [1, 2, 3],
      },
    );
    final r = PackageInspector.inspect(path);
    expect(r.isValid, isTrue, reason: r.issues.join('\n'));
    expect(r.manifest!.id, 'neon-hud');
    expect(r.mapped, hasLength(2));
    expect(r.mapped.every((m) => m.exists), isTrue);
    expect(r.payloadBytes, '{"color":"red"}'.length + 1);
    expect(r.unmapped, isEmpty, reason: 'README.md and preview.png are allowed extras');
    expect(r.issues, isEmpty);
    expect(r.archiveBytes, File(path).lengthSync());
    expect(PackageInspector.prettyManifest(r), contains('"id": "neon-hud"'));
  });

  test('background inspection returns the same report', () async {
    final path = await buildPackage(tmp, id: 'core-patch');
    final r = await inspectPackageInBackground(path);
    expect(r.isValid, isTrue);
    expect(r.manifest!.id, 'core-patch');
  });

  test('unmapped payload files produce warnings', () async {
    final path = await buildPackage(
      tmp,
      id: 'core-patch',
      extraEntries: {
        'files/extra.bin': [0, 1],
      },
    );
    final r = PackageInspector.inspect(path);
    expect(r.isValid, isTrue);
    expect(r.unmapped, ['files/extra.bin']);
    expect(r.issues.warnings.single.message, contains('not mapped'));
  });

  group('hostile or broken packages are rejected', () {
    Map<String, dynamic> manifest({List<Map<String, String>>? files}) => {
      ...manifestMap(id: 'evil-mod'),
      'files':
          files ??
          [
            {'source': 'files/a.txt', 'target': 'a.txt'},
          ],
    };

    final cases = <String, (List<RawZipEntry> Function(), String)>{
      'zip-slip traversal entry': (
        () => [
          RawZipEntry('j3mod.json', jsonBytes(manifest())),
          RawZipEntry('files/a.txt', utf8.encode('a')),
          RawZipEntry('../../evil.dll', utf8.encode('x')),
        ],
        'archive',
      ),
      'symlink entry': (
        () => [
          RawZipEntry('j3mod.json', jsonBytes(manifest())),
          RawZipEntry('files/a.txt', utf8.encode('/etc/passwd'), unixMode: 0xA1FF),
        ],
        'archive',
      ),
      'duplicate entries': (
        () => [
          RawZipEntry('j3mod.json', jsonBytes(manifest())),
          RawZipEntry('files/a.txt', utf8.encode('1')),
          RawZipEntry('FILES/A.TXT', utf8.encode('2')),
        ],
        'archive',
      ),
      'duplicate targets in manifest': (
        () => [
          RawZipEntry(
            'j3mod.json',
            jsonBytes(
              manifest(
                files: [
                  {'source': 'files/a.txt', 'target': 'data/x.txt'},
                  {'source': 'files/b.txt', 'target': 'DATA/X.txt'},
                ],
              ),
            ),
          ),
          RawZipEntry('files/a.txt', utf8.encode('a')),
          RawZipEntry('files/b.txt', utf8.encode('b')),
        ],
        'files[1].target',
      ),
      'missing source file': (
        () => [
          RawZipEntry(
            'j3mod.json',
            jsonBytes(
              manifest(
                files: [
                  {'source': 'files/missing.txt', 'target': 'a.txt'},
                ],
              ),
            ),
          ),
          RawZipEntry('files/a.txt', utf8.encode('a')),
        ],
        'files[0].source',
      ),
      'source is a folder': (
        () => [
          RawZipEntry(
            'j3mod.json',
            jsonBytes(
              manifest(
                files: [
                  {'source': 'files/dir', 'target': 'a.txt'},
                ],
              ),
            ),
          ),
          RawZipEntry('files/dir/', const []),
          RawZipEntry('files/dir/x.txt', utf8.encode('x')),
        ],
        'files[0].source',
      ),
      'target traversal in manifest': (
        () => [
          RawZipEntry(
            'j3mod.json',
            jsonBytes(
              manifest(
                files: [
                  {'source': 'files/a.txt', 'target': '../../../outside.txt'},
                ],
              ),
            ),
          ),
          RawZipEntry('files/a.txt', utf8.encode('a')),
        ],
        'files[0].target',
      ),
      'bad semver': (
        () => [
          RawZipEntry('j3mod.json', jsonBytes({...manifest(), 'version': '1.0'})),
          RawZipEntry('files/a.txt', utf8.encode('a')),
        ],
        'version',
      ),
      'formatVersion 2': (
        () => [
          RawZipEntry('j3mod.json', jsonBytes({...manifest(), 'formatVersion': 2})),
          RawZipEntry('files/a.txt', utf8.encode('a')),
        ],
        'formatVersion',
      ),
      'missing manifest': (() => [RawZipEntry('files/a.txt', utf8.encode('a'))], 'j3mod.json'),
      'manifest in wrong case': (
        () => [RawZipEntry('J3MOD.JSON', jsonBytes(manifest())), RawZipEntry('files/a.txt', utf8.encode('a'))],
        'j3mod.json',
      ),
      'manifest is not JSON': (
        () => [RawZipEntry('j3mod.json', utf8.encode('{"id": ')), RawZipEntry('files/a.txt', utf8.encode('a'))],
        'j3mod.json',
      ),
      'manifest too large': (
        () => [
          RawZipEntry('j3mod.json', utf8.encode(' ' * (1024 * 1024 + 10))),
          RawZipEntry('files/a.txt', utf8.encode('a')),
        ],
        'j3mod.json',
      ),
      'manifest with corrupt CRC': (
        () => [
          RawZipEntry('j3mod.json', jsonBytes(manifest()), crcOverride: 1234),
          RawZipEntry('files/a.txt', utf8.encode('a')),
        ],
        'j3mod.json',
      ),
      'encrypted entry': (
        () => [
          RawZipEntry('j3mod.json', jsonBytes(manifest())),
          RawZipEntry('files/a.txt', utf8.encode('a'), encrypted: true),
        ],
        'archive',
      ),
    };

    cases.forEach((name, spec) {
      test(name, () {
        final path = writeRawZip(tmp, 'bad.j3mod', spec.$1());
        final r = PackageInspector.inspect(path);
        expect(r.isValid, isFalse, reason: 'expected $name to be rejected');
        expect(r.manifest, isNull);
        expect(r.issues.errors.map((i) => i.field), contains(spec.$2), reason: r.issues.join('\n'));
      });
    });

    test('not a zip at all', () {
      final f = File(p.join(tmp.path, 'x.j3mod'))..writeAsStringSync('hello');
      final r = PackageInspector.inspect(f.path);
      expect(r.isValid, isFalse);
      expect(r.issues.single.field, 'archive');
    });

    test('missing file', () {
      final r = PackageInspector.inspect(p.join(tmp.path, 'nope.j3mod'));
      expect(r.isValid, isFalse);
      expect(r.issues.single.field, 'file');
    });

    test('formatVersion 2 keeps display values for the UI', () {
      final path = writeRawZip(tmp, 'v2.j3mod', [
        RawZipEntry('j3mod.json', jsonBytes({...manifest(), 'formatVersion': 2})),
        RawZipEntry('files/a.txt', utf8.encode('a')),
      ]);
      final r = PackageInspector.inspect(path);
      expect(r.displayId, 'evil-mod');
      expect(r.displayVersion, '1.0.0');
      expect(r.issues.errors.single.message, contains('newer'));
    });
  });
}
