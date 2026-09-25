import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/theme/effects.dart';
import 'package:j3nsontop_multitool/core/theme/j3_colors.dart';
import 'package:j3nsontop_multitool/core/theme/j3_theme.dart';
import 'package:j3nsontop_multitool/core/tools/tool_definition.dart';
import 'package:j3nsontop_multitool/core/widgets/widgets.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/intro/skull_art.dart';
import 'package:path/path.dart' as p;

import '../helpers/harness.dart';

Widget _host(
  TestEnv env,
  Widget child, {
  EffectsConfig effects = staticEffects,
  List<FeatureModule> modules = const [],
}) {
  return ProviderScope(
    overrides: env.overrides(modules: modules),
    child: MaterialApp(
      theme: J3Theme.build(AccentPreset.neon),
      home: J3Effects(
        config: effects,
        child: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  void small(WidgetTester tester) {
    setSurface(tester, const Size(320, 568));
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  testWidgets('kit renders at 320px with 2x text without overflow', (tester) async {
    small(tester);
    final code = TextEditingController(text: 'line 1\nline 2');
    final number = TextEditingController(text: '2');
    addTearDown(code.dispose);
    addTearDown(number.dispose);
    await tester.pumpWidget(
      _host(
        env,
        SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              NeonPanel(
                kicker: 'input',
                title: 'A fairly long panel title that must wrap or ellipsize',
                icon: Icons.bolt,
                actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.copy), tooltip: 'Copy')],
                child: const Text('content'),
              ),
              const NeonPanel(emphasis: PanelEmphasis.danger, child: Text('danger')),
              const NeonPanel(emphasis: PanelEmphasis.success, child: Text('ok')),
              const NeonPanel(emphasis: PanelEmphasis.subtle, child: Text('subtle')),
              NeonButton(label: 'Primary action with a long label', icon: Icons.play_arrow, onPressed: () {}),
              NeonButton.secondary(label: 'Secondary', onPressed: () {}),
              NeonButton.ghost(label: 'Ghost', onPressed: () {}),
              NeonButton.danger(label: 'Danger', onPressed: () {}),
              const NeonButton(label: 'Disabled', onPressed: null),
              NeonButton(label: 'Busy', busy: true, onPressed: () {}),
              for (final k in StatusKind.values) StatusBadge(kind: k),
              for (final k in StatusKind.values)
                StatusBanner(kind: k, title: 'Title ${k.name}', message: 'Message', details: const ['a', 'b']),
              const ErrorPanel(title: 'Failed', error: 'boom', hint: 'try again'),
              const EmptyState(title: 'Nothing here', message: 'Add something'),
              const LoadingState(label: 'Hashing a very large file name.bin', progress: 0.4),
              const NeonProgressBar(),
              CodeField(controller: code, label: 'Code'),
              const KeyValueTable(rows: [('Key', 'Value'), ('Long key name', 'Long value that wraps across lines')]),
              OptionSwitch(label: 'Switch', description: 'Explains', value: true, onChanged: (_) {}),
              ChoiceRow<int>(
                label: 'Choice',
                options: const [1, 2, 3],
                selected: 2,
                onSelected: (_) {},
                labelOf: (v) => 'Option $v',
              ),
              NumberField(controller: number, label: 'Count', min: 1, max: 3),
              const AsciiArt(lines: [...kSkullCranium, ...kSkullJaw]),
              const SectionHeader(title: 'Section', kicker: 'kicker', trailing: Icon(Icons.star)),
              const AccentBarBox(color: J3Colors.info, child: Text('accent')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('<= 3'), findsNothing);
    await tester.enterText(find.byType(TextField).last, '9');
    await tester.pump();
    expect(find.text('<= 3'), findsOneWidget, reason: 'NumberField validates range');
  });

  testWidgets('NeonButton activates by tap, Enter and Space; disabled does nothing', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        env,
        Column(
          children: [
            NeonButton(label: 'Go', onPressed: () => taps++),
            NeonButton(label: 'Off', onPressed: null, key: const Key('off')),
          ],
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pump();
    expect(taps, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(taps, 3);
    await tester.tap(find.text('Off'));
    await tester.pump();
    expect(taps, 3);
  });

  testWidgets('primary button glitch and GlitchText animations complete with motion enabled', (tester) async {
    await tester.pumpWidget(
      _host(
        env,
        Column(
          children: [
            NeonButton(label: 'Go', onPressed: () {}),
            GlitchText('GLITCH', style: const TextStyle(fontSize: 20), trigger: 1),
          ],
        ),
        effects: EffectsConfig.fallback,
      ),
    );
    await tester.tap(find.text('Go'));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('backdrop with particles and scanlines disposes its ticker', (tester) async {
    await tester.pumpWidget(_host(env, const J3Backdrop(child: Text('x')), effects: EffectsConfig.fallback));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('ResultPanel copies text and virtualises large output', (tester) async {
    final big = List.generate(5000, (i) => 'line $i').join('\n');
    await tester.pumpWidget(
      _host(
        env,
        SingleChildScrollView(
          child: Column(
            children: [
              ResultPanel(text: big),
              const ResultPanel(text: ''),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('5000 lines'), findsOneWidget);
    expect(find.text('(empty)'), findsOneWidget);
    expect(find.text('line 4999'), findsNothing, reason: 'only visible rows are built');
  });

  testWidgets('ToolScaffold two-pane layout stacks on phones', (tester) async {
    final module = FeatureModule(
      id: 't',
      tools: [
        ToolDefinition(
          id: 'dev.t',
          name: 'Tool T',
          section: ToolSection.devTools,
          description: 'desc',
          icon: Icons.abc,
          builder: (_) => const SizedBox(),
        ),
      ],
    );
    small(tester);
    await tester.pumpWidget(
      _host(
        env,
        const ToolScaffold(toolId: 'dev.t', inputs: [Text('IN')], results: [Text('OUT')]),
        modules: [module],
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(find.text('OUT')).dy, greaterThan(tester.getTopLeft(find.text('IN')).dy));
    await tester.tap(find.byTooltip('Add to favourites'));
    await tester.pump();
    expect(find.byTooltip('Remove from favourites'), findsOneWidget);
  });

  testWidgets('confirm and text input dialogs return values', (tester) async {
    bool? confirmed;
    String? typed;
    await tester.pumpWidget(
      _host(
        env,
        Builder(
          builder: (context) => Column(
            children: [
              TextButton(
                onPressed: () async => confirmed = await showJ3Confirm(
                  context,
                  title: 'Sure?',
                  message: 'Really',
                  destructive: true,
                  confirmLabel: 'Delete',
                ),
                child: const Text('ask'),
              ),
              TextButton(
                onPressed: () async => typed = await showJ3TextInput(
                  context,
                  title: 'Name',
                  initial: 'abc',
                  validator: (v) => v.isEmpty ? 'Required' : null,
                ),
                child: const Text('type'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.text('ask'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);

    await tester.tap(find.text('type'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('OK'));
    await tester.pump();
    expect(find.text('Required'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'j3');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(typed, 'j3');
  });

  testWidgets('workspace browser stays inside the workspace and picks a file', (tester) async {
    final container = env.container();
    addTearDown(container.dispose);
    // Real file IO must run outside the fake-async test zone.
    final ws = (await tester.runAsync(() async {
      final w = await container.read(workspacesProvider.notifier).addAppOwned('WS');
      await Directory(p.join(w.rootPath, 'sub')).create();
      await File(p.join(w.rootPath, 'sub', 'a.json')).writeAsString('{}');
      await File(p.join(w.rootPath, 'b.txt')).writeAsString('x');
      return w;
    }))!;
    String? picked;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: J3Theme.build(AccentPreset.neon),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    picked = await showWorkspaceBrowser(context, workspace: ws, extensions: ['json']),
                child: const Text('browse'),
              ),
            ),
          ),
        ),
      ),
    );
    // The dialog lists folders with real IO: let real time pass between pumps
    // (pumpAndSettle would spin forever on the loading indicator).
    Future<void> waitFor(Finder f) async {
      for (var i = 0; i < 50 && f.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(f, findsWidgets);
    }

    await tester.tap(find.text('browse'));
    await waitFor(find.text('sub'));
    expect(find.byTooltip('Up one folder'), findsOneWidget);
    await tester.tap(find.text('sub'));
    await waitFor(find.text('a.json'));
    await tester.tap(find.text('a.json'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(picked, p.join(ws.rootPath, 'sub', 'a.json'));
  });
}
