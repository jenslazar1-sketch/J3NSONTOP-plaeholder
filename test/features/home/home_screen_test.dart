import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/app/app_info.dart';
import 'package:j3nsontop_multitool/core/activity/activity_controller.dart';
import 'package:j3nsontop_multitool/core/storage/user_data.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/home/home_favorites.dart';
import 'package:j3nsontop_multitool/features/home/home_hero.dart' show kSkullLaughNotice;
import 'package:j3nsontop_multitool/features/home/home_status.dart';
import 'package:j3nsontop_multitool/features/intro/skull_art.dart';
import 'package:j3nsontop_multitool/features/palette/command_palette.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';
import 'experience_harness.dart';

/// Text of a stat tile's value, found through its semantics-free Text.
Finder statValue(String label, String value) => find.bySemanticsLabel(RegExp('^$label: ${RegExp.escape(value)},'));

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  group('HomeScreen', () {
    testWidgets('renders the hero, cosmetic label, sections and real tool counts', (tester) async {
      setSurface(tester, const Size(1400, 2600));
      await tester.pumpWidget(buildExperienceApp(env));
      await settleIo(tester);

      for (final line in AppInfo.fullNameLines) {
        expect(find.text(line), findsWidgets);
      }
      expect(find.text(AppInfo.tagline), findsOneWidget);
      expect(find.text('// cosmetic - not real activity'), findsOneWidget);
      // 4 of 5 fake tools are available on Linux (one is Windows-only).
      expect(statValue('TOOLS ONLINE', '4/5'), findsOneWidget);
      expect(statValue('WORKSPACES', '0'), findsOneWidget);
      expect(statValue('OPS TODAY', '0'), findsOneWidget);
      expect(statValue('RUNNING NOW', '0'), findsOneWidget);
      expect(statValue('MOD PACKAGES', '--'), findsOneWidget);
      // Section tiles with real per-section counts (system is not a tile).
      expect(find.text('File Tools'), findsOneWidget);
      expect(find.text('01 TOOL'), findsNWidgets(3));
      expect(find.text('00 TOOLS'), findsNWidgets(3));
      expect(find.text('Nothing has run yet'), findsOneWidget);
      expect(find.text('No favourites yet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('operation numbers and recent activity follow the activity state', (tester) async {
      setSurface(tester, const Size(1400, 2600));
      await tester.pumpWidget(buildExperienceApp(env));
      await settleIo(tester);
      final activity = containerOf(tester).read(activityProvider.notifier);

      activity.start(toolId: 'files.hash', title: 'Hash 3 files').succeed('3 files hashed', counts: {'files': 3});
      final running = activity.start(toolId: 'dev.base64', title: 'Encode payload');
      await tester.pump();

      expect(statValue('OPS TODAY', '2'), findsOneWidget);
      expect(statValue('RUNNING NOW', '1'), findsOneWidget);
      expect(find.text('Hash 3 files'), findsWidgets);
      expect(find.text('Encode payload'), findsWidgets);
      expect(find.textContaining('1 running'), findsOneWidget);

      running.fail('boom');
      await tester.pump();
      expect(statValue('RUNNING NOW', '0'), findsOneWidget);
      expect(find.text('FAILED'), findsWidgets);

      await tester.tap(find.text('Open activity log'));
      await tester.pumpAndSettle();
      expect(find.text('Activity'), findsOneWidget);
      await settleIo(tester);
    });

    testWidgets('counts mod packages and profiles of the active workspace', (tester) async {
      setSurface(tester, const Size(1400, 2600));
      await tester.pumpWidget(buildExperienceApp(env));
      await settleIo(tester);
      final container = containerOf(tester);

      late Workspace ws;
      await tester.runAsync(() async {
        ws = await container.read(workspacesProvider.notifier).addAppOwned('Neon Test');
      });
      await settleIo(tester);
      expect(statValue('WORKSPACES', '1'), findsOneWidget);
      // No mods/ or profiles/ folder yet: counted as zero, not guessed.
      expect(statValue('MOD PACKAGES', '0'), findsOneWidget);
      expect(statValue('PROFILES', '0'), findsOneWidget);
      expect(find.text('REACHABLE'), findsOneWidget);
      expect(find.text('IMPORTED COPY'), findsWidgets);

      await tester.runAsync(() async {
        final meta = container.read(workspacesProvider.notifier).metaDir(ws);
        await Directory(p.join(meta, 'mods')).create(recursive: true);
        await Directory(p.join(meta, 'profiles')).create(recursive: true);
        await File(p.join(meta, 'mods', 'neon-hud-1.2.0.j3mod')).writeAsString('x');
        await File(p.join(meta, 'mods', 'core-patch-1.0.0.j3mod')).writeAsString('x');
        await File(p.join(meta, 'mods', 'notes.txt')).writeAsString('not a mod');
        await File(p.join(meta, 'profiles', 'hardcore-run.j3profile.json')).writeAsString('{}');
      });
      await tester.tap(find.byTooltip('Recount workspace files and re-check health'));
      await pumpUntilFound(tester, statValue('MOD PACKAGES', '2'));
      expect(statValue('MOD PACKAGES', '2'), findsOneWidget);
      expect(statValue('PROFILES', '1'), findsOneWidget);

      // A deleted workspace folder is reported with its reason.
      await tester.runAsync(() => Directory(ws.rootPath).delete(recursive: true));
      await tester.tap(find.byTooltip('Recount workspace files and re-check health'));
      await pumpUntilFound(tester, find.text('MISSING'));
      expect(find.text('MISSING'), findsOneWidget);
      expect(find.textContaining('no longer exists'), findsOneWidget);
    });

    testWidgets('recent workspaces switch the active workspace', (tester) async {
      setSurface(tester, const Size(1400, 2600));
      await tester.pumpWidget(buildExperienceApp(env));
      final container = containerOf(tester);
      await tester.runAsync(() async {
        await container.read(workspacesProvider.notifier).addAppOwned('Alpha');
        await container.read(workspacesProvider.notifier).addAppOwned('Beta', kind: WorkspaceKind.sample);
      });
      await settleIo(tester);
      expect(container.read(activeWorkspaceProvider)!.name, 'Beta');
      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('SAMPLE (DISPOSABLE)'), findsWidgets);

      await tester.tap(find.byTooltip('Make "Alpha" the active workspace'));
      await settleIo(tester);
      expect(container.read(activeWorkspaceProvider)!.name, 'Alpha');
    });

    testWidgets('recent tools show relative times and open the tool', (tester) async {
      setSurface(tester, const Size(1400, 2600));
      await tester.pumpWidget(buildExperienceApp(env));
      unawaited(containerOf(tester).read(userDataProvider.notifier).recordToolOpened('files.hash'));
      await tester.pump();
      expect(find.textContaining('File Tools  |  just now'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel(RegExp(r'^Hash files, opened')));
      await tester.pumpAndSettle();
      expect(find.text('TOOL files.hash'), findsOneWidget);
      await settleIo(tester);
    });

    testWidgets('favourites reorder by menu, keyboard and drag and persist', (tester) async {
      setSurface(tester, const Size(1400, 2600));
      await tester.pumpWidget(buildExperienceApp(env));
      final container = containerOf(tester);
      final user = container.read(userDataProvider.notifier);
      unawaited(user.toggleFavorite('files.hash'));
      unawaited(user.toggleFavorite('dev.base64'));
      unawaited(user.toggleFavorite('mods.profiles'));
      await settleIo(tester);
      List<String> favs() => container.read(userDataProvider).favorites;

      expect(find.text('Pinned tools (3)'), findsOneWidget);
      expect(find.text('#01  FILE TOOLS'), findsOneWidget);

      // Menu alternative.
      await tester.tap(find.byTooltip('Reorder or remove "Hash files"'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Move right'));
      await tester.pumpAndSettle();
      expect(favs(), ['dev.base64', 'files.hash', 'mods.profiles']);

      // Keyboard alternative: Alt+Left on the focused card.
      Focus.of(tester.element(find.text('Mod profiles'))).requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(favs(), ['dev.base64', 'mods.profiles', 'files.hash']);

      // Drag the first card by its handle onto the last one.
      final handle = find.descendant(
        of: find.byKey(const ValueKey('fav-dev.base64')),
        matching: find.byIcon(Icons.drag_indicator),
      );
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.text('Hash files')));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(favs(), ['mods.profiles', 'files.hash', 'dev.base64']);

      // Remove via menu.
      await tester.tap(find.byTooltip('Reorder or remove "Hash files"'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from favourites'));
      await tester.pumpAndSettle();
      expect(favs(), ['mods.profiles', 'dev.base64']);

      // Persisted to userdata.json (saves are chained; wait for the last).
      final saved = await eventually(
        tester,
        () async => UserData.fromJson(await readDocumentData(env.paths.userDataFile)).favorites,
        (List<String> f) => f.join(',') == 'mods.profiles,dev.base64',
      );
      expect(saved, ['mods.profiles', 'dev.base64']);
    });

    testWidgets('quick actions open the palette and navigate', (tester) async {
      setSurface(tester, const Size(1400, 2600));
      await tester.pumpWidget(buildExperienceApp(env));
      await settleIo(tester);

      await tester.tap(find.bySemanticsLabel(RegExp(r'^Command palette\.')));
      await tester.pumpAndSettle();
      expect(find.text(CommandPalette.hintText), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel(RegExp(r'^Replay intro\.')));
      await tester.pumpAndSettle();
      expect(find.text('INTRO replay=1'), findsOneWidget);
    });

    testWidgets('create sample workspace reports its real outcome', (tester) async {
      setSurface(tester, const Size(1400, 2600));
      await tester.pumpWidget(buildExperienceApp(env));
      await settleIo(tester);
      await tester.tap(find.bySemanticsLabel(RegExp(r'^Create sample workspace\.')));
      bool reported() => containerOf(tester)
          .read(activityProvider)
          .notices
          .any((n) => n.message.startsWith('Sample workspace') || n.message.startsWith('Could not create the sample'));
      for (var i = 0; i < 400 && !reported(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      final notices = containerOf(tester).read(activityProvider).notices.map((n) => n.message).toList();
      expect(
        notices.any((m) => m.startsWith('Sample workspace') || m.startsWith('Could not create the sample workspace')),
        isTrue,
        reason: 'notices: $notices',
      );
    });

    testWidgets('five quick taps make the skull laugh and post a notice', (tester) async {
      setSurface(tester, const Size(1400, 2600));
      await tester.pumpWidget(buildExperienceApp(env, effects: motionEffects));
      await tester.pump(const Duration(milliseconds: 400));
      final skull = find.byKey(const ValueKey('home-skull'));
      final jaw = find.text(kMiniSkullJaw.first);
      double jawOffset() => tester
          .widget<Transform>(find.ancestor(of: jaw, matching: find.byType(Transform)).first)
          .transform
          .getTranslation()
          .y;

      for (var i = 0; i < 4; i++) {
        await tester.tap(skull);
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(containerOf(tester).read(activityProvider).notices, isEmpty);
      await tester.tap(skull);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(containerOf(tester).read(activityProvider).notices.map((n) => n.message), contains(kSkullLaughNotice));
      expect(jawOffset(), greaterThan(0));
      expect(find.text('   #     #   '), findsWidgets);

      await tester.pump(const Duration(seconds: 2));
      expect(jawOffset(), 0);
      expect(find.text('   #     #   '), findsNothing);
    });

    testWidgets('with reduced motion the skull only flashes its eyes', (tester) async {
      setSurface(tester, const Size(1400, 2600));
      await tester.pumpWidget(buildExperienceApp(env));
      await tester.pump();
      final skull = find.byKey(const ValueKey('home-skull'));
      for (var i = 0; i < 5; i++) {
        await tester.tap(skull);
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.pump(const Duration(milliseconds: 160));
      expect(find.text('   #     #   '), findsWidgets);
      final t = tester.widget<Transform>(
        find.ancestor(of: find.text(kMiniSkullJaw.first), matching: find.byType(Transform)).first,
      );
      expect(t.transform.getTranslation().y, 0);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('fits a 320 px phone at 2x text without overflow', (tester) async {
      await loadAppFonts();
      usePhoneWithLargeText(tester);
      await tester.pumpWidget(buildExperienceApp(env));
      final container = containerOf(tester);
      await tester.runAsync(() => container.read(workspacesProvider.notifier).addAppOwned('A long workspace name'));
      final user = container.read(userDataProvider.notifier);
      unawaited(user.toggleFavorite('files.hash'));
      unawaited(user.toggleFavorite('dev.base64'));
      unawaited(user.recordToolOpened('mods.profiles'));
      final activity = container.read(activityProvider.notifier);
      activity.start(toolId: 'files.hash', title: 'Hash a very long list of files').succeed('Done');
      activity.start(toolId: 'dev.base64', title: 'Decode').fail('Invalid input');
      await settleIo(tester);
      await scrollThrough(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('favoriteMoveTarget', () {
    test('grid moves', () {
      // 4 columns, 6 items: row 0 = 0..3, row 1 = 4..5.
      expect(favoriteMoveTarget(FavoriteMove.left, index: 0, count: 6, cols: 4), isNull);
      expect(favoriteMoveTarget(FavoriteMove.right, index: 0, count: 6, cols: 4), 1);
      expect(favoriteMoveTarget(FavoriteMove.right, index: 5, count: 6, cols: 4), isNull);
      expect(favoriteMoveTarget(FavoriteMove.down, index: 1, count: 6, cols: 4), 5);
      expect(favoriteMoveTarget(FavoriteMove.down, index: 3, count: 6, cols: 4), 5);
      expect(favoriteMoveTarget(FavoriteMove.down, index: 4, count: 6, cols: 4), isNull);
      expect(favoriteMoveTarget(FavoriteMove.up, index: 5, count: 6, cols: 4), 1);
      expect(favoriteMoveTarget(FavoriteMove.up, index: 2, count: 6, cols: 4), isNull);
    });

    test('single column and degenerate cases', () {
      expect(favoriteMoveTarget(FavoriteMove.left, index: 1, count: 3, cols: 1), isNull);
      expect(favoriteMoveTarget(FavoriteMove.up, index: 1, count: 3, cols: 1), 0);
      expect(favoriteMoveTarget(FavoriteMove.down, index: 1, count: 3, cols: 1), 2);
      expect(favoriteMoveTarget(FavoriteMove.down, index: 2, count: 3, cols: 1), isNull);
      expect(favoriteMoveTarget(FavoriteMove.right, index: 0, count: 1, cols: 3), isNull);
    });
  });

  group('countFilesWithSuffix', () {
    test('counts matching files, ignores others and missing folders', () async {
      final dir = await Directory.systemTemp.createTemp('j3_count_');
      addTearDown(() => dir.delete(recursive: true));
      expect(await countFilesWithSuffix(p.join(dir.path, 'missing'), '.j3mod'), 0);
      await File(p.join(dir.path, 'a.j3mod')).writeAsString('');
      await File(p.join(dir.path, 'B.J3MOD')).writeAsString('');
      await File(p.join(dir.path, 'c.zip')).writeAsString('');
      await Directory(p.join(dir.path, 'd.j3mod')).create();
      expect(await countFilesWithSuffix(dir.path, '.j3mod'), 2);
    });

    test('health descriptions pair a status with a reason', () {
      for (final h in WorkspaceHealth.values) {
        final (kind, label, reason) = describeHealth(h);
        expect(label, isNotEmpty);
        expect(reason, isNotEmpty);
        expect(kind.label, isNotEmpty);
      }
    });
  });
}
