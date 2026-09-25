import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/utils/safe_path.dart';
import 'package:path/path.dart' as p;

void main() {
  group('normalizeRelative', () {
    test('accepts and normalises ordinary relative paths', () {
      expect(SafePath.normalizeRelative('data/ui/hud.json'), 'data/ui/hud.json');
      expect(SafePath.normalizeRelative(r'data\ui\hud.json'), 'data/ui/hud.json');
      expect(SafePath.normalizeRelative('./data//x.txt'), 'data/x.txt');
      expect(SafePath.normalizeRelative('ünïcødé/ファイル.txt'), 'ünïcødé/ファイル.txt');
    });

    for (final bad in [
      '../escape.txt',
      'a/../../b',
      r'..\evil.dll',
      '/etc/passwd',
      r'\\server\share\x',
      'C:/Windows/system32/x.dll',
      r'C:\x',
      'c:relative',
      'a/\u0000b',
      'con.txt',
      'dir/NUL',
      'bad./x',
      'x/y ',
      'what?.txt',
      '',
      '.',
      './',
    ]) {
      test('rejects ${bad.replaceAll('\u0000', r'\0')}', () {
        expect(() => SafePath.normalizeRelative(bad), throwsA(isA<UnsafePathException>()));
      });
    }
  });

  group('resolveInside', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('j3_safe_'));
    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('joins inside the root', () {
      final r = SafePath.resolveInside(root.path, 'a/b.txt');
      expect(p.isWithin(root.path, r), isTrue);
    });

    test('rejects a symlinked parent that escapes the root', () {
      if (Platform.isWindows) return; // symlinks need privileges on Windows
      final outside = Directory.systemTemp.createTempSync('j3_outside_');
      addTearDown(() => outside.deleteSync(recursive: true));
      Link(p.join(root.path, 'link')).createSync(outside.path);
      expect(() => SafePath.resolveInside(root.path, 'link/file.txt'), throwsA(isA<UnsafePathException>()));
    });

    test('rejects writing through an existing symlink target', () {
      if (Platform.isWindows) return;
      final outsideFile = File(
        p.join(Directory.systemTemp.path, 'j3_target_${DateTime.now().microsecondsSinceEpoch}.txt'),
      )..writeAsStringSync('x');
      addTearDown(outsideFile.deleteSync);
      Link(p.join(root.path, 'f.txt')).createSync(outsideFile.path);
      expect(() => SafePath.resolveInside(root.path, 'f.txt'), throwsA(isA<UnsafePathException>()));
    });
  });

  test('collisionKey is case-insensitive', () {
    expect(SafePath.collisionKey('Data/HUD.json'), SafePath.collisionKey(r'data\hud.JSON'));
  });

  test('sanitizeFileName', () {
    expect(SafePath.sanitizeFileName('a<b>:c?.txt'), 'a_b__c_.txt');
    expect(SafePath.sanitizeFileName('CON'), '_CON');
    expect(SafePath.sanitizeFileName('  ...'), 'file');
  });

  test('uniquePath appends a counter', () {
    final dir = Directory.systemTemp.createTempSync('j3_unique_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = p.join(dir.path, 'out.png');
    expect(SafePath.uniquePath(f), f);
    File(f).writeAsStringSync('x');
    expect(p.basename(SafePath.uniquePath(f)), 'out (2).png');
  });
}
