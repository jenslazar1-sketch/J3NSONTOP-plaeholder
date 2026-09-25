import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/document_io.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/json_studio/json_studio_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/json_studio/json_studio_page.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';
import 'lab_test_utils.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  testWidgets('renders with an empty editor', (tester) async {
    await pumpLabPage(tester, env, const JsonStudioPage());
    expect(find.text('JSON Studio'), findsOneWidget);
    expect(find.text('EMPTY'), findsOneWidget);
    expect(find.text('Validate'), findsOneWidget);
    expect(find.text('No document'), findsOneWidget);
  });

  testWidgets('valid JSON: format, tree, undo', (tester) async {
    final c = await pumpLabPage(tester, env, const JsonStudioPage());
    await tester.enterText(find.byType(TextField).first, '{"player":{"name":"Kaya","hp":10},"tags":["a"]}');
    await tester.pump();
    expect(find.text('VALID'), findsOneWidget);
    expect(find.textContaining('2 objects, 1 arrays, 4 keys'), findsOneWidget);

    await tester.tap(find.text('Format'));
    await tester.pump();
    final input = draftText(c, kJsonInputKey);
    expect(input.text, '{\n  "player": {\n    "name": "Kaya",\n    "hp": 10\n  },\n  "tags": [\n    "a"\n  ]\n}');

    // Tree shows the top-level keys once the root is expanded.
    expect(find.text('player'), findsOneWidget);
    expect(find.text('tags'), findsOneWidget);
    await tester.tap(find.byTooltip('Expand player'));
    await tester.pump();
    expect(find.text('name'), findsOneWidget);

    await tester.tap(find.text('Undo format'));
    await tester.pump();
    expect(input.text, '{"player":{"name":"Kaya","hp":10},"tags":["a"]}');
  });

  testWidgets('minify, sort keys and ensure ASCII', (tester) async {
    final c = await pumpLabPage(tester, env, const JsonStudioPage());
    await tester.enterText(find.byType(TextField).first, '{ "b": 1, "a": {"d": "é", "c": 2} }');
    await tester.pump();
    await tester.tap(find.text('Ensure ASCII'));
    await tester.pump();
    await tester.tap(find.text('Minify'));
    await tester.pump();
    final input = draftText(c, kJsonInputKey);
    const backslash = r'\';
    expect(input.text, contains('"d":"${backslash}u00e9"'));
    await tester.tap(find.text('4 spaces'));
    await tester.pump();
    await tester.tap(find.text('Sort keys'));
    await tester.pump();
    expect(input.text.indexOf('"a"'), lessThan(input.text.indexOf('"b"')));
    expect(input.text, contains('\n    "a": {\n        "c": 2,'));
  });

  testWidgets('malformed input shows location, snippet and jumps to the error', (tester) async {
    final c = await pumpLabPage(tester, env, const JsonStudioPage());
    await tester.enterText(find.byType(TextField).first, '{\n  "a": 1,\n}');
    await tester.pump();
    expect(find.text('INVALID'), findsOneWidget);
    expect(find.text('Line 2, column 9'), findsOneWidget);
    expect(find.textContaining('Trailing comma'), findsWidgets);
    expect(find.text('Fix the JSON error first'), findsOneWidget);
    // Format is disabled for invalid JSON.
    await tester.tap(find.text('Format'));
    await tester.pump();
    final input = draftText(c, kJsonInputKey);
    expect(input.text, '{\n  "a": 1,\n}');

    await tester.tap(find.text('Jump to error'));
    await tester.pump();
    await tester.pump();
    expect(input.selection.baseOffset, input.text.indexOf(','));
  });

  testWidgets('tree edits rewrite the text; search reveals nodes', (tester) async {
    final c = await pumpLabPage(tester, env, const JsonStudioPage());
    await tester.enterText(find.byType(TextField).first, '{"alpha": 1, "beta": {"max hp": [3, 4]}}');
    await tester.pump();

    // Delete "alpha" through the node menu.
    await tester.tap(find.byTooltip(r'Actions for $.alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete property').last);
    await tester.pumpAndSettle();
    final input = draftText(c, kJsonInputKey);
    expect(input.text, '{\n  "beta": {\n    "max hp": [\n      3,\n      4\n    ]\n  }\n}');

    // Rename "beta" -> "gamma".
    await tester.tap(find.byTooltip(r'Actions for $.beta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename key…').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'gamma');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(input.text, contains('"gamma"'));

    // Search for 4 and show it in the tree.
    await tester.tap(find.text('Search').first);
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Find in keys and values'), '4');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(find.text(r'$.gamma["max hp"][1]'), findsOneWidget);
    await tester.tap(find.byTooltip('Show in tree'));
    await tester.pump();
    await tester.pump();
    expect(c.read(jsonStudioProvider).selectedPointer, '/gamma/max hp/1');
    expect(find.text('[1]'), findsOneWidget);
  });

  testWidgets('duplicate keys are listed as warnings', (tester) async {
    await pumpLabPage(tester, env, const JsonStudioPage());
    await tester.enterText(find.byType(TextField).first, '{"a": 1, "a": 2}');
    await tester.pump();
    expect(find.text('VALID'), findsOneWidget);
    expect(find.textContaining('Duplicate key "a"'), findsOneWidget);
  });

  testWidgets('opens a picked file and saves via Save as (export)', (tester) async {
    final files = FakeFileAccess();
    files.queuedPicks.add([writePickedFile(env, 'graphics.json', '{"quality": "high"}')]);
    final c = await pumpLabPage(tester, env, const JsonStudioPage(), files: files);
    await tester.tap(find.text('Open'));
    await waitFor(tester, () => draftText(c, kJsonInputKey).text.isNotEmpty);
    expect(draftText(c, kJsonInputKey).text, '{"quality": "high"}');
    expect(find.text('graphics.json'), findsOneWidget);
    expect(find.text('IMPORTED COPY'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '{"quality": "low"}');
    await tester.pump();
    expect(find.text('MODIFIED'), findsOneWidget);
    await tester.tap(find.text('Save…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export...'));
    await waitFor(tester, () => files.savedBytes.isNotEmpty);
    await tester.pump();
    expect(files.savedBytes.single.$1, 'graphics.json');
    expect(String.fromCharCodes(files.savedBytes.single.$2), '{"quality": "low"}');
    expect(find.textContaining('SAVED'), findsWidgets);
  });

  testWidgets('workspace files are replaced with a backup', (tester) async {
    final c = await pumpLabPage(tester, env, const JsonStudioPage());
    final ws = await createWorkspace(tester, c, {'game/config/graphics.json': '{"quality": "high"}\n'});
    final path = p.join(ws.rootPath, 'game', 'config', 'graphics.json');
    // Simulate opening the workspace file (the picker flow is covered elsewhere).
    draftText(c, kJsonInputKey).text = '{"quality": "high"}\n';
    c
        .read(docSourceProvider(kJsonDocKey).notifier)
        .set(
          DocSource(
            path: path,
            displayName: 'game/config/graphics.json',
            fromWorkspace: true,
            savedText: '{"quality": "high"}\n',
          ),
        );
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, '{"quality": "ultra"}\n');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Replace game/config/graphics.json?'), findsOneWidget);
    await tester.tap(find.text('Save with backup'));
    await waitFor(tester, () => c.read(docSourceProvider(kJsonDocKey)).lastSave != null);
    expect(File(path).readAsStringSync(), '{"quality": "ultra"}\n');
    final receipt = c.read(docSourceProvider(kJsonDocKey)).lastSave!;
    expect(receipt.backupPath, isNotNull);
    expect(File(receipt.backupPath!).readAsStringSync(), '{"quality": "high"}\n');
    expect(p.isWithin(c.read(workspacesProvider.notifier).metaDir(ws), receipt.backupPath!), isTrue);
    expect(find.textContaining('backup: backups/'), findsOneWidget);
  });

  testWidgets('non-UTF-8 files are read as Latin-1 with a warning banner', (tester) async {
    final files = FakeFileAccess();
    final picked = writePickedFile(env, 'legacy.json', '');
    File(picked.path).writeAsBytesSync([0x7B, 0x22, 0x6E, 0x22, 0x3A, 0x22, 0x63, 0x61, 0x66, 0xE9, 0x22, 0x7D]);
    files.queuedPicks.add([picked]);
    final c = await pumpLabPage(tester, env, const JsonStudioPage(), files: files);
    await tester.tap(find.text('Open'));
    await waitFor(tester, () => draftText(c, kJsonInputKey).text.isNotEmpty);
    expect(draftText(c, kJsonInputKey).text, '{"n":"caf${String.fromCharCode(0xE9)}"}');
    final source = c.read(docSourceProvider(kJsonDocKey));
    expect(source.malformed, isTrue);
    expect(source.encodingLabel, 'Latin-1');
    expect(find.text('Latin-1'), findsOneWidget);
    expect(find.text('WARN // Read as Latin-1'), findsOneWidget);
  });

  testWidgets('small screen with large text does not overflow', (tester) async {
    await pumpLabPage(tester, env, const JsonStudioPage(), size: const Size(320, 568), textScale: 2.0);
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField).first, '{"a": [1, 2,]}');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('INVALID'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '{"a": {"b": [1, 2, {"c": "long value here"}]}}');
    await tester.pump();
    await tester.ensureVisible(find.text('Tree'));
    await tester.pump();
    await tester.tap(find.text('Tree'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('a'), findsOneWidget);
    await tester.ensureVisible(find.text('Stats'));
    await tester.pump();
    await tester.tap(find.text('Stats'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Document shape'), findsOneWidget);
  });
}
