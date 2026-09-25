import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/activity/activity_controller.dart';
import 'package:j3nsontop_multitool/core/activity/operation.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/settings/app_settings.dart';
import 'package:j3nsontop_multitool/core/settings/settings_controller.dart';
import 'package:j3nsontop_multitool/core/theme/j3_colors.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';
import '../home/experience_harness.dart';

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  /// Waits for the storage measurement started on open (its indeterminate
  /// progress bar would keep pumpAndSettle busy).
  Future<void> scanDone(WidgetTester tester) => pumpUntilFound(tester, find.text('MEASURED'));

  AppSettings settingsOf(WidgetTester tester) => containerOf(tester).read(settingsProvider);

  Future<AppSettings> savedSettings(WidgetTester tester, bool Function(AppSettings s) ok) =>
      eventually(tester, () async => AppSettings.fromJson(await readDocumentData(env.paths.settingsFile)), ok);

  /// Taps the switch of an [OptionSwitch] by its label.
  Future<void> toggle(WidgetTester tester, String label) async {
    final tile = find.widgetWithText(SwitchListTile, label);
    await tester.ensureVisible(tile);
    await tester.pump();
    await tester.tap(tile);
    await tester.pump();
  }

  group('SettingsScreen', () {
    testWidgets('renders every section on a wide screen', (tester) async {
      setSurface(tester, const Size(1400, 3200));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/settings'));
      await tester.pump();
      await scanDone(tester);
      for (final kicker in [
        '// EFFECTS',
        '// INTRO',
        '// SOUND',
        '// THEME',
        '// DATA & PRIVACY',
        '// KEYBOARD',
        '// PLATFORM',
        '// ABOUT',
        '// LIVE PREVIEW',
      ]) {
        expect(find.text(kicker), findsOneWidget, reason: kicker);
      }
      expect(find.text(env.paths.root), findsOneWidget);
      expect(find.textContaining('No telemetry'), findsOneWidget);
      expect(find.text('Go to Home'), findsOneWidget);
      expect(find.text('Open the command palette (also Ctrl+Shift+P)'), findsOneWidget);
      expect(find.text('Capabilities on Linux (dev/test)'), findsOneWidget);
      expect(find.text('System setting: reduce motion is OFF.'), findsOneWidget);
      await settleIo(tester);
    });

    testWidgets('switches apply immediately and persist', (tester) async {
      setSurface(tester, const Size(1400, 3200));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/settings', liveEffects: true));
      await tester.pump();
      await scanDone(tester);

      expect(settingsOf(tester).scanlines, isTrue);
      await toggle(tester, 'Scanlines');
      expect(settingsOf(tester).scanlines, isFalse);
      expect(find.text('SCANLINES OFF'), findsOneWidget);

      await toggle(tester, 'Skip intro on launch');
      await toggle(tester, 'Show the activity panel on wide screens');
      expect(settingsOf(tester).skipIntro, isTrue);
      expect(settingsOf(tester).showActivityPanel, isFalse);

      final saved = await savedSettings(tester, (s) => s.skipIntro && !s.showActivityPanel && !s.scanlines);
      expect(saved.skipIntro, isTrue);
      expect(saved.scanlines, isFalse);
      expect(saved.showActivityPanel, isFalse);
    });

    testWidgets('low-effects mode disables the individual effect switches', (tester) async {
      setSurface(tester, const Size(1400, 3200));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/settings', liveEffects: true));
      await tester.pump();
      await scanDone(tester);

      await toggle(tester, 'Low-effects mode');
      expect(settingsOf(tester).lowEffects, isTrue);
      expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Glow')).onChanged, isNull);
      expect(find.text('Disabled by low-effects mode.'), findsNWidgets(3));
      expect(find.text('0 % (low-effects mode)'), findsOneWidget);
      expect(find.text('GLOW OFF'), findsOneWidget);
      // The stored individual preference is kept.
      expect(settingsOf(tester).glow, isTrue);
      await settleIo(tester);
    });

    testWidgets('motion preference shows the resolved state', (tester) async {
      setSurface(tester, const Size(1400, 3200));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/settings', liveEffects: true));
      await tester.pump();
      await scanDone(tester);
      expect(find.textContaining('Result: full motion'), findsOneWidget);

      await tester.tap(find.text('Always reduce'));
      await tester.pump();
      expect(settingsOf(tester).motion, MotionPreference.reduced);
      expect(find.textContaining('Result: motion is reduced'), findsOneWidget);
      expect(find.text('Paused while motion is reduced.'), findsOneWidget);
      await settleIo(tester);
    });

    testWidgets('intensity slider previews live and persists on release', (tester) async {
      setSurface(tester, const Size(1400, 3200));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/settings', liveEffects: true));
      await tester.pump();
      await scanDone(tester);
      expect(find.text('75 %'), findsOneWidget);

      final slider = find.byType(Slider).first;
      await tester.drag(slider, const Offset(-2000, 0));
      await tester.pump();
      expect(settingsOf(tester).intensity, 0);
      expect(find.text('INTENSITY 0%'), findsOneWidget);
      final saved = await savedSettings(tester, (s) => s.intensity == 0);
      expect(saved.intensity, 0);
    });

    testWidgets('accent swatches switch the preset', (tester) async {
      setSurface(tester, const Size(1400, 3200));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/settings', liveEffects: true));
      await tester.pump();
      await scanDone(tester);
      expect(find.bySemanticsLabel('Accent Neon red, selected'), findsOneWidget);

      await tester.tap(find.text('Crimson'));
      await tester.pump();
      expect(settingsOf(tester).accent, AccentPreset.crimson);
      expect(find.bySemanticsLabel('Accent Crimson, selected'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);
      final saved = await savedSettings(tester, (s) => s.accent == AccentPreset.crimson);
      expect(saved.accent, AccentPreset.crimson);
    });

    testWidgets('volume is disabled while sound is off', (tester) async {
      setSurface(tester, const Size(1400, 3200));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/settings'));
      await tester.pump();
      await scanDone(tester);
      Slider volume() => tester.widgetList<Slider>(find.byType(Slider)).last;
      expect(settingsOf(tester).sound, isFalse);
      expect(volume().onChanged, isNull);
      expect(find.text('sound is off'), findsOneWidget);

      await toggle(tester, 'Sound effects');
      expect(settingsOf(tester).sound, isTrue);
      expect(volume().onChanged, isNotNull);
      expect(find.text('60 %'), findsOneWidget);
      await settleIo(tester);
    });

    testWidgets('measures real storage use in the data directory', (tester) async {
      setSurface(tester, const Size(1400, 3200));
      await tester.runAsync(() async {
        final ws = Directory(p.join(env.paths.workspacesDir, 'w1', 'files'));
        await ws.create(recursive: true);
        await File(p.join(ws.path, 'a.bin')).writeAsBytes(List.filled(1000, 1));
        await File(p.join(ws.path, 'b.bin')).writeAsBytes(List.filled(24, 1));
        await File(p.join(env.paths.cacheDir, 'c.bin')).writeAsBytes(List.filled(100, 1));
      });
      await tester.pumpWidget(buildExperienceApp(env, initial: '/settings'));
      await tester.pump();
      await scanDone(tester);
      await pumpUntilFound(tester, find.text('MEASURED'));
      expect(find.text('MEASURED'), findsOneWidget);
      expect(find.text('1.0 KB  |  2 files'), findsOneWidget);
      expect(find.text('100 B  |  1 file'), findsOneWidget);
      expect(find.text('Measure again'), findsOneWidget);
    });

    testWidgets('copy path uses the clipboard adapter', (tester) async {
      setSurface(tester, const Size(1400, 3200));
      final files = FakeFileAccess();
      await tester.pumpWidget(buildExperienceApp(env, initial: '/settings', fileAccess: files));
      await tester.pump();
      await scanDone(tester);
      await tester.ensureVisible(find.text('Copy path'));
      await tester.tap(find.text('Copy path'));
      await tester.pump();
      expect(files.copied, [env.paths.root]);
      await settleIo(tester);
    });

    testWidgets('clear history confirms and keeps running operations', (tester) async {
      setSurface(tester, const Size(1400, 3200));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/settings'));
      final activity = containerOf(tester).read(activityProvider.notifier);
      activity.start(toolId: 'files.hash', title: 'Done op').succeed('ok');
      activity.start(toolId: 'files.hash', title: 'Running op');
      await tester.pump();
      await scanDone(tester);

      final button = find.text('Clear operation history (1)');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Clear operation history?'), findsOneWidget);
      await tester.tap(find.text('Clear history'));
      await tester.pumpAndSettle();
      final ops = containerOf(tester).read(activityProvider).operations;
      expect(ops.map((o) => o.status), [OperationStatus.running]);
      expect(find.text('Clear operation history (0)'), findsOneWidget);
      await settleIo(tester);
    });

    testWidgets('reset restores defaults but keeps the sample marker', (tester) async {
      setSurface(tester, const Size(1400, 3200));
      final custom = (await tester.runAsync(
        () => TestEnv.create(
          settings: const AppSettings(
            sampleWorkspaceCreated: true,
            sound: true,
            accent: AccentPreset.ember,
            skipIntro: true,
          ),
        ),
      ))!;
      await tester.pumpWidget(buildExperienceApp(custom, initial: '/settings'));
      await tester.pump();
      await scanDone(tester);
      expect(settingsOf(tester).accent, AccentPreset.ember);

      final button = find.text('Reset settings to defaults');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset settings'));
      await tester.pumpAndSettle();
      final s = settingsOf(tester);
      expect(s.accent, AccentPreset.neon);
      expect(s.sound, isFalse);
      expect(s.skipIntro, isFalse);
      expect(s.sampleWorkspaceCreated, isTrue);
      await settleIo(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(custom.dispose);
    });

    testWidgets('mobile shows the shortcut alternative instead of the list', (tester) async {
      setSurface(tester, const Size(1400, 3200));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/settings', platform: AppPlatform.android));
      await tester.pump();
      await scanDone(tester);
      expect(find.text('Go to Home'), findsNothing);
      expect(find.textContaining('Keyboard shortcuts are not available on Android'), findsOneWidget);
      expect(find.text('Capabilities on Android'), findsOneWidget);
      expect(find.textContaining('Alternative: Mobile systems do not allow'), findsOneWidget);
      await settleIo(tester);
    });

    testWidgets('replay intro and about links navigate', (tester) async {
      setSurface(tester, const Size(1400, 3200));
      await tester.pumpWidget(buildExperienceApp(env, initial: '/settings'));
      await tester.pump();
      await scanDone(tester);
      await tester.ensureVisible(find.text('About this app'));
      await tester.tap(find.text('About this app'));
      await tester.pumpAndSettle();
      expect(find.text('// ABOUT'), findsWidgets);
      expect(find.text('Version and identity'), findsOneWidget);

      await tester.pumpWidget(buildExperienceApp(env, initial: '/settings'));
      await tester.pump();
      await scanDone(tester);
      await tester.ensureVisible(find.text('Replay intro now'));
      await tester.tap(find.text('Replay intro now'));
      await tester.pumpAndSettle();
      expect(find.text('INTRO replay=1'), findsOneWidget);
    });

    testWidgets('fits a 320 px phone at 2x text without overflow', (tester) async {
      await loadAppFonts();
      usePhoneWithLargeText(tester);
      await tester.pumpWidget(buildExperienceApp(env, initial: '/settings'));
      await tester.pump();
      await scanDone(tester);
      await settleIo(tester);
      await scrollThrough(tester);
      expect(tester.takeException(), isNull);
    });
  });
}
