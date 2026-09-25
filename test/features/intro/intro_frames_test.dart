// Visual frame capture of the intro at key timestamps.
//
// Writes PNGs to build/intro_frames/ (git-ignored) for manual inspection:
//   flutter test test/features/intro/intro_frames_test.dart
// The test also checks a few pixel facts so it fails if the skull stops
// rendering (e.g. fonts not loaded, layers collapsed).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/theme/effects.dart';
import 'package:j3nsontop_multitool/core/theme/j3_theme.dart';
import 'package:j3nsontop_multitool/core/widgets/backdrop.dart';
import 'package:j3nsontop_multitool/features/intro/intro_screen.dart';
import 'package:j3nsontop_multitool/features/intro/intro_timeline.dart';
import 'package:j3nsontop_multitool/features/intro/laughing_skull.dart';

import '../../helpers/harness.dart';
import 'intro_test_utils.dart';

const EffectsConfig _fx = fullFx;

void main() {
  late TestEnv env;
  final outDir = Directory('build/intro_frames');

  setUpAll(() async {
    await loadAppFonts();
    if (outDir.existsSync()) outDir.deleteSync(recursive: true);
    outDir.createSync(recursive: true);
  });
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  Future<ui.Image> capture(WidgetTester tester, GlobalKey key, String name) async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = (await tester.runAsync(() => boundary.toImage(pixelRatio: 1.5)))!;
    final bytes = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png)))!;
    File('${outDir.path}/$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
    return image;
  }

  Future<int> brightRedPixels(WidgetTester tester, ui.Image image) async {
    final data = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawRgba)))!;
    var count = 0;
    for (var i = 0; i < data.lengthInBytes; i += 4) {
      final r = data.getUint8(i);
      final g = data.getUint8(i + 1);
      if (r > 170 && g < 120) count++;
    }
    return count;
  }

  Widget host(GlobalKey key, Widget child, {EffectsConfig fx = _fx}) {
    return UncontrolledProviderScope(
      container: env.container(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: J3Theme.build(fx.accent),
        home: J3Effects(
          config: fx,
          child: RepaintBoundary(
            key: key,
            child: J3Backdrop(child: child),
          ),
        ),
      ),
    );
  }

  Future<void> runSequence(
    WidgetTester tester, {
    required String prefix,
    required Size size,
    required Map<String, double> shots,
    double textScale = 1,
    EffectsConfig fx = _fx,
  }) async {
    setSurface(tester, size);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final key = GlobalKey();
    var finished = 0;
    await tester.pumpWidget(host(key, IntroScreen(onFinished: () => finished++), fx: fx));
    await tester.pump();
    var now = 0.0;
    final ordered = shots.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
    for (final shot in ordered) {
      await tester.pump(Duration(microseconds: ((shot.value - now) * 1e6).round()));
      now = shot.value;
      final image = await capture(tester, key, '${prefix}_${shot.key}');
      if (shot.key.contains('peak') || shot.key.contains('closed')) {
        expect(await brightRedPixels(tester, image), greaterThan(400), reason: '${shot.key}: skull glyphs visible');
      }
      image.dispose();
      expect(tester.takeException(), isNull);
    }
    await tester.pump(const Duration(seconds: 5));
    expect(finished, 1);
  }

  final tl = IntroTimeline();
  final laugh = tl[IntroPhase.laugh].start;
  double peak(int i) => laugh + kLaughPulses[i].peak;

  testWidgets('desktop frames', (tester) async {
    await runSequence(
      tester,
      prefix: 'desktop',
      size: const Size(1280, 800),
      shots: {
        '00_signal': tl[IntroPhase.signal].start + 0.14,
        '01_reveal': tl[IntroPhase.reveal].start + 0.33,
        '02_closed': laugh + 0.02,
        '03_peak1': peak(0),
        '04_between': laugh + 0.47,
        '05_peak2': peak(1),
        '06_peak3': peak(2),
        '07_glitch_a': tl[IntroPhase.glitch].start + 0.02,
        '08_glitch_b': tl[IntroPhase.glitch].start + 0.11,
        '09_title_mid': tl[IntroPhase.title].start + 0.2,
        '10_title': tl[IntroPhase.title].end - 0.02,
        '11_outro': tl[IntroPhase.outro].start + 0.2,
      },
    );
  });

  testWidgets('phone frames', (tester) async {
    await runSequence(
      tester,
      prefix: 'phone',
      size: const Size(390, 844),
      shots: {'02_closed': laugh + 0.02, '06_peak3': peak(2), '10_title': tl[IntroPhase.title].end - 0.02},
    );
  });

  testWidgets('small phone 2x text frames', (tester) async {
    await runSequence(
      tester,
      prefix: 'small2x',
      size: const Size(320, 568),
      textScale: 2,
      shots: {'06_peak3': peak(2), '10_title': tl[IntroPhase.title].end - 0.02},
    );
  });

  testWidgets('landscape phone frames', (tester) async {
    await runSequence(
      tester,
      prefix: 'landscape',
      size: const Size(740, 360),
      shots: {'06_peak3': peak(2), '10_title': tl[IntroPhase.title].end - 0.02},
    );
  });

  testWidgets('low-effects frames', (tester) async {
    final low = IntroTimeline(decorative: false);
    final lowLaugh = low[IntroPhase.laugh].start;
    await runSequence(
      tester,
      prefix: 'low',
      size: const Size(390, 844),
      fx: lowFx,
      shots: {
        '01_reveal': low[IntroPhase.reveal].start + 0.33,
        '06_peak3': lowLaugh + kLaughPulses[2].peak,
        '10_title': low[IntroPhase.title].end - 0.02,
      },
    );
  });

  testWidgets('reduced motion frame', (tester) async {
    setSurface(tester, const Size(390, 844));
    final key = GlobalKey();
    const fx = reducedFx;
    await tester.pumpWidget(host(key, IntroScreen(onFinished: () {}), fx: fx));
    await tester.pump();
    (await capture(tester, key, 'static_reduced_motion')).dispose();
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('laughing skull widget frames (full + mini)', (tester) async {
    setSurface(tester, const Size(640, 360));
    final key = GlobalKey();
    final controller = LaughingSkullController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        key,
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 260, height: 300, child: LaughingSkull(controller: controller)),
              const SizedBox(width: 40),
              SizedBox(width: 160, height: 160, child: LaughingSkull(mini: true, controller: controller)),
            ],
          ),
        ),
      ),
    );
    (await capture(tester, key, 'widget_closed')).dispose();
    controller.laugh();
    await tester.pump();
    await tester.pump(Duration(milliseconds: (kLaughPulses[2].peak * 1000).round()));
    (await capture(tester, key, 'widget_peak3')).dispose();
    await tester.pump(const Duration(seconds: 2));
  });
}
