import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/utils/text_codec.dart';
import 'package:j3nsontop_multitool/core/workspace/file_backup.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace.dart';
import 'package:j3nsontop_multitool/features/workspaces/data/replace_service.dart';
import 'package:j3nsontop_multitool/features/workspaces/data/search_service.dart';
import 'package:j3nsontop_multitool/features/workspaces/domain/fs_errors.dart';
import 'package:j3nsontop_multitool/features/workspaces/domain/name_query.dart';
import 'package:j3nsontop_multitool/features/workspaces/domain/text_pattern.dart';
import 'package:path/path.dart' as p;

Uint8List utf16le(String s, {bool bom = true}) {
  final b = BytesBuilder();
  if (bom) b.add([0xFF, 0xFE]);
  for (final u in s.codeUnits) {
    b.add([u & 0xFF, u >> 8]);
  }
  return b.toBytes();
}

void main() {
  late Directory tmp;
  late String root;
  late String meta;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('j3_rs_');
    root = p.join(tmp.path, 'files');
    meta = p.join(tmp.path, 'meta');
    Directory(root).createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  File write(String rel, List<int> bytes) => File(p.join(root, rel))
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);

  WorkspaceFileWriter writerFor(DateTime at) => WorkspaceFileWriter(
    workspace: Workspace(
      id: 'w',
      name: 'W',
      kind: WorkspaceKind.imported,
      rootPath: root,
      createdAt: at,
      lastOpenedAt: at,
    ),
    metaDir: meta,
    clock: () => at,
  );

  group('replace engine', () {
    test('CRLF UTF-8 BOM and UTF-16 LE files keep every byte except the replacements', () async {
      final crlf = write('game/config/settings.ini', [
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('[Audio]\r\nvolume=80\r\nmusic=80\r\n'),
      ]);
      final u16 = write('game/data/strings.txt', utf16le('hp=80\r\nname=Neon Ünïcødé\r\n'));
      write('game/data/other.bin', [0, 1, 2, 80, 56, 48, 0]);
      const options = ReplaceOptions(
        find: FindSpec(pattern: r'=(\d+)', isRegex: true),
        replacement: r'=[$1]',
      );
      final preview = await ReplaceService.preview(root: root, options: options);
      expect(preview.files.map((f) => f.relative).toSet(), {'game/config/settings.ini', 'game/data/strings.txt'});
      expect(preview.skippedBinary, 1);
      expect(preview.totalReplacements, 3);
      final ini = preview.files.firstWhere((f) => f.relative.endsWith('.ini'));
      expect(ini.count, 2);
      expect(ini.encodingLabel, 'UTF-8 with BOM');
      expect(ini.lineEnding, 'CRLF');
      expect(ini.diff, contains('-volume=80'));
      expect(ini.diff, contains('+volume=[80]'));

      final at = DateTime(2026, 9, 25, 10, 30, 5);
      final result = await ReplaceService.apply(files: preview.files, options: options, writer: writerFor(at));
      expect(result.changed.length, 2);
      expect(result.replacements, 3);
      expect(result.failed, isEmpty);
      expect(crlf.readAsBytesSync(), [0xEF, 0xBB, 0xBF, ...utf8.encode('[Audio]\r\nvolume=[80]\r\nmusic=[80]\r\n')]);
      expect(u16.readAsBytesSync(), utf16le('hp=[80]\r\nname=Neon Ünïcødé\r\n'));
      // Backups of the originals, all in one snapshot folder.
      expect(result.backupDir, isNotNull);
      final backupIni = File(p.join(result.backupDir!, 'game', 'config', 'settings.ini'));
      expect(backupIni.readAsBytesSync(), [0xEF, 0xBB, 0xBF, ...utf8.encode('[Audio]\r\nvolume=80\r\nmusic=80\r\n')]);
      expect(
        File(p.join(result.backupDir!, 'game', 'data', 'strings.txt')).readAsBytesSync(),
        utf16le('hp=80\r\nname=Neon Ünïcødé\r\n'),
      );
    });

    test('files changed after the preview are skipped, not overwritten', () async {
      final f = write('a.txt', utf8.encode('x=1'));
      const options = ReplaceOptions(
        find: FindSpec(pattern: 'x'),
        replacement: 'y',
      );
      final preview = await ReplaceService.preview(root: root, options: options);
      f.writeAsStringSync('x=2 edited elsewhere');
      final r = await ReplaceService.apply(files: preview.files, options: options, writer: writerFor(DateTime(2026)));
      expect(r.changed, isEmpty);
      expect(r.skipped.single, contains('changed since the preview'));
      expect(f.readAsStringSync(), 'x=2 edited elsewhere');
    });

    test('Latin-1 fallback files are rewritten losslessly or skipped with a reason', () async {
      write('latin.txt', [0x63, 0x61, 0x66, 0xE9, 0x3D, 0x31]); // "café=1" in Latin-1
      final ok = await ReplaceService.preview(
        root: root,
        options: const ReplaceOptions(
          find: FindSpec(pattern: '1'),
          replacement: '2',
        ),
      );
      expect(ok.files.single.encodingLabel, 'Latin-1 (fallback)');
      final bad = await ReplaceService.preview(
        root: root,
        options: const ReplaceOptions(
          find: FindSpec(pattern: '1'),
          replacement: '名',
        ),
      );
      expect(bad.files, isEmpty);
      expect(bad.skippedUnsafe.single, contains('Latin-1'));
      final bytes = transformBytes([0x63, 0x61, 0x66, 0xE9, 0x3D, 0x31], const FindSpec(pattern: '1'), '2')!;
      expect(bytes.$1, [0x63, 0x61, 0x66, 0xE9, 0x3D, 0x32]);
    });

    test('glob filter, size limit and catastrophic regex timeout', () async {
      write('a.json', utf8.encode('{"hp": 1}'));
      write('b.txt', utf8.encode('hp'));
      write('big.json', utf8.encode('hp ${'x' * 2000}'));
      final r = await ReplaceService.preview(
        root: root,
        options: const ReplaceOptions(
          find: FindSpec(pattern: 'hp'),
          replacement: 'HP',
          includeGlob: '*.json',
          maxFileBytes: 1000,
        ),
      );
      expect(r.files.map((f) => f.relative), ['a.json']);
      expect(r.skippedLarge, 1);

      write('evil.txt', utf8.encode('${'a' * 40}!'));
      await expectLater(
        ReplaceService.preview(
          root: root,
          options: const ReplaceOptions(
            find: FindSpec(pattern: r'^(a+)+$', isRegex: true),
            replacement: '',
            batchTimeout: Duration(milliseconds: 400),
          ),
        ),
        throwsA(isA<PatternTimeoutException>()),
      );
    });
  });

  group('file-name search', () {
    setUp(() {
      write('game/saves/slot1.json', utf8.encode('{}'));
      write('game/saves/save_auto.json', utf8.encode('{}'));
      write('game/config/graphics.json', utf8.encode('{}'));
      write('game/.cache/save_old.json', utf8.encode('{}'));
      write('notes/unicode-名前-ünïcødé.txt', utf8.encode('x'));
    });

    test('glob semantics, hidden folders and folders toggle', () async {
      final r = await FindFilesService.run(root: root, query: NameQuery.compile('**/save*.json', NameMatchMode.glob));
      expect(r.hits.map((h) => h.relative), ['game/saves/save_auto.json']);
      final hidden = await FindFilesService.run(
        root: root,
        query: NameQuery.compile('**/save*.json', NameMatchMode.glob),
        includeHidden: true,
      );
      expect(
        hidden.hits.map((h) => h.relative),
        containsAll(['game/.cache/save_old.json', 'game/saves/save_auto.json']),
      );
      final folders = await FindFilesService.run(
        root: root,
        query: NameQuery.compile('saves', NameMatchMode.substring),
        includeFolders: true,
      );
      expect(folders.hits.single.isDirectory, isTrue);
      final all = await FindFilesService.run(root: root, query: NameQuery.compile('*.json', NameMatchMode.glob));
      expect(all.hits.length, 3);
      expect(all.hits.first.size, 2);
    });

    test('regex mode, unicode names and result limit', () async {
      final r = await FindFilesService.run(root: root, query: NameQuery.compile(r'名前.*\.txt$', NameMatchMode.regex));
      expect(r.hits.single.relative, 'notes/unicode-名前-ünïcødé.txt');
      final limited = await FindFilesService.run(
        root: root,
        query: NameQuery.compile('*', NameMatchMode.glob),
        maxResults: 2,
      );
      expect(limited.hits.length, 2);
      expect(limited.truncated, isTrue);
    });

    test('symlinked folders are never followed (no loops)', () async {
      Link(p.join(root, 'game', 'loop')).createSync(root);
      final r = await FindFilesService.run(root: root, query: NameQuery.compile('*.json', NameMatchMode.glob));
      expect(r.hits.length, 3);
      expect(r.skippedLinks, 1);
    });

    test('cancellation stops the walk', () async {
      final token = CancellationToken()..cancel();
      await expectLater(
        FindFilesService.run(root: root, query: NameQuery.compile('*', NameMatchMode.glob), token: token),
        throwsA(isA<OperationCancelled>()),
      );
    });
  });

  group('text search', () {
    test('plain, whole word, glob include, binary and size skips', () async {
      write('game/config/settings.ini', utf8.encode('[Gameplay]\r\nmax_hp=100\r\nhp_regen=2\r\n'));
      write('game/data/items.csv', utf8.encode('id,name,hp\n1,potion,hp\n'));
      write('game/sprites/x.png', [0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 104, 112]);
      write('game/logs/huge.log', utf8.encode('hp\n' * 10));
      final r = await TextSearchService.run(
        root: root,
        options: const TextSearchOptions(find: FindSpec(pattern: 'hp', wholeWord: true), maxFileBytes: 25),
      );
      expect(r.files.map((f) => f.relative).toList(), ['game/data/items.csv']);
      expect(r.files.single.matches.map((m) => m.line), [1, 2]);
      expect(r.skippedBinary, 1);
      expect(r.skippedLarge, 2, reason: 'huge.log and settings.ini exceed 25 bytes');
      final ini = await TextSearchService.run(
        root: root,
        options: const TextSearchOptions(
          find: FindSpec(pattern: 'HP'),
          includeGlob: '*.ini',
        ),
      );
      expect(ini.files.single.matches.map((m) => m.line), [2, 3]);
      expect(ini.skippedFilter, 3);
      expect(ini.toReport(), contains('game/config/settings.ini:2:5: max_hp=100'));
    });

    test('invalid regex fails before any file is read', () async {
      write('a.txt', utf8.encode('x'));
      await expectLater(
        TextSearchService.run(
          root: root,
          options: const TextSearchOptions(find: FindSpec(pattern: '(', isRegex: true)),
        ),
        throwsFormatException,
      );
    });

    test('catastrophic regex surfaces a timeout error instead of hanging', () async {
      write('evil.txt', utf8.encode('${'a' * 40}!'));
      final sw = Stopwatch()..start();
      await expectLater(
        TextSearchService.run(
          root: root,
          options: const TextSearchOptions(
            find: FindSpec(pattern: r'^(a+)+$', isRegex: true),
            batchTimeout: Duration(milliseconds: 400),
          ),
        ),
        throwsA(isA<PatternTimeoutException>().having((e) => e.files, 'files', ['evil.txt'])),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('UTF-16 files are searched after decoding; cancel works', () async {
      write('u16.txt', utf16le('alpha\r\nbeta gamma\r\n'));
      final r = await TextSearchService.run(
        root: root,
        options: const TextSearchOptions(find: FindSpec(pattern: 'gamma')),
      );
      expect(r.files.single.matches.single.line, 2);
      expect(TextCodec.decode(File(p.join(root, 'u16.txt')).readAsBytesSync()).encoding, TextEncodingKind.utf16le);
      final token = CancellationToken()..cancel();
      await expectLater(
        TextSearchService.run(
          root: root,
          options: const TextSearchOptions(find: FindSpec(pattern: 'x')),
          token: token,
        ),
        throwsA(isA<OperationCancelled>()),
      );
    });
  });
}
