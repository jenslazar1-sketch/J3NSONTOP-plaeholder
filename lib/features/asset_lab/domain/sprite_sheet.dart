import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'color_model.dart';
import 'image_codec.dart';

/// Sprite sheet grid math, slicing and animated GIF export.

enum GridMode {
  frameSize('Frame size'),
  columnsRows('Columns x rows');

  const GridMode(this.label);
  final String label;
}

/// User-entered grid settings. In [GridMode.frameSize] the frame size is
/// given and columns/rows are derived unless overridden; in
/// [GridMode.columnsRows] the frame size is derived from the sheet.
class GridSpec {
  const GridSpec({
    this.mode = GridMode.frameSize,
    this.frameWidth = 32,
    this.frameHeight = 32,
    this.columns,
    this.rows,
    this.margin = 0,
    this.spacing = 0,
    this.frameCount,
  });

  final GridMode mode;
  final int frameWidth;
  final int frameHeight;

  /// Null = automatic (as many as fit) in frame-size mode. Required in
  /// columns x rows mode.
  final int? columns;
  final int? rows;

  /// Offset of the first frame from the top-left corner (and the minimum
  /// border on the right/bottom when deriving sizes).
  final int margin;

  /// Gap between neighbouring frames.
  final int spacing;

  /// Frames actually used (null = every cell). Lets the user exclude
  /// trailing empty cells.
  final int? frameCount;

  GridSpec copyWith({
    GridMode? mode,
    int? frameWidth,
    int? frameHeight,
    int? Function()? columns,
    int? Function()? rows,
    int? margin,
    int? spacing,
    int? Function()? frameCount,
  }) => GridSpec(
    mode: mode ?? this.mode,
    frameWidth: frameWidth ?? this.frameWidth,
    frameHeight: frameHeight ?? this.frameHeight,
    columns: columns != null ? columns() : this.columns,
    rows: rows != null ? rows() : this.rows,
    margin: margin ?? this.margin,
    spacing: spacing ?? this.spacing,
    frameCount: frameCount != null ? frameCount() : this.frameCount,
  );
}

/// One frame rectangle on the sheet.
class FrameRect {
  const FrameRect(this.index, this.x, this.y, this.width, this.height);
  final int index;
  final int x;
  final int y;
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is FrameRect &&
      other.index == index &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;
  @override
  int get hashCode => Object.hash(index, x, y, width, height);
  @override
  String toString() => 'Frame#$index($x, $y, ${width}x$height)';
}

/// A validated grid ready for slicing.
class SpriteGrid {
  const SpriteGrid({
    required this.frameWidth,
    required this.frameHeight,
    required this.columns,
    required this.rows,
    required this.margin,
    required this.spacing,
    required this.frameCount,
    this.warnings = const [],
  });

  final int frameWidth;
  final int frameHeight;
  final int columns;
  final int rows;
  final int margin;
  final int spacing;
  final int frameCount;
  final List<String> warnings;

  int get cellCount => columns * rows;

  /// Pixel extent the grid covers (from 0,0).
  int get usedWidth => margin + columns * frameWidth + (columns - 1) * spacing;
  int get usedHeight => margin + rows * frameHeight + (rows - 1) * spacing;

  FrameRect frame(int index) {
    final col = index % columns;
    final row = index ~/ columns;
    return FrameRect(
      index,
      margin + col * (frameWidth + spacing),
      margin + row * (frameHeight + spacing),
      frameWidth,
      frameHeight,
    );
  }

  List<FrameRect> get frames => [for (var i = 0; i < frameCount; i++) frame(i)];
}

