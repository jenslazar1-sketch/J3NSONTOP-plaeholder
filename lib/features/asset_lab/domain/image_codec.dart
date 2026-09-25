import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'color_model.dart';

/// Image decoding/encoding shared by every Asset Lab tool. Everything here is
/// pure Dart (package:image), runs identically on every platform and is
/// called from a background isolate with plain data in and out.

/// Extensions the Asset Lab can decode (package:image 4.10 decoders).
const List<String> decodableImageExtensions = [
  'png',
  'jpg',
  'jpeg',
  'gif',
  'bmp',
  'tga',
  'tif',
  'tiff',
  'ico',
  'webp',
  'psd',
  'exr',
  'pvr',
  'pnm',
  'pbm',
  'pgm',
  'ppm',
];

/// Largest image (in pixels) the Asset Lab decodes. 64 MP of RGBA is 256 MB
/// in memory; bigger inputs are refused with an explanation.
const int maxImagePixels = 64 * 1024 * 1024;

/// Largest input file read into memory.
const int maxImageFileBytes = 256 * 1024 * 1024;

/// Decoded 8-bit pixels (RGB or RGBA, tightly packed, row-major) that cross
/// isolate boundaries cheaply.
class Raster {
  Raster(this.width, this.height, this.channels, this.pixels)
    : assert(channels == 3 || channels == 4),
      assert(pixels.length == width * height * channels);

  /// Converts any decoded image (palette, grey, 16-bit, float) to 8-bit
  /// RGB/RGBA. Only the first frame is kept.
  factory Raster.fromImage(img.Image source) {
    var i = source;
    final wantChannels = i.hasAlpha ? 4 : 3;
    if (i.hasPalette || i.format != img.Format.uint8 || i.numChannels != wantChannels) {
      i = i.convert(format: img.Format.uint8, numChannels: wantChannels, noAnimation: true);
    }
    final bytes = i.getBytes(order: wantChannels == 4 ? img.ChannelOrder.rgba : img.ChannelOrder.rgb);
    return Raster(i.width, i.height, wantChannels, Uint8List.fromList(bytes));
  }

  final int width;
  final int height;
  final int channels;
  final Uint8List pixels;

  bool get hasAlpha => channels == 4;
  int get pixelCount => width * height;

  img.Image toImage() => img.Image.fromBytes(
    width: width,
    height: height,
    bytes: pixels.buffer,
    bytesOffset: pixels.offsetInBytes,
    numChannels: channels,
    order: channels == 4 ? img.ChannelOrder.rgba : img.ChannelOrder.rgb,
  );

  /// Colour of one pixel (alpha 255 for RGB rasters).
  Rgba pixel(int x, int y) {
    final i = (y * width + x) * channels;
    return Rgba(pixels[i], pixels[i + 1], pixels[i + 2], channels == 4 ? pixels[i + 3] : 255);
  }

  /// True when an alpha channel exists and at least one pixel uses it.
  bool get usesTransparency {
    if (channels != 4) return false;
    for (var i = 3; i < pixels.length; i += 4) {
      if (pixels[i] != 255) return true;
    }
    return false;
  }
}

/// Metadata shown in the Image Studio's info panel.
class ImageMetadata {
  const ImageMetadata({
    required this.formatName,
    required this.width,
    required this.height,
    required this.channels,
    required this.hasAlpha,
    required this.bitsPerChannel,
    required this.frameCount,
    required this.fileSize,
    required this.indexed,
    this.exif = const [],
    this.notes = const [],
  });

  final String formatName;
  final int width;
  final int height;

  /// Channels of the decoded source (palette images report the palette's).
  final int channels;
  final bool hasAlpha;
  final int bitsPerChannel;
  final int frameCount;
  final int fileSize;
  final bool indexed;

  /// Readable EXIF summary (tag, value).
  final List<(String, String)> exif;

  /// Processing notes (first frame only, orientation applied, 16 -> 8 bit...).
  final List<String> notes;
}

/// Result of [decodeImageFile].
class DecodedImage {
  const DecodedImage({
    required this.raster,
    required this.metadata,
    required this.previewPng,
    required this.previewScale,
  });
  final Raster raster;
  final ImageMetadata metadata;

