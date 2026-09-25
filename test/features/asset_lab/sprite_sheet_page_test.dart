import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:j3nsontop_multitool/core/archive/safe_zip.dart';
import 'package:j3nsontop_multitool/core/theme/effects.dart';
import 'package:j3nsontop_multitool/core/theme/j3_colors.dart';
import 'package:j3nsontop_multitool/core/widgets/widgets.dart';
import 'package:j3nsontop_multitool/features/asset_lab/presentation/sprite_sheet/sprite_sheet_page.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';
import 'asset_test_helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  Future<FakeFileAccess> openSheet(
    WidgetTester tester, {
    Size size = const Size(1280, 1000),
    double textScale = 1,
    int filled = 8,
  }) async {
    final files = FakeFileAccess()
      ..queuedPicks.add([writePick(env, 'hero_walk.png', pngOf(spriteSheet(4, 2, 32, filled: filled)))]);
    await pumpAssetPage(tester, env, const SpriteSheetPage(), files: files, size: size, textScale: textScale);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Open sheet').first);
    await settle(tester);
    return files;
  }

  assetWidgetTest('renders the empty state', (tester) async {
    await pumpAssetPage(tester, env, const SpriteSheetPage());
    expect(find.text('Sprite Sheet'), findsWidgets);
    expect(find.text('Load a sprite sheet'), findsOneWidget);
  });

  assetWidgetTest('loads a sheet, steps frames without autoplay and exports a GIF', (tester) async {
    final files = await openSheet(tester);
    expect(find.textContaining('4 x 2 grid of 32 x 32 px, 8 of 8 cells used'), findsOneWidget);
    expect(find.text('Frame 1 / 8'), findsOneWidget);
    expect(find.textContaining('Reduced motion'), findsOneWidget, reason: 'static effects => no autoplay');
    expect(find.text('hero_walk_000.png, hero_walk_001.png ... hero_walk_007.png'), findsOneWidget);

    await tapVisible(tester, find.byTooltip('Next frame'));
    expect(find.text('Frame 2 / 8'), findsOneWidget);
    await tapVisible(tester, find.byTooltip('Previous frame'));
    await tapVisible(tester, find.byTooltip('Previous frame'));
    expect(find.text('Frame 8 / 8'), findsOneWidget, reason: 'wraps around');

    await tapVisible(tester, find.widgetWithText(NeonButton, 'Export animated GIF'));
    await settle(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export...'));
    await tester.pumpAndSettle();
    final (name, bytes) = files.savedBytes.single;
    expect(name, 'hero_walk.gif');
    final gif = img.decodeGif(Uint8List.fromList(bytes))!;
    expect(gif.numFrames, 8);
    expect(gif.width, 32);
  });

  assetWidgetTest('frames export as a ZIP with predictable names', (tester) async {
    final files = await openSheet(tester);
    // SafeZip writes a real staging file: let real IO progress between frames.
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Export frames (ZIP)'));
    await pumpUntil(tester, () => find.text('Export...').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export...'));
    await pumpUntil(tester, () => files.savedBytes.isNotEmpty);
    await tester.pumpAndSettle();
    final (name, bytes) = files.savedBytes.single;
    expect(name, 'hero_walk_frames.zip');
    final zipPath = p.join(env.dir.path, 'frames.zip');
    File(zipPath).writeAsBytesSync(bytes);
    final entries = SafeZip.inspect(zipPath).files.map((e) => e.path).toList();
    expect(entries, [for (var i = 0; i < 8; i++) 'hero_walk_00$i.png']);
  });

  assetWidgetTest('grid errors are shown and trailing empty cells can be trimmed', (tester) async {
    await openSheet(tester, filled: 6);
    await tester.enterText(find.widgetWithText(TextField, 'Columns (auto)'), '5');
    await tester.pump();
    expect(find.text('ERROR // Grid does not fit'), findsOneWidget);
    expect(find.textContaining('exceed the width by 32 px'), findsWidgets);
    await tester.enterText(find.widgetWithText(TextField, 'Columns (auto)'), '');
    await tester.pump();
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Trim empty trailing cells'));
    await settle(tester);
    expect(find.textContaining('6 of 8 cells used'), findsOneWidget);
    expect(find.text('Frame 1 / 6'), findsOneWidget);
  });

  assetWidgetTest('opening another sheet suggests its own base name', (tester) async {
    final files = await openSheet(tester);
    files.queuedPicks.add([writePick(env, 'tiles.png', pngOf(spriteSheet(2, 2, 16)))]);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Open another'));
    await settle(tester);
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Base name')).controller!.text, 'tiles');
    expect(find.text('tiles_000.png, tiles_001.png ... tiles_003.png'), findsOneWidget);
  });

  assetWidgetTest('malformed sheet shows an error', (tester) async {
    final files = FakeFileAccess()..queuedPicks.add([writePick(env, 'bad.png', utf8.encode('garbage'))]);
    await pumpAssetPage(tester, env, const SpriteSheetPage(), files: files);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Open sheet').first);
    await settle(tester);
    expect(find.text('ERROR // Cannot open sheet'), findsOneWidget);
  });

  assetWidgetTest('explicit play advances frames and pause stops them (reduced motion)', (tester) async {
    final files = FakeFileAccess()..queuedPicks.add([writePick(env, 's.png', pngOf(spriteSheet(4, 1, 8)))]);
    await pumpAssetPage(tester, env, const SpriteSheetPage(), files: files);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Open sheet').first);
    await settle(tester);
    expect(find.text('Frame 1 / 4'), findsOneWidget, reason: 'no autoplay with reduced motion');
    await tapVisible(tester, find.byTooltip('Play'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Frame 1 / 4'), findsNothing, reason: '12 fps advances frames');
    await tapVisible(tester, find.byTooltip('Pause'));
    final shown = find.textContaining(RegExp(r'^Frame \d / 4$'));
    final before = tester.widget<Text>(shown.first).data;
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<Text>(shown.first).data, before);
  });

  assetWidgetTest('autoplays when motion is allowed', (tester) async {
    const motion = EffectsConfig(
      reduceMotion: false,
      intensity: 0,
      scanlines: false,
      particles: false,
      glow: false,
      accent: AccentPreset.neon,
      sound: false,
      volume: 0,
    );
    final files = FakeFileAccess()..queuedPicks.add([writePick(env, 's.png', pngOf(spriteSheet(4, 1, 8)))]);
    await pumpAssetPage(tester, env, const SpriteSheetPage(), files: files, effects: motion);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Open sheet').first);
    await settle(tester);
    expect(find.byTooltip('Pause'), findsOneWidget, reason: 'playing without a tap');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Frame 1 / 4'), findsNothing);
    expect(find.byTooltip('Pause'), findsOneWidget);
    await tapVisible(tester, find.byTooltip('Pause'));
  });

  assetWidgetTest('no overflow at 320x568 with 2x text', (tester) async {
    await openSheet(tester, size: const Size(320, 568), textScale: 2);
    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Columns x rows'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Frame 1 / 8'), findsOneWidget);
  });
}
