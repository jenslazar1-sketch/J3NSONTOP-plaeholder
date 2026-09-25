import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/activity/activity_controller.dart';
import 'package:j3nsontop_multitool/core/activity/operation.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/activity/activity_log.dart';

import '../../helpers/harness.dart';
import '../home/experience_harness.dart';

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  Future<OperationHandle> seed(WidgetTester tester, {String? workspaceId}) async {
    final activity = containerOf(tester).read(activityProvider.notifier);
    activity
        .start(toolId: 'files.hash', title: 'Hash 3 files', workspaceId: workspaceId)
        .succeed('3 files hashed', counts: {'files': 3, 'bytes': 4096}, details: ['game/config/settings.ini']);
    activity
        .start(toolId: 'dev.base64', title: 'Decode payload')
        .fail('Invalid padding', details: ['Authorization: Bearer supersecret']);
    activity.start(toolId: 'mods.profiles', title: 'Apply profile').warn('Applied with overlaps');
    final running = activity.start(toolId: 'files.hash', title: 'Hash big folder', cancellable: true);
    running.progress(0.4, '4 of 10 files');
    await tester.pump();
    return running;
  }

  group('ActivityScreen', () {
    testWidgets('shows an empty state without operations', (tester) async {
      setSurface(tester, const Size(1200, 1600));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/activity'));
      await tester.pump();
      expect(find.text('No operations yet'), findsOneWidget);
      expect(find.text('0 operations in history  |  0 running  |  0 today'), findsOneWidget);
      await tester.tap(find.text('Browse tools'));
      await tester.pumpAndSettle();
      expect(find.text(routeLabel('/tools')), findsOneWidget);
    });

    testWidgets('lists real operations with counts, running progress and cancel', (tester) async {
      setSurface(tester, const Size(1200, 2000));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/activity'));
      final running = await seed(tester);

      expect(find.text('3 operations in history  |  1 running  |  4 today'), findsOneWidget);
      expect(find.text('Finished operations (3)'), findsOneWidget);
      expect(find.text('1 operation in progress'), findsOneWidget);
      expect(find.text('40 %'), findsOneWidget);
      expect(find.text('4 of 10 files'), findsOneWidget);
      // Chips carry icon + label + real count.
      expect(find.text('All  3'), findsOneWidget);
      expect(find.text('Done  1'), findsOneWidget);
      expect(find.text('Warnings  1'), findsOneWidget);
      expect(find.text('Failed  1'), findsOneWidget);
      expect(find.text('Cancelled  0'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(running.token.isCancelled, isTrue);
      running.cancelled();
      await tester.pump();
      expect(find.text('Cancelled  1'), findsOneWidget);
    });

    testWidgets('search, status chips and tool dropdown filter the history', (tester) async {
      setSurface(tester, const Size(1200, 2000));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/activity'));
      await seed(tester);

      await tester.enterText(find.byType(TextField), 'padding');
      await tester.pump();
      expect(find.text('Showing 1 of 3'), findsOneWidget);
      expect(find.text('Decode payload'), findsOneWidget);
      expect(find.text('Apply profile'), findsNothing);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      expect(find.text('Showing 3 of 3'), findsOneWidget);

      await tester.tap(find.text('Warnings  1'));
      await tester.pump();
      expect(find.text('Showing 1 of 3'), findsOneWidget);
      expect(find.text('Apply profile'), findsOneWidget);
      await tester.tap(find.text('Warnings  1'));
      await tester.pump();

      await tester.tap(find.text('All tools'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hash files  (files.hash)').last);
      await tester.pumpAndSettle();
      expect(find.text('Showing 1 of 3'), findsOneWidget);
      expect(find.text('Hash 3 files'), findsOneWidget);

      await tester.tap(find.text('Clear filters').first);
      await tester.pump();
      expect(find.text('Showing 3 of 3'), findsOneWidget);
    });

    testWidgets('rows expand to show details, counts, workspace and duration', (tester) async {
      setSurface(tester, const Size(1200, 2000));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/activity'));
      final container = containerOf(tester);
      late String wsId;
      await tester.runAsync(() async {
        wsId = (await container.read(workspacesProvider.notifier).addAppOwned('Neon Dungeon')).id;
      });
      await seed(tester, workspaceId: wsId);

      expect(find.text('> game/config/settings.ini'), findsNothing);
      await tester.tap(find.text('Hash 3 files'));
      await tester.pumpAndSettle();
      expect(find.text('> game/config/settings.ini'), findsOneWidget);
      expect(find.text('files: 3'), findsOneWidget);
      expect(find.text('bytes: 4.0 KB (4096)'), findsOneWidget);
      expect(find.text('Neon Dungeon'), findsOneWidget);
      expect(find.text('Duration'), findsOneWidget);
      expect(find.text('Hash files  (files.hash)'), findsWidgets);

      await tester.tap(find.text('Decode payload'));
      await tester.pumpAndSettle();
      expect(find.text('ERROR // Invalid padding'), findsOneWidget);
      expect(find.text('None'), findsOneWidget); // no workspace recorded

      await tester.tap(find.text('Hash 3 files'));
      await tester.pumpAndSettle();
      expect(find.text('> game/config/settings.ini'), findsNothing);
      await settleIo(tester);
    });

    testWidgets('exports a redacted plain-text log', (tester) async {
      setSurface(tester, const Size(1200, 2000));
      final files = FakeFileAccess();
      await tester.pumpWidget(buildExperienceApp(env, initial: '/activity', fileAccess: files));
      await seed(tester);

      await tester.tap(find.text('Export log'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export...'));
      await tester.pumpAndSettle();

      expect(files.savedBytes, hasLength(1));
      final (name, bytes) = files.savedBytes.single;
      expect(name, startsWith('j3nsontop-activity-'));
      expect(name, endsWith('.txt'));
      final text = utf8.decode(bytes);
      expect(text, contains('Entries:   4'));
      expect(text, contains('Decode payload'));
      expect(text, contains('> Authorization: $kRedacted'));
      expect(text, isNot(contains('supersecret')));
      expect(text, contains('Progress:  40 % - 4 of 10 files'));
    });

    testWidgets('clear history asks first and keeps running operations', (tester) async {
      setSurface(tester, const Size(1200, 2000));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/activity'));
      await seed(tester);

      await tester.tap(find.text('Clear history'));
      await tester.pumpAndSettle();
      expect(find.text('Clear operation history?'), findsOneWidget);
      expect(find.text('> 1 running operation is kept'), findsOneWidget);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(containerOf(tester).read(activityProvider).operations, hasLength(4));

      await tester.tap(find.text('Clear history'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(GestureDetector, 'Clear history').last);
      await tester.pump();
      await tester.pump();
      final ops = containerOf(tester).read(activityProvider).operations;
      expect(ops, hasLength(1));
      expect(ops.single.status, OperationStatus.running);
      expect(find.text('No finished operations yet'), findsOneWidget);
      await settleIo(tester);
    });

    testWidgets('fits a 320 px phone at 2x text without overflow', (tester) async {
      await loadAppFonts();
      usePhoneWithLargeText(tester);
      await tester.pumpWidget(buildExperienceApp(env, initial: '/activity'));
      await seed(tester);
      await tester.scrollUntilVisible(find.text('Decode payload'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Decode payload'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await scrollThrough(tester);
      expect(tester.takeException(), isNull);
    });
  });
}