  /// PNG of the (possibly downscaled) image for on-screen preview.
  final Uint8List previewPng;

  /// previewWidth / raster.width (1 when not downscaled).
  final double previewScale;
}

class ImageDecodeException implements Exception {
  const ImageDecodeException(this.message);
  final String message;
  @override
  String toString() => message;
}

String _formatName(img.ImageFormat f) => switch (f) {
  img.ImageFormat.png => 'PNG',
  img.ImageFormat.jpg => 'JPEG',
  img.ImageFormat.gif => 'GIF',
  img.ImageFormat.bmp => 'BMP',
  img.ImageFormat.tga => 'TGA',
  img.ImageFormat.tiff => 'TIFF',
  img.ImageFormat.ico => 'ICO',
  img.ImageFormat.webp => 'WebP',
  img.ImageFormat.psd => 'PSD',
  img.ImageFormat.exr => 'OpenEXR',
  img.ImageFormat.pvr => 'PVR',
  img.ImageFormat.pnm => 'PNM',
  _ => f.name.toUpperCase(),
};

/// Content probes in the package's own order. Each probe is guarded: some
/// validators throw on truncated or hostile input instead of returning
/// false, which would otherwise abort detection of the remaining formats.
/// TGA has no magic number (almost any bytes "validate"), so it is only
/// chosen by file extension, never by content.
List<img.Decoder> _probes() => [
  img.JpegDecoder(),
  img.PngDecoder(),
  img.GifDecoder(),
  img.WebPDecoder(),
  img.TiffDecoder(),
  img.PsdDecoder(),
  img.ExrDecoder(),
  img.BmpDecoder(),
  img.PnmDecoder(),
  img.IcoDecoder(),
  img.PvrDecoder(),
];

bool _accepts(img.Decoder d, Uint8List bytes) {
  try {
    return d.isValidFile(bytes);
  } catch (_) {
    return false;
  }
}

/// Chooses a decoder by content first (robust against wrong extensions),
/// then by file name (only if that decoder accepts the data).
img.Decoder? _decoderFor(Uint8List bytes, String name) {
  for (final d in _probes()) {
    if (_accepts(d, bytes)) return d;
  }
  final byName = img.findDecoderForNamedImage(name);
  return byName != null && _accepts(byName, bytes) ? byName : null;
}

int _frameCount(img.Decoder d) {
  try {
    return math.max(1, d.numFrames());
  } catch (_) {
    return 1;
  }
}

