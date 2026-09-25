import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/app/app_info.dart';
import 'package:j3nsontop_multitool/core/settings/app_settings.dart';
import 'package:j3nsontop_multitool/core/settings/settings_controller.dart';
import 'package:j3nsontop_multitool/core/theme/effects.dart';
import 'package:j3nsontop_multitool/core/theme/j3_colors.dart';
import 'package:j3nsontop_multitool/features/intro/intro_screen.dart';
import 'package:j3nsontop_multitool/features/intro/intro_sound.dart';
import 'package:j3nsontop_multitool/features/intro/intro_timeline.dart';
import 'package:j3nsontop_multitool/features/intro/skull_art.dart';

import '../../helpers/harness.dart';
import 'intro_test_utils.dart';

void main() {
  late TestEnv env;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  /// A sound factory that fails the test if audio is ever requested.
  final noAudio = introSoundProvider.overrideWithValue(() => throw StateError('audio must not be created'));

  Future<(ProviderContainer, List<int>)> pumpIntro(
    WidgetTester tester, {
    EffectsConfig fx = fullFx,
    bool replay = false,
  }) async {
    final container = introContainer(env, extra: [noAudio]);
    final finished = <int>[];
    await tester.pumpWidget(
      introHost(
        container,
        IntroScreen(replay: replay, onFinished: () => finished.add(finished.length)),
        fx: fx,
      ),
    );
    return (container, finished);
  }

  group('controls', () {
    testWidgets('SKIP is visible on the first frame and finishes exactly once', (tester) async {
      final (_, finished) = await pumpIntro(tester);
      // First frame: darkness phase, but the control is there.
      expect(find.byKey(IntroKeys.skip), findsOneWidget);
      expect(find.text('SKIP >>'), findsOneWidget);
      expect(find.byTooltip('Skip intro (Esc)'), findsOneWidget);
      await tester.tap(find.byKey(IntroKeys.skip));
      await tester.pump();
      expect(finished, hasLength(1));
      await tester.tap(find.byKey(IntroKeys.skip));
      await tester.pump(const Duration(seconds: 6));
      expect(finished, hasLength(1), reason: 'completion after a skip must not call onFinished again');
      // Nothing keeps ticking after a skip.
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('Esc skips', (tester) async {
      final (_, finished) = await pumpIntro(tester);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(finished, hasLength(1));
    });

    for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
      testWidgets('${key.keyLabel} skips when no control has focus', (tester) async {
        final (_, finished) = await pumpIntro(tester);
        await tester.pump();
        await tester.sendKeyEvent(key);
        await tester.pump();
        expect(finished, hasLength(1));
      });
    }

    testWidgets('Space on the focused toggle toggles it instead of skipping', (tester) async {
      final (container, finished) = await pumpIntro(tester);
      await tester.pump();
      // Tab from the intro to the toggle.
      bool switchFocused() =>
          tester.binding.focusManager.primaryFocus?.context?.findAncestorWidgetOfExactType<Switch>() != null;
      for (var i = 0; i < 6 && !switchFocused(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(switchFocused(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(finished, isEmpty);
      expect(container.read(settingsProvider).skipIntro, isTrue);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('"Skip intro on launch" persists to settings', (tester) async {
      final (container, finished) = await pumpIntro(tester);
      expect(find.text('Skip intro on launch'), findsOneWidget);
      expect(container.read(settingsProvider).skipIntro, isFalse);
      await tester.tap(find.byKey(IntroKeys.skipToggle));
      await tester.pump();
      expect(container.read(settingsProvider).skipIntro, isTrue);
      expect(finished, isEmpty, reason: 'toggling does not end the intro');
      // Let the atomic write finish (real IO), then read the file back.
      Map<String, dynamic>? saved;
      for (var i = 0; i < 20 && saved?['skipIntro'] != true; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
        saved = (await tester.runAsync(env.stores.settings.load))!.data;
      }
      expect(AppSettings.fromJson(saved!).skipIntro, isTrue);
      // The label toggles too.
      await tester.tap(find.text('Skip intro on launch'));
      await tester.pump();
      expect(container.read(settingsProvider).skipIntro, isFalse);
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('replay plays the sequence and keeps the toggle', (tester) async {
      final (container, finished) = await pumpIntro(tester, replay: true);
      expect(find.text('REPLAY'), findsOneWidget);
      expect(find.byKey(IntroKeys.skipToggle), findsOneWidget);
      await tester.tap(find.byKey(IntroKeys.skipToggle));
      await tester.pump();
      expect(container.read(settingsProvider).skipIntro, isTrue);
      await tester.pump();
      await tester.pump(IntroTimeline().duration + const Duration(milliseconds: 50));
      expect(finished, hasLength(1));
    });
  });

  group('choreography', () {
    testWidgets('jaw drops ~1 line height at each laugh peak while the cranium stays steady', (tester) async {
      await pumpIntro(tester);
      await tester.pump(); // t = 0
      final clock = IntroClock(tester);
      final tl = IntroTimeline();
      final laughStart = tl[IntroPhase.laugh].start;

      await clock.to(laughStart + 0.01);
      final craniumRest = tester.getRect(find.byKey(IntroKeys.cranium));
      final jawRest = tester.getTopLeft(find.byKey(IntroKeys.jaw));
      final lineHeight = craniumRest.height / kSkullCranium.length;
      // Closed: the jaw sits exactly under the cranium (shared grid).
      expect(jawRest.dy, closeTo(craniumRest.bottom, 0.01));
      expect(jawRest.dx, closeTo(craniumRest.left, 0.01));

      final drops = <double>[];
      for (final pulse in kLaughPulses) {
        await clock.to(laughStart + pulse.peak);
        final cranium = tester.getTopLeft(find.byKey(IntroKeys.cranium));
        final jaw = tester.getTopLeft(find.byKey(IntroKeys.jaw));
        final jawMove = (jaw.dy - jawRest.dy) / lineHeight;
        final craniumMove = (cranium - craniumRest.topLeft).distance / lineHeight;
        // Gap between the upper teeth row (cranium bottom) and the jaw top.
        final relative = (jaw.dy - tester.getBottomLeft(find.byKey(IntroKeys.cranium)).dy) / lineHeight;
        expect(jawMove, greaterThanOrEqualTo(0.8), reason: 'jaw drops at peak ${pulse.peak}');
        expect(relative, inInclusiveRange(0.85, 1.15), reason: 'mouth gap ~1 line height');
        expect(craniumMove, lessThanOrEqualTo(0.3), reason: 'cranium only bobs');
        expect((jaw.dx - cranium.dx).abs() / lineHeight, lessThan(0.3), reason: 'no horizontal drift');
        drops.add(relative);
        // Snaps shut after every pulse; the head settles a moment later.
        await clock.to(laughStart + pulse.end + 0.005);
        final shut = tester.getTopLeft(find.byKey(IntroKeys.jaw)).dy;
        expect(shut, closeTo(tester.getBottomLeft(find.byKey(IntroKeys.cranium)).dy, 0.01));
        await clock.to(laughStart + pulse.end + kHeadLag + 0.01);
        expect(tester.getTopLeft(find.byKey(IntroKeys.jaw)).dy, closeTo(jawRest.dy, 0.01));
      }
      expect(drops.toSet().length, 3, reason: 'three distinct peaks');
      await clock.to(tl.total + 0.1);
    });

    testWidgets('completing the sequence calls onFinished exactly once and stops ticking', (tester) async {
      final (_, finished) = await pumpIntro(tester);
      await tester.pump();
      final clock = IntroClock(tester);
      final tl = IntroTimeline();
      var sawGlitch = false;
      var sawSignal = false;
      for (var t = 0.02; t < tl.total - 0.01; t += 0.02) {
        await clock.to(t);
        sawGlitch |= find.byKey(IntroKeys.glitch).evaluate().isNotEmpty;
        sawSignal |= find.byKey(IntroKeys.signal).evaluate().isNotEmpty;
        expect(finished, isEmpty, reason: 'not finished at $t');
      }
      expect(sawGlitch, isTrue);
      expect(sawSignal, isTrue);
      await clock.to(tl.total + 0.05);
      expect(finished, hasLength(1));
      await tester.pump(const Duration(seconds: 3));
      expect(finished, hasLength(1));
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('low-effects mode: no glitch layer or flicker, the laugh remains', (tester) async {
      final (_, finished) = await pumpIntro(tester, fx: lowFx);
      await tester.pump();
      final clock = IntroClock(tester);
      final tl = IntroTimeline(decorative: false);
      Offset? jawRest;
      var maxDrop = 0.0;
      for (var t = 0.01; t < tl.total; t += 0.01) {
        await clock.to(t);
        expect(find.byKey(IntroKeys.glitch), findsNothing, reason: 't=$t');
        expect(find.byKey(IntroKeys.signal), findsNothing, reason: 't=$t');
        if (t > tl[IntroPhase.reveal].end && t < tl[IntroPhase.laugh].end) {
          final jaw = tester.getTopLeft(find.byKey(IntroKeys.jaw));
          jawRest ??= jaw;
          maxDrop = maxDrop < jaw.dy - jawRest.dy ? jaw.dy - jawRest.dy : maxDrop;
        }
      }
      expect(maxDrop, greaterThan(5), reason: 'jaw still laughs in low-effects mode');
      await clock.to(tl.total + 0.05);
      expect(finished, hasLength(1));
    });
  });

  group('reduced motion', () {
    testWidgets('static skull and title, Continue, auto-continues after 1.2 s', (tester) async {
      final (_, finished) = await pumpIntro(tester, fx: reducedFx);
      expect(find.byKey(IntroKeys.continueButton), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(AppInfo.tagline)), findsOneWidget);
      final jaw = tester.getTopLeft(find.byKey(IntroKeys.jaw));
      final cranium = tester.getTopLeft(find.byKey(IntroKeys.cranium));
      expect(tester.binding.transientCallbackCount, 0, reason: 'no animation is running');
      for (final ms in [100, 300, 400, 300]) {
        await tester.pump(Duration(milliseconds: ms));
        expect(tester.getTopLeft(find.byKey(IntroKeys.jaw)), jaw);
        expect(tester.getTopLeft(find.byKey(IntroKeys.cranium)), cranium);
        expect(find.byKey(IntroKeys.glitch), findsNothing);
        expect(tester.binding.transientCallbackCount, 0);
      }
      expect(finished, isEmpty);
      await tester.pump(const Duration(milliseconds: 150)); // 1.25 s
      expect(finished, hasLength(1));
      await tester.pump(const Duration(seconds: 2));
      expect(finished, hasLength(1));
    });

    testWidgets('Continue finishes immediately', (tester) async {
      final (_, finished) = await pumpIntro(tester, fx: reducedFx);
      await tester.tap(find.byKey(IntroKeys.continueButton));
      await tester.pump();
      expect(finished, hasLength(1));
      await tester.pump(const Duration(seconds: 2));
      expect(finished, hasLength(1));
    });
  });

  group('layout', () {
    testWidgets('fits 320x568 at 2x text scale without overflow or clipping', (tester) async {
      setSurface(tester, const Size(320, 568));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final (_, finished) = await pumpIntro(tester);
      await tester.pump();
      final clock = IntroClock(tester);
      final tl = IntroTimeline();
      final screen = Offset.zero & const Size(320, 568);
      for (final t in [0.1, 1.0, tl[IntroPhase.laugh].start + kLaughPulses[2].peak, 2.8, 3.5, 3.81]) {
        await clock.to(t);
        expect(tester.takeException(), isNull, reason: 'no overflow at t=$t');
      }
      for (final line in [...AppInfo.fullNameLines, 'SKIP >>', 'Skip intro on launch']) {
        final rect = tester.getRect(find.text(line));
        expect(
          screen.contains(rect.topLeft) && screen.contains(rect.bottomRight - const Offset(0.01, 0.01)),
          isTrue,
          reason: '"$line" at $rect is on screen',
        );
      }
      final skull = tester.getRect(find.byKey(IntroKeys.skull));
      expect(screen.contains(skull.topLeft) && screen.contains(skull.bottomRight - const Offset(0.01, 0.01)), isTrue);
      final skip = tester.getSize(find.byKey(IntroKeys.skip));
      expect(skip.height, greaterThanOrEqualTo(44));
      await clock.to(tl.total + 0.05);
      expect(finished, hasLength(1));
    });

    testWidgets('fits a short landscape phone', (tester) async {
      setSurface(tester, const Size(640, 320));
      await pumpIntro(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 3800));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('sound', () {
    testWidgets('sound off (default): no audio is created and no mute control', (tester) async {
      // pumpIntro installs a factory that throws if called.
      await pumpIntro(tester);
      await tester.pump();
      expect(find.byKey(IntroKeys.mute), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('sound on: plays at the volume, MUTE stops it and persists sound=false', (tester) async {
      final fake = FakeIntroSound();
      final container = introContainer(env, extra: [introSoundProvider.overrideWithValue(() => fake)]);
      await tester.runAsync(() => container.read(settingsProvider.notifier).update((s) => s.copyWith(sound: true)));
      const fx = EffectsConfig(
        reduceMotion: false,
        intensity: 0.75,
        scanlines: true,
        particles: false,
        glow: true,
        accent: AccentPreset.neon,
        sound: true,
        volume: 0.4,
      );
      var finished = 0;
      await tester.pumpWidget(introHost(container, IntroScreen(onFinished: () => finished++), fx: fx));
      expect(find.byKey(IntroKeys.mute), findsOneWidget, reason: 'visible immediately');
      expect(find.byTooltip('Mute'), findsOneWidget);
      expect(fake.calls, ['start']);
      expect(fake.volume, 0.4);
      expect(fake.startPosition, Duration.zero);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(IntroKeys.mute));
      await tester.pump();
      expect(fake.calls, ['start', 'stop']);
      expect(container.read(settingsProvider).sound, isFalse);
      expect(find.byKey(IntroKeys.mute), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(finished, 1);
      await tester.pumpWidget(const SizedBox());
      expect(fake.calls.last, 'dispose');
    });

    testWidgets('skipping stops the sound', (tester) async {
      final fake = FakeIntroSound();
      final container = introContainer(env, extra: [introSoundProvider.overrideWithValue(() => fake)]);
      const fx = EffectsConfig(
        reduceMotion: false,
        intensity: 0,
        scanlines: false,
        particles: false,
        glow: false,
        accent: AccentPreset.neon,
        sound: true,
        volume: 1,
      );
      await tester.pumpWidget(introHost(container, IntroScreen(onFinished: () {}), fx: fx));
      // Low effects: the clip starts at the offset that keeps the HAs on the jaw.
      expect(fake.startPosition!.inMilliseconds, (IntroTimeline(decorative: false).soundOffset * 1000).round());
      await tester.tap(find.byKey(IntroKeys.skip));
      await tester.pump();
      expect(fake.calls, ['start', 'stop']);
      await tester.pumpWidget(const SizedBox());
      expect(fake.calls.last, 'dispose');
    });

    testWidgets('reduced motion plays no sound', (tester) async {
      final fake = FakeIntroSound();
      final container = introContainer(env, extra: [introSoundProvider.overrideWithValue(() => fake)]);
      const fx = EffectsConfig(
        reduceMotion: true,
        intensity: 0.75,
        scanlines: true,
        particles: false,
        glow: true,
        accent: AccentPreset.neon,
        sound: true,
        volume: 1,
      );
      await tester.pumpWidget(introHost(container, IntroScreen(onFinished: () {}), fx: fx));
      await tester.pump(const Duration(seconds: 2));
      expect(fake.calls, isEmpty);
    });
  });
}
