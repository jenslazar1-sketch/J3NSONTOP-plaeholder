import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:j3nsontop_multitool/features/asset_lab/domain/color_model.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/image_codec.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/sprite_sheet.dart';
import 'package:j3nsontop_multitool/features/asset_lab/presentation/sprite_sheet/sprite_controller.dart';

import 'asset_test_helpers.dart';

void main() {
  group('grid math', () {
    test('frame size derives columns and rows (sample hero sheet 128x64, 32px)', () {
      final g = resolveGrid(const GridSpec(frameWidth: 32, frameHeight: 32), 128, 64);
      expect((g.columns, g.rows, g.frameCount), (4, 2, 8));
      expect(g.frame(0), const FrameRect(0, 0, 0, 32, 32));
      expect(g.frame(5), const FrameRect(5, 32, 32, 32, 32));
      expect(g.warnings, isEmpty);
    });

    test('margin and spacing', () {
      // 2px margin, 1px spacing, 3 x 2 frames of 10px => 2+10+1+10+1+10+2 = 36 wide.
      final g = resolveGrid(const GridSpec(frameWidth: 10, frameHeight: 10, margin: 2, spacing: 1), 36, 25);
      expect((g.columns, g.rows), (3, 2));
      expect(g.frame(4), const FrameRect(4, 13, 13, 10, 10));
      expect(g.usedWidth, 34);
    });

    test('columns x rows derives the frame size and warns about leftovers', () {
      final g = resolveGrid(const GridSpec(mode: GridMode.columnsRows, columns: 4, rows: 2), 128, 64);
      expect((g.frameWidth, g.frameHeight), (32, 32));
      final uneven = resolveGrid(const GridSpec(mode: GridMode.columnsRows, columns: 3, rows: 1), 100, 20);
      expect(uneven.frameWidth, 33);
      expect(uneven.warnings.single, contains('1 px unused on the right'));
    });

    test('grid exceeding the sheet gives a precise error', () {
      expect(
        () => resolveGrid(const GridSpec(frameWidth: 32, frameHeight: 32, columns: 5), 128, 64),
        throwsA(
          isA<GridException>().having(
            (e) => e.message,
            'message',
            allOf(contains('160x64'), contains('exceed the width by 32 px')),
          ),
        ),
      );
      expect(
        () => resolveGrid(const GridSpec(frameWidth: 200, frameHeight: 10), 128, 64),
        throwsA(isA<GridException>().having((e) => e.message, 'message', contains('does not fit'))),
      );
      expect(
        () => resolveGrid(const GridSpec(mode: GridMode.columnsRows, columns: 200, rows: 1), 128, 64),
        throwsA(isA<GridException>()),
      );
      expect(() => resolveGrid(const GridSpec(frameWidth: 0, frameHeight: 5), 10, 10), throwsA(isA<GridException>()));
      expect(() => resolveGrid(const GridSpec(margin: -1), 64, 64), throwsA(isA<GridException>()));
    });

    test('frame count can exclude trailing cells but not exceed the grid', () {
      final g = resolveGrid(const GridSpec(frameWidth: 32, frameHeight: 32, frameCount: 6), 128, 64);
      expect(g.frameCount, 6);
      expect(g.frames, hasLength(6));
      expect(
        () => resolveGrid(const GridSpec(frameWidth: 32, frameHeight: 32, frameCount: 9), 128, 64),
        throwsA(isA<GridException>().having((e) => e.message, 'm', contains('larger than the 8 cells'))),
      );
    });

    test('default guess prefers 32px tiles', () {
      final g = guessGrid(128, 64);
      expect((g.frameWidth, g.frameHeight), (32, 32));
      final strip = guessGrid(300, 60);
      expect((strip.frameWidth, strip.frameHeight), (60, 60));
    });
  });

  group('naming and slicing', () {
    test('predictable zero-padded names', () {
      expect(frameFileNames('hero_walk', 3), ['hero_walk_000.png', 'hero_walk_001.png', 'hero_walk_002.png']);
      final many = frameFileNames('x', 1200);
      expect(many.first, 'x_0000.png');
      expect(many.last, 'x_1199.png');
      expect(frameFileNames('bad/na:me ', 1).single, 'bad_na_me_000.png');
      expect(frameFileNames('   ', 1).single, 'frame_000.png');
    });

    test('slices exact pixels and trims empty trailing cells', () {
      final sheet = rasterOf(spriteSheet(4, 2, 8, filled: 6, margin: 1, spacing: 2));
      final grid = resolveGrid(
        const GridSpec(frameWidth: 8, frameHeight: 8, margin: 1, spacing: 2),
        sheet.width,
        sheet.height,
      );
      expect(grid.frameCount, 8);
      expect(isFrameEmpty(sheet, grid.frame(6)), isTrue);
      expect(isFrameEmpty(sheet, grid.frame(5)), isFalse);
      expect(countWithoutTrailingEmpty(sheet, grid), 6);

      final files = sliceFramesToPng(sheet, grid, 'hero');
      expect(files.map((f) => f.$1).take(2), ['hero_000.png', 'hero_001.png']);
      final f3 = img.decodePng(files[3].$2)!;
      expect((f3.width, f3.height), (8, 8));
      final expected = const Rgba((3 * 40) % 256, 255 - (3 * 30) % 256, (3 * 70) % 256);
      final px = f3.getPixel(4, 4);
      expect(Rgba(px.r.toInt(), px.g.toInt(), px.b.toInt(), px.a.toInt()), expected);
      expect(cropFrame(sheet, grid.frame(3)).pixel(0, 0), expected);
    });

    test('animated GIF has one frame per sprite with the FPS delay and exact colours', () {
      final sheet = rasterOf(spriteSheet(3, 1, 6));
      final grid = resolveGrid(const GridSpec(frameWidth: 6, frameHeight: 6), sheet.width, sheet.height);
      final gif = encodeFramesGif(sheet, grid, fps: 10, background: Rgba.black);
      final decoded = img.decodeGif(gif)!;
      expect(decoded.numFrames, 3);
      expect(decoded.width, 6);
      expect(decoded.frames.first.frameDuration, 100, reason: '10 fps = 10/100 s = 100 ms');
      final p = decoded.frames[1].getPixel(2, 2);
      expect((p.r, p.g, p.b), (40, 225, 70));
      expect(gifDelayForFps(60), 2);
      expect(gifDelayForFps(1), 100);
    });

    test('RGB sheets are never empty', () {
      final sheet = Raster.fromImage(img.Image(width: 8, height: 8));
      final grid = resolveGrid(const GridSpec(frameWidth: 4, frameHeight: 4), 8, 8);
      expect(countWithoutTrailingEmpty(sheet, grid), 4);
    });
  });
}
