import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/atlas_packer.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/image_codec.dart';

List<AtlasInput> randomInputs(int seed, int count, {int maxSide = 64}) {
  final rnd = math.Random(seed);
  return [
    for (var i = 0; i < count; i++)
      AtlasInput('s${i.toString().padLeft(3, '0')}', 1 + rnd.nextInt(maxSide), 1 + rnd.nextInt(maxSide)),
  ];
}

Raster solid(int w, int h, int r, int g, int b, [int a = 255]) {
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < px.length; i += 4) {
    px[i] = r;
    px[i + 1] = g;
    px[i + 2] = b;
    px[i + 3] = a;
  }
  return Raster(w, h, 4, px);
}

void main() {
  group('packing property test', () {
    for (final (seed, count, pad, extrude, pot) in const [
      (1, 300, 2, 0, false),
      (2, 250, 0, 0, false),
      (3, 200, 1, 1, true),
      (4, 400, 4, 1, false),
      (5, 150, 0, 1, true),
    ]) {
      test('seed $seed: $count random sprites, padding $pad, extrude $extrude, pot $pot', () {
        final inputs = randomInputs(seed, count);
        final options = AtlasOptions(padding: pad, extrude: extrude, maxSize: 4096, powerOfTwo: pot);
        final layout = packAtlas(inputs, options);
        final v = validateLayout(layout);
        expect(v.issues, isEmpty);
        expect(v.frameCount, count);
        expect(layout.frames.map((f) => f.name).toSet(), inputs.map((i) => i.name).toSet());
        if (pot) expect(isPowerOfTwo(layout.width) && isPowerOfTwo(layout.height), isTrue);
        // Sizes are preserved and not rotated.
        final byName = {for (final i in inputs) i.name: i};
        for (final f in layout.frames) {
          expect((f.w, f.h), (byName[f.name]!.width, byName[f.name]!.height));
          expect((f.sourceW, f.sourceH), (f.w, f.h));
        }
        // Reasonably tight: the reserved boxes (sprite + extrusion + padding)
        // fill most of the atlas; power-of-two rounding may double the area.
        final boxArea = inputs.fold<int>(
          0,
          (s, i) => s + (i.width + 2 * extrude + pad) * (i.height + 2 * extrude + pad),
        );
        expect(boxArea / (layout.width * layout.height), greaterThan(pot ? 0.4 : 0.75));
        // Deterministic: packing again gives identical JSON.
        expect(atlasJson(packAtlas(inputs, options), 'a.png'), atlasJson(layout, 'a.png'));
      });
    }

    test('a brute-force pairwise check agrees with the sweep validator', () {
      final layout = packAtlas(randomInputs(9, 120, maxSide: 40), const AtlasOptions(padding: 3, extrude: 1));
      final e = layout.extrude, p = layout.padding;
      for (var i = 0; i < layout.frames.length; i++) {
        final a = layout.frames[i];
        expect(a.x - e >= p && a.y - e >= p, isTrue);
        expect(a.x + a.w + e + p <= layout.width && a.y + a.h + e + p <= layout.height, isTrue);
        for (var j = i + 1; j < layout.frames.length; j++) {
          final b = layout.frames[j];
          final overlapX = a.x - e < b.x + b.w + e + p && b.x - e < a.x + a.w + e + p;
          final overlapY = a.y - e < b.y + b.h + e + p && b.y - e < a.y + a.h + e + p;
          expect(overlapX && overlapY, isFalse, reason: '${a.name} vs ${b.name}');
        }
      }
    });
  });

  group('validator', () {
    test('catches overlaps, padding violations and out-of-bounds frames', () {
      const good = [
        AtlasFrame(name: 'a', x: 2, y: 2, w: 10, h: 10, sourceW: 10, sourceH: 10),
        AtlasFrame(name: 'b', x: 14, y: 2, w: 10, h: 10, sourceW: 10, sourceH: 10),
      ];
      expect(validateAtlas(width: 26, height: 14, padding: 2, extrude: 0, frames: good).ok, isTrue);
      final tooClose = validateAtlas(width: 26, height: 14, padding: 3, extrude: 0, frames: good);
      expect(tooClose.ok, isFalse);
      expect(tooClose.issues.any((i) => i.contains('overlap')), isTrue);
      final outside = validateAtlas(width: 20, height: 14, padding: 2, extrude: 0, frames: good);
      expect(outside.issues.single, contains('"b"'));
      final dup = validateAtlas(
        width: 100,
        height: 100,
        padding: 0,
        extrude: 0,
        frames: const [
          AtlasFrame(name: 'a', x: 0, y: 0, w: 1, h: 1, sourceW: 1, sourceH: 1),
          AtlasFrame(name: 'a', x: 5, y: 5, w: 1, h: 1, sourceW: 1, sourceH: 1),
        ],
      );
      expect(dup.issues.single, contains('Duplicate'));
    });
  });

  group('errors', () {
    test('sprites that cannot fit report the size they need and the largest sprite', () {
      final inputs = [for (var i = 0; i < 20; i++) AtlasInput('big$i', 200, 200)];
      expect(
        () => packAtlas(inputs, const AtlasOptions(padding: 0, maxSize: 256)),
        throwsA(
          isA<AtlasDoesNotFit>()
              .having((e) => e.neededWidth, 'neededWidth', isNotNull)
              .having((e) => e.largestSize, 'largest', (200, 200))
              .having(
                (e) => e.message,
                'message',
                allOf(contains('do not fit in 256x256'), contains('Largest sprite')),
              ),
        ),
      );
    });

    test('a single sprite larger than the maximum is named', () {
      expect(
        () =>
            packAtlas(const [AtlasInput('small', 4, 4), AtlasInput('huge', 300, 10)], const AtlasOptions(maxSize: 256)),
        throwsA(isA<AtlasDoesNotFit>().having((e) => e.message, 'm', allOf(contains('"huge"'), contains('256')))),
      );
    });

    test('invalid input', () {
      expect(() => packAtlas(const [], const AtlasOptions()), throwsA(isA<AtlasInputException>()));
      expect(
        () => packAtlas(const [AtlasInput('a', 1, 1), AtlasInput('a', 2, 2)], const AtlasOptions()),
        throwsA(isA<AtlasInputException>().having((e) => e.message, 'm', contains('Duplicate'))),
      );
      expect(() => packAtlas(const [AtlasInput('', 1, 1)], const AtlasOptions()), throwsA(isA<AtlasInputException>()));
      expect(
        () => packAtlas(const [AtlasInput('a', 1, 1)], const AtlasOptions(extrude: 2)),
        throwsA(isA<AtlasInputException>()),
      );
    });
  });

  group('format', () {
    test('JSON follows the j3atlas v1 layout and parses back', () {
      final layout = packAtlas(const [
        AtlasInput('hero', 32, 32),
        AtlasInput('coin', 8, 8),
      ], const AtlasOptions(padding: 2));
      final text = atlasJson(layout, 'sprites.png');
      final j = jsonDecode(text) as Map<String, dynamic>;
      final meta = j['meta'] as Map<String, dynamic>;
      expect(meta['app'], 'J3NSONTOP Multitool');
      expect(meta['format'], 'j3atlas');
      expect(meta['version'], 1);
      expect(meta['image'], 'sprites.png');
      expect(meta['size'], {'w': layout.width, 'h': layout.height});
      expect(meta['padding'], 2);
      final frames = j['frames'] as Map<String, dynamic>;
      expect(frames.keys, ['coin', 'hero'], reason: 'sorted by name');
      expect((frames['hero'] as Map).keys, ['x', 'y', 'w', 'h', 'sourceW', 'sourceH']);
      final (w, h, pad, ex, parsed) = parseAtlasJson(text);
      expect((w, h, pad, ex), (layout.width, layout.height, 2, 0));
      expect(validateAtlas(width: w, height: h, padding: pad, extrude: ex, frames: parsed).ok, isTrue);
      expect(() => parseAtlasJson('{"meta":{"format":"other"}}'), throwsFormatException);
    });

    test('composition copies pixels and extrudes edges', () {
      final layout = packAtlas(const [
        AtlasInput('red', 3, 2),
        AtlasInput('blue', 2, 2),
      ], const AtlasOptions(padding: 1, extrude: 1));
      final atlas = composeAtlas(layout, {'red': solid(3, 2, 255, 0, 0), 'blue': solid(2, 2, 0, 0, 255)});
      final red = layout.frames.firstWhere((f) => f.name == 'red');
      expect(atlas.pixel(red.x, red.y).r, 255);
      expect(atlas.pixel(red.x - 1, red.y - 1).r, 255, reason: 'corner extruded');
      expect(atlas.pixel(red.x + red.w, red.y + red.h - 1).r, 255, reason: 'right edge extruded');
      // Padding outside the extrusion stays transparent.
      expect(atlas.pixel(red.x - 2, red.y).a, 0);
      final blue = layout.frames.firstWhere((f) => f.name == 'blue');
      expect(atlas.pixel(blue.x + 1, blue.y + 1).b, 255);
    });

    test('power-of-two helpers', () {
      expect(nextPowerOfTwo(1), 1);
      expect(nextPowerOfTwo(257), 512);
      expect(isPowerOfTwo(1024), isTrue);
      expect(isPowerOfTwo(1000), isFalse);
    });
  });
}
