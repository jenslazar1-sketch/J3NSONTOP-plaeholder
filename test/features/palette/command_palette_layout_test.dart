import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/theme/effects.dart';
import 'package:j3nsontop_multitool/core/theme/j3_theme.dart';
import 'package:j3nsontop_multitool/features/palette/command_palette.dart';

import '../../helpers/harness.dart';
import '../terminal/terminal_test_support.dart';

/// The palette with the real fonts on a 320x568 phone at 2x text size.
void main() {
  late TestEnv env;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadAppFonts();
  });
  setUp(() async => env = await TestEnv.create());
  tearDown(() => disposeEnv(env));

  for (final platform in [AppPlatform.android, AppPlatform.windows]) {
    testWidgets('no overflow at 320x568 with 2x text on ${platform.name}', (tester) async {
      setSurface(tester, const Size(320, 568));
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final container = ProviderContainer(
        overrides: env.overrides(registry: buildTerminalRegistry(), platform: platform),
      );
      addTearDown(container.dispose);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (c, s) => Scaffold(
              body: Builder(
                builder: (ctx) => TextButton(onPressed: () => showCommandPalette(ctx), child: const Text('open')),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(
            routerConfig: router,
            theme: J3Theme.build(staticEffects.accent),
            builder: (context, child) => J3Effects(config: staticEffects, child: child!),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);

      for (final q in ['base', '> ', '> help tools', 'zzzz']) {
        await tester.enterText(find.descendant(of: find.byType(CommandPalette), matching: find.byType(TextField)), q);
        await tester.pump();
        expect(tester.takeException(), isNull, reason: q);
      }
    });
  }
}
