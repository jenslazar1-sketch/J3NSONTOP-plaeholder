import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/storage/user_data.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_parser.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/presets.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/compare/compare_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/compare/compare_page.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/document_io.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/presets/presets_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/presets/presets_page.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';
import 'lab_test_utils.dart';

Finder _dialogField(String label) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(TextField, label));

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  group('Compare page', () {
    testWidgets('renders', (tester) async {
      await pumpLabPage(tester, env, const ComparePage());
      expect(find.text('Config Compare'), findsOneWidget);
      expect(find.text('A // BEFORE'), findsOneWidget);
      expect(find.text('Compare'), findsOneWidget);
    });

    testWidgets('JSON vs YAML: semantic + text diff, views, export', (tester) async {
      final files = FakeFileAccess();
      final c = await pumpLabPage(tester, env, const ComparePage(), files: files);
      await tester.enterText(find.widgetWithText(TextField, 'Document A'), '{"a": 1, "b": {"c": true}, "gone": 0}');
      await tester.enterText(find.widgetWithText(TextField, 'Document B'), 'a: 2\nb:\n  c: true\nd: new\n');
      await tester.pump();
      expect(find.text('Auto (JSON)'), findsOneWidget);
      expect(find.text('Auto (YAML)'), findsOneWidget);
      await tester.tap(find.text('Compare'));
      await waitFor(tester, () => c.read(compareProvider).result != null);
      expect(find.text('+1 ADDED'), findsOneWidget);
      expect(find.text('-1 REMOVED'), findsOneWidget);
      expect(find.text('~1 CHANGED'), findsOneWidget);
      expect(find.text(r'$.a'), findsOneWidget);
      expect(find.text(r'$.d'), findsOneWidget);
      expect(find.text(r'$.gone'), findsOneWidget);

      await tester.tap(find.text('Side by side'));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Export report'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export...'));
      await waitFor(tester, () => files.savedBytes.isNotEmpty);
      final report = utf8.decode(files.savedBytes.single.$2);
      expect(files.savedBytes.single.$1, 'config-comparison.txt');
      expect(report, contains('Semantic differences: 1 added, 1 removed, 1 changed, 0 type changes'));
      expect(report, contains(r'+ $.d added: "new"'));
    });

    testWidgets('same data with different formatting', (tester) async {
      final c = await pumpLabPage(tester, env, const ComparePage());
      await tester.enterText(find.widgetWithText(TextField, 'Document A'), '{"x": 1, "y": [1, 2]}');
      await tester.enterText(find.widgetWithText(TextField, 'Document B'), '{\n  "y": [1, 2],\n  "x": 1\n}');
      await tester.tap(find.text('Compare'));
      await waitFor(tester, () => c.read(compareProvider).result != null);
      expect(find.text('SAME DATA'), findsOneWidget);
      expect(find.textContaining('only formatting, order or comments differ'), findsOneWidget);
    });

    testWidgets('malformed side shows its parse error', (tester) async {
      final c = await pumpLabPage(tester, env, const ComparePage());
      await tester.tap(find.text('JSON').first);
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, 'Document A'), '{"a": }');
      await tester.enterText(find.widgetWithText(TextField, 'Document B'), '{"a": 1}');
      await tester.tap(find.text('Compare'));
      await waitFor(tester, () => c.read(compareProvider).result != null);
      expect(find.text('A: PARSE ERROR'), findsOneWidget);
      expect(find.text('Line 1, column 7'), findsOneWidget);
    });

    testWidgets('small screen with large text', (tester) async {
      final c = await pumpLabPage(tester, env, const ComparePage(), size: const Size(320, 568), textScale: 2.0);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.widgetWithText(TextField, 'Document A'), '[Display]\nwidth = 1920\n');
      await tester.enterText(find.widgetWithText(TextField, 'Document B'), '[Display]\nwidth = 2560\n');
      // Unfocus so the focused editor does not scroll itself back into view.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.ensureVisible(find.text('Compare'));
      await tester.pump();
      await tester.tap(find.text('Compare'));
      await waitFor(tester, () => c.read(compareProvider).result != null);
      expect(tester.takeException(), isNull);
    });
  });

  group('Presets page', () {
    testWidgets('lists the labelled built-in examples', (tester) async {
      await pumpLabPage(tester, env, const PresetsPage());
      expect(find.text('Config Presets'), findsOneWidget);
      expect(find.text('Potato mode'), findsOneWidget);
      expect(find.text('Ultra'), findsOneWidget);
      expect(find.text('EXAMPLE · BUILT-IN'), findsNWidgets(2));
    });

    testWidgets('preview and apply a built-in to pasted JSON', (tester) async {
      final c = await pumpLabPage(tester, env, const PresetsPage());
      await tester.enterText(
        find.widgetWithText(TextField, 'Target JSON document'),
        '{\n    "quality": "high",\n    "vsync": true\n}\n',
      );
      await tester.pump();
      await tester.tap(find.text('Preview changes'));
      await waitFor(tester, () => c.read(presetsProvider).preview != null);
      expect(find.textContaining('"Potato mode":'), findsOneWidget);
      expect(find.textContaining(r'~ $.quality: "high" -> "low"'), findsOneWidget);
      await tester.tap(find.text('Apply to editor only'));
      await tester.pump();
      final applied = decodeJsonStrict(draftText(c, kPresetsTargetKey).text)! as Map<String, Object?>;
      expect(applied['quality'], 'low');
      expect(applied['vsync'], false);
      expect(draftText(c, kPresetsTargetKey).text, startsWith('{\n    "quality": "low",'));
    });

    testWidgets('create a preset (persisted, versioned) and import presets', (tester) async {
      final files = FakeFileAccess();
      files.queuedPicks.add([
        writePickedFile(env, 'shared.json', '{"v": 1, "items": [{"id": "x", "name": "Shared", "patch": {"a": 1}}]}'),
      ]);
      final c = await pumpLabPage(tester, env, const PresetsPage(), files: files);
      await tester.tap(find.text('New preset'));
      await tester.pumpAndSettle();
      await tester.enterText(_dialogField('Name'), 'Wide FOV');
      await tester.enterText(_dialogField('Merge patch (JSON)'), '{"fov": 110}');
      await tester.pump();
      expect(find.textContaining('Valid patch: 1 change(s)'), findsOneWidget);
      await tester.tap(find.text('Save preset'));
      await tester.pumpAndSettle();
      expect(find.text('Wide FOV'), findsOneWidget);
      final stored = c.read(featureDataProvider)[kPresetsKey]! as Map<String, Object?>;
      expect(stored['v'], 1);
      expect((stored['items']! as List).single, containsPair('name', 'Wide FOV'));

      await tester.tap(find.text('Import'));
      await waitFor(tester, () => c.read(allPresetsProvider).length == 4);
      expect(find.text('Shared'), findsOneWidget);
    });

    testWidgets('invalid target JSON shows an error', (tester) async {
      await pumpLabPage(tester, env, const PresetsPage());
      await tester.enterText(find.widgetWithText(TextField, 'Target JSON document'), '{"quality": }');
      await tester.pump();
      await tester.tap(find.text('Preview changes'));
      await tester.pump();
      await tester.pump();
      expect(find.text('TARGET IS NOT VALID JSON'), findsOneWidget);
    });

    testWidgets('sample graphics.json: apply and save with backup', (tester) async {
      final c = await pumpLabPage(tester, env, const PresetsPage());
      final ws = await createWorkspace(tester, c, {
        'game/config/graphics.json': '{\n  "quality": "high",\n  "postfx": {"bloom": true}\n}\n',
      });
      await tester.tap(find.text('Open sample graphics.json'));
      await waitFor(tester, () => draftText(c, kPresetsTargetKey).text.isNotEmpty);
      await tester.tap(find.text('Ultra'));
      await tester.pump();
      await tester.tap(find.text('Preview changes'));
      await waitFor(tester, () => c.read(presetsProvider).preview != null);
      await tester.tap(find.text('Apply & save with backup'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save with backup'));
      await waitFor(tester, () => c.read(docSourceProvider(kPresetsDocKey)).lastSave != null);
      final saved = decodeJsonStrict(File(p.join(ws.rootPath, 'game/config/graphics.json')).readAsStringSync());
      expect((saved! as Map)['quality'], 'ultra');
      final backup = c.read(docSourceProvider(kPresetsDocKey)).lastSave!.backupPath!;
      expect(File(backup).readAsStringSync(), contains('"high"'));
    });

    testWidgets('small screen with large text', (tester) async {
      final c = await pumpLabPage(tester, env, const PresetsPage(), size: const Size(320, 568), textScale: 2.0);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.widgetWithText(TextField, 'Target JSON document'), '{"quality": "high"}');
      await tester.pump();
      await tester.ensureVisible(find.text('Preview changes'));
      await tester.pump();
      await tester.tap(find.text('Preview changes'));
      await waitFor(tester, () => c.read(presetsProvider).preview != null);
      expect(tester.takeException(), isNull);
    });
  });
}
