import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_parser.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/document_io.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/save_editor/save_editor_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/save_editor/save_editor_page.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';
import 'fixtures.dart';
import 'lab_test_utils.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  Future<void> openSample(WidgetTester tester) async {
    await tester.tap(find.text('Open sample save'));
    await tester.pump();
  }

  testWidgets('renders the support statement and empty state', (tester) async {
    await pumpLabPage(tester, env, const SaveEditorPage());
    expect(find.text('Save Data Editor'), findsOneWidget);
    expect(find.text(kSupportStatement), findsOneWidget);
    expect(find.text('No save loaded'), findsOneWidget);
    expect(find.text('EMPTY'), findsOneWidget);
    expect(find.text('Open sample save'), findsNothing);
  });

  testWidgets('sample save: auto schema, form edits, validation, issues, save with backup', (tester) async {
    final c = await pumpLabPage(tester, env, const SaveEditorPage());
    final ws = await createWorkspace(tester, c, {
      'game/saves/slot1.json': validSave,
      'game/saves/save.schema.json': saveSchema,
    });
    await tester.pump();
    await openSample(tester);
    await waitFor(tester, () {
      final s = c.read(saveEditorProvider);
      return s.hasData && s.schemaOk && !s.validating;
    });
    expect(find.text('Schema: save.schema.json'), findsOneWidget);
    expect(find.text('VALID SAVE'), findsOneWidget);
    expect(find.text('Player *'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'name *'), findsOneWidget);

    // Stepper on an integer field.
    await tester.tap(find.byTooltip('Increase level *'));
    await tester.pump();
    expect((decodeJsonStrict(draftText(c, kSaveRawKey).text)! as Map)['player'], containsPair('level', 8));

    // Out of range value -> schema violation shown on the field and in Issues.
    await tester.enterText(find.widgetWithText(TextField, 'level *'), '100');
    await tester.pump();
    await waitFor(tester, () => c.read(saveEditorProvider).violations.isNotEmpty);
    expect(find.text('1 ISSUE'), findsOneWidget);
    expect(find.text('must be <= 99 (is 100)'), findsOneWidget);
    await tester.tap(find.text('Issues (1)'));
    await tester.pump();
    expect(find.text('/player/level  '), findsNothing);
    expect(find.textContaining('/player/level'), findsWidgets);
    await tester.tap(find.byTooltip('Show /player/level in the raw JSON'));
    await tester.pump();
    await tester.pump();
    expect(find.text('RAW JSON'), findsOneWidget);
    final raw = draftText(c, kSaveRawKey);
    expect(raw.text.substring(raw.selection.baseOffset).startsWith('100'), isTrue);

    // Save anyway with backup.
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Save with 1 schema issue(s)?'), findsOneWidget);
    await tester.tap(find.text('Save anyway'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save with backup'));
    await waitFor(tester, () => c.read(docSourceProvider(kSaveDocKey)).lastSave != null);
    final path = p.join(ws.rootPath, 'game', 'saves', 'slot1.json');
    expect((decodeJsonStrict(File(path).readAsStringSync())! as Map)['player'], containsPair('level', 100));
    final backup = c.read(docSourceProvider(kSaveDocKey)).lastSave!.backupPath!;
    expect(File(backup).readAsStringSync(), validSave);
  });

  testWidgets('enum dropdown and array add/remove', (tester) async {
    final c = await pumpLabPage(tester, env, const SaveEditorPage());
    await createWorkspace(tester, c, {'game/saves/slot1.json': validSave, 'game/saves/save.schema.json': saveSchema});
    await openSample(tester);
    await waitFor(tester, () => c.read(saveEditorProvider).schemaOk && !c.read(saveEditorProvider).validating);

    await tester.tap(find.text('rogue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('mage').last);
    await tester.pumpAndSettle();
    expect((decodeJsonStrict(draftText(c, kSaveRawKey).text)! as Map)['player'], containsPair('class', 'mage'));

    await tester.tap(find.text('Add item'));
    await tester.pump();
    final inv = (decodeJsonStrict(draftText(c, kSaveRawKey).text)! as Map)['inventory']! as List;
    expect(inv, hasLength(3));
    expect(inv.last, {'id': '', 'count': 1});
    await waitFor(tester, () => c.read(saveEditorProvider).violations.isNotEmpty);
    expect(c.read(saveEditorProvider).violations.single.pointer, '/inventory/2/id');

    await tester.tap(find.byTooltip('Move item 3 up'));
    await tester.pump();
    final moved = (decodeJsonStrict(draftText(c, kSaveRawKey).text)! as Map)['inventory']! as List;
    expect(moved[1], {'id': '', 'count': 1});
    await tester.tap(find.byTooltip('Remove item 2'));
    await tester.pump();
    await waitFor(
      tester,
      () => c.read(saveEditorProvider).violations.isEmpty && !c.read(saveEditorProvider).validating,
    );
    expect(find.text('VALID SAVE'), findsOneWidget);
  });

  testWidgets('malformed raw JSON locks the form and shows the error', (tester) async {
    final files = FakeFileAccess();
    files.queuedPicks.add([writePickedFile(env, 'slot2.json', validSave)]);
    files.queuedPicks.add([writePickedFile(env, 'save.schema.json', saveSchema)]);
    final c = await pumpLabPage(tester, env, const SaveEditorPage(), files: files);
    await tester.tap(find.text('Open'));
    await waitFor(tester, () => c.read(saveEditorProvider).hasData);
    expect(find.text('NO SCHEMA'), findsOneWidget);
    expect(find.text('Choose a schema'), findsOneWidget);
    await tester.tap(find.text('Open schema').first);
    await waitFor(tester, () => c.read(saveEditorProvider).schemaOk && !c.read(saveEditorProvider).validating);
    expect(find.text('VALID SAVE'), findsOneWidget);

    await tester.tap(find.text('Raw JSON'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Save file JSON'), '{"version": 2,');
    await tester.pump();
    await tester.pump();
    expect(find.text('INVALID JSON'), findsOneWidget);
    expect(find.text('PARSE ERROR'), findsOneWidget);
    await tester.tap(find.text('Form'));
    await tester.pump();
    expect(find.textContaining('read-only'), findsOneWidget);
  });

  testWidgets('small screen with large text', (tester) async {
    final c = await pumpLabPage(tester, env, const SaveEditorPage(), size: const Size(320, 568), textScale: 2.0);
    expect(tester.takeException(), isNull);
    await createWorkspace(tester, c, {'game/saves/slot1.json': validSave, 'game/saves/save.schema.json': saveSchema});
    await tester.ensureVisible(find.text('Open sample save'));
    await tester.pump();
    await openSample(tester);
    await waitFor(tester, () => c.read(saveEditorProvider).schemaOk && !c.read(saveEditorProvider).validating);
    expect(tester.takeException(), isNull);
    for (final tab in ['Raw JSON', 'Issues (0)', 'Form']) {
      await tester.ensureVisible(find.text(tab).first);
      await tester.pump();
      await tester.tap(find.text(tab).first);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: tab);
    }
  });
}
