import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/widgets/widgets.dart';
import 'package:j3nsontop_multitool/features/config_lab/domain/json_parser.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/csv/csv_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/csv/csv_page.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/ini/ini_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/presentation/ini/ini_page.dart';

import '../../helpers/harness.dart';
import 'lab_test_utils.dart';

const _ini =
    '; Neon Dungeon\r\n[Display]\r\nwidth = 1920\r\n# comment\r\nheight=1080\r\n\r\n[Audio]\r\nvolume: 0.8\r\n';

Finder _dialogField() => find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField));

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  group('INI page', () {
    testWidgets('renders empty', (tester) async {
      await pumpLabPage(tester, env, const IniPage());
      expect(find.text('INI Editor'), findsOneWidget);
      expect(find.text('EMPTY'), findsOneWidget);
      expect(find.text('No keys yet'), findsOneWidget);
    });

    testWidgets('table edit rewrites exactly one line', (tester) async {
      final c = await pumpLabPage(tester, env, const IniPage());
      await tester.enterText(find.byType(TextField).first, _ini);
      await tester.pump();
      expect(find.text('VALID'), findsOneWidget);
      expect(find.text('[Display] · 2'), findsOneWidget);

      await tester.tap(find.byTooltip('Edit value of width'));
      await tester.pumpAndSettle();
      await tester.enterText(_dialogField(), '2560');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(draftText(c, kIniInputKey).text, _ini.replaceFirst('width = 1920', 'width = 2560'));

      // Add a key to [Audio] (style and CRLF copied from nearby lines).
      await tester.tap(find.byTooltip('Add key to [Audio]'));
      await tester.pumpAndSettle();
      await tester.enterText(_dialogField(), 'muted');
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.enterText(_dialogField(), 'false');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(draftText(c, kIniInputKey).text, endsWith('volume: 0.8\r\nmuted: false\r\n'));

      // Delete height.
      await tester.tap(find.byTooltip('Delete height'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete line'));
      await tester.pumpAndSettle();
      expect(draftText(c, kIniInputKey).text, isNot(contains('height')));
      expect(draftText(c, kIniInputKey).text, contains('# comment\r\n\r\n[Audio]'));
    });

    testWidgets('invalid lines and duplicates are listed; conversion refused', (tester) async {
      final c = await pumpLabPage(tester, env, const IniPage());
      await tester.enterText(find.byType(TextField).first, '[A]\nx=1\nx=2\nnot a pair\n');
      await tester.pump();
      expect(find.text('INVALID'), findsOneWidget);
      expect(find.textContaining('Not a section, comment or key=value line'), findsOneWidget);
      expect(find.textContaining('Duplicate key "x"'), findsOneWidget);
      await tester.tap(find.text('Convert to JSON').first);
      await waitFor(tester, () => c.read(iniLabProvider).toJson != null);
      expect(find.text('FAILED'), findsOneWidget);
    });

    testWidgets('INI -> JSON with opt-in inference', (tester) async {
      final c = await pumpLabPage(tester, env, const IniPage());
      await tester.enterText(find.byType(TextField).first, _ini);
      await tester.pump();
      await tester.tap(find.text('To JSON'));
      await tester.pump();
      await tester.tap(find.text('Infer numbers and booleans (changes representation)'));
      await tester.pump();
      await tester.tap(find.text('Convert to JSON').last);
      await waitFor(tester, () => c.read(iniLabProvider).toJson != null);
      expect(decodeJsonStrict(c.read(iniLabProvider).toJson!.output!), {
        'Display': {'width': 1920, 'height': 1080},
        'Audio': {'volume': 0.8},
      });
      expect(find.textContaining('Types inferred (3)'), findsOneWidget);
      expect(find.textContaining('Comments dropped (2)'), findsOneWidget);
    });

    testWidgets('small screen with large text', (tester) async {
      await pumpLabPage(tester, env, const IniPage(), size: const Size(320, 568), textScale: 2.0);
      await tester.enterText(find.byType(TextField).first, '$_ini\nbroken line\n');
      await tester.pump();
      expect(tester.takeException(), isNull);
      for (final tab in ['Table', 'To JSON', 'From JSON']) {
        await tester.ensureVisible(find.text(tab).first);
        await tester.pump();
        await tester.tap(find.text(tab).first);
        await tester.pump();
        expect(tester.takeException(), isNull, reason: tab);
      }
    });
  });

  group('CSV page', () {
    const csv = 'id,name,price\n1,"Potion, small",5\n2,Sword\n3,Shield,12\n';

    testWidgets('renders empty', (tester) async {
      await pumpLabPage(tester, env, const CsvPage());
      expect(find.text('CSV / TSV Table'), findsOneWidget);
      expect(find.text('EMPTY'), findsOneWidget);
      expect(find.text('No table'), findsOneWidget);
    });

    testWidgets('preview table, filter, stats', (tester) async {
      await pumpLabPage(tester, env, const CsvPage());
      await tester.enterText(find.byType(TextField).first, csv);
      await tester.pump();
      expect(find.text('VALID'), findsOneWidget);
      expect(find.textContaining('4 records, 3 columns, comma-separated (detected), 1 ragged'), findsOneWidget);
      expect(find.text('Potion, small'), findsOneWidget);
      expect(find.text('(missing)'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Filter rows'), 'shield');
      await tester.pump();
      expect(find.text('1 of 3 rows match'), findsOneWidget);
      expect(find.text('Potion, small'), findsNothing);

      await tester.tap(find.text('Stats'));
      await tester.pump();
      expect(find.text('Rows with a different field count (1)'), findsOneWidget);
      expect(find.textContaining('Record 3 has 2 field(s)'), findsOneWidget);
    });

    testWidgets('convert to JSON and TSV with reports', (tester) async {
      final c = await pumpLabPage(tester, env, const CsvPage());
      await tester.enterText(find.byType(TextField).first, csv);
      await tester.pump();
      await tester.tap(find.text('Convert').first);
      await tester.pump();
      await tester.tap(find.widgetWithText(NeonButton, 'Convert').last);
      await waitFor(tester, () => c.read(csvLabProvider).converted != null);
      expect(decodeJsonStrict(c.read(csvLabProvider).converted!.output!), [
        {'id': '1', 'name': 'Potion, small', 'price': '5'},
        {'id': '2', 'name': 'Sword'},
        {'id': '3', 'name': 'Shield', 'price': '12'},
      ]);
      expect(find.textContaining('Missing cells (1)'), findsOneWidget);

      await tester.tap(find.text('TSV (tab)'));
      await tester.pump();
      await tester.tap(find.widgetWithText(NeonButton, 'Convert').last);
      await waitFor(tester, () => c.read(csvLabProvider).converted!.report.to == 'TSV');
      expect(
        c.read(csvLabProvider).converted!.output,
        'id\tname\tprice\n1\tPotion, small\t5\n2\tSword\n3\tShield\t12\n',
      );
      expect(find.text('LOSSLESS'), findsOneWidget);
    });

    testWidgets('malformed CSV shows the parse problem with its line', (tester) async {
      await pumpLabPage(tester, env, const CsvPage());
      await tester.enterText(find.byType(TextField).first, 'a,b\n1,"open\n');
      await tester.pump();
      expect(find.text('INVALID'), findsOneWidget);
      expect(find.textContaining('Quoted field is never closed'), findsWidgets);
      expect(find.textContaining('ERROR L2:3'), findsOneWidget);
    });

    testWidgets('JSON -> CSV with flattening', (tester) async {
      final c = await pumpLabPage(tester, env, const CsvPage());
      await tester.tap(find.text('From JSON'));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, 'JSON'), '[{"id": 1, "stats": {"hp": 3}}]');
      await tester.pump();
      await tester.tap(find.text('Convert to CSV'));
      await waitFor(tester, () => c.read(csvLabProvider).fromJson != null);
      expect(find.text('FAILED'), findsOneWidget);
      await tester.tap(find.text('Flatten nested values to dotted columns (changes representation)'));
      await tester.pump();
      await tester.tap(find.text('Convert to CSV'));
      await waitFor(tester, () => c.read(csvLabProvider).fromJson!.ok);
      expect(c.read(csvLabProvider).fromJson!.output, 'id,stats.hp\n1,3\n');
      await tester.tap(find.byTooltip('Use as editor text'));
      await tester.pump();
      expect(draftText(c, kCsvInputKey).text, 'id,stats.hp\n1,3\n');
    });

    testWidgets('small screen with large text', (tester) async {
      await pumpLabPage(tester, env, const CsvPage(), size: const Size(320, 568), textScale: 2.0);
      await tester.enterText(find.byType(TextField).first, csv);
      await tester.pump();
      expect(tester.takeException(), isNull);
      for (final tab in ['Table', 'Stats', 'Convert', 'From JSON']) {
        await tester.ensureVisible(find.text(tab).first);
        await tester.pump();
        await tester.tap(find.text(tab).first);
        await tester.pump();
        expect(tester.takeException(), isNull, reason: tab);
      }
    });
  });
}
