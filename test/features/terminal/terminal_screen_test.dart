import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:j3nsontop_multitool/core/commands/terminal_command.dart';
import 'package:j3nsontop_multitool/core/drafts/drafts.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/theme/effects.dart';
import 'package:j3nsontop_multitool/core/theme/j3_colors.dart';
import 'package:j3nsontop_multitool/core/theme/j3_theme.dart';
import 'package:j3nsontop_multitool/core/tools/tool_registry.dart';
import 'package:j3nsontop_multitool/features/terminal/presentation/terminal_screen.dart';
import 'package:j3nsontop_multitool/features/terminal/presentation/terminal_session.dart';

import '../../helpers/harness.dart';
import 'terminal_test_support.dart';

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => disposeEnv(env));

  Future<ProviderContainer> pumpTerminal(
    WidgetTester tester, {
    ToolRegistry? registry,
    AppPlatform platform = AppPlatform.linux,
    FakeFileAccess? files,
    void Function(ProviderContainer c)? before,
  }) async {
    final container = ProviderContainer(
      overrides: env.overrides(registry: registry ?? buildTerminalRegistry(), platform: platform, fileAccess: files),
    );
    addTearDown(container.dispose);
    before?.call(container);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: themed(const TerminalScreen(), effects: staticEffects),
      ),
    );
    await tester.pump();
    return container;
  }

  TextEditingController input(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!;
  bool inputFocused(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {bool ctrl = false}) async {
    if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('shows the banner, runs a command with Enter and keeps focus', (tester) async {
    await pumpTerminal(tester);
    expect(find.textContaining('This is not a system shell.'), findsOneWidget);
    expect(find.textContaining('Type `help`'), findsOneWidget);

    await type(tester, 'echo hello terminal');
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.text('hello terminal'), findsOneWidget);
    expect(find.text(r'j3nsontop@~$ echo hello terminal'), findsOneWidget);
    expect(input(tester).text, isEmpty);
    expect(inputFocused(tester), isTrue);
  });

  testWidgets('errors keep their ERROR: prefix; unknown commands suggest', (tester) async {
    await pumpTerminal(tester);
    await type(tester, 'hepl');
    await press(tester, LogicalKeyboardKey.enter);
    final error = find.text('ERROR: Unknown command "hepl".');
    expect(error, findsOneWidget);
    expect(tester.widget<Text>(error).style!.color, J3Colors.error);
    expect(find.text('Did you mean: help?'), findsOneWidget);
  });

  testWidgets('Up/Down walk the command history and restore the draft', (tester) async {
    await pumpTerminal(tester);
    for (final c in ['echo one', 'echo two']) {
      await type(tester, c);
      await press(tester, LogicalKeyboardKey.enter);
    }
    await type(tester, 'draft');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(input(tester).text, 'echo two');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(input(tester).text, 'echo one');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(input(tester).text, 'echo two');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(input(tester).text, 'draft');
  });

  testWidgets('Tab completes; several candidates become a clickable row', (tester) async {
    await pumpTerminal(tester);
    await type(tester, 'ec');
    await press(tester, LogicalKeyboardKey.tab);
    expect(input(tester).text, 'echo ');
    expect(inputFocused(tester), isTrue);

    await type(tester, 'theme accent ');
    await press(tester, LogicalKeyboardKey.tab);
    expect(find.text('4 matches:'), findsOneWidget);
    await tester.tap(find.byTooltip('Use "crimson"'));
    await tester.pump();
    expect(input(tester).text, 'theme accent crimson ');
    expect(find.text('4 matches:'), findsNothing);

    await type(tester, 'sk');
    await press(tester, LogicalKeyboardKey.tab);
    expect(find.text('No completions for "sk".'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('No completions for "sk".'), findsNothing);
    expect(input(tester).text, 'sk');
  });

  testWidgets('Esc clears the input and Ctrl+L clears the screen', (tester) async {
    await pumpTerminal(tester);
    await type(tester, 'something');
    await press(tester, LogicalKeyboardKey.escape);
    expect(input(tester).text, isEmpty);

    expect(find.textContaining('This is not a system shell.'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.keyL, ctrl: true);
    expect(find.textContaining('This is not a system shell.'), findsNothing);
    expect(find.textContaining('0 lines'), findsOneWidget);
  });

  testWidgets('Ctrl+C cancels a running command (spinner row + Cancel)', (tester) async {
    final slow = SlowCommand();
    final container = await pumpTerminal(tester, registry: buildTerminalRegistry(extra: [slow]));
    await type(tester, 'slow');
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.textContaining('running: slow'), findsOneWidget);
    expect(find.text('RUNNING'), findsOneWidget);

    await press(tester, LogicalKeyboardKey.keyC, ctrl: true);
    expect(find.text('^C'), findsOneWidget);
    expect(find.textContaining('running: slow'), findsNothing);
    expect(container.read(terminalSessionProvider).isRunning, isFalse);
    slow.gate.complete(CommandResult.text('late'));
    await tester.pump();
    expect(find.text('late'), findsNothing);

    // Touch path: the Cancel button on the spinner row.
    slow.gate = Completer<CommandResult>();
    await type(tester, 'slow');
    await press(tester, LogicalKeyboardKey.enter);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump();
    expect(find.text('^C'), findsNWidgets(2));
    slow.gate.complete(CommandResult.text('late'));

    // Idle Ctrl+C abandons the current line.
    await type(tester, 'half');
    await press(tester, LogicalKeyboardKey.keyC, ctrl: true);
    expect(find.text(r'j3nsontop@~$ half^C'), findsOneWidget);
    expect(input(tester).text, isEmpty);
  });

  testWidgets('a command that throws is shown as an error, screen stays usable', (tester) async {
    await pumpTerminal(tester, registry: buildTerminalRegistry(extra: const [BoomCommand()]));
    await type(tester, 'boom');
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.text('ERROR: "boom" failed: Bad state: kaput'), findsOneWidget);
    await type(tester, 'echo ok');
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.text('ok'), findsOneWidget);
  });

  testWidgets('Copy all copies the transcript', (tester) async {
    final files = FakeFileAccess();
    await pumpTerminal(tester, files: files);
    await tester.tap(find.byTooltip('Copy all output'));
    await tester.pump();
    expect(files.copied.single, contains(kTerminalBannerTitle));
  });

  testWidgets('runs a command handed over by the palette (pending draft)', (tester) async {
    const key = kTerminalPendingCommandKey;
    final container = await pumpTerminal(
      tester,
      before: (c) => c.read(draftValueProvider(key).notifier).set('echo from palette'),
    );
    await tester.pump();
    expect(find.text('from palette'), findsOneWidget);
    expect(container.read(draftValueProvider(key)), isNull);

    container.read(draftValueProvider(key).notifier).set('echo again');
    await tester.pump();
    await tester.pump();
    expect(find.text('again'), findsOneWidget);
  });

  testWidgets('open navigates through the router', (tester) async {
    final container = ProviderContainer(overrides: env.overrides(registry: buildTerminalRegistry()));
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (c, s) => const Scaffold(body: TerminalScreen()),
        ),
        GoRoute(
          path: '/settings',
          builder: (c, s) => const Scaffold(body: Text('SETTINGS PAGE')),
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
    await tester.pump();
    await type(tester, 'open settings');
    await press(tester, LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('SETTINGS PAGE'), findsOneWidget);
    expect(container.read(terminalSessionProvider).plainText, contains('Opening settings  ->  /settings'));
  });

  testWidgets('small screens get suggestion chips, a Tab key and a Run button', (tester) async {
    setSurface(tester, const Size(320, 568));
    await pumpTerminal(tester);
    for (final c in kTerminalQuickCommands) {
      expect(find.byTooltip('Insert "$c"'), findsOneWidget, reason: c);
    }
    await tester.tap(find.byTooltip('Insert "help"'));
    await tester.pump();
    expect(input(tester).text, 'help ');
    await tester.tap(find.byTooltip('Run command (Enter)'));
    await tester.pump();
    await tester.pump();
    // Auto-scrolled to the newest output: the last help line is on screen.
    expect(find.textContaining('Keys: Tab complete'), findsOneWidget);

    await type(tester, 'ec');
    await tester.tap(find.byTooltip('Complete the current word (Tab)'));
    await tester.pump();
    expect(input(tester).text, 'echo ');

    await tester.tap(find.byTooltip('Previous command (Up)'));
    await tester.pump();
    expect(input(tester).text, 'help');
    expect(tester.getSize(find.byTooltip('Insert "ws"')).height, greaterThanOrEqualTo(44));
  });

  testWidgets('touch platforms show the chips on wide screens too', (tester) async {
    await pumpTerminal(tester, platform: AppPlatform.android);
    expect(find.byTooltip('Complete the current word (Tab)'), findsOneWidget);
    expect(inputFocused(tester), isFalse, reason: 'no automatic soft keyboard on mobile');
  });

  testWidgets('desktop hides the chips and focuses the prompt', (tester) async {
    await pumpTerminal(tester);
    await tester.pump();
    expect(find.byTooltip('Complete the current word (Tab)'), findsNothing);
    expect(inputFocused(tester), isTrue);
  });

  testWidgets('scrolling up stops following new output; the jump button returns', (tester) async {
    final c = await pumpTerminal(tester, platform: AppPlatform.android);
    final session = c.read(terminalSessionProvider.notifier);
    session.writeLines([for (var i = 0; i < 200; i++) TermLine('line $i')]);
    await tester.pumpAndSettle();
    expect(find.text('line 199'), findsOneWidget);
    expect(find.byTooltip('Scroll to latest output'), findsNothing);

    await tester.drag(find.text('line 199'), const Offset(0, 4000));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Scroll to latest output'), findsOneWidget);
    session.writeLines([const TermLine('new line')]);
    await tester.pumpAndSettle();
    expect(find.text('new line'), findsNothing, reason: 'the view stays where the user scrolled');

    await tester.tap(find.byTooltip('Scroll to latest output'));
    await tester.pumpAndSettle();
    expect(find.text('new line'), findsOneWidget);
    expect(find.byTooltip('Scroll to latest output'), findsNothing);
  });

  testWidgets('the session survives the screen being rebuilt', (tester) async {
    final container = await pumpTerminal(tester);
    await type(tester, 'echo persisted');
    await press(tester, LogicalKeyboardKey.enter);
    await type(tester, 'unfinished draft');
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: themed(const SizedBox())));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: themed(const TerminalScreen(), effects: staticEffects),
      ),
    );
    await tester.pump();
    expect(find.text('persisted'), findsOneWidget);
    expect(input(tester).text, 'unfinished draft');
  });
}
