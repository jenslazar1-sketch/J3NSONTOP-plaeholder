import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:j3nsontop_multitool/core/platform/file_access.dart';
import 'package:j3nsontop_multitool/core/theme/effects.dart';
import 'package:j3nsontop_multitool/features/asset_lab/asset_lab_module.dart';
import 'package:j3nsontop_multitool/features/asset_lab/data/asset_worker.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/image_codec.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';

/// RGBA test image: red/green gradient, blue 100, left third transparent,
/// middle third half transparent, right third opaque.
img.Image gradientImage(int w, int h, {bool alpha = true}) {
  final im = img.Image(width: w, height: h, numChannels: alpha ? 4 : 3);
  for (final px in im) {
    px
      ..r = (px.x * 255 ~/ (w == 1 ? 1 : w - 1))
      ..g = (px.y * 255 ~/ (h == 1 ? 1 : h - 1))
      ..b = 100;
    if (alpha) px.a = px.x < w / 3 ? 0 : (px.x < 2 * w / 3 ? 128 : 255);
  }
  return im;
}

Uint8List pngOf(img.Image im) => img.encodePng(im);

Raster rasterOf(img.Image im) => Raster.fromImage(im);

/// Sprite sheet [cols] x [rows] of [size] px frames; frame i is filled with a
/// distinct opaque colour, cells >= [filled] are fully transparent.
img.Image spriteSheet(int cols, int rows, int size, {int? filled, int margin = 0, int spacing = 0}) {
  final w = margin * 2 + cols * size + (cols - 1) * spacing;
  final h = margin * 2 + rows * size + (rows - 1) * spacing;
  final im = img.Image(width: w, height: h, numChannels: 4);
  final n = filled ?? cols * rows;
  for (var i = 0; i < n; i++) {
    final cx = margin + (i % cols) * (size + spacing);
    final cy = margin + (i ~/ cols) * (size + spacing);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        im.setPixelRgba(cx + x, cy + y, (i * 40) % 256, 255 - (i * 30) % 256, (i * 70) % 256, 255);
      }
    }
  }
  return im;
}

/// Writes [bytes] into the env's temp dir and returns a fake pick for it.
PickedLocalFile writePick(TestEnv env, String name, List<int> bytes) {
  final path = p.join(env.dir.path, 'picks', name);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  return PickedLocalFile(name: name, path: path, size: bytes.length);
}

/// Pumps [page] with the Asset Lab module, an inline worker (deterministic,
/// no isolates) and optional small-screen/large-text settings.
Future<void> pumpAssetPage(
  WidgetTester tester,
  TestEnv env,
  Widget page, {
  FakeFileAccess? files,
  Size size = const Size(1280, 1000),
  double textScale = 1,
  List<Override> extra = const [],
  EffectsConfig effects = staticEffects,
}) async {
  setSurface(tester, size);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...env.overrides(modules: [assetLabModule], fileAccess: files ?? FakeFileAccess()),
        assetWorkerProvider.overrideWithValue(const InlineAssetWorker()),
        ...extra,
      ],
      child: themed(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: page,
          ),
        ),
        effects: effects,
      ),
    ),
  );
  await tester.pump();
}

/// Lets queued futures (inline worker tasks, provider updates) complete.
Future<void> settle(WidgetTester tester, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// [testWidgets] alias used by the Asset Lab tests.
void assetWidgetTest(String description, Future<void> Function(WidgetTester tester) body) =>
    testWidgets(description, body);

/// Alternates short real-time waits (so real file IO started by the UI can
/// progress) with frames until [done] holds. Fails after [maxRounds].
Future<void> pumpUntil(WidgetTester tester, bool Function() done, {int maxRounds = 250}) async {
  for (var i = 0; i < maxRounds; i++) {
    if (done()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  if (!done()) throw TestFailure('Condition not met after $maxRounds rounds');
}

/// Scrolls [finder] into view inside the tool page and taps it.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}
