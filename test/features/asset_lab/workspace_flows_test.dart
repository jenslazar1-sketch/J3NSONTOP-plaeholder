import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:j3nsontop_multitool/core/widgets/widgets.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/asset_lab/presentation/image_studio/image_studio_page.dart';
import 'package:j3nsontop_multitool/features/asset_lab/presentation/sprite_sheet/sprite_sheet_page.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';
import 'asset_test_helpers.dart';

/// Waits (with real IO progressing) until the workspace browser has listed
/// its folder.
Future<void> realIo(WidgetTester tester) async {
  await tester.pump();
  await pumpUntil(tester, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
  await tester.pumpAndSettle();
}

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  Future<Workspace> addWorkspace(WidgetTester tester, Type page) async {
    final container = ProviderScope.containerOf(tester.element(find.byType(page)));
    Workspace? ws;
    await tester.runAsync(() async {
      ws = await container.read(workspacesProvider.notifier).addAppOwned('Game');
    });
    await tester.pump();
    return ws!;
  }

  assetWidgetTest('sprite frames are written into a workspace folder without overwriting', (tester) async {
    final files = FakeFileAccess()..queuedPicks.add([writePick(env, 'hero_walk.png', pngOf(spriteSheet(2, 1, 8)))]);
    await pumpAssetPage(tester, env, const SpriteSheetPage(), files: files);
    final ws = await addWorkspace(tester, SpriteSheetPage);
    final existing = File(p.join(ws.rootPath, 'hero_walk_000.png'))..writeAsStringSync('keep');

    // With a workspace the picker asks where to open from.
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Open sheet').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('From device'));
    await settle(tester);
    expect(find.textContaining('2 x 1 grid'), findsOneWidget);

    await tapVisible(tester, find.widgetWithText(NeonButton, 'Save to workspace folder'));
    await realIo(tester);
    await tester.tap(find.widgetWithText(NeonButton, 'Use this folder'));
    await settle(tester);
    expect(existing.readAsStringSync(), 'keep');
    final written = File(p.join(ws.rootPath, 'hero_walk_000 (2).png'));
    expect(written.existsSync(), isTrue);
    expect(img.decodePng(written.readAsBytesSync())!.width, 8);
    expect(File(p.join(ws.rootPath, 'hero_walk_001.png')).existsSync(), isTrue);
  });

  assetWidgetTest('studio saves next to a workspace original under a new name', (tester) async {
    await pumpAssetPage(tester, env, const ImageStudioPage());
    final ws = await addWorkspace(tester, ImageStudioPage);
    final original = File(p.join(ws.rootPath, 'textures', 'logo.png'))..createSync(recursive: true);
    final originalBytes = pngOf(gradientImage(40, 20));
    original.writeAsBytesSync(originalBytes);

    await tapVisible(tester, find.widgetWithText(NeonButton, 'Open image').first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('From workspace'));
    await realIo(tester);
    await tester.tap(find.text('textures'));
    await realIo(tester);
    await tester.tap(find.text('logo.png'));
    await settle(tester);
    expect(find.text('workspace: textures/logo.png'), findsOneWidget);

    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'Flip'));
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Flip horizontal'));
    await settle(tester);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Save next to original'));
    await settle(tester);
    expect(find.textContaining('Saved as textures/logo_edited.png (original untouched)'), findsOneWidget);
    expect(original.readAsBytesSync(), originalBytes);
    final edited = img.decodePng(File(p.join(ws.rootPath, 'textures', 'logo_edited.png')).readAsBytesSync())!;
    expect(edited.width, 40);
  });
}
