import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/drafts/drafts.dart';
import 'package:j3nsontop_multitool/core/widgets/widgets.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/file_tools/domain/text_files.dart';
import 'package:j3nsontop_multitool/features/file_tools/domain/whitespace.dart';
import 'package:j3nsontop_multitool/features/file_tools/presentation/line_endings/line_endings_page.dart';
import 'package:j3nsontop_multitool/features/file_tools/presentation/shared.dart';
import 'package:j3nsontop_multitool/features/file_tools/presentation/text_batch.dart';
import 'package:j3nsontop_multitool/features/file_tools/presentation/whitespace/whitespace_page.dart';
import 'package:path/path.dart' as p;

import 'ft_harness.dart';

Uint8List utf16le(String s) => Uint8List.fromList([
  0xFF,
  0xFE,
  for (final u in s.codeUnits) ...[u & 0xFF, u >> 8],
]);

void main() {
  late FtHarness h;
  setUp(() async => h = await FtHarness.create());
  tearDown(() async => h.dispose());

  void set(String key, Object value) => h.container.read(draftValueProvider(key).notifier).set(value);

  group('Line Endings', () {
    testWidgets('text mode analyses mixed endings and previews the conversion', (tester) async {
      await pumpPage(tester, h, const LineEndingsPage());
      expect(find.text('Paste text to analyse'), findsWidgets);
      h.container.read(draftTextProvider('files.line_endings/text')).text = 'a\r\nb\nc\r\n';
      await tester.pump();
      expect(find.text('Detected: Mixed'), findsOneWidget);
      expect(find.text('MIXED line endings'), findsOneWidget);
      expect(find.text('2 to change'), findsOneWidget);
      final preview = tester.widget<SelectableText>(find.byKey(const Key('le.preview')));
      expect(preview.data, 'a«LF»\nb«LF»\nc«LF»\n');
      await tapVisible(tester, find.text('CRLF (Windows)'));
      expect(tester.widget<SelectableText>(find.byKey(const Key('le.preview'))).data, 'a«CRLF»\nb«CRLF»\nc«CRLF»\n');
      expect(find.text('1 to change'), findsOneWidget);
    });

    testWidgets('files mode analyses, then converts in place with backups (UTF-16 kept)', (tester) async {
      final u16 = h.write('win/readme.txt', utf16le('one\r\ntwo\r\n'));
      final u8 = h.write('win/config.ini', utf8.encode('[a]\r\nx=1\r\n'));
      final bin = h.write('win/icon.bin', [0, 1, 2, 3, 0, 5]);
      set('files.line_endings/mode', TextOrFiles.files);
      await pumpPage(tester, h, const LineEndingsPage());
      h.container.read(lineEndingBatchProvider.notifier).addFiles([
        for (final f in [u16, u8, bin])
          FileItem(path: f.path, label: 'win/${p.basename(f.path)}', inWorkspace: true, size: f.lengthSync()),
      ]);
      await tester.pump();
      expect(tester.widget<NeonButton>(find.byKey(const Key('files.line_endings.apply'))).onPressed, isNull);

      await tapVisible(tester, find.byKey(const Key('files.line_endings.analyse')));
      await waitFor(tester, () => h.container.read(lineEndingBatchProvider).results != null);
      expect(find.widgetWithText(StatusBadge, 'WILL CHANGE'), findsNWidgets(2));
      expect(find.widgetWithText(StatusBadge, 'SKIPPED: BINARY'), findsOneWidget);
      expect(File(u8.path).readAsStringSync(), '[a]\r\nx=1\r\n', reason: 'analysis writes nothing');

      await tapVisible(tester, find.byKey(const Key('files.line_endings.apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Convert files').last);
      await tester.pump();
      await waitFor(tester, () {
        final st = h.container.read(lineEndingBatchProvider);
        return !st.running && st.applied;
      });
      expect(File(u16.path).readAsBytesSync(), utf16le('one\ntwo\n'));
      expect(File(u8.path).readAsStringSync(), '[a]\nx=1\n');
      expect(find.widgetWithText(StatusBadge, 'CHANGED'), findsNWidgets(2));
      expect(find.textContaining('Originals were backed up'), findsOneWidget);
      final backups = Directory(p.join(h.container.read(workspacesProvider.notifier).metaDir(h.ws!), 'backups'));
      expect(backups.listSync(recursive: true).whereType<File>(), hasLength(2));
    });

    testWidgets('device copies are exported, never rewritten', (tester) async {
      final dev = File(p.join(h.env.dir.path, 'dev.txt'))..writeAsStringSync('x\r\ny\r\n');
      set('files.line_endings/mode', TextOrFiles.files);
      await pumpPage(tester, h, const LineEndingsPage());
      h.container.read(lineEndingBatchProvider.notifier).addFiles([
        FileItem(path: dev.path, label: 'dev.txt', inWorkspace: false, size: dev.lengthSync()),
      ]);
      await tester.pump();
      await tapVisible(tester, find.byKey(const Key('files.line_endings.analyse')));
      await waitFor(tester, () => h.container.read(lineEndingBatchProvider).results != null);
      await tapVisible(tester, find.byTooltip('Export converted copy of dev.txt'));
      await waitFor(tester, () => find.text('Export...').evaluate().isNotEmpty);
      await chooseExport(tester);
      final (name, bytes) = h.files.savedBytes.single;
      expect(name, 'dev-lf.txt');
      expect(utf8.decode(bytes), 'x\ny\n');
      expect(dev.readAsStringSync(), 'x\r\ny\r\n');
    });

    testWidgets('folder batch with a malformed glob reports the error', (tester) async {
      set('files.line_endings/mode', TextOrFiles.files);
      set('files.line_endings/batchSource', BatchSource.folder);
      await pumpPage(tester, h, const LineEndingsPage());
      await tester.enterText(find.widgetWithText(TextField, 'Include (globs, comma separated)'), '*.{txt');
      await tester.pump();
      expect(find.textContaining('Unclosed "{"'), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('files.line_endings.analyse')));
      await waitFor(tester, () => !h.container.read(lineEndingBatchProvider).running);
      expect(h.container.read(lineEndingBatchProvider).error, contains('Unclosed'));
    });

    testWidgets('fits 320x568 at 2x text', (tester) async {
      h.container.read(draftTextProvider('files.line_endings/text')).text = 'a\r\nb\n';
      await pumpPage(tester, h, const LineEndingsPage(), size: const Size(320, 568), textScale: 2);
      expect(tester.takeException(), isNull);
      set('files.line_endings/mode', TextOrFiles.files);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('Whitespace Cleanup', () {
    testWidgets('live preview shows the diff with visible whitespace', (tester) async {
      await pumpPage(tester, h, const WhitespacePage());
      expect(find.text('Paste text to preview the cleanup'), findsOneWidget);
      h.container.read(draftTextProvider('files.whitespace/text')).text = 'keep\nvalue = 1   \n\n\n\nend';
      await tester.pump();
      expect(find.text('Changes'), findsOneWidget);
      expect(find.textContaining('Trimmed trailing whitespace on 1 line(s)'), findsOneWidget);
      expect(find.textContaining('Removed 2 extra blank line(s)'), findsOneWidget);
      expect(find.textContaining('Added the final line break'), findsOneWidget);
      expect(find.textContaining('value = 1···'), findsOneWidget, reason: 'deleted line shows its trailing spaces');
      // Turning a rule off updates the preview immediately.
      await tapVisible(tester, find.text('Trim trailing whitespace'));
      expect(find.textContaining('Trimmed trailing whitespace'), findsNothing);
      // Replace the input with the cleaned text.
      await tapVisible(tester, find.byTooltip('Replace the input with the cleaned text'));
      expect(h.container.read(draftTextProvider('files.whitespace/text')).text, 'keep\nvalue = 1   \n\nend\n');
      expect(find.text('Already clean'), findsOneWidget);
    });

    testWidgets('files mode cleans workspace files in place', (tester) async {
      final f = h.write('notes/todo.md', [0xEF, 0xBB, 0xBF, ...utf8.encode('# Todo  \n\n\n\n- item\t\n')]);
      set('files.whitespace/mode', TextOrFiles.files);
      await pumpPage(tester, h, const WhitespacePage());
      h.container.read(whitespaceBatchProvider.notifier).addFiles([
        FileItem(path: f.path, label: 'notes/todo.md', inWorkspace: true, size: f.lengthSync()),
      ]);
      await tester.pump();
      await tapVisible(tester, find.byKey(const Key('files.whitespace.analyse')));
      await waitFor(tester, () => h.container.read(whitespaceBatchProvider).results != null);
      expect(find.widgetWithText(StatusBadge, 'WILL CHANGE'), findsOneWidget);
      expect(find.textContaining('Removed the UTF-8 byte order mark'), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('files.whitespace.apply')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clean files').last);
      await tester.pump();
      await waitFor(tester, () => h.container.read(whitespaceBatchProvider).applied);
      expect(f.readAsBytesSync(), utf8.encode('# Todo\n\n- item\n'));
      final results = h.container.read(whitespaceBatchProvider).results!;
      expect(results.single.status, TextFileStatus.changed);
      expect(results.single.backupPath, isNotNull);
    });

    testWidgets('invalid tab width is flagged inline and ignored', (tester) async {
      set('files.whitespace/options', const WhitespaceOptions(indentMode: IndentMode.tabsToSpaces));
      await pumpPage(tester, h, const WhitespacePage());
      await tester.enterText(find.widgetWithText(TextField, 'Tab width'), '99');
      await tester.pump();
      expect(find.text('<= 16'), findsOneWidget);
      h.container.read(draftTextProvider('files.whitespace/text')).text = '\tx';
      await tester.pump();
      expect(find.textContaining('Expanded 1 tab(s)'), findsOneWidget);
      expect(find.textContaining('→x'), findsOneWidget);
    });

    testWidgets('fits 320x568 at 2x text', (tester) async {
      h.container.read(draftTextProvider('files.whitespace/text')).text = 'a  \n\n\n\tb';
      await pumpPage(tester, h, const WhitespacePage(), size: const Size(320, 568), textScale: 2);
      expect(tester.takeException(), isNull);
      set('files.whitespace/mode', TextOrFiles.files);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