/// Decodes [bytes] (file called [name]) to an 8-bit raster plus metadata and
/// a preview PNG whose longest side is at most [previewMax].
///
/// Throws [ImageDecodeException] with a readable reason for unsupported,
/// damaged or oversized input.
DecodedImage decodeImageFile(Uint8List bytes, String name, {int previewMax = 1600}) {
  if (bytes.isEmpty) throw const ImageDecodeException('The file is empty.');
  if (bytes.length > maxImageFileBytes) {
    throw ImageDecodeException('The file is ${bytes.length} bytes; the Asset Lab reads files up to 256 MB.');
  }
  final decoder = _decoderFor(bytes, name);
  if (decoder == null) {
    throw ImageDecodeException(
      '"$name" is not an image format the Asset Lab can read. Supported: '
      '${decodableImageExtensions.map((e) => e.toUpperCase()).join(', ')}.',
    );
  }
  img.DecodeInfo? info;
  try {
    info = decoder.startDecode(bytes);
  } catch (_) {
    info = null;
  }
  if (info == null) throw ImageDecodeException('"$name" looks like ${_formatName(decoder.format)} but is damaged.');
  if (info.width > 0 && info.height > 0 && info.width * info.height > maxImagePixels) {
    throw ImageDecodeException(
      '"$name" is ${info.width}x${info.height} (${(info.width * info.height / 1e6).toStringAsFixed(1)} MP). '
      'The Asset Lab handles up to ${maxImagePixels ~/ (1024 * 1024)} MP.',
    );
  }
  final frames = _frameCount(decoder);
  int? jpegOrientation;
  if (decoder is img.JpegDecoder) {
    try {
      jpegOrientation = img.decodeJpgExif(bytes)?.imageIfd.orientation;
    } catch (_) {
      jpegOrientation = null;
    }
  }
  img.Image? decoded;
  try {
    if (decoder is img.IcoDecoder) {
      decoded = decoder.decodeImageLargest(bytes);
    } else {
      decoded = decoder.decode(bytes, frame: 0);
    }
  } catch (e) {
    throw ImageDecodeException('"$name" could not be decoded as ${_formatName(decoder.format)}: $e');
  }
  if (decoded == null || !decoded.isValid) {
    throw ImageDecodeException('"$name" could not be decoded as ${_formatName(decoder.format)} (damaged data).');
  }
  if (decoded.width * decoded.height > maxImagePixels) {
    throw ImageDecodeException('"$name" is ${decoded.width}x${decoded.height}, above the 64 MP limit.');
  }

  final notes = <String>[];
  final exif = _exifSummary(decoded);
  var working = decoded;
  if (jpegOrientation != null && jpegOrientation != 1) {
    // The JPEG decoder already rotated the pixels and cleared the tag.
    exif.add(('Orientation', '$jpegOrientation'));
    notes.add('EXIF orientation $jpegOrientation applied: pixels are shown and processed upright.');
  } else if (decoded.hasExif && (decoded.exif.imageIfd.orientation ?? 1) != 1) {
    final orientation = decoded.exif.imageIfd.orientation;
    working = img.bakeOrientation(decoded);
    notes.add('EXIF orientation $orientation applied: pixels are shown and processed upright.');
  }
  if (frames > 1) {
    notes.add(
      decoder is img.IcoDecoder
          ? 'Icon with $frames sizes: the largest one is used.'
          : 'Contains $frames frames: only the first frame is edited; exports are single images.',
    );
  }
  final bits = decoded.bitsPerChannel;
  if (bits > 8 || decoded.formatType == img.FormatType.float) {
    notes.add('Source has $bits bits per channel; it is processed and exported at 8 bits per channel.');
  }
  if (exif.isNotEmpty) notes.add('EXIF metadata is displayed but not copied into exports.');

  final raster = Raster.fromImage(working);
  final preview = makePreview(raster, previewMax);
  return DecodedImage(
    raster: raster,
    previewPng: preview.$1,
    previewScale: preview.$2,
    metadata: ImageMetadata(
      formatName: _formatName(decoder.format),
      width: raster.width,
      height: raster.height,
      channels: decoded.numChannels,
      hasAlpha: decoded.hasAlpha,
      bitsPerChannel: bits,
      frameCount: frames,
      fileSize: bytes.length,
      indexed: decoded.hasPalette,
      exif: exif,
      notes: notes,
    ),
  );
}

/// Encodes a preview PNG no larger than [maxSide] on its longest side.
/// Returns the PNG and the scale factor (preview / source).
(Uint8List, double) makePreview(Raster raster, int maxSide) {
  var image = raster.toImage();
  var scale = 1.0;
  final longest = math.max(raster.width, raster.height);
  if (longest > maxSide) {
    scale = maxSide / longest;
    image = img.copyResize(
      image,
      width: math.max(1, (raster.width * scale).round()),
      height: math.max(1, (raster.height * scale).round()),
      interpolation: img.Interpolation.average,
    );
    scale = image.width / raster.width;
  }
  return (img.encodePng(image, level: 1), scale);
}

