import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'color_model.dart';
import 'image_codec.dart';

/// App icon generation for Android, Google Play, iOS and Windows, plus an
/// independent verifier that decodes every output again.
///
/// Pure Dart (no Flutter imports) so a script can regenerate a project's
/// icons, e.g. from `tool/`:
///
/// ```dart
/// final result = generateAppIcons(File('icon_1024.png').readAsBytesSync(), const IconExportOptions());
/// for (final f in result.files) {
///   File(f.path)..createSync(recursive: true)..writeAsBytesSync(f.bytes);
/// }
/// final failed = verifyAppIcons(result.files).where((c) => !c.ok);
/// ```
///
/// Output paths mirror a Flutter project (`android/app/src/main/res/...`,
/// `ios/Runner/Assets.xcassets/AppIcon.appiconset/...`,
/// `windows/runner/resources/app_icon.ico`) plus `store/` for the
/// Google Play listing icon, so the ZIP can be unpacked onto a project root.

enum NonSquareMode {
  pad('Pad to square'),
  crop('Centre-crop');

  const NonSquareMode(this.label);
  final String label;
}

class IconExportOptions {
  const IconExportOptions({
    this.nonSquare = NonSquareMode.pad,
    this.padColor = Rgba.transparent,
    this.background = const Rgba(5, 5, 7),
    this.android = true,
    this.ios = true,
    this.windows = true,
  });

  final NonSquareMode nonSquare;

  /// Fill used when padding a non-square source (may be transparent).
  final Rgba padColor;

  /// Opaque colour for icons that must not have alpha (iOS, Google Play)
  /// and the adaptive icon background layer.
  final Rgba background;
  final bool android;
  final bool ios;
  final bool windows;

  IconExportOptions copyWith({
    NonSquareMode? nonSquare,
    Rgba? padColor,
    Rgba? background,
    bool? android,
    bool? ios,
    bool? windows,
  }) => IconExportOptions(
    nonSquare: nonSquare ?? this.nonSquare,
    padColor: padColor ?? this.padColor,
    background: background ?? this.background,
    android: android ?? this.android,
    ios: ios ?? this.ios,
    windows: windows ?? this.windows,
  );
}

enum IconFileKind { png, ico, xml, json }

/// What a generated file must look like; checked by [verifyAppIcons].
class IconExpectation {
  const IconExpectation.png(this.size, {this.noAlphaChannel = false, this.opaque32 = false})
    : kind = IconFileKind.png,
      icoSizes = const [];
  const IconExpectation.ico(this.icoSizes)
    : kind = IconFileKind.ico,
      size = 0,
      noAlphaChannel = false,
      opaque32 = false;
  const IconExpectation.text(this.kind) : size = 0, icoSizes = const [], noAlphaChannel = false, opaque32 = false;

  final IconFileKind kind;

  /// Square pixel size for PNGs.
  final int size;

  /// iOS: the PNG must not contain an alpha channel at all.
  final bool noAlphaChannel;

  /// Google Play: 32-bit PNG whose alpha is fully opaque.
  final bool opaque32;
  final List<int> icoSizes;

  String describe() => switch (kind) {
    IconFileKind.png => '${size}x$size PNG${noAlphaChannel ? ', no alpha' : ''}${opaque32 ? ', 32-bit opaque' : ''}',
    IconFileKind.ico => 'ICO with ${icoSizes.join(', ')} px',
    IconFileKind.xml => 'valid resource XML',
    IconFileKind.json => 'Contents.json matching the PNGs',
  };
}

class IconFile {
  const IconFile({required this.path, required this.bytes, required this.expect, required this.group});
  final String path;
  final Uint8List bytes;
  final IconExpectation expect;

  /// "Android", "Google Play", "iOS" or "Windows".
  final String group;

  IconFile withBytes(Uint8List b) => IconFile(path: path, bytes: b, expect: expect, group: group);
}

class IconExportResult {
  const IconExportResult({required this.files, required this.notes, required this.masterSize});
  final List<IconFile> files;
  final List<String> notes;

  /// Side of the square master image the icons were scaled from.
  final int masterSize;

  int get totalBytes => files.fold(0, (s, f) => s + f.bytes.length);
}

/// Android legacy launcher sizes (48 dp).
const Map<String, int> androidLegacySizes = {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192};

