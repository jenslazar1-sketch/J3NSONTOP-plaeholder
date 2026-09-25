import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:j3nsontop_multitool/features/asset_lab/domain/color_model.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/image_codec.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/image_ops.dart';

import 'asset_test_helpers.dart';

/// 4x3 RGBA image where pixel (x, y) = (x*10, y*10, x+y, 255).
Raster coords() {
  final im = img.Image(width: 4, height: 3, numChannels: 4);
  for (final p in im) {
    p
      ..r = p.x * 10
      ..g = p.y * 10
      ..b = p.x + p.y
      ..a = 255;
  }
  return Raster.fromImage(im);
}

void main() {
  group('resize', () {
    test('produces the requested size with every interpolation', () {
      final src = rasterOf(gradientImage(40, 20));
      for (final i in ResizeInterpolation.values) {
        final out = applyPipeline(src, [ResizeOp(10, 7, i)]);
        expect((out.width, out.height), (10, 7), reason: i.name);
        expect(out.channels, 4, reason: 'alpha channel kept');
      }
    });

    test('aspect lock helper and percent scaling', () {
      expect(aspectLockedSide(200, 400, 300), 150);
      expect(aspectLockedSide(1, 1920, 1080), 1);
      expect(aspectLockedSide(99, 0, 50), 50);
      expect(scaledByPercent(const PixelSize(640, 480), 50), const PixelSize(320, 240));
      expect(scaledByPercent(const PixelSize(3, 3), 10), const PixelSize(1, 1));
    });

    test('rejects impossible sizes', () {
      const s = PixelSize(10, 10);
      expect(const ResizeOp(0, 5).validate(s), isNotNull);
      expect(const ResizeOp(maxOutputSide + 1, 5).validate(s), isNotNull);
      expect(const ResizeOp(16000, 16000).validate(s), contains('64 MP'));
      expect(const ResizeOp(100, 100).validate(s), isNull);
    });
  });

  group('crop', () {
    test('validation of bounds', () {
      const s = PixelSize(100, 50);
      expect(CropOp.check(0, 0, 100, 50, s), isNull);
      expect(CropOp.check(-1, 0, 10, 10, s), contains('negative'));
      expect(CropOp.check(0, 0, 0, 10, s), contains('at least 1'));
      expect(CropOp.check(100, 0, 1, 1, s), contains('outside'));
      expect(CropOp.check(95, 0, 10, 10, s), contains('exceeds the image width'));
      expect(CropOp.check(0, 45, 10, 10, s), contains('exceeds the image height'));
    });

    test('copies exactly the requested pixels', () {
      final out = applyPipeline(coords(), [const CropOp(1, 1, 2, 2)]);
      expect((out.width, out.height), (2, 2));
      expect(out.pixel(0, 0), const Rgba(10, 10, 2));
      expect(out.pixel(1, 0), const Rgba(20, 10, 3));
      expect(out.pixel(1, 1), const Rgba(20, 20, 4));
    });

    test('crop rect helpers clamp and fit aspect ratios', () {
      const b = PixelSize(200, 100);
      expect(const CropRect(190, 90, 50, 50).clampTo(b), const CropRect(150, 50, 50, 50));
      final sq = const CropRect(0, 0, 200, 100).fitAspect(1, b);
      expect((sq.width, sq.height), (100, 100));
      expect(sq.x, 50);
      final wide = const CropRect(0, 0, 200, 100).fitAspect(16 / 9, b);
      expect(wide.width / wide.height, closeTo(16 / 9, 0.02));
      expect(wide.right <= 200 && wide.bottom <= 100, isTrue);
    });
  });

  group('rotate and flip', () {
    test('right angles swap or keep dimensions and move pixels', () {
      final src = coords(); // 4x3
      final r90 = applyPipeline(src, [const RotateOp(90)]);
      expect((r90.width, r90.height), (3, 4));
      // 90 deg clockwise: the top-left of the result is the bottom-left source pixel.
      expect(r90.pixel(0, 0), src.pixel(0, 2));
      final r180 = applyPipeline(src, [const RotateOp(180)]);
      expect((r180.width, r180.height), (4, 3));
      expect(r180.pixel(0, 0), src.pixel(3, 2));
      final r270 = applyPipeline(src, [const RotateOp(-90)]);
      expect((r270.width, r270.height), (3, 4));
      expect(r270.pixel(0, 0), src.pixel(3, 0));
      expect(const RotateOp(450).outputSize(const PixelSize(4, 3)), const PixelSize(3, 4));
    });

    test('arbitrary angles expand the canvas with transparent corners', () {
      final src = rasterOf(gradientImage(40, 20, alpha: false));
      const op = RotateOp(30);
      final expected = op.outputSize(const PixelSize(40, 20));
      final out = applyPipeline(src, const [op]);
      expect((out.width, out.height), (expected.width, expected.height));
      expect(out.width, greaterThan(40));
      expect(out.channels, 4, reason: 'converted to RGBA for transparent corners');
      expect(out.pixel(0, 0).a, 0);
      expect(out.pixel(out.width ~/ 2, out.height ~/ 2).a, 255);
    });

    test('flip mirrors pixels', () {
      final src = coords();
      final h = applyPipeline(src, [const FlipOp(FlipAxis.horizontal)]);
      expect(h.pixel(0, 0), src.pixel(3, 0));
      expect(h.pixel(3, 2), src.pixel(0, 2));
      final v = applyPipeline(src, [const FlipOp(FlipAxis.vertical)]);
      expect(v.pixel(0, 0), src.pixel(0, 2));
      expect(v.pixel(2, 1), src.pixel(2, 1));
    });
  });

  group('pipeline', () {
    test('plan tracks sizes and stops at the first invalid step', () {
      final plan = planPipeline(const PixelSize(100, 80), [
        const ResizeOp(50, 40),
        const RotateOp(90),
        const CropOp(0, 0, 60, 10),
        const FlipOp(FlipAxis.vertical),
      ]);
      expect(plan.sizes, const [PixelSize(100, 80), PixelSize(50, 40), PixelSize(40, 50)]);
      expect(plan.errorIndex, 2);
      expect(plan.error, startsWith('Step 3:'));
      expect(plan.runnableCount, 2);
    });

    test('undo/redo/reset/move history', () {
      var h = const PipelineHistory();
      h = h.add(const ResizeOp(10, 10));
      h = h.add(const RotateOp(90));
      h = h.add(const FlipOp(FlipAxis.horizontal));
      expect(h.ops, hasLength(3));
      h = h.undo();
      expect(h.ops, const [ResizeOp(10, 10), RotateOp(90)]);
      expect(h.canRedo, isTrue);
      h = h.redo();
      expect(h.ops.last, const FlipOp(FlipAxis.horizontal));
      h = h.move(2, 0);
      expect(h.ops.first, const FlipOp(FlipAxis.horizontal));
      h = h.removeAt(1);
      expect(h.ops, const [FlipOp(FlipAxis.horizontal), RotateOp(90)]);
      h = h.reset();
      expect(h.ops, isEmpty);
      h = h.undo();
      expect(h.ops, hasLength(2), reason: 'reset is undoable');
      // A new edit clears the redo stack.
      h = h.undo().add(const RotateOp(180));
      expect(h.canRedo, isFalse);
    });

    test('ops serialise to JSON and back', () {
      const ops = [
        ResizeOp(12, 34, ResizeInterpolation.cubic),
        CropOp(1, 2, 3, 4),
        RotateOp(-7.5),
        FlipOp(FlipAxis.vertical),
      ];
      for (final op in ops) {
        expect(ImageOp.fromJson(op.toJson()), op);
      }
      expect(ImageOp.fromJson({'op': 'nope'}), isNull);
    });

    test('renderStudio encodes and reports errors separately', () {
      final src = rasterOf(gradientImage(30, 30));
      final ok = renderStudio(
        StudioRenderRequest(source: src, ops: const [ResizeOp(16, 16)], settings: const ExportSettings()),
      );
      expect((ok.width, ok.height), (16, 16));
      expect(ok.encoded, isNotNull);
      expect(img.decodePng(ok.encoded!.bytes)!.width, 16);
      final bad = renderStudio(
        StudioRenderRequest(source: src, ops: const [CropOp(0, 0, 99, 99)], settings: const ExportSettings()),
      );
      expect(bad.pipelineError, isNotNull);
      expect(bad.encoded, isNull);
      expect((bad.width, bad.height), (30, 30), reason: 'preview shows the valid prefix');
      final ico = renderStudio(
        StudioRenderRequest(
          source: rasterOf(gradientImage(300, 20)),
          ops: const [],
          settings: const ExportSettings(format: ExportFormat.ico),
        ),
      );
      expect(ico.encodeError, contains('256'));
    });
  });

  group('codec', () {
    test('PNG keeps alpha exactly', () {
      final src = rasterOf(gradientImage(21, 9));
      final enc = encodeRaster(src, const ExportSettings());
      final back = img.decodePng(enc.bytes)!;
      expect(back.numChannels, 4);
      expect(enc.flattened, isFalse);
      expect(back.getPixel(1, 1).a, 0);
      expect(back.getPixel(10, 1).a, 128);
      expect(back.getPixel(20, 1).a, 255);
      expect(Raster.fromImage(back).pixels, src.pixels);
    });

    test('JPEG flattens transparency onto the chosen colour', () {
      final im = img.Image(width: 16, height: 16, numChannels: 4); // fully transparent
      final enc = encodeRaster(
        rasterOf(im),
        const ExportSettings(format: ExportFormat.jpeg, background: Rgba(255, 0, 0)),
      );
      expect(enc.flattened, isTrue);
      expect(enc.hasAlpha, isFalse);
      final back = img.decodeJpg(enc.bytes)!;
      final p = back.getPixel(8, 8);
      expect(p.r, greaterThan(245));
      expect(p.g, lessThan(10));
      expect(p.b, lessThan(10));
      expect(back.numChannels, 3);
    });

    test('flattenOnto blends partial alpha', () {
      final im = img.Image(width: 1, height: 1, numChannels: 4)..setPixelRgba(0, 0, 255, 255, 255, 128);
      final out = flattenOnto(im, Rgba.black);
      expect(out.numChannels, 3);
      expect(out.getPixel(0, 0).r, 128);
    });

    test('every offered export format round-trips through the package decoder', () {
      final src = rasterOf(gradientImage(24, 12));
      for (final f in ExportFormat.values) {
        final enc = encodeRaster(src, ExportSettings(format: f));
        final back = img.findDecoderForData(enc.bytes)?.decode(enc.bytes);
        expect(back, isNotNull, reason: f.label);
        expect((back!.width, back.height), (24, 12), reason: f.label);
        if (f.alpha) {
          expect(back.getPixel(1, 1).a, 0, reason: '${f.label} keeps alpha');
          expect(enc.flattened, isFalse);
        } else {
          expect(enc.flattened, isTrue, reason: '${f.label} flattens');
        }
      }
      final lossy = encodeRaster(
        src,
        const ExportSettings(format: ExportFormat.webp, webpLossless: false, quality: 40),
      );
      expect(img.decodeWebP(lossy.bytes)!.width, 24);
    });

    test('decodeImageFile reports metadata and refuses junk', () {
      final bytes = Uint8List.fromList(img.encodeGif(gradientImage(12, 8, alpha: false)));
      final d = decodeImageFile(bytes, 'anim.gif');
      expect(d.metadata.formatName, 'GIF');
      expect(d.metadata.width, 12);
      expect(d.metadata.indexed, isTrue);
      expect(d.metadata.frameCount, 1);
      expect(d.metadata.fileSize, bytes.length);
      expect(img.decodePng(d.previewPng)!.width, 12);

      final big = decodeImageFile(pngOf(gradientImage(400, 100)), 'big.png', previewMax: 100);
      expect(big.previewScale, closeTo(0.25, 0.001));
      expect(img.decodePng(big.previewPng)!.width, 100);
      expect(big.raster.width, 400, reason: 'raster stays full size');

      expect(() => decodeImageFile(Uint8List.fromList([1, 2, 3, 4, 5]), 'x.png'), throwsA(isA<ImageDecodeException>()));
      expect(() => decodeImageFile(Uint8List(0), 'x.png'), throwsA(isA<ImageDecodeException>()));
      final truncated = Uint8List.sublistView(pngOf(gradientImage(50, 50)), 0, 60);
      expect(() => decodeImageFile(truncated, 'cut.png'), throwsA(isA<ImageDecodeException>()));
    });

    test('EXIF is summarised, orientation applied, and not exported', () {
      final im = gradientImage(20, 10, alpha: false);
      im.exif.imageIfd['Make'] = 'J3Cam';
      im.exif.imageIfd['Model'] = 'Neon 1';
      im.exif.imageIfd['Orientation'] = 6; // rotate 90 CW to display upright
      final jpg = img.encodeJpg(im, quality: 95);
      final d = decodeImageFile(jpg, 'photo.jpg');
      expect(d.metadata.exif, containsAll([('Camera make', 'J3Cam'), ('Camera model', 'Neon 1')]));
      expect((d.raster.width, d.raster.height), (10, 20), reason: 'baked upright');
      expect(d.metadata.notes.any((n) => n.contains('orientation 6')), isTrue);
      expect(d.metadata.notes.any((n) => n.contains('not copied into exports')), isTrue);
      final out = encodeRaster(d.raster, const ExportSettings(format: ExportFormat.jpeg));
      final back = img.decodeJpg(out.bytes)!;
      expect(back.exif.isEmpty, isTrue, reason: 'no EXIF (camera, GPS...) copied into exports');
      expect(back.exif.imageIfd.hasMake, isFalse);
    });

    test('multi-frame sources report frames; TGA is recognised by extension only', () {
      final anim = img.Image(width: 6, height: 6)..addFrame(img.Image(width: 6, height: 6));
      final d = decodeImageFile(img.encodeGif(anim), 'anim.gif');
      expect(d.metadata.frameCount, 2);
      expect(d.metadata.notes.first, contains('only the first frame'));

      final tga = img.encodeTga(gradientImage(8, 4));
      final t = decodeImageFile(tga, 'tile.tga');
      expect(t.metadata.formatName, 'TGA');
      expect(t.raster.pixel(7, 0).a, 255);
      expect(() => decodeImageFile(tga, 'tile.bin'), throwsA(isA<ImageDecodeException>()));

      final ico = img.IcoEncoder().encodeImages([img.Image(width: 16, height: 16), img.Image(width: 48, height: 48)]);
      final i = decodeImageFile(ico, 'app.ico');
      expect(i.raster.width, 48, reason: 'largest entry');
      expect(i.metadata.notes.first, contains('largest'));
    });

    test('file name helpers', () {
      expect(editedFileName('hero.png', 'jpg'), 'hero_edited.jpg');
      expect(editedFileName('archive.tar.gz', 'png'), 'archive.tar_edited.png');
      expect(editedFileName('.hidden', 'png'), '.hidden_edited.png');
      expect(fileStem('sprites/items/potion.png'), 'potion');
      expect(fileStem(r'C:\x\y.tga'), 'y');
    });
  });
}
