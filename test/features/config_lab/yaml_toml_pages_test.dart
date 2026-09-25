import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_parser.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/toml/toml_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/toml/toml_page.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/yaml/yaml_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/yaml/yaml_page.dart';

import '../../helpers/harness.dart';
import 'lab_test_utils.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  group('YAML page', () {
    testWidgets('renders empty', (tester) async {
      await pumpLabPage(tester, env, const YamlPage());
      expect(find.text('YAML Editor'), findsOneWidget);
      expect(find.text('EMPTY'), findsOneWidget);
      expect(find.text('No document'), findsOneWidget);
    });

    testWidgets('valid YAML: tree and YAML -> JSON with itemised report', (tester) async {
      final c = await pumpLabPage(tester, env, const YamlPage());
      await tester.enterText(
        find.byType(TextField).first,
        '# controls\nmove: &keys [W, A, S, D]\nalt: *keys\njump: Space\n',
      );
      await tester.pump();
      expect(find.text('VALID'), findsOneWidget);
      expect(find.text('move'), findsOneWidget);
      expect(find.text('jump'), findsOneWidget);

      await tester.tap(find.text('Convert to JSON').first);
      await waitFor(tester, () => c.read(yamlLabProvider).toJson != null);
      final r = c.read(yamlLabProvider).toJson!;
      expect(decodeJsonStrict(r.output!), {
        'move': ['W', 'A', 'S', 'D'],
        'alt': ['W', 'A', 'S', 'D'],
        'jump': 'Space',
      });
      expect(find.text('CHANGES REPRESENTATION'), findsOneWidget);
      expect(find.textContaining('Comments dropped (1)'), findsOneWidget);
      expect(find.textContaining('Anchors/aliases expanded (1)'), findsOneWidget);
    });

    testWidgets('malformed YAML shows the location and jumps there', (tester) async {
      final c = await pumpLabPage(tester, env, const YamlPage());
      await tester.enterText(find.byType(TextField).first, 'a: 1\n  b: 2\n');
      await tester.pump();
      expect(find.text('INVALID'), findsOneWidget);
      expect(find.text('Line 2, column 4'), findsOneWidget);
      await tester.tap(find.text('Jump to error'));
      await tester.pump();
      await tester.pump();
      expect(draftText(c, kYamlInputKey).selection.baseOffset, 'a: 1\n  b'.length);
    });

    testWidgets('JSON -> YAML is verified and can replace the editor text', (tester) async {
      final c = await pumpLabPage(tester, env, const YamlPage());
      await tester.tap(find.text('From JSON'));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, 'JSON'), '{"answer": "no", "list": [1, 2]}');
      await tester.pump();
      await tester.tap(find.text('Convert to YAML'));
      await waitFor(tester, () => c.read(yamlLabProvider).fromJson != null);
      expect(find.text('ROUND TRIP VERIFIED'), findsOneWidget);
      expect(find.text('LOSSLESS'), findsOneWidget);
      expect(c.read(yamlLabProvider).fromJson!.output, 'answer: "no"\nlist:\n  - 1\n  - 2\n');
      await tester.tap(find.byTooltip('Use as editor text'));
      await tester.pump();
      expect(draftText(c, kYamlInputKey).text, 'answer: "no"\nlist:\n  - 1\n  - 2\n');
    });

    testWidgets('small screen with large text', (tester) async {
      await pumpLabPage(tester, env, const YamlPage(), size: const Size(320, 568), textScale: 2.0);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField).first, 'a: [1\n');
      await tester.pump();
      expect(tester.takeException(), isNull);
      for (final tab in ['Tree', 'To JSON', 'From JSON']) {
        await tester.ensureVisible(find.text(tab).first);
        await tester.pump();
        await tester.tap(find.text(tab).first);
        await tester.pump();
        expect(tester.takeException(), isNull, reason: tab);
      }
    });
  });

  group('TOML page', () {
    testWidgets('renders empty', (tester) async {
      await pumpLabPage(tester, env, const TomlPage());
      expect(find.text('TOML Editor'), findsOneWidget);
      expect(find.text('EMPTY'), findsOneWidget);
    });

    testWidgets('valid TOML: date chips and TOML -> JSON report', (tester) async {
      final c = await pumpLabPage(tester, env, const TomlPage());
      await tester.enterText(
        find.byType(TextField).first,
        'title = "x"\nwhen = 2026-09-01T10:00:00Z\n[player]\nhp = 3\n',
      );
      await tester.pump();
      expect(find.text('VALID'), findsOneWidget);
      expect(find.text('date'), findsOneWidget);
      expect(find.text('2026-09-01T10:00:00Z'), findsOneWidget);
      await tester.tap(find.text('Convert to JSON').first);
      await waitFor(tester, () => c.read(tomlLabProvider).toJson != null);
      expect(find.textContaining('Date-time converted to string (1)'), findsOneWidget);
      expect(decodeJsonStrict(c.read(tomlLabProvider).toJson!.output!), {
        'title': 'x',
        'when': '2026-09-01T10:00:00Z',
        'player': {'hp': 3},
      });
    });

    testWidgets('malformed TOML shows an error panel', (tester) async {
      await pumpLabPage(tester, env, const TomlPage());
      await tester.enterText(find.byType(TextField).first, 'a = [1,\nb = 2');
      await tester.pump();
      expect(find.text('INVALID'), findsOneWidget);
      expect(find.text('PARSE ERROR'), findsOneWidget);
      expect(find.text('Jump to error'), findsOneWidget);
    });

    testWidgets('JSON -> TOML: nulls fail until dropped', (tester) async {
      final c = await pumpLabPage(tester, env, const TomlPage());
      await tester.tap(find.text('From JSON'));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, 'JSON'), '{"a": 1, "b": null}');
      await tester.pump();
      await tester.tap(find.text('Convert to TOML'));
      await waitFor(tester, () => c.read(tomlLabProvider).fromJson != null);
      expect(find.text('FAILED'), findsOneWidget);
      expect(find.textContaining(r'$.b'), findsWidgets);
      await tester.tap(find.text('Drop null properties'));
      await tester.pump();
      await tester.tap(find.text('Convert to TOML'));
      await waitFor(tester, () => c.read(tomlLabProvider).fromJson!.ok);
      expect(find.text('CHANGES REPRESENTATION'), findsOneWidget);
      expect(c.read(tomlLabProvider).fromJson!.output, 'a = 1\n');
    });

    testWidgets('small screen with large text', (tester) async {
      await pumpLabPage(tester, env, const TomlPage(), size: const Size(320, 568), textScale: 2.0);
      await tester.enterText(find.byType(TextField).first, '[a]\nwhen = 2026-01-01\n');
      await tester.pump();
      for (final tab in ['Tree', 'To JSON', 'From JSON']) {
        await tester.ensureVisible(find.text(tab).first);
        await tester.pump();
        await tester.tap(find.text(tab).first);
        await tester.pump();
        expect(tester.takeException(), isNull, reason: tab);
      }
    });
  });
}