class GridException implements Exception {
  const GridException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// How many cells of [frame] + [spacing] fit into [available] after the
/// margin.
int _fit(int available, int margin, int frame, int spacing) {
  final usable = available - margin;
  if (usable < frame) return 0;
  return 1 + (usable - frame) ~/ (frame + spacing);
}

/// Resolves [spec] against a sheet of [sheetWidth] x [sheetHeight] pixels.
/// Throws [GridException] with a precise explanation when the grid does not
/// fit the sheet or the values are invalid.
SpriteGrid resolveGrid(GridSpec spec, int sheetWidth, int sheetHeight) {
  if (sheetWidth < 1 || sheetHeight < 1) throw const GridException('The sheet is empty.');
  if (spec.margin < 0) throw const GridException('Margin cannot be negative.');
  if (spec.spacing < 0) throw const GridException('Spacing cannot be negative.');
  int fw, fh, cols, rows;
  final warnings = <String>[];
  switch (spec.mode) {
    case GridMode.frameSize:
      fw = spec.frameWidth;
      fh = spec.frameHeight;
      if (fw < 1 || fh < 1) throw const GridException('Frame width and height must be at least 1 px.');
      final fitCols = _fit(sheetWidth, spec.margin, fw, spec.spacing);
      final fitRows = _fit(sheetHeight, spec.margin, fh, spec.spacing);
      if (fitCols == 0 || fitRows == 0) {
        throw GridException(
          'A ${fw}x$fh frame with margin ${spec.margin} does not fit in the ${sheetWidth}x$sheetHeight sheet.',
        );
      }
      cols = spec.columns ?? fitCols;
      rows = spec.rows ?? fitRows;
    case GridMode.columnsRows:
      cols = spec.columns ?? 0;
      rows = spec.rows ?? 0;
      if (cols < 1 || rows < 1) throw const GridException('Columns and rows must be at least 1.');
      final availW = sheetWidth - 2 * spec.margin - (cols - 1) * spec.spacing;
      final availH = sheetHeight - 2 * spec.margin - (rows - 1) * spec.spacing;
      fw = availW ~/ cols;
      fh = availH ~/ rows;
      if (fw < 1 || fh < 1) {
        throw GridException(
          '$cols x $rows frames with margin ${spec.margin} and spacing ${spec.spacing} '
          'leave no room for frames in a ${sheetWidth}x$sheetHeight sheet.',
        );
      }
      final leftX = availW - fw * cols, leftY = availH - fh * rows;
      if (leftX > 0 || leftY > 0) {
        warnings.add(
          'The sheet does not divide evenly: ${leftX > 0 ? '$leftX px unused on the right' : ''}'
          '${leftX > 0 && leftY > 0 ? ', ' : ''}${leftY > 0 ? '$leftY px unused at the bottom' : ''}.',
        );
      }
  }
  if (cols < 1 || rows < 1) throw const GridException('Columns and rows must be at least 1.');
  final grid = SpriteGrid(
    frameWidth: fw,
    frameHeight: fh,
    columns: cols,
    rows: rows,
    margin: spec.margin,
    spacing: spec.spacing,
    frameCount: cols * rows,
  );
  if (grid.usedWidth > sheetWidth || grid.usedHeight > sheetHeight) {
    final parts = <String>[
      if (grid.usedWidth > sheetWidth) 'columns exceed the width by ${grid.usedWidth - sheetWidth} px',
      if (grid.usedHeight > sheetHeight) 'rows exceed the height by ${grid.usedHeight - sheetHeight} px',
    ];
    throw GridException(
      'The grid needs ${grid.usedWidth}x${grid.usedHeight} px but the sheet is ${sheetWidth}x$sheetHeight '
      '(${parts.join(', ')}).',
    );
  }
  final count = spec.frameCount ?? grid.cellCount;
  if (count < 1) throw const GridException('Frame count must be at least 1.');
  if (count > grid.cellCount) {
    throw GridException('Frame count $count is larger than the ${grid.cellCount} cells of a $cols x $rows grid.');
  }
  return SpriteGrid(
    frameWidth: fw,
    frameHeight: fh,
    columns: cols,
    rows: rows,
    margin: spec.margin,
    spacing: spec.spacing,
    frameCount: count,
    warnings: warnings,
  );
}

/// Predictable frame file names: `<base>_000.png`, `<base>_001.png`...
/// Uses at least 3 digits, more when there are over 1000 frames.
List<String> frameFileNames(String base, int count, {String extension = 'png'}) {
  final digits = math.max(3, (count - 1).toString().length);
  final stem = sanitizeBaseName(base);
  return [for (var i = 0; i < count; i++) '${stem}_${i.toString().padLeft(digits, '0')}.$extension'];
}

/// Makes a user-entered base name safe for file names on every platform.
String sanitizeBaseName(String base) {
  var s = base.trim().replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').replaceAll(' ', '_');
  while (s.endsWith('.')) {
    s = s.substring(0, s.length - 1);
  }
  return s.isEmpty ? 'frame' : s;
}

/// Copies one frame out of [sheet].
Raster cropFrame(Raster sheet, FrameRect f) {
  final c = sheet.channels;
  final out = Uint8List(f.width * f.height * c);
  for (var row = 0; row < f.height; row++) {
    final srcStart = ((f.y + row) * sheet.width + f.x) * c;
    out.setRange(row * f.width * c, (row + 1) * f.width * c, sheet.pixels, srcStart);
  }
  return Raster(f.width, f.height, c, out);
}

/// True when every pixel of the frame is fully transparent.
bool isFrameEmpty(Raster sheet, FrameRect f) {
  if (!sheet.hasAlpha) return false;
  for (var row = 0; row < f.height; row++) {
    var i = ((f.y + row) * sheet.width + f.x) * 4 + 3;
    for (var col = 0; col < f.width; col++, i += 4) {
      if (sheet.pixels[i] != 0) return false;
    }
  }
  return true;
}

/// Number of frames left after dropping fully transparent trailing cells
/// (at least 1).
int countWithoutTrailingEmpty(Raster sheet, SpriteGrid grid) {
  var n = grid.cellCount;
  while (n > 1 && isFrameEmpty(sheet, grid.frame(n - 1))) {
    n--;
  }
  return n;
}

/// Slices every frame and encodes it as PNG, in order.
List<(String, Uint8List)> sliceFramesToPng(Raster sheet, SpriteGrid grid, String baseName) {
  final names = frameFileNames(baseName, grid.frameCount);
  return [for (var i = 0; i < grid.frameCount; i++) (names[i], encodePngRaster(cropFrame(sheet, grid.frame(i))))];
}

/// GIF frame delay (1/100 s) for [fps]. GIF viewers treat delays below
/// 2/100 s inconsistently, so 2 is the minimum (50 fps effective maximum).
int gifDelayForFps(int fps) => math.max(2, (100 / fps.clamp(1, 60)).round());

/// Encodes the frames as an endlessly looping animated GIF. The encoder
/// writes opaque palettes, so frames are flattened onto [background]. Each
/// frame gets its own palette (octree quantiser, no dithering), so sprites
/// with up to 256 colours per frame keep their exact colours.
Uint8List encodeFramesGif(Raster sheet, SpriteGrid grid, {required int fps, required Rgba background}) {
  final delay = gifDelayForFps(fps);
  final encoder = img.GifEncoder(
    repeat: 0,
    delay: delay,
    quantizerType: img.QuantizerType.octree,
    dither: img.DitherKernel.none,
  );
  for (var i = 0; i < grid.frameCount; i++) {
    final frame = cropFrame(sheet, grid.frame(i)).toImage();
    encoder.addFrame(flattenOnto(frame, background), duration: delay);
  }
  final bytes = encoder.finish();
  if (bytes == null) throw StateError('GIF encoder produced no data');
  return bytes;
}
