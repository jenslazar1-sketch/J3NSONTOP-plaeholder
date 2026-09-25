import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'image_codec.dart';

/// Non-destructive Image Studio operations. Each operation is a small value
/// object that knows its output size (so the UI can validate the whole
/// pipeline instantly) and how to apply itself to pixels.

/// Largest output dimension an operation may produce.
const int maxOutputSide = 16384;

/// Pixel size (width x height).
class PixelSize {
  const PixelSize(this.width, this.height);
  final int width;
  final int height;
  int get pixels => width * height;
  @override
  bool operator ==(Object other) => other is PixelSize && other.width == width && other.height == height;
  @override
  int get hashCode => Object.hash(width, height);
  @override
  String toString() => '${width}x$height';
}

enum ResizeInterpolation {
  nearest('Nearest', img.Interpolation.nearest, 'Crisp pixel art'),
  linear('Linear', img.Interpolation.linear, 'Smooth, fast'),
  cubic('Cubic', img.Interpolation.cubic, 'Smoothest upscaling'),
  average('Average', img.Interpolation.average, 'Best for downscaling');

  const ResizeInterpolation(this.label, this.value, this.hint);
  final String label;
  final img.Interpolation value;
  final String hint;
}

enum FlipAxis { horizontal, vertical }

sealed class ImageOp {
  const ImageOp();

  /// Short human-readable description for the operation list.
  String get label;

  /// Returns an error message when this op cannot run on [input], else null.
  String? validate(PixelSize input);

  /// Output size for [input] (only meaningful when [validate] passes).
  PixelSize outputSize(PixelSize input);

  img.Image apply(img.Image input);

  Map<String, Object?> toJson();

  static ImageOp? fromJson(Map<String, Object?> j) {
    int? i(String k) => j[k] is int ? j[k] as int : null;
    switch (j['op']) {
      case 'resize':
        final w = i('width'), h = i('height');
        if (w == null || h == null) return null;
        final interp = ResizeInterpolation.values.where((e) => e.name == j['interpolation']).firstOrNull;
        return ResizeOp(w, h, interp ?? ResizeInterpolation.linear);
      case 'crop':
        final x = i('x'), y = i('y'), w = i('width'), h = i('height');
        if (x == null || y == null || w == null || h == null) return null;
        return CropOp(x, y, w, h);
      case 'rotate':
        final d = j['degrees'];
        return d is num ? RotateOp(d.toDouble()) : null;
      case 'flip':
        return FlipOp(j['axis'] == 'vertical' ? FlipAxis.vertical : FlipAxis.horizontal);
    }
    return null;
  }
}

class ResizeOp extends ImageOp {
  const ResizeOp(this.width, this.height, [this.interpolation = ResizeInterpolation.linear]);
  final int width;
  final int height;
  final ResizeInterpolation interpolation;

  @override
  String get label => 'Resize to ${width}x$height (${interpolation.label.toLowerCase()})';

  @override
  String? validate(PixelSize input) {
    if (width < 1 || height < 1) return 'Resize: width and height must be at least 1 px.';
    if (width > maxOutputSide || height > maxOutputSide) {
      return 'Resize: $maxOutputSide px is the largest supported side.';
    }
    if (width * height > maxImagePixels) return 'Resize: ${width}x$height exceeds the 64 MP limit.';
    return null;
  }

  @override
  PixelSize outputSize(PixelSize input) => PixelSize(width, height);

  @override
  img.Image apply(img.Image input) {
    if (input.width == width && input.height == height) return input.clone();
    return img.copyResize(input, width: width, height: height, interpolation: interpolation.value);
  }

  @override
  Map<String, Object?> toJson() => {
    'op': 'resize',
    'width': width,
    'height': height,
    'interpolation': interpolation.name,
  };

  @override
  bool operator ==(Object other) =>
      other is ResizeOp && other.width == width && other.height == height && other.interpolation == interpolation;
  @override
  int get hashCode => Object.hash('resize', width, height, interpolation);
}

class CropOp extends ImageOp {
  const CropOp(this.x, this.y, this.width, this.height);
  final int x;
  final int y;
  final int width;
  final int height;

  @override
  String get label => 'Crop ${width}x$height at ($x, $y)';

