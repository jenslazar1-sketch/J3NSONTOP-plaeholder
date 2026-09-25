import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:j3nsontop_multitool/core/drafts/drafts.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/settings/settings_controller.dart';
import 'package:j3nsontop_multitool/core/theme/effects.dart';
import 'package:j3nsontop_multitool/core/theme/j3_theme.dart';
import 'package:j3nsontop_multitool/features/palette/command_palette.dart';
import 'package:j3nsontop_multitool/features/shell/destinations.dart';
import 'package:j3nsontop_multitool/features/terminal/presentation/terminal_screen.dart';
import 'package:j3nsontop_multitool/features/terminal/presentation/terminal_session.dart';

import '../../helpers/harness.dart';
import '../terminal/terminal_test_support.dart';

const _pages = ['/workspaces', '/mods', '/config', '/assets', '/files', '/dev', '/activity', '/settings', '/about'];

class _Harness {
  _Harness(this.container, this.router);
  final ProviderContainer container;
  final GoRouter router;

  String get location => router.routerDelegate.currentConfiguration.uri.toString();
}

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => disposeEnv(env));

  Future<_Harness> pumpPalette(
    WidgetTester tester, {
    AppPlatform platform = AppPlatform.linux,
    String initialQuery = '',
  }) async {
    final container = ProviderContainer(
      overrides: env.overrides(registry: buildTerminalRegistry(), platform: platform),
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (c, s) => Scaffold(
            body: Center(
              child: Builder(
                builder: (ctx) => TextButton(
                  onPressed: () => showCommandPalette(ctx, initialQuery: initialQuery),
                  child: const Text('open palette'),
                ),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/tool/:id',
          builder: (c, s) => Scaffold(
            body: s.pathParameters['id'] == kTerminalToolId
                ? const TerminalScreen()
                : Text('TOOL ${s.pathParameters['id']}'),
          ),
        ),
        for (final p in _pages)
          GoRoute(
            path: p,
            builder: (c, s) => Scaffold(body: Text('PAGE $p')),
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
    await tester.tap(find.text('open palette'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(CommandPalette), findsOneWidget);
    return _Harness(container, router);
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.descendant(of: find.byType(CommandPalette), matching: find.byType(TextField)), text);
    await tester.pump();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
    await tester.pump();
  }

  String queryText(WidgetTester tester) => tester
      .widget<TextField>(find.descendant(of: find.byType(CommandPalette), matching: find.byType(TextField)))
      .controller!
      .text;

  test('the palette and the terminal share the hand-over key', () {
    expect(kPaletteTerminalRequestKey, kTerminalPendingCommandKey);
  });

  testWidgets('search by name, Enter opens the tool and closes the palette', (tester) async {
    final h = await pumpPalette(tester);
    await type(tester, 'base');
    expect(find.text('Base64'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.byType(CommandPalette), findsNothing);
    expect(h.location, '/tool/dev.base64');
    expect(find.text('TOOL dev.base64'), findsOneWidget);
  });

  testWidgets('search by keyword and by description', (tester) async {
    await pumpPalette(tester);
    await type(tester, 'checksum');
    expect(find.text('Hash Files'), findsOneWidget);
    expect(find.text('Base64'), findsNothing);
    await type(tester, 'decode');
    expect(find.text('Base64'), findsOneWidget);
    expect(find.text('Hash Files'), findsNothing);
    await type(tester, 'qqqqqq');
    expect(find.text('No match for "qqqqqq"'), findsOneWidget);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.byType(CommandPalette), findsOneWidget, reason: 'nothing to run');
  });

  testWidgets('matched substrings are highlighted in titles', (tester) async {
    await pumpPalette(tester);
    await type(tester, 'base');
    final title = tester.widget<Text>(find.text('Base64'));
    final spans = (title.textSpan! as TextSpan).children!.cast<TextSpan>();
    expect(spans.map((s) => s.text), ['Base', '64']);
    expect(spans.first.style!.decoration, TextDecoration.underline);
    expect(spans.first.style!.fontWeight, FontWeight.w700);
    expect(spans.last.style!.decoration, isNot(TextDecoration.underline));
  });

  testWidgets('arrow keys move the selection and Enter runs it', (tester) async {
    final h = await pumpPalette(tester);
    await press(tester, LogicalKeyboardKey.arrowUp);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.enter);
    expect(h.location, '/mods', reason: 'Home, Workspaces, [Mods]');
  });

  testWidgets('Esc closes without navigating', (tester) async {
    final h = await pumpPalette(tester);
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.byType(CommandPalette), findsNothing);
    expect(h.location, '/');
  });

  testWidgets('entries work on touch; actions update settings', (tester) async {
    final h = await pumpPalette(tester, platform: AppPlatform.android);
    await type(tester, 'settings');
    final row = find.ancestor(of: find.text('Settings'), matching: find.byType(InkWell)).first;
    expect(tester.getSize(row).height, greaterThanOrEqualTo(44));
    expect(tester.getSize(find.byTooltip('Close')).height, greaterThanOrEqualTo(44));
    await tester.tap(find.text('Settings'));
    await tester.pump();
    await tester.pump();
    expect(h.location, '/settings');

    h.router.go('/');
    await tester.pump();
    await tester.tap(find.text('open palette'));
    await tester.pump();
    await type(tester, 'low effects');
    await tester.tap(find.text('Toggle low-effects mode'));
    await tester.pump();
    expect(h.container.read(settingsProvider).lowEffects, isTrue);
  });

  testWidgets('shortcut keycaps on desktop; one row per destination', (tester) async {
    await pumpPalette(tester);
    expect(find.text('Ctrl+1'), findsOneWidget);
    expect(find.textContaining('Up/Down select'), findsOneWidget);
    await type(tester, 'terminal');
    expect(find.text('Terminal'), findsOneWidget, reason: 'tool hit and static shortcut are merged');
    expect(find.text('Ctrl+`'), findsOneWidget);
    expect(find.text('Run a terminal command'), findsOneWidget);
  });

  testWidgets('touch platforms show no keycaps and a touch footer', (tester) async {
    await pumpPalette(tester, platform: AppPlatform.ios);
    expect(find.text('Ctrl+1'), findsNothing);
    expect(find.textContaining('tap to open'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    expect(find.byType(CommandPalette), findsNothing);
  });

  group('> terminal command mode', () {
    testWidgets('lists registered commands (hidden ones excluded)', (tester) async {
      await pumpPalette(tester);
      await type(tester, '>');
      expect(find.text('Run in terminal: help'), findsOneWidget);
      expect(find.text('Run in terminal: about'), findsOneWidget);
      expect(find.text('Run in terminal: skull'), findsNothing);
      await type(tester, '> ha');
      expect(find.text('Run in terminal: hash'), findsOneWidget);
      expect(find.text('Run in terminal: help'), findsNothing);
      await type(tester, '> zzz');
      expect(find.text('No terminal command matches "zzz". Try "> help".'), findsOneWidget);
    });

    testWidgets('Enter opens the terminal and runs the typed line', (tester) async {
      final h = await pumpPalette(tester);
      await type(tester, '> help tools');
      expect(find.text('Run in terminal: help tools'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.enter);
      await tester.pump();
      expect(h.location, kTerminalRoute);
      expect(find.byType(TerminalScreen), findsOneWidget);
      final transcript = h.container.read(terminalSessionProvider).plainText;
      expect(transcript, contains(r'j3nsontop@~$ help tools'));
      expect(transcript, contains('usage: tools [section|query]'));
      expect(h.container.read(draftValueProvider(kPaletteTerminalRequestKey)), isNull);
    });

    testWidgets('Tab completes the selected command name', (tester) async {
      await pumpPalette(tester);
      await type(tester, '> he');
      await press(tester, LogicalKeyboardKey.tab);
      expect(queryText(tester), '> help ');
      expect(find.byType(CommandPalette), findsOneWidget);
    });

    testWidgets('the "Run a terminal command" entry switches to > mode', (tester) async {
      await pumpPalette(tester);
      await type(tester, 'terminal command');
      await tester.tap(find.text('Run a terminal command'));
      await tester.pump();
      expect(queryText(tester), '> ');
      expect(find.text('Run in terminal: help'), findsOneWidget);
    });

    testWidgets('initialQuery opens straight into command mode', (tester) async {
      await pumpPalette(tester, initialQuery: '> ec');
      expect(find.text('Run in terminal: echo'), findsOneWidget);
    });
  });
}
