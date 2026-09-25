import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:j3nsontop_multitool/core/widgets/widgets.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/atlas_packer.dart';
import 'package:j3nsontop_multitool/features/asset_lab/presentation/atlas_packer/atlas_packer_page.dart';

import '../../helpers/harness.dart';
import 'asset_test_helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  FakeFileAccess threeSprites() => FakeFileAccess()
    ..queuedPicks.add([
      writePick(env, 'coin.png', pngOf(gradientImage(16, 16))),
      writePick(env, 'gem.png', pngOf(gradientImage(24, 12))),
      writePick(env, 'key.tga', img.encodeTga(gradientImage(10, 20))),
    ]);

  Future<void> addAndPack(WidgetTester tester) async {
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Add images'));
    await settle(tester);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Pack atlas'));
    await settle(tester);
  }

  assetWidgetTest('renders the empty state', (tester) async {
    await pumpAssetPage(tester, env, const AtlasPackerPage());
    expect(find.text('Atlas Packer'), findsWidgets);
    expect(find.text('No sprites yet'), findsOneWidget);
    expect(find.textContaining('Rotation: off'), findsOneWidget);
  });

  assetWidgetTest('adds images, packs, validates and shows the JSON', (tester) async {
    await pumpAssetPage(tester, env, const AtlasPackerPage(), files: threeSprites());
    await addAndPack(tester);
    expect(find.text('Sprites (3)'), findsOneWidget);
    expect(find.text('OK // Validator passed'), findsOneWidget);
    expect(find.textContaining('3 frames, no overlaps'), findsOneWidget);
    expect(find.text('atlas.json'), findsOneWidget);
    final json = tester.widget<ResultPanel>(find.byType(ResultPanel)).text;
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    expect((decoded['meta'] as Map)['image'], 'atlas.png');
    expect((decoded['frames'] as Map).keys, ['coin', 'gem', 'key']);
    final (w, h, pad, ex, frames) = parseAtlasJson(json);
    expect(validateAtlas(width: w, height: h, padding: pad, extrude: ex, frames: frames).ok, isTrue);
  });

  assetWidgetTest('duplicate names are rejected and renaming validates', (tester) async {
    final files = threeSprites()..queuedPicks.add([writePick(env, 'coin.png', pngOf(gradientImage(4, 4)))]);
    await pumpAssetPage(tester, env, const AtlasPackerPage(), files: files);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Add images'));
    await settle(tester);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Add images'));
    await settle(tester);
    expect(find.text('Sprites (3)'), findsOneWidget);
    expect(find.textContaining('the name "coin" is already used'), findsOneWidget);

    await tapVisible(tester, find.byTooltip('Rename coin'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'gem');
    await tester.tap(find.widgetWithText(NeonButton, 'OK'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Another sprite is already called "gem"'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'gold coin');
    await tester.tap(find.widgetWithText(NeonButton, 'OK'));
    await tester.pumpAndSettle();
    expect(find.text('gold coin'), findsOneWidget);
  });

  assetWidgetTest('sprites that do not fit show a clear error', (tester) async {
    final files = FakeFileAccess()..queuedPicks.add([writePick(env, 'wall.png', pngOf(gradientImage(300, 40)))]);
    await pumpAssetPage(tester, env, const AtlasPackerPage(), files: files);
    await tapVisible(tester, find.widgetWithText(ChoiceChip, '256'));
    await addAndPack(tester);
    expect(find.text('ERROR // Atlas not created'), findsOneWidget);
    expect(find.textContaining('"wall" (300x40)'), findsOneWidget);
  });

  assetWidgetTest('hovering the preview names the sprite', (tester) async {
    await pumpAssetPage(tester, env, const AtlasPackerPage(), files: threeSprites());
    await addAndPack(tester);
    final viewport = find.bySemanticsLabel(RegExp('Packed atlas'));
    await tester.ensureVisible(viewport);
    await tester.pump();
    expect(find.text('Hover or tap a sprite to see its name and rectangle.'), findsOneWidget);
    // Tap every point on a coarse grid until one lands on a sprite.
    final box = tester.getRect(viewport);
    var found = false;
    for (var y = box.top + 4; y < box.bottom && !found; y += 6) {
      for (var x = box.left + 4; x < box.right && !found; x += 6) {
        await tester.tapAt(Offset(x, y));
        await tester.pump();
        found = find.textContaining(RegExp(r'^(coin|gem|key)  x=')).evaluate().isNotEmpty;
      }
    }
    expect(found, isTrue);
  });

  assetWidgetTest('no overflow at 320x568 with 2x text', (tester) async {
    await pumpAssetPage(
      tester,
      env,
      const AtlasPackerPage(),
      files: threeSprites(),
      size: const Size(320, 568),
      textScale: 2,
    );
    await addAndPack(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('OK // Validator passed'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  });
}
