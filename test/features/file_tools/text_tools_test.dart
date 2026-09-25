import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/utils/text_codec.dart';
import 'package:j3nsontop_multitool/core/workspace/file_backup.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace.dart';
import 'package:j3nsontop_multitool/features/file_tools/domain/line_endings.dart';
import 'package:j3nsontop_multitool/features/file_tools/domain/text_files.dart';
import 'package:j3nsontop_multitool/features/file_tools/domain/whitespace.dart';
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
  group('line endings', () {
    test('counts LF, CRLF and lone CR; mixed flag', () {
      final c = countLineEndings('a\nb\r\nc\rd\r\n');
      expect((c.lf, c.crlf, c.cr), (1, 2, 1));
      expect(c.mixed, isTrue);
      expect(c.kind, LineEnding.mixed);
      expect(c.dominant, LineEnding.crlf);
      expect(countLineEndings('x').kind, LineEnding.none);
      expect(countLineEndings('a\r\nb\r\n').kind, LineEnding.crlf);
      expect(countLineEndings('a\rb').kind, LineEnding.cr);
      expect(countLineEndings('a\r').cr, 1, reason: 'trailing CR is a lone CR');
    });

    test('converts mixed text to each target', () {
      const mixed = 'one\ntwo\r\nthree\rfour\r\n\r\nend';
      expect(convertLineEndings(mixed, LineEnding.lf), 'one\ntwo\nthree\nfour\n\nend');
      expect(convertLineEndings(mixed, LineEnding.crlf), 'one\r\ntwo\r\nthree\r\nfour\r\n\r\nend');
      expect(convertLineEndings(mixed, LineEnding.cr), 'one\rtwo\rthree\rfour\r\rend');
      final after = countLineEndings(convertLineEndings(mixed, LineEnding.crlf));
      expect((after.lf, after.crlf, after.cr, after.mixed), (0, 5, 0, false));
    });

    test('visualizes terminators', () {
      expect(visualizeLineEndings('a\r\nb\nc\rd'), 'a«CRLF»\nb«LF»\nc«CR»\nd');
      expect(visualizeLineEndings('1\n2\n3\n', maxLines: 2), '1«LF»\n2«LF»\n');
    });
  });

  group('whitespace rules', () {
    WhitespaceResult run(String s, WhitespaceOptions o) => cleanWhitespace(s, o);
    const none = WhitespaceOptions.none;

    test('no rules = no change', () {
      const s = '﻿a  \n\n\n\tb \r\nc';
      final r = run(s, none);
      expect(r.text, s);
      expect(r.changed, isFalse);
    });

    test('trim trailing whitespace keeps each line ending', () {
      final r = run('a  \r\nb\t\nc \t', none.copyWith(trimTrailing: true));
      expect(r.text, 'a\r\nb\nc');
      expect(r.stats.trailingTrimmed, 3);
      expect(r.stats.linesChanged, 3);
    });

    test('tabs to spaces: indentation only by default, inner tabs on request', () {
      final o = none.copyWith(indentMode: IndentMode.tabsToSpaces, tabWidth: 4);
      expect(run('\tx\ty\n  \tz', o).text, '    x\ty\n    z');
      final all = run('\tx\ty', o.copyWith(expandInnerTabs: true));
      expect(all.text, '    x   y');
      expect(all.stats.tabsExpanded, 2);
    });

    test('leading spaces to tabs with a remainder', () {
      final r = run('        a\n      b\n  c\nd', none.copyWith(indentMode: IndentMode.spacesToTabs, tabWidth: 4));
      expect(r.text, '\t\ta\n\t  b\n  c\nd');
      expect(r.stats.indentsConverted, 2);
    });

    test('collapse blank lines to a maximum (0 removes all)', () {
      const s = 'a\n\n\n\nb\n  \n\t\nc\n';
      final one = run(s, none.copyWith(collapseBlankLines: true, maxBlankLines: 1));
      expect(one.text, 'a\n\nb\n  \nc\n');
      expect(one.stats.blankLinesRemoved, 3);
      final zero = run(s, none.copyWith(collapseBlankLines: true, maxBlankLines: 0));
      expect(zero.text, 'a\nb\nc\n');
    });

    test('exactly one final newline (added, or trailing blanks removed)', () {
      final o = none.copyWith(ensureFinalNewline: true);
      final added = run('a\r\nb', o);
      expect(added.text, 'a\r\nb\r\n', reason: 'uses the dominant ending');
      expect(added.stats.finalNewlineAdded, isTrue);
      final trimmed = run('a\n\n\n  \n', o);
      expect(trimmed.text, 'a\n');
      expect(trimmed.stats.trailingBlankLinesRemoved, 3);
      expect(run('', o).text, '');
      expect(run('\n\n', o).text, '');
      expect(run('a\n', o).changed, isFalse);
    });

    test('BOM and special spaces; ZWJ kept', () {
      final r = run('﻿a b c d e​f⁠g﻿h 👩‍💻', none.copyWith(stripBom: true, replaceSpecialSpaces: true));
      expect(r.text, 'a b c d efgh 👩‍💻');
      expect(r.stats.bomRemoved, 1);
      expect(r.stats.specialSpacesReplaced, 3);
      expect(r.stats.zeroWidthRemoved, 3);
      final keepBom = run('﻿x​y', none.copyWith(replaceSpecialSpaces: true));
      expect(keepBom.text, '﻿xy');
      final latin = cleanWhitespace('a b', none.copyWith(replaceSpecialSpaces: true), allowSpecialSpaces: false);
      expect(latin.text, 'a b');
      expect(latin.stats.notes.single, contains('not valid UTF-8'));
    });

    test('normalise line endings (optional)', () {
      final r = run('a\r\nb\rc\n', none.copyWith(normalizeLineEndings: true, lineEnding: LineEnding.lf));
      expect(r.text, 'a\nb\nc\n');
      expect(r.stats.lineEndingsChanged, 2);
    });

    test('rules combined', () {
      const input = '﻿  key = 1   \r\n\r\n\r\n\r\n\tnested value\t\r\n\r\n';
      final r = run(
        input,
        const WhitespaceOptions(
          indentMode: IndentMode.tabsToSpaces,
          tabWidth: 2,
          maxBlankLines: 1,
          normalizeLineEndings: true,
          lineEnding: LineEnding.lf,
        ),
      );
      expect(r.text, '  key = 1\n\n  nested value\n');
      final d = r.stats.describe();
      expect(d, contains('Removed the UTF-8 byte order mark'));
      expect(d.any((s) => s.contains('Trimmed trailing whitespace on 2')), isTrue);
      expect(d.any((s) => s.contains('extra blank line')), isTrue);
      expect(d.any((s) => s.contains('line ending')), isTrue);
    });

    test('showInvisibles and diff budget', () {
      expect(showInvisibles('\ta b​  '), '→a°b¤··');
      expect(previewDiffBudget(10, 10), 20000);
      expect(previewDiffBudget(100000, 100000), 64);
    });
  });

  group('text file batch', () {
    late Directory tmp;
    late WorkspaceFileWriter writer;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('j3_txt_');
      final ws = Workspace(
        id: 'w',
        name: 'W',
        kind: WorkspaceKind.imported,
        rootPath: p.join(tmp.path, 'root'),
        createdAt: DateTime(2026),
        lastOpenedAt: DateTime(2026),
      );
      Directory(ws.rootPath).createSync();
      writer = WorkspaceFileWriter(
        workspace: ws,
        metaDir: p.join(tmp.path, 'meta'),
        clock: () => DateTime(2026, 1, 2, 3),
      );
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    TextFileTarget target(String rel, List<int> bytes, {bool inWorkspace = true}) {
      final f = File(p.join(tmp.path, 'root', rel))..writeAsBytesSync(bytes);
      return TextFileTarget(path: f.path, label: rel, inWorkspace: inWorkspace);
    }

    test('UTF-16 LE with BOM is converted byte-exactly', () async {
      final t = target('win.txt', utf16le('名前 one\r\ntwo\r\nthree 😀\r\n'));
      final r = await processTextFiles([t], lineEndingTransform(LineEnding.lf), apply: true, writer: writer);
      expect(r.single.status, TextFileStatus.changed);
      expect(r.single.encodingLabel, 'UTF-16 LE');
      expect(File(t.path).readAsBytesSync(), utf16le('名前 one\ntwo\nthree 😀\n'));
      expect(r.single.stats!.before.crlf, 3);
      expect(r.single.stats!.after.lf, 3);
      final backup = File(r.single.backupPath!);
      expect(backup.readAsBytesSync(), utf16le('名前 one\r\ntwo\r\nthree 😀\r\n'));
      expect(backup.path, contains(p.join('meta', 'backups')));
    });

    test('UTF-8 BOM and Latin-1 files keep their bytes except the changed endings', () async {
      final bom = target('bom.txt', [0xEF, 0xBB, 0xBF, ...utf8.encode('ä\r\nb')]);
      final latin = target('latin.txt', [0x61, 0xE9, 0x0D, 0x0A, 0x62, 0xFF]);
      final r = await processTextFiles([bom, latin], lineEndingTransform(LineEnding.lf), apply: true, writer: writer);
      expect(r.map((x) => x.status), everyElement(TextFileStatus.changed));
      expect(File(bom.path).readAsBytesSync(), [0xEF, 0xBB, 0xBF, ...utf8.encode('ä\nb')]);
      expect(File(latin.path).readAsBytesSync(), [0x61, 0xE9, 0x0A, 0x62, 0xFF]);
      expect(r[1].detail, contains('Latin-1'));
    });

    test('dry run writes nothing; unchanged, binary, too large, odd UTF-16 and device files', () async {
      final same = target('same.txt', utf8.encode('a\nb\n'));
      final change = target('change.txt', utf8.encode('a\r\nb'));
      final bin = target('image.png', [0x89, 0x50, 0x4E, 0x47, 0, 0, 1, 2]);
      final big = target('big.txt', List.filled(2048, 65));
      final odd = target('odd.txt', [...utf16le('x\r\n'), 0x41]);
      final device = target('device.txt', utf8.encode('x\r\n'), inWorkspace: false);
      final targets = [same, change, bin, big, odd, device];
      final dry = await processTextFiles(targets, lineEndingTransform(LineEnding.lf), maxBytes: 1024);
      expect(dry.map((r) => r.status), [
        TextFileStatus.unchanged,
        TextFileStatus.willChange,
        TextFileStatus.binary,
        TextFileStatus.tooLarge,
        TextFileStatus.encodingUnsafe,
        TextFileStatus.willChange,
      ]);
      expect(File(change.path).readAsStringSync(), 'a\r\nb', reason: 'dry run writes nothing');
      final applied = await processTextFiles(
        targets,
        lineEndingTransform(LineEnding.lf),
        apply: true,
        writer: writer,
        maxBytes: 1024,
      );
      expect(applied[1].status, TextFileStatus.changed);
      expect(applied[5].status, TextFileStatus.exportOnly);
      expect(File(device.path).readAsStringSync(), 'x\r\n', reason: 'device copies are never rewritten');
      expect(countStatuses(applied)[TextFileStatus.changed], 1);
    });

    test('whitespace transform strips the BOM by switching to plain UTF-8', () async {
      final t = target('ws.txt', [0xEF, 0xBB, 0xBF, ...utf8.encode('a  \n\n\n\nb')]);
      final r = await processTextFiles(
        [t],
        whitespaceTransform(const WhitespaceOptions()),
        apply: true,
        writer: writer,
      );
      expect(r.single.status, TextFileStatus.changed);
      expect(File(t.path).readAsBytesSync(), utf8.encode('a\n\nb\n'));
      expect(r.single.stats!.bomRemoved, 1);
    });

    test('UTF-16 whitespace cleanup keeps the BOM; cancellation throws', () async {
      final t = target('u16.txt', utf16le('x \r\n'));
      final r = await processTextFiles(
        [t],
        whitespaceTransform(const WhitespaceOptions()),
        apply: true,
        writer: writer,
      );
      expect(File(t.path).readAsBytesSync(), utf16le('x\r\n'));
      expect(r.single.stats!.notes.single, contains('UTF-16'));
      await expectLater(
        processTextFiles([t], lineEndingTransform(LineEnding.lf), token: CancellationToken()..cancel()),
        throwsA(isA<OperationCancelled>()),
      );
    });
  });
}
