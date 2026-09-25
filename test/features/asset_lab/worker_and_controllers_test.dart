import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:j3nsontop_multitool/core/archive/safe_zip.dart';
import 'package:j3nsontop_multitool/core/storage/user_data.dart';
import 'package:j3nsontop_multitool/core/widgets/io_flows.dart';
import 'package:j3nsontop_multitool/features/asset_lab/asset_lab_module.dart';
import 'package:j3nsontop_multitool/features/asset_lab/data/asset_worker.dart';
import 'package:j3nsontop_multitool/features/asset_lab/data/palette_store.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/atlas_packer.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/color_model.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/icon_export.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/image_codec.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/image_ops.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/palette.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/sprite_sheet.dart';
import 'package:j3nsontop_multitool/features/asset_lab/presentation/atlas_packer/atlas_controller.dart';
import 'package:j3nsontop_multitool/features/asset_lab/presentation/color_lab/color_controller.dart';
import 'package:j3nsontop_multitool/features/asset_lab/presentation/icon_export/icon_controller.dart';
import 'package:j3nsontop_multitool/features/asset_lab/presentation/image_studio/studio_controller.dart';
import 'package:j3nsontop_multitool/features/asset_lab/presentation/sprite_sheet/sprite_controller.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';
import 'asset_test_helpers.dart';

