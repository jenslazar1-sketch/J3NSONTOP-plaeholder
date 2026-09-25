import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/asset_lab/presentation/asset_lab_landing.dart';

import '../../helpers/harness.dart';
import 'asset_test_helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  assetWidgetTest('landing lists the five tools and the real format matrix', (tester) async {
    await pumpAssetPage(tester, env, const AssetLabLanding());
    for (final name in ['Image Studio', 'Sprite Sheet', 'Atlas Packer', 'Color Lab', 'App Icon Export']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(find.textContaining('WebP'), findsWidgets);
    expect(find.textContaining('JPEG (no alpha)'), findsOneWidget);
    expect(find.textContaining('ICO (<=256px)'), findsOneWidget);
    expect(find.bySemanticsLabel('Decorative pixel grid banner'), findsOneWidget);
  });

  assetWidgetTest('landing fits 320x568 at 2x text', (tester) async {
    await pumpAssetPage(tester, env, const AssetLabLanding(), size: const Size(320, 568), textScale: 2);
    expect(tester.takeException(), isNull);
    expect(find.text('Color Lab'), findsOneWidget);
  });
}