/// Android adaptive icon layer sizes (108 dp).
const Map<String, int> androidAdaptiveSizes = {'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432};

/// Windows ICO frame sizes.
const List<int> windowsIcoSizes = [16, 24, 32, 48, 64, 128, 256];

/// One entry of the iOS asset catalog.
class IosIconSlot {
  const IosIconSlot(this.idiom, this.points, this.scale);
  final String idiom;
  final double points;
  final int scale;

  int get pixels => (points * scale).round();
  String get sizeLabel {
    final p = points == points.roundToDouble() ? points.toInt().toString() : points.toString();
    return '${p}x$p';
  }

  String get fileName => 'Icon-App-$sizeLabel@${scale}x.png';
}

/// The standard iPhone/iPad/App Store set (same slots as Flutter's template).
const List<IosIconSlot> iosIconSlots = [
  IosIconSlot('iphone', 20, 2),
  IosIconSlot('iphone', 20, 3),
  IosIconSlot('iphone', 29, 1),
  IosIconSlot('iphone', 29, 2),
  IosIconSlot('iphone', 29, 3),
  IosIconSlot('iphone', 40, 2),
  IosIconSlot('iphone', 40, 3),
  IosIconSlot('iphone', 60, 2),
  IosIconSlot('iphone', 60, 3),
  IosIconSlot('ipad', 20, 1),
  IosIconSlot('ipad', 20, 2),
  IosIconSlot('ipad', 29, 1),
  IosIconSlot('ipad', 29, 2),
  IosIconSlot('ipad', 40, 1),
  IosIconSlot('ipad', 40, 2),
  IosIconSlot('ipad', 76, 1),
  IosIconSlot('ipad', 76, 2),
  IosIconSlot('ipad', 83.5, 2),
  IosIconSlot('ios-marketing', 1024, 1),
];

const String androidResDir = 'android/app/src/main/res';
const String iosIconSetDir = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
const String windowsIconPath = 'windows/runner/resources/app_icon.ico';
const String playIconPath = 'store/google_play_icon_512.png';

class IconExportException implements Exception {
  const IconExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Makes the square master image from [source].
img.Image squareMaster(img.Image source, IconExportOptions o) {
  final w = source.width, h = source.height;
  if (w == h) return source.hasAlpha ? source : source.convert(numChannels: 4);
  final rgba = source.hasAlpha ? source : source.convert(numChannels: 4);
  if (o.nonSquare == NonSquareMode.crop) {
    final side = math.min(w, h);
    return img.copyCrop(rgba, x: (w - side) ~/ 2, y: (h - side) ~/ 2, width: side, height: side);
  }
  final side = math.max(w, h);
  final canvas = img.Image(width: side, height: side, numChannels: 4);
  canvas.clear(img.ColorRgba8(o.padColor.r, o.padColor.g, o.padColor.b, o.padColor.a));
  img.compositeImage(canvas, rgba, dstX: (side - w) ~/ 2, dstY: (side - h) ~/ 2, blend: img.BlendMode.direct);
  return canvas;
}

img.Image _scaled(img.Image master, int size) {
  if (master.width == size) return master.clone();
  return img.copyResize(
    master,
    width: size,
    height: size,
    interpolation: size < master.width ? img.Interpolation.average : img.Interpolation.cubic,
  );
}

String _androidColor(Rgba c) => ColorFormat.hex(c.opaque);

/// Generates every requested icon from the encoded [sourceBytes].
IconExportResult generateAppIcons(Uint8List sourceBytes, IconExportOptions o, {String sourceName = 'icon.png'}) {
  if (!o.android && !o.ios && !o.windows) {
    throw const IconExportException('Choose at least one platform.');
  }
  final Raster raster;
  try {
    raster = decodeToRaster(sourceBytes, sourceName);
  } on ImageDecodeException catch (e) {
    throw IconExportException(e.message);
  }
  return generateAppIconsFromRaster(raster, o);
}

/// Same as [generateAppIcons] for an already decoded source.
IconExportResult generateAppIconsFromRaster(Raster raster, IconExportOptions o) {
  if (!o.android && !o.ios && !o.windows) {
    throw const IconExportException('Choose at least one platform.');
  }
  if (raster.width < 16 || raster.height < 16) {
    throw IconExportException(
      'The source is ${raster.width}x${raster.height}; use at least 16x16 (1024x1024 is ideal).',
    );
  }
  final notes = <String>[];
  final master = squareMaster(raster.toImage(), o);
  if (raster.width != raster.height) {
    notes.add(
      o.nonSquare == NonSquareMode.crop
          ? 'Source ${raster.width}x${raster.height} is not square: centre-cropped to ${master.width}x${master.width}.'
          : 'Source ${raster.width}x${raster.height} is not square: padded to ${master.width}x${master.width}.',
    );
  }
  if (master.width < 1024) {
    notes.add('Master is ${master.width}x${master.width}: larger icons are upscaled. A 1024x1024 source looks best.');
  }
  final bg = o.background.opaque;
  if (!o.background.isOpaque) notes.add('Background alpha ignored: store/iOS icons must be opaque.');
  final files = <IconFile>[];
  final cache = <int, img.Image>{};
  img.Image at(int size) => cache.putIfAbsent(size, () => _scaled(master, size));

  if (o.android) {
    for (final e in androidLegacySizes.entries) {
      files.add(
        IconFile(
          path: '$androidResDir/mipmap-${e.key}/ic_launcher.png',
          bytes: img.encodePng(at(e.value)),
          expect: IconExpectation.png(e.value),
          group: 'Android',
        ),
      );
    }
    for (final e in androidAdaptiveSizes.entries) {
      // The artwork goes into the 72 dp safe zone centred on the 108 dp layer.
      final canvasSize = e.value;
      final art = (canvasSize * 72 / 108).round();
      final layer = img.Image(width: canvasSize, height: canvasSize, numChannels: 4);
      final offset = (canvasSize - art) ~/ 2;
      img.compositeImage(layer, at(art), dstX: offset, dstY: offset, blend: img.BlendMode.direct);
      files.add(
        IconFile(
          path: '$androidResDir/mipmap-${e.key}/ic_launcher_foreground.png',
          bytes: img.encodePng(layer),
          expect: IconExpectation.png(canvasSize),
          group: 'Android',
        ),
      );
    }
    files.add(
      IconFile(
        path: '$androidResDir/mipmap-anydpi-v26/ic_launcher.xml',
        bytes: Uint8List.fromList(utf8.encode(_adaptiveXml)),
        expect: const IconExpectation.text(IconFileKind.xml),
        group: 'Android',
      ),
    );
    files.add(
      IconFile(
        path: '$androidResDir/values/ic_launcher_background.xml',
        bytes: Uint8List.fromList(utf8.encode(_backgroundXml(bg))),
        expect: const IconExpectation.text(IconFileKind.xml),
        group: 'Android',
      ),
    );
    final play = flattenOnto(at(512), bg).convert(numChannels: 4, alpha: 255);
    files.add(
      IconFile(
        path: playIconPath,
        bytes: img.encodePng(play),
        expect: const IconExpectation.png(512, opaque32: true),
        group: 'Google Play',
      ),
    );
  }

  if (o.ios) {
    // iPhone and iPad slots of the same size and scale share one file.
    final written = <String>{};
    for (final slot in iosIconSlots) {
      if (!written.add(slot.fileName)) continue;
      files.add(
        IconFile(
          path: '$iosIconSetDir/${slot.fileName}',
          bytes: img.encodePng(flattenOnto(at(slot.pixels), bg)),
          expect: IconExpectation.png(slot.pixels, noAlphaChannel: true),
          group: 'iOS',
        ),
      );
    }
    files.add(
      IconFile(
        path: '$iosIconSetDir/Contents.json',
        bytes: Uint8List.fromList(utf8.encode(iosContentsJson())),
        expect: const IconExpectation.text(IconFileKind.json),
        group: 'iOS',
      ),
    );
    if (raster.usesTransparency) notes.add('iOS icons were flattened onto ${ColorFormat.hex(bg)} (no alpha allowed).');
  }

  if (o.windows) {
    files.add(
      IconFile(
        path: windowsIconPath,
        bytes: img.IcoEncoder().encodeImages([for (final s in windowsIcoSizes) at(s)]),
        expect: const IconExpectation.ico(windowsIcoSizes),
        group: 'Windows',
      ),
    );
  }
  return IconExportResult(files: files, notes: notes, masterSize: master.width);
}

const String _adaptiveXml = '''
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
''';

String _backgroundXml(Rgba bg) =>
    '''
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">${_androidColor(bg)}</color>
</resources>
''';

/// The asset catalog index for [iosIconSlots].
String iosContentsJson() => const JsonEncoder.withIndent('  ').convert({
  'images': [
    for (final s in iosIconSlots)
      {'size': s.sizeLabel, 'idiom': s.idiom, 'filename': s.fileName, 'scale': '${s.scale}x'},
  ],
  'info': {'version': 1, 'author': 'xcode'},
});

/// One row of the verification table.
class IconCheck {
  const IconCheck({
    required this.path,
    required this.group,
    required this.expected,
    required this.actual,
    required this.ok,
  });
  final String path;
  final String group;
  final String expected;
  final String actual;
  final bool ok;
}

/// Frame sizes listed in an ICO directory (0 in the directory means 256).
List<(int, int)> readIcoDirectory(Uint8List bytes) {
  if (bytes.length < 6) throw const FormatException('ICO file is truncated');
  final d = ByteData.sublistView(bytes);
  if (d.getUint16(0, Endian.little) != 0 || d.getUint16(2, Endian.little) != 1) {
    throw const FormatException('Not an ICO file (bad header)');
  }
  final count = d.getUint16(4, Endian.little);
  if (bytes.length < 6 + count * 16) throw const FormatException('ICO directory is truncated');
  return [
    for (var i = 0; i < count; i++)
      (bytes[6 + i * 16] == 0 ? 256 : bytes[6 + i * 16], bytes[7 + i * 16] == 0 ? 256 : bytes[7 + i * 16]),
  ];
}

/// Decodes every generated file again and checks it against its
/// expectation (dimensions, alpha rules, ICO frames, XML/JSON integrity).
List<IconCheck> verifyAppIcons(List<IconFile> files) {
  final byPath = {for (final f in files) f.path: f};
  return [for (final f in files) _verifyOne(f, byPath)];
}

IconCheck _verifyOne(IconFile f, Map<String, IconFile> byPath) {
  final expected = f.expect.describe();
  IconCheck result(bool ok, String actual) =>
      IconCheck(path: f.path, group: f.group, expected: expected, actual: actual, ok: ok);
  try {
    switch (f.expect.kind) {
      case IconFileKind.png:
        final decoded = img.PngDecoder().decode(f.bytes);
        if (decoded == null) return result(false, 'not a readable PNG');
        final size = '${decoded.width}x${decoded.height}';
        final alpha = decoded.numChannels == 4 || decoded.numChannels == 2;
        final desc = '$size PNG, ${alpha ? 'with' : 'no'} alpha channel';
        if (decoded.width != f.expect.size || decoded.height != f.expect.size) {
          return result(false, '$desc (wrong size)');
        }
        if (f.expect.noAlphaChannel && alpha) return result(false, '$desc (alpha not allowed)');
        if (f.expect.opaque32) {
          if (!alpha) return result(false, '$desc (expected 32-bit)');
          for (final p in decoded) {
            if (p.a != p.maxChannelValue) return result(false, '$desc (transparent pixels found)');
          }
        }
        return result(true, desc);
      case IconFileKind.ico:
        final dir = readIcoDirectory(f.bytes);
        final decoder = img.IcoDecoder();
        if (decoder.startDecode(f.bytes) == null) return result(false, 'not a readable ICO');
        final decodedSizes = <int>[];
        for (var i = 0; i < dir.length; i++) {
          final frame = decoder.decodeFrame(i);
          if (frame == null) return result(false, 'frame ${i + 1} could not be decoded');
          if (frame.width != dir[i].$1 || frame.height != dir[i].$2) {
            return result(false, 'frame ${i + 1} is ${frame.width}x${frame.height}, directory says ${dir[i].$1}');
          }
          if (frame.width != frame.height) return result(false, 'frame ${i + 1} is not square');
          decodedSizes.add(frame.width);
        }
        final actual = 'ICO with ${decodedSizes.join(', ')} px';
        final want = [...f.expect.icoSizes]..sort();
        final got = [...decodedSizes]..sort();
        final same =
            want.length == got.length && [for (var i = 0; i < want.length; i++) want[i] == got[i]].every((b) => b);
        return result(same, same ? actual : '$actual (expected ${want.join(', ')})');
      case IconFileKind.xml:
        final text = utf8.decode(f.bytes);
        if (!text.trimLeft().startsWith('<?xml')) return result(false, 'missing XML declaration');
        if (f.path.endsWith('ic_launcher.xml')) {
          final ok =
              text.contains('<adaptive-icon') &&
              text.contains('@color/ic_launcher_background') &&
              text.contains('@mipmap/ic_launcher_foreground') &&
              text.contains('</adaptive-icon>');
          final fg = byPath.keys.where((k) => k.endsWith('ic_launcher_foreground.png')).length;
          return result(ok && fg > 0, ok ? 'adaptive-icon with $fg foreground densities' : 'adaptive-icon incomplete');
        }
        final m = RegExp(r'<color name="ic_launcher_background">(#[0-9A-Fa-f]{6,8})</color>').firstMatch(text);
        return result(m != null, m == null ? 'colour resource missing' : 'background colour ${m.group(1)}');
      case IconFileKind.json:
        final root = jsonDecode(utf8.decode(f.bytes));
        if (root is! Map || root['images'] is! List) return result(false, 'no "images" list');
        final dir = f.path.substring(0, f.path.lastIndexOf('/') + 1);
        var n = 0;
        for (final e in root['images'] as List) {
          if (e is! Map) return result(false, 'malformed image entry');
          final name = e['filename'];
          final png = byPath['$dir$name'];
          if (png == null) return result(false, 'references missing file $name');
          final sizeText = (e['size'] as String? ?? '').split('x').first;
          final pts = double.tryParse(sizeText);
          final scale = int.tryParse((e['scale'] as String? ?? '').replaceAll('x', ''));
          if (pts == null || scale == null) return result(false, 'bad size/scale for $name');
          if ((pts * scale).round() != png.expect.size) return result(false, '$name size does not match its slot');
          n++;
        }
        return result(true, '$n images, all files present');
    }
  } catch (e) {
    return result(false, 'unreadable: $e');
  }
}
