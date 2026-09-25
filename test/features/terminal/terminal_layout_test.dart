import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/commands/terminal_command.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/features/terminal/presentation/terminal_screen.dart';

import '../../helpers/harness.dart';
import 'terminal_test_support.dart';

/// Layout checks with the real bundled fonts: no overflow on a 320x568
/// phone at 2x text size, in every state of the screen.
void main() {
  late TestEnv env;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadAppFonts();
  });
  setUp(() async => env = await TestEnv.create());
  tearDown(() => disposeEnv(env));

  for (final platform in [AppPlatform.android, AppPlatform.windows]) {
    for (final size in [const Size(320, 568), const Size(1280, 800)]) {
      testWidgets('no overflow at ${size.width.toInt()}x${size.height.toInt()} with 2x text on ${platform.name}', (
        tester,
      ) async {
        setSurface(tester, size);
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final slow = SlowCommand();
        final container = ProviderContainer(
          overrides: env.overrides(
            registry: buildTerminalRegistry(extra: [slow]),
            platform: platform,
          ),
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: themed(const TerminalScreen(), effects: staticEffects),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);

        Future<void> run(String line) async {
          await tester.enterText(find.byType(TextField), line);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pump();
          await tester.pump();
        }

        await run('help');
        await run('skull');
        await run('tools');
        await tester.enterText(find.byType(TextField), 't');
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(find.textContaining('matches:'), findsOneWidget);
        await run('slow');
        expect(find.textContaining('running: slow'), findsOneWidget);
        expect(tester.takeException(), isNull);
        slow.gate.complete(CommandResult.text('done'));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
