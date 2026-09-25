import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/features/mods/data/apply_engine.dart';
import 'package:j3nsontop_multitool/features/mods/data/journal.dart';
import 'package:j3nsontop_multitool/features/mods/data/mod_library.dart';
import 'package:j3nsontop_multitool/features/mods/data/profile_store.dart';
import 'package:j3nsontop_multitool/features/mods/data/target_game.dart';
import 'package:j3nsontop_multitool/features/mods/domain/package_inspector.dart';
import 'package:j3nsontop_multitool/features/mods/domain/plan.dart';
import 'package:j3nsontop_multitool/features/mods/domain/resolver.dart';
import 'package:j3nsontop_multitool/features/mods/mods_module.dart';
import 'package:j3nsontop_multitool/features/mods/presentation/manager_page.dart';
import 'package:j3nsontop_multitool/features/mods/presentation/mods_controller.dart';
import 'package:j3nsontop_multitool/features/mods/presentation/plan_dialog.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';
import 'mod_fixtures.dart';
import 'mods_workspace_fixture.dart';

void main() {
  Future<(ProviderContainer, ModsWorkspace)> boot(
    WidgetTester tester, {
    Size size = const Size(1400, 1000),
    AppPlatform platform = AppPlatform.linux,
  }) async {
    setSurface(tester, size);
    final env = await widgetEnv(tester);
    final c = ProviderContainer(
      overrides: env.overrides(modules: [modsModule], platform: platform),
    );
    addTearDown(c.dispose);
    final ws = (await tester.runAsync(() => createModsWorkspace(c)))!;
    await tester.pumpWidget(scoped(c, const ModsManagerPage()));
    await pumpUntil(tester, () => c.read(modsProvider).phase == ModsPhase.ready, reason: 'mods loaded');
    return (c, ws);
  }

  testWidgets('renders library, profiles and operations side by side', (tester) async {
    await boot(tester);
    expect(find.text('Mod packages (7)'), findsOneWidget);
    expect(find.text('Mod profiles (3)'), findsOneWidget);
    expect(find.text('Journal (0)'), findsOneWidget);
    expect(find.text('HARDCORE-BALANCE'), findsWidgets);
    expect(find.text('needs core-patch ^1.0.0'), findsOneWidget);
    expect(find.text('Workspace: Neon test'), findsOneWidget);
    // Profiles are sorted by name; the first one is edited by default.
    expect(find.text('PROFILE EDITOR'), findsOneWidget);
    expect(find.textContaining('Dependency cycle: cycle-a -> cycle-b -> cycle-a'), findsWidgets);
    expect(find.textContaining('[CYCLE]'), findsWidgets);
    expect(find.textContaining('Missing dependency: legacy-skin requires retro-core'), findsWidgets);
  });

  testWidgets('selecting a profile shows overlaps with the winner and the dependency chain', (tester) async {
    await boot(tester);
    await tapVisible(tester, find.text('Conflict demo'));
    await tester.pump();
    expect(find.text('Overlaps (last one wins) (1)'), findsOneWidget);
    expect(find.text('brutal-mode WINS'), findsOneWidget);
    expect(find.text('hardcore-balance (overridden)'), findsOneWidget);
    expect(find.textContaining('core-patch ^1.0.0 ──> hardcore-balance'), findsOneWidget);
  });

  testWidgets('plan & apply lists every change, applies, then rolls back', (tester) async {
    final (c, ws) = await boot(tester);
    final original = snapshot(ws.game);
    await tapVisible(tester, find.text('Hardcore run'));
    await tester.pump();

    await tapVisible(tester, find.text('Plan & apply'));
    await pumpUntil(tester, () => shows(find.text('// APPLY PLAN')), reason: 'plan dialog');
    expect(find.text('config/balance.toml'), findsOneWidget);
    expect(find.text('config/core.ini'), findsOneWidget);
    expect(find.text('data/items.csv'), findsOneWidget);
    expect(find.text('data/ui/hud.json'), findsOneWidget);
    expect(find.text('data/ui/neon/theme.json'), findsOneWidget);
    expect(find.text('2 CREATE'), findsOneWidget);
    expect(find.text('2 OVERWRITE'), findsOneWidget);
    expect(find.text('1 SAME'), findsOneWidget);
    expect(find.text('data/ui/neon/'), findsOneWidget);
    expect(find.textContaining('from hardcore-balance 2.0.1'), findsWidgets);

    await tapVisible(tester, find.text('Apply 4 change(s)'));
    await pumpUntil(tester, () => shows(find.textContaining('Applied "Hardcore run"')), reason: 'apply result');
    await pumpUntil(tester, () => c.read(modsProvider).operations.isNotEmpty, reason: 'journal listed');
    expect(File(p.join(ws.game, 'config/balance.toml')).readAsStringSync(), '[player]\nhp = 50\n');
    expect(File(p.join(ws.game, 'data/ui/neon/theme.json')).existsSync(), isTrue);
    expect(c.read(modsProvider).operations.single.status, JournalStatus.applied);
    expect(find.text('APPLIED'), findsWidgets);

    await tapVisible(tester, find.text('Roll back').first);
    await pumpUntil(tester, () => shows(find.text('Roll back "Hardcore run"?')), reason: 'confirm');
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Roll back')));
    await pumpUntil(tester, () => c.read(modsProvider).operations.firstOrNull?.status == JournalStatus.rolledBack);
    await settle(tester, rounds: 3);
    expect(snapshot(ws.game), original);
    expect(Directory(p.join(ws.game, 'data/ui/neon')).existsSync(), isFalse);
  });

  testWidgets('rollback with a user edit asks per file and honours "keep"', (tester) async {
    final (c, ws) = await boot(tester);
    await tapVisible(tester, find.text('Hardcore run'));
    await tester.pump();
    await tapVisible(tester, find.text('Plan & apply'));
    await pumpUntil(tester, () => shows(find.text('// APPLY PLAN')));
    await tapVisible(tester, find.text('Apply 4 change(s)'));
    await pumpUntil(tester, () => c.read(modsProvider).operations.isNotEmpty);
    await settle(tester, rounds: 3);

    File(p.join(ws.game, 'data/ui/hud.json')).writeAsStringSync('{"color":"mine"}');
    await tapVisible(tester, find.text('Roll back').first);
    await pumpUntil(tester, () => shows(find.text('// ROLLBACK CONFLICTS')), reason: 'conflict dialog');
    expect(find.text('data/ui/hud.json'), findsOneWidget);
    expect(find.text('Keep my edit'), findsOneWidget);
    await tapVisible(tester, find.descendant(of: find.byType(Dialog), matching: find.text('Roll back')));
    await pumpUntil(tester, () => c.read(modsProvider).operations.firstOrNull?.status == JournalStatus.rolledBack);
    expect(File(p.join(ws.game, 'data/ui/hud.json')).readAsStringSync(), '{"color":"mine"}');
    expect(File(p.join(ws.game, 'config/balance.toml')).readAsStringSync(), kGameFiles['game/config/balance.toml']);
  });

  testWidgets('interrupted operation shows a top banner with resume and roll back', (tester) async {
    setSurface(tester, const Size(1400, 1000));
    final env = await widgetEnv(tester);
    final c = ProviderContainer(overrides: env.overrides(modules: [modsModule]));
    addTearDown(c.dispose);
    final ws = (await tester.runAsync(() => createModsWorkspace(c)))!;
    // Simulate a crash half way through applying.
    await tester.runAsync(() async {
      final lib = await ModLibrary(ws.meta).list();
      final prof = (await ProfileStore(ws.meta).load('hardcore-run'))!;
      final plan = await PlanBuilder.build(
        workspaceRoot: ws.root,
        profile: prof,
        packages: [
          for (final id in prof.enabledIds)
            PlanSource(
              manifest: ModLibrary.entryFor(lib, id)!.manifest!,
              archivePath: ModLibrary.entryFor(lib, id)!.path,
            ),
        ],
      );
      final engine = ApplyEngine(
        metaDir: ws.meta,
        workspaceRoot: ws.root,
        workspaceId: ws.workspace.id,
        faults: const EngineFaults(crashAfterApplyChanges: 2),
      );
      try {
        await engine.apply(plan);
      } on SimulatedCrash {
        // expected
      }
    });
    await tester.pumpWidget(scoped(c, const ModsManagerPage()));
    await pumpUntil(tester, () => c.read(modsProvider).phase == ModsPhase.ready);
    expect(find.text('WARN // Interrupted operation: "Hardcore run"'), findsOneWidget);
    expect(find.textContaining('2 of 4 change(s) done'), findsOneWidget);
    expect(find.text('INTERRUPTED (APPLYING)'), findsOneWidget);

    await tapVisible(tester, find.text('Resume'));
    await pumpUntil(tester, () => c.read(modsProvider).operations.firstOrNull?.status == JournalStatus.applied);
    await settle(tester, rounds: 3);
    expect(find.textContaining('Interrupted operation'), findsNothing);
    expect(File(p.join(ws.game, 'data/ui/neon/theme.json')).existsSync(), isTrue);
  });

  testWidgets('sort by dependencies fixes the order', (tester) async {
    final (c, ws) = await boot(tester);
    await tester.runAsync(() async {
      final store = ProfileStore(ws.meta);
      final prof = (await store.load('hardcore-run'))!;
      await store.save(prof.moveMod(0, 2));
    });
    unawaited(c.read(modsProvider.notifier).refresh());
    await pumpUntil(tester, () => c.read(modsProvider).profileById('hardcore-run')!.mods.last.id == 'core-patch');
    await tapVisible(tester, find.text('Hardcore run'));
    await tester.pump();
    expect(find.textContaining('Ordered after dependent'), findsWidgets);
    await tapVisible(tester, find.text('Sort by dependencies'));
    List<String> order() => [for (final m in c.read(modsProvider).profileById('hardcore-run')!.mods) m.id];
    await pumpUntil(tester, () => order().indexOf('core-patch') < order().indexOf('hardcore-balance'));
    // Stable: neon-hud keeps its lead, core-patch moves before its dependent.
    expect(order(), ['neon-hud', 'core-patch', 'hardcore-balance']);
    final file = File(ProfileStore(ws.meta).pathFor('hardcore-run'));
    await pumpUntil(
      tester,
      () => file.readAsStringSync().indexOf('"core-patch"') < file.readAsStringSync().indexOf('"hardcore-balance"'),
    );
    expect(find.textContaining('Ordered after dependent'), findsNothing);
  });

  testWidgets('enable switch and up/down buttons edit and persist the profile', (tester) async {
    final (c, ws) = await boot(tester);
    await tapVisible(tester, find.text('Hardcore run'));
    await tester.pump();
    await tapVisible(tester, find.byTooltip('Move neon-hud up (applied earlier)'));
    await settle(tester, rounds: 5);
    expect(c.read(modsProvider).profileById('hardcore-run')!.mods.map((m) => m.id), [
      'core-patch',
      'neon-hud',
      'hardcore-balance',
    ]);
    await tapVisible(tester, find.byType(Switch).at(1));
    await tester.pump();
    final prof = c.read(modsProvider).profileById('hardcore-run')!;
    expect(prof.mods[1].enabled, isFalse);
    final file = File(ProfileStore(ws.meta).pathFor('hardcore-run'));
    await pumpUntil(tester, () => file.readAsStringSync().contains('"enabled": false'), reason: 'profile saved');
    final saved = (await tester.runAsync(() => ProfileStore(ws.meta).load('hardcore-run')))!;
    expect(saved.mods.map((m) => m.toString()), ['+core-patch', '-neon-hud', '+hardcore-balance']);
  });

  testWidgets('no workspace: empty state with workspace and sample buttons', (tester) async {
    setSurface(tester, const Size(800, 900));
    final env = await widgetEnv(tester);
    final c = ProviderContainer(overrides: env.overrides(modules: [modsModule]));
    addTearDown(c.dispose);
    await tester.pumpWidget(scoped(c, const ModsManagerPage()));
    await tester.pump();
    expect(find.text('No active workspace'), findsOneWidget);
    expect(find.text('Open workspaces'), findsOneWidget);
    expect(find.text('Create sample workspace'), findsOneWidget);
  });

  testWidgets('phone: tabs, mobile banner with export, no overflow at 320px and 2x text', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final (c, _) = await boot(tester, size: const Size(320, 568), platform: AppPlatform.android);
    expect(find.textContaining('Profiles apply to the workspace copy'), findsOneWidget);
    expect(find.textContaining('Export result'), findsWidgets);
    // Tabs: profiles first, then library and operations.
    await tapVisible(tester, find.text('Library (7)'));
    await tester.pump();
    expect(find.text('Mod packages (7)'), findsOneWidget);
    await tapVisible(tester, find.text('Operations (0)'));
    await tester.pump();
    expect(find.text('Journal (0)'), findsOneWidget);
    await tapVisible(tester, find.text('Profiles (3)'));
    await tester.pump();
    await tapVisible(tester, find.text('Conflict demo'));
    await tester.pump();
    expect(c.read(modsProvider).phase, ModsPhase.ready);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plan dialog fits 320px with 2x text', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    setSurface(tester, const Size(320, 568));
    final env = await widgetEnv(tester);
    final c = ProviderContainer(overrides: env.overrides(modules: [modsModule]));
    addTearDown(c.dispose);
    final ws = (await tester.runAsync(() => createModsWorkspace(c)))!;
    final (plan, report) = (await tester.runAsync(() async {
      final lib = await ModLibrary(ws.meta).list();
      final prof = (await ProfileStore(ws.meta).load('conflict-demo'))!;
      final plan = await PlanBuilder.build(
        workspaceRoot: ws.root,
        profile: prof,
        packages: [
          for (final id in prof.enabledIds)
            PlanSource(
              manifest: ModLibrary.entryFor(lib, id)!.manifest!,
              archivePath: ModLibrary.entryFor(lib, id)!.path,
            ),
        ],
      );
      final report = ModResolver.resolve(
        profile: prof,
        library: ModLibrary.manifestsById(lib),
        target: await readTargetGame(ws.root, prof),
      );
      return (plan, report);
    }))!;
    bool? confirmed;
    await tester.pumpWidget(
      scoped(
        c,
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async => confirmed = await showPlanDialog(context, plan: plan, report: report),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final dialogScroll = find.descendant(of: find.byType(Dialog), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('config/balance.toml'), 120, scrollable: dialogScroll);
    expect(find.text('config/balance.toml'), findsOneWidget);
    expect(find.textContaining('overrides hardcore-balance'), findsOneWidget);
    // Warnings (overlap) must be acknowledged before applying.
    final apply = find.textContaining('Apply 2 change(s)');
    await tester.scrollUntilVisible(find.byType(CheckboxListTile), 120, scrollable: dialogScroll);
    await tester.tap(apply, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(confirmed, isNull, reason: 'disabled until warnings are acknowledged');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    await tester.tap(apply);
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });

  test('package reports used by the widget tests are valid', () async {
    final tmp = Directory.systemTemp.createTempSync('j3_fx_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final path = await buildPackage(tmp, id: 'core-patch');
    expect(PackageInspector.inspect(path).isValid, isTrue);
  });
}
