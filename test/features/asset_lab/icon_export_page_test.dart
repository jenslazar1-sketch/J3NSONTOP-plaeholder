import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/archive/safe_zip.dart';
import 'package:j3nsontop_multitool/core/widgets/widgets.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/icon_export.dart';
import 'package:j3nsontop_multitool/features/asset_lab/presentation/icon_export/icon_export_page.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';
import 'asset_test_helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  Future<FakeFileAccess> open(
    WidgetTester tester, {
    int w = 128,
    int h = 128,
    Size size = const Size(1280, 1000),
    double textScale = 1,
  }) async {
    final files = FakeFileAccess()..queuedPicks.add([writePick(env, 'art.png', pngOf(gradientImage(w, h)))]);
    await pumpAssetPage(tester, env, const IconExportPage(), files: files, size: size, textScale: textScale);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Open artwork'));
    await settle(tester);
    return files;
  }

  Future<void> generate(WidgetTester tester) async {
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Generate & verify'));
    await settle(tester);
  }

  assetWidgetTest('renders the empty state', (tester) async {
    await pumpAssetPage(tester, env, const IconExportPage());
    expect(find.text('App Icon Export'), findsWidgets);
    expect(find.textContaining('Open artwork and press'), findsOneWidget);
  });

  assetWidgetTest('generates, verifies every file and exports a ZIP', (tester) async {
    final files = await open(tester);
    expect(find.textContaining('Square 128 x 128 artwork'), findsOneWidget);
    await generate(tester);
    expect(find.text('OK // All outputs verified'), findsOneWidget);
    expect(find.textContaining('30 of 30 files passed'), findsOneWidget);
    expect(find.text('PASS'), findsNWidgets(30));
    expect(find.byIcon(Icons.check), findsNWidgets(30));
    expect(find.text('FAIL'), findsNothing);
    expect(find.text(windowsIconPath), findsOneWidget);
    expect(find.textContaining('ICO with 16, 24, 32, 48, 64, 128, 256 px'), findsWidgets);

    // SafeZip writes a real staging file: let real IO progress between frames.
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Export all (ZIP)'));
    await pumpUntil(tester, () => find.text('Export...').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export...'));
    await pumpUntil(tester, () => files.savedBytes.isNotEmpty);
    await tester.pumpAndSettle();
    final (name, bytes) = files.savedBytes.single;
    expect(name, 'app_icons.zip');
    final zip = p.join(env.dir.path, 'icons.zip');
    File(zip).writeAsBytesSync(bytes);
    final inspection = SafeZip.inspect(zip);
    expect(inspection.isSafe, isTrue);
    expect(inspection.files.map((e) => e.path), contains('$iosIconSetDir/Contents.json'));
    expect(inspection.files, hasLength(30));
  });

  assetWidgetTest('non-square artwork can be centre-cropped', (tester) async {
    await open(tester, w: 200, h: 100);
    expect(find.textContaining('not square'), findsOneWidget);
    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Centre-crop'));
    await generate(tester);
    expect(find.textContaining('centre-cropped to 100x100'), findsOneWidget);
    expect(find.text('OK // All outputs verified'), findsOneWidget);
  });

  assetWidgetTest('platform selection matters and none disables generation', (tester) async {
    await open(tester);
    await tapVisible(tester, find.text('iOS'));
    await tapVisible(tester, find.text('Android + Google Play'));
    await generate(tester);
    expect(find.textContaining('1 of 1 files passed'), findsOneWidget);
    await tapVisible(tester, find.text('Windows'));
    expect(find.textContaining('Select at least one platform'), findsOneWidget);
    final button = tester.widget<NeonButton>(find.widgetWithText(NeonButton, 'Generate & verify'));
    expect(button.onPressed, isNull);
    expect(find.textContaining('Settings changed since generating'), findsOneWidget);
  });

  assetWidgetTest('malformed artwork shows an error', (tester) async {
    final files = FakeFileAccess()..queuedPicks.add([writePick(env, 'icon.png', utf8.encode('<svg>nope</svg>'))]);
    await pumpAssetPage(tester, env, const IconExportPage(), files: files);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Open artwork'));
    await settle(tester);
    expect(find.text('ERROR // Cannot open artwork'), findsOneWidget);
    expect(find.widgetWithText(NeonButton, 'Generate & verify'), findsOneWidget);
    expect(tester.widget<NeonButton>(find.widgetWithText(NeonButton, 'Generate & verify')).onPressed, isNull);
  });

  assetWidgetTest('no overflow at 320x568 with 2x text', (tester) async {
    await open(tester, w: 160, h: 90, size: const Size(320, 568), textScale: 2);
    await generate(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('OK // All outputs verified'), findsOneWidget);
  });
}
