import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:j3nsontop_multitool/features/asset_lab/domain/color_model.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/icon_export.dart';

import 'asset_test_helpers.dart';

void main() {
  late IconExportResult all;

  setUpAll(() {
    // Transparent-cornered 256px artwork so alpha handling is exercised.
    final art = img.Image(width: 256, height: 256, numChannels: 4);
    img.fillCircle(art, x: 128, y: 128, radius: 100, color: img.ColorRgba8(255, 22, 59, 255));
    all = generateAppIcons(pngOf(art), const IconExportOptions(background: Rgba(5, 5, 7)), sourceName: 'art.png');
  });

  IconFile file(String suffix) => all.files.firstWhere((f) => f.path.endsWith(suffix));

  test('produces every expected path', () {
    final paths = all.files.map((f) => f.path).toSet();
    for (final d in androidLegacySizes.keys) {
      expect(paths, contains('$androidResDir/mipmap-$d/ic_launcher.png'));
      expect(paths, contains('$androidResDir/mipmap-$d/ic_launcher_foreground.png'));
    }
    expect(paths, contains('$androidResDir/mipmap-anydpi-v26/ic_launcher.xml'));
    expect(paths, contains('$androidResDir/values/ic_launcher_background.xml'));
    expect(paths, contains(playIconPath));
    expect(paths, contains(windowsIconPath));
    expect(paths, contains('$iosIconSetDir/Contents.json'));
    // 19 catalog slots; iPhone and iPad share 4 files (as in Flutter's template).
    final uniqueIos = iosIconSlots.map((s) => s.fileName).toSet();
    expect(uniqueIos, hasLength(15));
    expect(paths.where((x) => x.startsWith(iosIconSetDir) && x.endsWith('.png')), hasLength(15));
    expect(all.files, hasLength(5 + 5 + 2 + 1 + 15 + 1 + 1));
    expect(all.files.map((f) => f.path).toSet(), hasLength(all.files.length), reason: 'no duplicate paths');
  });

  test('icon sizes are right', () {
    androidLegacySizes.forEach((d, s) {
      expect(img.decodePng(file('mipmap-$d/ic_launcher.png').bytes)!.width, s);
    });
    androidAdaptiveSizes.forEach((d, s) {
      expect(img.decodePng(file('mipmap-$d/ic_launcher_foreground.png').bytes)!.width, s);
    });
    expect(img.decodePng(file(playIconPath).bytes)!.width, 512);
    for (final slot in iosIconSlots) {
      final png = img.decodePng(file(slot.fileName).bytes)!;
      expect((png.width, png.height), (slot.pixels, slot.pixels), reason: slot.fileName);
    }
    expect(
      iosIconSlots.map((s) => s.pixels).toSet(),
      containsAll([20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180, 1024]),
    );
  });

  test('adaptive foreground keeps the artwork inside the 72dp safe zone', () {
    final fg = img.decodePng(file('mipmap-xxxhdpi/ic_launcher_foreground.png').bytes)!;
    expect(fg.width, 432);
    // Outside the centred 288px safe square everything is transparent.
    expect(fg.getPixel(10, 10).a, 0);
    expect(fg.getPixel(71, 216).a, 0);
    expect(fg.getPixel(216, 216).a, 255, reason: 'artwork centre');
  });

  test('ICO contains all 7 sizes', () {
    final ico = file(windowsIconPath).bytes;
    final dir = readIcoDirectory(ico);
    expect(dir.map((e) => e.$1), windowsIcoSizes);
    final decoder = img.IcoDecoder()..startDecode(ico);
    for (var i = 0; i < dir.length; i++) {
      expect(decoder.decodeFrame(i)!.width, windowsIcoSizes[i]);
    }
  });

  test('iOS icons have no alpha channel; Play icon is 32-bit opaque', () {
    for (final slot in iosIconSlots) {
      final png = img.decodePng(file(slot.fileName).bytes)!;
      expect(png.numChannels, 3, reason: slot.fileName);
    }
    final corner = img.decodePng(file('Icon-App-1024x1024@1x.png').bytes)!.getPixel(0, 0);
    expect((corner.r, corner.g, corner.b), (5, 5, 7), reason: 'transparent corners flattened onto background');
    final play = img.decodePng(file(playIconPath).bytes)!;
    expect(play.numChannels, 4);
    expect(play.getPixel(0, 0).a, 255);
  });

  test('XML resources and Contents.json', () {
    final bg = utf8.decode(file('values/ic_launcher_background.xml').bytes);
    expect(bg, contains('<color name="ic_launcher_background">#050507</color>'));
    final adaptive = utf8.decode(file('mipmap-anydpi-v26/ic_launcher.xml').bytes);
    expect(adaptive, contains('@mipmap/ic_launcher_foreground'));
    final contents = jsonDecode(utf8.decode(file('Contents.json').bytes)) as Map<String, dynamic>;
    final images = contents['images'] as List;
    expect(images, hasLength(iosIconSlots.length));
    expect(images.last, {
      'size': '1024x1024',
      'idiom': 'ios-marketing',
      'filename': 'Icon-App-1024x1024@1x.png',
      'scale': '1x',
    });
    expect(images.any((e) => (e as Map)['size'] == '83.5x83.5' && e['scale'] == '2x'), isTrue);
  });

  test('verification passes for generated output', () {
    final checks = verifyAppIcons(all.files);
    expect(checks, hasLength(all.files.length));
    expect(checks.where((c) => !c.ok).map((c) => '${c.path}: ${c.actual}'), isEmpty);
  });

  test('verification catches a wrong size, alpha in iOS icons and a broken ICO', () {
    final wrong = all.files.map((f) {
      if (f.path.endsWith('mipmap-mdpi/ic_launcher.png')) {
        return f.withBytes(img.encodePng(img.Image(width: 47, height: 47)));
      }
      if (f.path.endsWith('Icon-App-20x20@2x.png')) {
        return f.withBytes(img.encodePng(img.Image(width: 40, height: 40, numChannels: 4)));
      }
      if (f.path == windowsIconPath) {
        return f.withBytes(
          img.IcoEncoder().encodeImages([img.Image(width: 16, height: 16), img.Image(width: 32, height: 32)]),
        );
      }
      if (f.path.endsWith(playIconPath)) {
        return f.withBytes(img.encodePng(img.Image(width: 512, height: 512, numChannels: 4)));
      }
      return f;
    }).toList();
    final failed = {for (final c in verifyAppIcons(wrong).where((c) => !c.ok)) c.path: c.actual};
    expect(failed.keys, hasLength(4));
    expect(failed['$androidResDir/mipmap-mdpi/ic_launcher.png'], contains('wrong size'));
    expect(failed['$iosIconSetDir/Icon-App-20x20@2x.png'], contains('alpha not allowed'));
    expect(failed[windowsIconPath], contains('expected 16, 24, 32'));
    expect(failed[playIconPath], contains('transparent'));
  });

  test('Contents.json referencing a missing file fails', () {
    final missing = all.files.where((f) => !f.path.endsWith('Icon-App-60x60@3x.png')).toList();
    final contents = verifyAppIcons(missing).firstWhere((c) => c.path.endsWith('Contents.json'));
    expect(contents.ok, isFalse);
    expect(contents.actual, contains('Icon-App-60x60@3x.png'));
  });

  test('non-square sources are padded or centre-cropped', () {
    final wide = img.Image(width: 200, height: 100, numChannels: 4)..clear(img.ColorRgba8(0, 255, 0, 255));
    final padded = squareMaster(wide, const IconExportOptions(padColor: Rgba(0, 0, 255)));
    expect((padded.width, padded.height), (200, 200));
    expect(padded.getPixel(100, 10).b, 255, reason: 'pad colour above the artwork');
    expect(padded.getPixel(100, 100).g, 255);
    final cropped = squareMaster(wide, const IconExportOptions(nonSquare: NonSquareMode.crop));
    expect((cropped.width, cropped.height), (100, 100));
    final r = generateAppIcons(pngOf(wide), const IconExportOptions(ios: false, windows: false));
    expect(r.notes.first, contains('not square'));
    expect(r.files.every((f) => f.group == 'Android' || f.group == 'Google Play'), isTrue);
  });

  test('refuses junk, tiny sources and empty platform selection', () {
    expect(
      () => generateAppIcons(pngOf(img.Image(width: 8, height: 8)), const IconExportOptions()),
      throwsA(isA<IconExportException>()),
    );
    expect(
      () => generateAppIcons(
        pngOf(img.Image(width: 64, height: 64)),
        const IconExportOptions(android: false, ios: false, windows: false),
      ),
      throwsA(isA<IconExportException>()),
    );
    expect(
      () => generateAppIcons(utf8.encode('not an image'), const IconExportOptions()),
      throwsA(isA<IconExportException>()),
    );
  });
}