  /// Validates a crop rectangle against an input of [input] size.
  static String? check(int x, int y, int width, int height, PixelSize input) {
    if (x < 0 || y < 0) return 'Crop: X and Y cannot be negative.';
    if (width < 1 || height < 1) return 'Crop: width and height must be at least 1 px.';
    if (x >= input.width || y >= input.height) {
      return 'Crop: the start ($x, $y) lies outside the ${input.width}x${input.height} image.';
    }
    if (x + width > input.width) {
      return 'Crop: X + width = ${x + width} exceeds the image width ${input.width}.';
    }
    if (y + height > input.height) {
      return 'Crop: Y + height = ${y + height} exceeds the image height ${input.height}.';
    }
    return null;
  }

  @override
  String? validate(PixelSize input) => check(x, y, width, height, input);

  @override
  PixelSize outputSize(PixelSize input) => PixelSize(width, height);

  @override
  img.Image apply(img.Image input) => img.copyCrop(input, x: x, y: y, width: width, height: height);

  @override
  Map<String, Object?> toJson() => {'op': 'crop', 'x': x, 'y': y, 'width': width, 'height': height};

  @override
  bool operator ==(Object other) =>
      other is CropOp && other.x == x && other.y == y && other.width == width && other.height == height;
  @override
  int get hashCode => Object.hash('crop', x, y, width, height);
}

class RotateOp extends ImageOp {
  const RotateOp(this.degrees);

  /// Clockwise degrees. Multiples of 90 are lossless; other angles expand
  /// the canvas and fill the new corners with transparency.
  final double degrees;

  double get normalized {
    final m = degrees % 360;
    return m < 0 ? m + 360 : m;
  }

  bool get isRightAngle => normalized % 90 == 0;

  @override
  String get label {
    final d = normalized;
    final text = d == d.roundToDouble() ? d.toInt().toString() : d.toStringAsFixed(1);
    return isRightAngle ? 'Rotate $text°' : 'Rotate $text° (canvas expanded, transparent corners)';
  }

  @override
  String? validate(PixelSize input) {
    if (degrees.isNaN || degrees.isInfinite) return 'Rotate: angle must be a number.';
    final out = outputSize(input);
    if (out.width > maxOutputSide || out.height > maxOutputSide || out.pixels > maxImagePixels) {
      return 'Rotate: the rotated canvas ${out.width}x${out.height} is too large.';
    }
    if (out.width < 1 || out.height < 1) return 'Rotate: result would be empty.';
    return null;
  }

  @override
  PixelSize outputSize(PixelSize input) {
    final d = normalized;
    if (d == 0 || d == 180) return input;
    if (d == 90 || d == 270) return PixelSize(input.height, input.width);
    // Same formula as package:image copyRotate.
    final rad = d * math.pi / 180;
    final ca = math.cos(rad), sa = math.sin(rad);
    final ux = (input.width * ca).abs(), uy = (input.width * sa).abs();
    final vx = (input.height * sa).abs(), vy = (input.height * ca).abs();
    return PixelSize((ux + vx).toInt(), (uy + vy).toInt());
  }

  @override
  img.Image apply(img.Image input) {
    final d = normalized;
    if (d == 0) return input.clone();
    if (isRightAngle) return img.copyRotate(input, angle: d);
    // Arbitrary angles: work in RGBA so the expanded corners are transparent.
    final rgba = input.hasAlpha ? input : input.convert(numChannels: 4, alpha: 255);
    final out = img.copyRotate(rgba, angle: d, interpolation: img.Interpolation.linear);
    return out;
  }

  @override
  Map<String, Object?> toJson() => {'op': 'rotate', 'degrees': degrees};

  @override
  bool operator ==(Object other) => other is RotateOp && other.normalized == normalized;
  @override
  int get hashCode => Object.hash('rotate', normalized);
}

class FlipOp extends ImageOp {
  const FlipOp(this.axis);
  final FlipAxis axis;

  @override
  String get label => axis == FlipAxis.horizontal ? 'Flip horizontal' : 'Flip vertical';

  @override
  String? validate(PixelSize input) => null;

  @override
  PixelSize outputSize(PixelSize input) => input;

