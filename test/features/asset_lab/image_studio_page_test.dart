import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:j3nsontop_multitool/core/widgets/widgets.dart';
import 'package:j3nsontop_multitool/features/asset_lab/presentation/image_studio/image_studio_page.dart';

import '../../helpers/harness.dart';
import 'asset_test_helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  Future<FakeFileAccess> openHero(
    WidgetTester tester, {
    Size size = const Size(1280, 1000),
    double textScale = 1,
  }) async {
    final files = FakeFileAccess()..queuedPicks.add([writePick(env, 'hero.png', pngOf(gradientImage(64, 32)))]);
    await pumpAssetPage(tester, env, const ImageStudioPage(), files: files, size: size, textScale: textScale);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Open image').first);
    await settle(tester);
    return files;
  }

  assetWidgetTest('renders the empty state', (tester) async {
    await pumpAssetPage(tester, env, const ImageStudioPage());
    expect(find.text('Image Studio'), findsWidgets);
    expect(find.text('Open an image to start'), findsOneWidget);
    expect(find.text('Operations'), findsNothing);
  });

  assetWidgetTest('open, add an operation, undo, and export the edited copy', (tester) async {
    final files = await openHero(tester);
    expect(find.text('hero.png'), findsWidgets);
    // Source dimensions in the metadata table and the result size row.
    expect(find.text('64 x 32 px'), findsNWidgets(2));
    expect(find.textContaining('PNG'), findsWidgets);
    expect(find.text('Result'), findsOneWidget);

    // Rotate 90 degrees: the result becomes 32 x 64.
    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Rotate'));
    await tapVisible(tester, find.widgetWithText(NeonButton, '90°'));
    await settle(tester);
    expect(find.text('Rotate 90°'), findsOneWidget);
    expect(find.text('32 x 64 px'), findsOneWidget);

    // Undo removes it again, redo restores it.
    await tapVisible(tester, find.byTooltip('Undo'));
    await settle(tester);
    expect(find.text('Rotate 90°'), findsNothing);
    await tapVisible(tester, find.byTooltip('Redo'));
    await settle(tester);
    expect(find.text('Rotate 90°'), findsOneWidget);

    await tapVisible(tester, find.widgetWithText(NeonButton, 'Save / export'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export...'));
    await tester.pumpAndSettle();
    expect(files.savedBytes, hasLength(1));
    final (name, bytes) = files.savedBytes.single;
    expect(name, 'hero_edited.png');
    final out = img.decodePng(Uint8List.fromList(bytes))!;
    expect((out.width, out.height), (32, 64));
    expect(out.numChannels, 4, reason: 'alpha preserved');
  });

  assetWidgetTest('JPEG export warns about flattening and reports the size', (tester) async {
    await openHero(tester);
    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'JPEG'));
    await settle(tester);
    expect(find.text('WARN // JPEG has no transparency'), findsOneWidget);
    expect(find.textContaining('hero_edited.jpg'), findsWidgets);
    expect(find.text('flattened onto #FFFFFF'), findsOneWidget);
  });

  assetWidgetTest('invalid crop numbers show a validation error and add nothing', (tester) async {
    await openHero(tester);
    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Crop'));
    await tester.enterText(find.widgetWithText(TextField, 'Width'), '100');
    await tester.pump();
    expect(find.textContaining('exceeds the image width 64'), findsOneWidget);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Add crop'));
    await settle(tester);
    expect(find.textContaining('Crop 100x32'), findsNothing);
    expect(find.text('No operations yet: the export equals the source.'), findsOneWidget);

    // A valid crop drawn with the preview editor works.
    await tester.enterText(find.widgetWithText(TextField, 'Width'), '20');
    await tester.pump();
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Draw on preview'));
    expect(find.textContaining('Selection: 20 x 32 at (0, 0)'), findsOneWidget);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Add crop'));
    await settle(tester);
    expect(find.text('Crop 20x32 at (0, 0)'), findsOneWidget);
    expect(find.text('20 x 32 px'), findsOneWidget);
  });

  assetWidgetTest('malformed image shows an error', (tester) async {
    final files = FakeFileAccess()..queuedPicks.add([writePick(env, 'broken.png', utf8.encode('this is not a png'))]);
    await pumpAssetPage(tester, env, const ImageStudioPage(), files: files);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Open image').first);
    await settle(tester);
    expect(find.text('ERROR // Cannot open image'), findsOneWidget);
    expect(find.textContaining('not an image format'), findsOneWidget);
    expect(find.text('Operations'), findsNothing);
  });

  assetWidgetTest('no overflow at 320x568 with 2x text', (tester) async {
    await openHero(tester, size: const Size(320, 568), textScale: 2);
    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Crop'));
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Draw on preview'));
    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'JPEG'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('Operations'), findsOneWidget);
  });
}