Future<void> waitFor(bool Function() done, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late TestEnv env;
  late ProviderContainer c;

  setUp(() async {
    env = await TestEnv.create();
    c = env.container(modules: [assetLabModule]);
  });

  tearDown(() async {
    c.dispose();
    await env.dispose();
  });

  SelectedInput input(String name, List<int> bytes) {
    final pick = writePick(env, name, bytes);
    return SelectedInput(path: pick.path, displayName: name, fromWorkspace: false);
  }

  group('isolate worker', () {
    test('uses isolates on desktop and runs sendable tasks', () async {
      expect(c.read(assetWorkerProvider), isA<IsolateAssetWorker>());
      final pick = writePick(env, 'g.png', pngOf(gradientImage(20, 10)));
      final decoded = await const IsolateAssetWorker().run(decodeFileTask(pick.path, 'g.png'));
      expect(decoded.metadata.width, 20);
      final sheet = rasterOf(spriteSheet(2, 1, 4));
      final grid = resolveGrid(const GridSpec(frameWidth: 4, frameHeight: 4), sheet.width, sheet.height);
      final files = await const IsolateAssetWorker().run(sliceTask(sheet, grid, 'f'));
      expect(files.map((f) => f.$1), ['f_000.png', 'f_001.png']);
      final gif = await const IsolateAssetWorker().run(gifTask(sheet, grid, 12, Rgba.black));
      expect(img.decodeGif(gif)!.numFrames, 2);
    });

    test('errors from the isolate keep their message', () async {
      final pick = writePick(env, 'junk.png', utf8.encode('definitely not a png'));
      await expectLater(
        const IsolateAssetWorker().run(decodeFileTask(pick.path, 'junk.png')),
        throwsA(predicate((e) => e.toString().contains('not an image format'))),
      );
    });

    test('writeNewFilesTask never overwrites and stays inside the root', () async {
      final root = p.join(env.dir.path, 'ws');
      final folder = p.join(root, 'out');
      Directory(folder).createSync(recursive: true);
      File(p.join(folder, 'a.png')).writeAsStringSync('original');
      final written = await const IsolateAssetWorker().run(
        writeNewFilesTask(root, folder, [('a.png', utf8.encode('new')), ('sub/b.png', utf8.encode('b'))]),
      );
      expect(File(p.join(folder, 'a.png')).readAsStringSync(), 'original');
      expect(p.basename(written[0]), 'a (2).png');
      expect(File(written[0]).readAsStringSync(), 'new');
      expect(File(p.join(folder, 'sub', 'b.png')).existsSync(), isTrue);
      await expectLater(
        const InlineAssetWorker().run(writeNewFilesTask(root, env.dir.path, [('x.png', utf8.encode('x'))])),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        const InlineAssetWorker().run(writeNewFilesTask(root, folder, [('../escape.png', utf8.encode('x'))])),
        throwsA(anything),
      );
    });

    test('buildZipTask creates a safe ZIP with SafeZip', () async {
      final staging = p.join(env.dir.path, 'staging');
      final zip = await const IsolateAssetWorker().run(
        buildZipTask(staging, [('a.png', pngOf(gradientImage(4, 4))), ('dir/b.json', utf8.encode('{}'))]),
      );
      final path = p.join(env.dir.path, 'out.zip');
      File(path).writeAsBytesSync(zip);
      final inspection = SafeZip.inspect(path);
      expect(inspection.isSafe, isTrue);
      expect(inspection.files.map((e) => e.path), ['a.png', 'dir/b.json']);
      expect(SafeZip.readText(path, 'dir/b.json'), '{}');
      expect(Directory(staging).listSync(), isEmpty, reason: 'staging cleaned up');
    });

    test('listImagesTask finds supported images only', () async {
      final dir = Directory(p.join(env.dir.path, 'imgs'))..createSync();
      File(p.join(dir.path, 'b.PNG')).writeAsBytesSync(pngOf(gradientImage(2, 2)));
      File(p.join(dir.path, 'a.tga')).writeAsBytesSync(img.encodeTga(gradientImage(2, 2)));
      File(p.join(dir.path, 'notes.txt')).writeAsStringSync('x');
      final found = await const InlineAssetWorker().run(listImagesTask(dir.path));
      expect(found.map(p.basename), ['a.tga', 'b.PNG']);
    });

    test('saveAtlasTask keeps PNG and JSON names in sync when a name is taken', () async {
      final root = p.join(env.dir.path, 'ws2');
      Directory(root).createSync();
      File(p.join(root, 'atlas.png')).writeAsStringSync('keep me');
      final layout = packAtlas(const [AtlasInput('a', 4, 4)], const AtlasOptions());
      final paths = await const IsolateAssetWorker().run(
        saveAtlasTask(root, root, 'atlas', pngOf(gradientImage(8, 8)), layout),
      );
      expect(p.basename(paths[0]), 'atlas (2).png');
      expect(p.basename(paths[1]), 'atlas (2).json');
      final json = jsonDecode(File(paths[1]).readAsStringSync()) as Map<String, dynamic>;
      expect((json['meta'] as Map)['image'], 'atlas (2).png');
      expect(File(p.join(root, 'atlas.png')).readAsStringSync(), 'keep me');
    });
  });

  group('controllers (real isolates)', () {
    test('image studio: open, edit, re-encode, undo', () async {
      final ctrl = c.read(studioProvider.notifier);
      await ctrl.open(input('hero.png', pngOf(gradientImage(64, 32))));
      await waitFor(() => c.read(studioProvider).output != null && !c.read(studioProvider).rendering);
      var s = c.read(studioProvider);
      expect(s.source!.decoded.metadata.formatName, 'PNG');
      expect(s.outputName, 'hero_edited.png');
      expect(s.output!.encoded, isNotNull);

      ctrl.addOp(const ResizeOp(32, 16));
      await waitFor(() => !c.read(studioProvider).rendering && c.read(studioProvider).output!.render.width == 32);
      ctrl.addOp(const RotateOp(90));
      await waitFor(() => !c.read(studioProvider).rendering && c.read(studioProvider).output!.render.width == 16);
      s = c.read(studioProvider);
      expect((s.output!.encoded!.width, s.output!.encoded!.height), (16, 32));

      ctrl.setExport(s.export.copyWith(format: ExportFormat.jpeg, background: const Rgba(0, 0, 0)));
      await waitFor(() => !c.read(studioProvider).rendering);
      s = c.read(studioProvider);
      expect(s.outputName, 'hero_edited.jpg');
      expect(s.output!.encoded!.flattened, isTrue);
      expect(img.decodeJpg(s.output!.encoded!.bytes)!.width, 16);

      ctrl.undo();
      await waitFor(() => !c.read(studioProvider).rendering && c.read(studioProvider).output!.render.width == 32);
      expect(c.read(studioProvider).history.ops, const [ResizeOp(32, 16)]);
    });

    test('image studio: unreadable file shows a load error', () async {
      await c.read(studioProvider.notifier).open(input('bad.png', utf8.encode('nope')));
      final s = c.read(studioProvider);
      expect(s.source, isNull);
      expect(s.loadError.toString(), contains('not an image format'));
    });

    test('sprite sheet: open, guess grid, trim', () async {
      final ctrl = c.read(spriteProvider.notifier);
      await ctrl.open(input('hero_walk.png', pngOf(spriteSheet(4, 2, 32, filled: 7))));
      final s = c.read(spriteProvider);
      expect(s.baseName, 'hero_walk');
      expect(s.grid.$1!.frameCount, 8);
      expect(await ctrl.trimTrailingEmpty(), 7);
      expect(c.read(spriteProvider).grid.$1!.frameCount, 7);
    });

    test('atlas: add files, reject duplicates, pack and validate', () async {
      final ctrl = c.read(atlasProvider.notifier);
      final a = input('coin.png', pngOf(gradientImage(8, 8)));
      final b = input('gem.png', pngOf(gradientImage(12, 6)));
      await ctrl.addFiles([(a.path, 'coin.png'), (b.path, 'gem.png')]);
      await ctrl.addFiles([(a.path, 'coin.png')]);
      var s = c.read(atlasProvider);
      expect(s.sprites.map((x) => x.name), ['coin', 'gem']);
      expect(s.importNotes.single, contains('already used'));
      expect(ctrl.rename(s.sprites[0].id, 'gem'), contains('already'));
      expect(ctrl.rename(s.sprites[0].id, 'gold'), isNull);
      await ctrl.pack();
      s = c.read(atlasProvider);
      expect(s.packError, isNull);
      expect(s.result!.validation.ok, isTrue);
      expect(s.result!.layout.frames.map((f) => f.name), ['gem', 'gold']);
      expect(img.decodePng(s.result!.png)!.width, s.result!.layout.width);
      expect(s.isStale, isFalse);
      ctrl.setOptions(s.options.copyWith(padding: 5));
      expect(c.read(atlasProvider).isStale, isTrue);
    });

    test('atlas: sprites that cannot fit produce an error, not a result', () async {
      final ctrl = c.read(atlasProvider.notifier);
      final big = input('big.png', pngOf(gradientImage(300, 300, alpha: false)));
      await ctrl.addFiles([(big.path, 'big.png')]);
      ctrl.setOptions(const AtlasOptions(maxSize: 256));
      await ctrl.pack();
      final s = c.read(atlasProvider);
      expect(s.result, isNull);
      expect(s.packError.toString(), contains('"big"'));
    });

    test('icon export: generate and verify', () async {
      final ctrl = c.read(iconExportProvider.notifier);
      await ctrl.open(input('icon.png', pngOf(gradientImage(128, 128))));
      ctrl.setOptions(const IconExportOptions(ios: false));
      await ctrl.generate();
      final s = c.read(iconExportProvider);
      expect(s.error, isNull);
      expect(s.run!.allPassed, isTrue);
      expect(s.run!.result.files.any((f) => f.path == windowsIconPath), isTrue);
      expect(s.run!.result.files.any((f) => f.group == 'iOS'), isFalse);
    });

    test('color lab: eyedropper and palette persistence', () async {
      final lab = c.read(colorLabProvider.notifier);
      expect(c.read(colorLabProvider).color, const Rgba(255, 22, 59));
      await lab.openImage(input('pick.png', pngOf(gradientImage(30, 10))));
      final picked = lab.pick(25, 5);
      expect(picked, isNotNull);
      expect(c.read(colorLabProvider).color, picked);
      expect(lab.pick(99, 0), isNull);
      lab.setColor(Rgba.black);
      expect(c.read(colorLabProvider).hsv.h, closeTo(ColorMath.toHsv(picked!).h, 0.5), reason: 'hue kept for black');

      final pal = c.read(paletteProvider.notifier);
      final id = pal.add(const Rgba(255, 22, 59), name: 'Neon');
      pal.add(const Rgba(5, 5, 7));
      pal.rename(id, 'Brand red');
      pal.move(1, 0);
      final stored = PaletteDocument.fromJson(c.read(featureDataProvider)[PaletteDocument.storageKey]);
      expect(stored.swatches.map((s) => s.name), ['#050507', 'Brand red']);
      expect((c.read(featureDataProvider)[PaletteDocument.storageKey] as Map)['v'], 1);
      pal.remove(id);
      expect(c.read(paletteProvider).swatches, hasLength(1));
    });
  });
}