  @override
  img.Image apply(img.Image input) => img.copyFlip(
    input,
    direction: axis == FlipAxis.horizontal ? img.FlipDirection.horizontal : img.FlipDirection.vertical,
  );

  @override
  Map<String, Object?> toJson() => {'op': 'flip', 'axis': axis.name};

  @override
  bool operator ==(Object other) => other is FlipOp && other.axis == axis;
  @override
  int get hashCode => Object.hash('flip', axis);
}

/// Size after each step of a pipeline, with the first invalid step.
class PipelinePlan {
  const PipelinePlan({required this.sizes, this.errorIndex, this.error});

  /// sizes[0] is the source; sizes[i + 1] is the output of op i (only for
  /// valid steps).
  final List<PixelSize> sizes;
  final int? errorIndex;
  final String? error;

  bool get isValid => error == null;
  PixelSize get output => sizes.last;

  /// Number of leading ops that can run.
  int get runnableCount => errorIndex ?? (sizes.length - 1);
}

PipelinePlan planPipeline(PixelSize source, List<ImageOp> ops) {
  final sizes = [source];
  for (var i = 0; i < ops.length; i++) {
    final err = ops[i].validate(sizes.last);
    if (err != null) return PipelinePlan(sizes: sizes, errorIndex: i, error: 'Step ${i + 1}: $err');
    sizes.add(ops[i].outputSize(sizes.last));
  }
  return PipelinePlan(sizes: sizes);
}

/// Applies every valid op in order (stops at the first invalid one).
Raster applyPipeline(Raster source, List<ImageOp> ops) {
  final plan = planPipeline(PixelSize(source.width, source.height), ops);
  var image = source.toImage();
  for (var i = 0; i < plan.runnableCount; i++) {
    image = ops[i].apply(image);
  }
  return Raster.fromImage(image);
}

/// Immutable op list with undo/redo history.
class PipelineHistory {
  const PipelineHistory({this.ops = const [], this.undoStack = const [], this.redoStack = const []});

  static const int limit = 100;

  final List<ImageOp> ops;
  final List<List<ImageOp>> undoStack;
  final List<List<ImageOp>> redoStack;

  bool get canUndo => undoStack.isNotEmpty;
  bool get canRedo => redoStack.isNotEmpty;

  PipelineHistory _commit(List<ImageOp> next) {
    final undo = [...undoStack, ops];
    return PipelineHistory(
      ops: List.unmodifiable(next),
      undoStack: undo.length > limit ? undo.sublist(undo.length - limit) : undo,
      redoStack: const [],
    );
  }

  PipelineHistory add(ImageOp op) => _commit([...ops, op]);

  PipelineHistory removeAt(int index) {
    if (index < 0 || index >= ops.length) return this;
    return _commit([...ops]..removeAt(index));
  }

  PipelineHistory replaceAt(int index, ImageOp op) {
    if (index < 0 || index >= ops.length) return this;
    return _commit([...ops]..[index] = op);
  }

  PipelineHistory move(int from, int to) {
    if (from < 0 || from >= ops.length || to < 0 || to >= ops.length || from == to) return this;
    final list = [...ops];
    final item = list.removeAt(from);
    list.insert(to, item);
    return _commit(list);
  }

  /// Clears all operations (itself undoable).
  PipelineHistory reset() => ops.isEmpty ? this : _commit(const []);

  PipelineHistory undo() {
    if (!canUndo) return this;
    return PipelineHistory(
      ops: undoStack.last,
      undoStack: undoStack.sublist(0, undoStack.length - 1),
      redoStack: [...redoStack, ops],
    );
  }

  PipelineHistory redo() {
    if (!canRedo) return this;
    return PipelineHistory(
      ops: redoStack.last,
      undoStack: [...undoStack, ops],
      redoStack: redoStack.sublist(0, redoStack.length - 1),
    );
  }
}

/// Input for [renderStudio] (plain data; crosses isolates).
class StudioRenderRequest {
  const StudioRenderRequest({required this.source, required this.ops, required this.settings, this.previewMax = 1600});
  final Raster source;
  final List<ImageOp> ops;
  final ExportSettings settings;
  final int previewMax;
}