List<(String, String)> _exifSummary(img.Image image) {
  if (!image.hasExif) return <(String, String)>[];
  final exif = image.exif;
  final out = <(String, String)>[];
  final ifd0 = exif.imageIfd;
  void add(String label, Object? value) {
    if (value == null) return;
    final s = value.toString().replaceAll('\u0000', '').trim();
    if (s.isNotEmpty) out.add((label, s.length > 80 ? '${s.substring(0, 80)}...' : s));
  }

  if (ifd0.hasMake) add('Camera make', ifd0.make);
  if (ifd0.hasModel) add('Camera model', ifd0.model);
  if (ifd0.hasSoftware) add('Software', ifd0.software);
  add('Date/time', ifd0[0x0132]);
  final exifIfd = exif.exifIfd;
  add('Taken', exifIfd[0x9003]);
  add('Exposure', exifIfd[0x829A]);
  add('F-number', exifIfd[0x829D]);
  add('ISO', exifIfd[0x8827]);
  if (ifd0.hasOrientation) add('Orientation', ifd0.orientation);
  if (ifd0.hasCopyright) add('Copyright', ifd0.copyright);
  if (!exif.gpsIfd.isEmpty) out.add(('GPS', 'location data present (not exported)'));
  return out;
}

/// Output formats offered by the Asset Lab. Only formats whose encoder
/// output round-trips through the package's own decoder are listed.
enum ExportFormat {
  png('PNG', 'png', 'image/png', alpha: true),
  jpeg('JPEG', 'jpg', 'image/jpeg', alpha: false),
  webp('WebP', 'webp', 'image/webp', alpha: true),
  gif('GIF', 'gif', 'image/gif', alpha: false),
  bmp('BMP', 'bmp', 'image/bmp', alpha: true),
  tga('TGA', 'tga', 'image/x-tga', alpha: true),
  tiff('TIFF', 'tiff', 'image/tiff', alpha: true),
  ico('ICO', 'ico', 'image/vnd.microsoft.icon', alpha: true, maxSide: 256);

  const ExportFormat(this.label, this.extension, this.mimeType, {required this.alpha, this.maxSide});
  final String label;
  final String extension;
  final String mimeType;

  /// Whether the encoder keeps an alpha channel. JPEG has none; the GIF
  /// encoder quantises to an opaque 256-colour palette.
  final bool alpha;

  /// Largest width/height the format allows (ICO: 256).
  final int? maxSide;
}

/// Encoder settings.
class ExportSettings {
  const ExportSettings({
    this.format = ExportFormat.png,
    this.quality = 90,
    this.webpLossless = true,
    this.background = const Rgba(255, 255, 255),
  });

  final ExportFormat format;

  /// JPEG / lossy WebP quality 1..100.
  final int quality;
  final bool webpLossless;

  /// Flatten colour for formats without alpha.
  final Rgba background;

  ExportSettings copyWith({ExportFormat? format, int? quality, bool? webpLossless, Rgba? background}) => ExportSettings(
    format: format ?? this.format,
    quality: quality ?? this.quality,
    webpLossless: webpLossless ?? this.webpLossless,
    background: background ?? this.background,
  );
}

/// Composites [image] onto an opaque [background] and returns a 3-channel
/// image. Used for JPEG/GIF export and opaque app icons.
img.Image flattenOnto(img.Image image, Rgba background) {
  final out = img.Image(width: image.width, height: image.height, numChannels: 3);
  final src = image.hasAlpha ? image : image.convert(numChannels: 4);
  final br = background.r, bg = background.g, bb = background.b;
  for (final p in src) {
    final a = p.aNormalized.toDouble();
    if (a >= 1) {
      out.setPixelRgb(p.x, p.y, p.r, p.g, p.b);
    } else {
      out.setPixelRgb(
        p.x,
        p.y,
        (p.r * a + br * (1 - a)).round(),
        (p.g * a + bg * (1 - a)).round(),
        (p.b * a + bb * (1 - a)).round(),
      );
    }
  }
  return out;
}

class EncodeException implements Exception {
  const EncodeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Result of [encodeRaster].
class EncodedImage {
  const EncodedImage({
    required this.bytes,
    required this.width,
    required this.height,
    required this.flattened,
    required this.hasAlpha,
  });
  final Uint8List bytes;
  final int width;
  final int height;

  /// True when transparency was composited onto the background colour.
  final bool flattened;