/// Output of [renderStudio].
class StudioRender {
  const StudioRender({
    required this.output,
    required this.previewPng,
    required this.previewScale,
    required this.width,
    required this.height,
    required this.hasAlpha,
    this.encoded,
    this.encodeError,
    this.pipelineError,
  });

  /// Full-resolution pipeline result (lets export-only changes re-encode
  /// without re-running the pipeline).
  final Raster output;
  final Uint8List previewPng;
  final double previewScale;
  final int width;
  final int height;
  final bool hasAlpha;

  /// The export file (null when encoding failed, see [encodeError]).
  final EncodedImage? encoded;
  final String? encodeError;

  /// First invalid step (the preview shows the steps before it).
  final String? pipelineError;
}

/// Applies the pipeline, builds a preview and encodes the export file.
StudioRender renderStudio(StudioRenderRequest r) {
  final plan = planPipeline(PixelSize(r.source.width, r.source.height), r.ops);
  final out = applyPipeline(r.source, r.ops);
  final preview = makePreview(out, r.previewMax);
  EncodedImage? encoded;
  String? encodeError;
  if (plan.isValid) {
    try {
      encoded = encodeRaster(out, r.settings);
    } on EncodeException catch (e) {
      encodeError = e.message;
    } catch (e) {
      encodeError = 'Encoding failed: $e';
    }
  } else {
    encodeError = 'Fix the pipeline error before exporting.';
  }
  return StudioRender(
    output: out,
    previewPng: preview.$1,
    previewScale: preview.$2,
    width: out.width,
    height: out.height,
    hasAlpha: out.hasAlpha,
    encoded: encoded,
    encodeError: encodeError,
    pipelineError: plan.error,
  );
}

/// Aspect presets for the interactive crop.
enum CropAspect {
  free('Free', null),
  square('1:1', 1),
  fourThree('4:3', 4 / 3),
  sixteenNine('16:9', 16 / 9);

  const CropAspect(this.label, this.ratio);
  final String label;

  /// width / height, null for free.
  final double? ratio;
}

/// Integer crop rectangle helper used by the interactive crop editor.
class CropRect {
  const CropRect(this.x, this.y, this.width, this.height);
  final int x;
  final int y;
  final int width;
  final int height;

  int get right => x + width;
  int get bottom => y + height;

  /// Clamps into [bounds] keeping at least 1x1.
  CropRect clampTo(PixelSize bounds) {
    final w = width.clamp(1, bounds.width);
    final h = height.clamp(1, bounds.height);
    final nx = x.clamp(0, bounds.width - w);
    final ny = y.clamp(0, bounds.height - h);
    return CropRect(nx, ny, w, h);
  }

  /// Largest rect with [ratio] (w/h) centred on this rect's centre inside
  /// [bounds].
  CropRect fitAspect(double ratio, PixelSize bounds) {
    final cx = x + width / 2, cy = y + height / 2;
    var w = width.toDouble();
    var h = w / ratio;
    if (h > height) {
      h = height.toDouble();
      w = h * ratio;
    }
    final maxW = math.min(bounds.width.toDouble(), bounds.height * ratio);
    if (w > maxW) {
      w = maxW;
      h = w / ratio;
    }
    final iw = math.max(1, w.round()), ih = math.max(1, h.round());
    return CropRect((cx - iw / 2).round(), (cy - ih / 2).round(), iw, ih).clampTo(bounds);
  }

  @override
  bool operator ==(Object other) =>
      other is CropRect && other.x == x && other.y == y && other.width == width && other.height == height;
  @override
  int get hashCode => Object.hash(x, y, width, height);
  @override
  String toString() => 'CropRect($x, $y, $width, $height)';
}

/// Resize helper: the other side for an aspect-locked edit.
int aspectLockedSide(int changedSide, int sourceChanged, int sourceOther) {
  if (sourceChanged <= 0) return sourceOther;
  return math.max(1, (changedSide * sourceOther / sourceChanged).round());
}

/// Size for a percentage scale.
PixelSize scaledByPercent(PixelSize input, double percent) =>
    PixelSize(math.max(1, (input.width * percent / 100).round()), math.max(1, (input.height * percent / 100).round()));