  /// Whether the encoded file keeps an alpha channel.
  final bool hasAlpha;
}

/// Encodes [raster] with [settings]. Formats without alpha are flattened
/// onto [ExportSettings.background] (reported via [EncodedImage.flattened]).
EncodedImage encodeRaster(Raster raster, ExportSettings settings) {
  final f = settings.format;
  if (f.maxSide != null && (raster.width > f.maxSide! || raster.height > f.maxSide!)) {
    throw EncodeException(
      '${f.label} images can be at most ${f.maxSide}x${f.maxSide} px; this image is ${raster.width}x${raster.height}. '
      'Add a resize step first.',
    );
  }
  var image = raster.toImage();
  var flattened = false;
  if (!f.alpha && raster.hasAlpha) {
    flattened = raster.usesTransparency;
    image = flattenOnto(image, settings.background);
  }
  final q = settings.quality.clamp(1, 100);
  final Uint8List bytes = switch (f) {
    ExportFormat.png => img.encodePng(image),
    ExportFormat.jpeg => img.encodeJpg(image, quality: q),
    ExportFormat.webp =>
      settings.webpLossless ? img.encodeWebP(image) : img.encodeWebP(image, lossless: false, quality: q),
    ExportFormat.gif => img.encodeGif(image, singleFrame: true),
    ExportFormat.bmp => img.encodeBmp(image),
    ExportFormat.tga => img.encodeTga(image),
    ExportFormat.tiff => img.encodeTiff(image, singleFrame: true),
    ExportFormat.ico => img.encodeIco(image, singleFrame: true),
  };
  return EncodedImage(
    bytes: bytes,
    width: image.width,
    height: image.height,
    flattened: flattened,
    hasAlpha: f.alpha && raster.hasAlpha,
  );
}

/// Decodes any supported image to a raster without building a preview
/// (sprite imports, atlas inputs, eyedropper).
Raster decodeToRaster(Uint8List bytes, String name) {
  if (bytes.isEmpty) throw ImageDecodeException('"$name" is empty.');
  final decoder = _decoderFor(bytes, name);
  if (decoder == null) throw ImageDecodeException('"$name" is not a supported image.');
  img.DecodeInfo? info;
  try {
    info = decoder.startDecode(bytes);
  } catch (_) {
    info = null;
  }
  if (info == null) throw ImageDecodeException('"$name" is damaged or not a valid image.');
  if (info.width * info.height > maxImagePixels) {
    throw ImageDecodeException('"$name" is ${info.width}x${info.height}, above the 64 MP limit.');
  }
  img.Image? decoded;
  try {
    decoded = decoder is img.IcoDecoder ? decoder.decodeImageLargest(bytes) : decoder.decode(bytes, frame: 0);
  } catch (e) {
    throw ImageDecodeException('"$name" could not be decoded: $e');
  }
  if (decoded == null || !decoded.isValid) throw ImageDecodeException('"$name" could not be decoded.');
  if (decoded.width * decoded.height > maxImagePixels) {
    throw ImageDecodeException('"$name" is ${decoded.width}x${decoded.height}, above the 64 MP limit.');
  }
  final upright = decoded.hasExif && (decoded.exif.imageIfd.orientation ?? 1) != 1
      ? img.bakeOrientation(decoded)
      : decoded;
  return Raster.fromImage(upright);
}

/// Encodes a raster as PNG (used for thumbnails, frames and atlases).
Uint8List encodePngRaster(Raster raster, {int level = 6}) => img.encodePng(raster.toImage(), level: level);

/// `name.ext` -> `name_edited.<newExt>`.
String editedFileName(String sourceName, String extension) {
  final dot = sourceName.lastIndexOf('.');
  final stem = dot > 0 ? sourceName.substring(0, dot) : sourceName;
  return '${stem.isEmpty ? 'image' : stem}_edited.$extension';
}

/// File name without directories (handles both `/` and backslash separators).
String fileBaseName(String name) {
  final slash = math.max(name.lastIndexOf('/'), name.lastIndexOf(r'\'));
  return slash >= 0 ? name.substring(slash + 1) : name;
}

/// File name without directory and extension.
String fileStem(String name) {
  final slash = math.max(name.lastIndexOf('/'), name.lastIndexOf(r'\'));
  final base = slash >= 0 ? name.substring(slash + 1) : name;
  final dot = base.lastIndexOf('.');
  return dot > 0 ? base.substring(0, dot) : base;
}
