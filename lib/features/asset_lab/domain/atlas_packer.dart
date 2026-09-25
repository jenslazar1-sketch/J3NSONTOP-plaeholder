import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'image_codec.dart';

/// Texture atlas packing (MaxRects), independent validation, the `j3atlas`
/// JSON format (docs/ATLAS_FORMAT.md) and atlas image composition.
///
/// Geometry: with padding P and extrusion E every sprite of w x h reserves a
/// box of (w + 2E + P) x (h + 2E + P). Boxes are packed into a bin of
/// (W - P) x (H - P) and shifted by (P, P), so there are at least P
/// transparent pixels between any two extruded sprites and between every
/// sprite and the atlas border. Sprites are never rotated.

/// Supported maximum atlas sizes.
const List<int> atlasMaxSizes = [256, 512, 1024, 2048, 4096, 8192];

/// The size the packer probes up to when reporting how much room a set of
/// sprites needs.
const int atlasProbeLimit = 16384;

enum PackHeuristic {
  bestShortSideFit('MaxRects best short side fit'),
  bestAreaFit('MaxRects best area fit (fallback 1)'),
  bottomLeft('MaxRects bottom-left (fallback 2)');

  const PackHeuristic(this.label);
  final String label;
}

class AtlasOptions {
  const AtlasOptions({this.padding = 2, this.extrude = 0, this.maxSize = 2048, this.powerOfTwo = false});

  /// Transparent pixels between sprites and around the border (0..64).
  final int padding;

  /// Edge pixels duplicated around each sprite (0 or 1) to avoid bleeding
  /// with linear filtering.
  final int extrude;
  final int maxSize;
  final bool powerOfTwo;

  AtlasOptions copyWith({int? padding, int? extrude, int? maxSize, bool? powerOfTwo}) => AtlasOptions(
    padding: padding ?? this.padding,
    extrude: extrude ?? this.extrude,
    maxSize: maxSize ?? this.maxSize,
    powerOfTwo: powerOfTwo ?? this.powerOfTwo,
  );
}

/// A sprite to place (only its size matters for packing).
class AtlasInput {
  const AtlasInput(this.name, this.width, this.height);
  final String name;
  final int width;
  final int height;
}

/// A placed sprite. (x, y, w, h) is the sprite's own pixels, excluding
/// extrusion and padding.
class AtlasFrame {
  const AtlasFrame({
    required this.name,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.sourceW,
    required this.sourceH,
  });
  final String name;
  final int x;
  final int y;
  final int w;
  final int h;
  final int sourceW;
  final int sourceH;

  Map<String, int> toJson() => {'x': x, 'y': y, 'w': w, 'h': h, 'sourceW': sourceW, 'sourceH': sourceH};
}

class AtlasLayout {
  const AtlasLayout({
    required this.width,
    required this.height,
    required this.padding,
    required this.extrude,
    required this.frames,
    required this.heuristic,
  });
  final int width;
  final int height;
  final int padding;
  final int extrude;

  /// Sorted by name.
  final List<AtlasFrame> frames;
  final PackHeuristic heuristic;

  /// Fraction of the atlas covered by sprite pixels.
  double get efficiency {
    final used = frames.fold<int>(0, (s, f) => s + f.w * f.h);
    return width * height == 0 ? 0 : used / (width * height);
  }
}

/// Thrown when the sprites cannot be packed within the maximum size.
class AtlasDoesNotFit implements Exception {
  const AtlasDoesNotFit(this.message, {this.neededWidth, this.neededHeight, this.largestName, this.largestSize});
  final String message;

  /// Smallest size found by probing up to [atlasProbeLimit], if any.
  final int? neededWidth;
  final int? neededHeight;
  final String? largestName;
  final (int, int)? largestSize;

  @override
  String toString() => message;
}

class AtlasInputException implements Exception {
  const AtlasInputException(this.message);
  final String message;
  @override
  String toString() => message;
}

bool isPowerOfTwo(int v) => v > 0 && (v & (v - 1)) == 0;

int nextPowerOfTwo(int v) {
  var p = 1;
  while (p < v) {
    p <<= 1;
  }
  return p;
}

class _Rect {
  _Rect(this.x, this.y, this.w, this.h);
  final int x;
  final int y;
  final int w;
  final int h;
  int get right => x + w;
  int get bottom => y + h;

  bool contains(_Rect o) => o.x >= x && o.y >= y && o.right <= right && o.bottom <= bottom;
  bool intersects(_Rect o) => o.x < right && o.right > x && o.y < bottom && o.bottom > y;
}

/// Classic MaxRects bin (Jukka Jylänki, "A Thousand Ways to Pack the Bin").
class _MaxRectsBin {
  _MaxRectsBin(this.width, this.height) : _free = [_Rect(0, 0, width, height)];
  final int width;
  final int height;
  final List<_Rect> _free;

  _Rect? insert(int w, int h, PackHeuristic heuristic) {
    _Rect? best;
    var bestA = 1 << 62;
    var bestB = 1 << 62;
    for (final f in _free) {
      if (f.w < w || f.h < h) continue;
      int a, b;
      switch (heuristic) {
        case PackHeuristic.bestShortSideFit:
          final lw = f.w - w, lh = f.h - h;
          a = math.min(lw, lh);
          b = math.max(lw, lh);
        case PackHeuristic.bestAreaFit:
          a = f.w * f.h - w * h;
          b = math.min(f.w - w, f.h - h);
        case PackHeuristic.bottomLeft:
          a = f.y + h;
          b = f.x;
      }
      if (a < bestA || (a == bestA && b < bestB)) {
        bestA = a;
        bestB = b;
        best = _Rect(f.x, f.y, w, h);
      }
    }
    if (best != null) _place(best);
    return best;
  }

  void _place(_Rect used) {
    final added = <_Rect>[];
    for (var i = _free.length - 1; i >= 0; i--) {
      final f = _free[i];
      if (!f.intersects(used)) continue;
      _free.removeAt(i);
      if (used.x > f.x) added.add(_Rect(f.x, f.y, used.x - f.x, f.h));
      if (used.right < f.right) added.add(_Rect(used.right, f.y, f.right - used.right, f.h));
      if (used.y > f.y) added.add(_Rect(f.x, f.y, f.w, used.y - f.y));
      if (used.bottom < f.bottom) added.add(_Rect(f.x, used.bottom, f.w, f.bottom - used.bottom));
    }
    // Prune: drop new rects contained in any other rect, and old rects
    // contained in a new one. O(new x all) instead of O(all^2).
    final keptNew = <_Rect>[];
    for (var i = 0; i < added.length; i++) {
      final r = added[i];
      var redundant = false;
      for (final f in _free) {
        if (f.contains(r)) {
          redundant = true;
          break;
        }
      }
      if (!redundant) {
        for (var j = 0; j < added.length; j++) {
          if (i == j) continue;
          final o = added[j];
          if (o.contains(r) && (!r.contains(o) || j < i)) {
            redundant = true;
            break;
          }
        }
      }
      if (!redundant) keptNew.add(r);
    }
    _free.removeWhere((f) => keptNew.any((n) => n.contains(f)));
    _free.addAll(keptNew);
  }
}

/// Packs [boxes] (already sized with padding/extrusion) into a bin of
/// [binW] x [binH]. Returns positions in input order, or null if not all fit.
List<(int, int)>? _packInto(List<(int, int)> boxes, List<int> order, int binW, int binH, PackHeuristic h) {
  final bin = _MaxRectsBin(binW, binH);
  final pos = List<(int, int)?>.filled(boxes.length, null);
  for (final i in order) {
    final r = bin.insert(boxes[i].$1, boxes[i].$2, h);
    if (r == null) return null;
    pos[i] = (r.x, r.y);
  }
  return [for (final p in pos) p!];
}

/// Smaller area wins, with a mild penalty for elongated atlases (5% per unit
/// of aspect ratio above 1) so a nearly equal square-ish result is preferred.
/// Ties: smaller longest side, then narrower. Fully deterministic.
bool _better(_Candidate a, _Candidate b) {
  double cost(_Candidate c) => c.area * (1 + 0.05 * (math.max(c.width, c.height) / math.min(c.width, c.height) - 1));
  final ca = cost(a), cb = cost(b);
  if (ca != cb) return ca < cb;
  final ma = math.max(a.width, a.height), mb = math.max(b.width, b.height);
  if (ma != mb) return ma < mb;
  return a.width < b.width;
}

class _Candidate {
  _Candidate(this.width, this.height, this.positions, this.heuristic);
  final int width;
  final int height;
  final List<(int, int)> positions;
  final PackHeuristic heuristic;
  int get area => width * height;
}

/// Validates names: non-empty, no control characters, unique.
void checkAtlasNames(List<String> names) {
  final seen = <String>{};
  for (final n in names) {
    if (n.trim().isEmpty) throw const AtlasInputException('Every sprite needs a name.');
    if (n.codeUnits.any((c) => c < 32)) throw AtlasInputException('Sprite name "$n" contains control characters.');
    if (!seen.add(n)) throw AtlasInputException('Duplicate sprite name "$n". Names must be unique.');
  }
}

_Candidate? _search(List<(int, int)> boxes, AtlasOptions o, int maxSize, PackHeuristic heuristic, List<int> order) {
  final p = o.padding;
  final minW = boxes.fold<int>(0, (m, b) => math.max(m, b.$1)) + p;
  final minH = boxes.fold<int>(0, (m, b) => math.max(m, b.$2)) + p;
  if (minW > maxSize || minH > maxSize) return null;
  final area = boxes.fold<int>(0, (s, b) => s + b.$1 * b.$2);

  final widths = <int>{};
  if (o.powerOfTwo) {
    for (var w = nextPowerOfTwo(minW); w <= maxSize; w <<= 1) {
      widths.add(w);
    }
  } else {
    final ideal = math.max(minW, math.sqrt(area).ceil() + p);
    widths.add(minW);
    widths.add(math.min(maxSize, ideal));
    // Geometric probe from half the ideal width up to the maximum.
    var w = math.max(minW, ideal ~/ 2).toDouble();
    while (w <= maxSize) {
      widths.add(w.round().clamp(minW, maxSize));
      w *= 1.12;
    }
    widths.add(maxSize);
  }

  _Candidate? best;
  for (final w in widths.toList()..sort()) {
    final pos = _packInto(boxes, order, w - p, maxSize - p, heuristic);
    if (pos == null) continue;
    var usedW = 0, usedH = 0;
    for (var i = 0; i < boxes.length; i++) {
      usedW = math.max(usedW, pos[i].$1 + boxes[i].$1);
      usedH = math.max(usedH, pos[i].$2 + boxes[i].$2);
    }
    var aw = usedW + p;
    var ah = usedH + p;
    if (o.powerOfTwo) {
      aw = nextPowerOfTwo(aw);
      ah = nextPowerOfTwo(ah);
    }
    if (aw > maxSize || ah > maxSize) continue;
    final c = _Candidate(aw, ah, pos, heuristic);
    if (best == null || _better(c, best)) best = c;
  }
  return best;
}

/// Packs [inputs] into the smallest atlas found within [AtlasOptions.maxSize].
///
/// Deterministic: the same inputs and options always give the same layout.
/// Uses MaxRects best-short-side-fit; if that cannot fit everything, retries
/// with best-area-fit and then bottom-left (with a height-first ordering)
/// before throwing [AtlasDoesNotFit].
AtlasLayout packAtlas(List<AtlasInput> inputs, AtlasOptions o) {
  if (inputs.isEmpty) throw const AtlasInputException('Add at least one image to pack.');
  if (o.padding < 0 || o.padding > 64) throw const AtlasInputException('Padding must be between 0 and 64 px.');
  if (o.extrude < 0 || o.extrude > 1) throw const AtlasInputException('Extrude must be 0 or 1 px.');
  if (o.maxSize < 16 || o.maxSize > atlasProbeLimit) throw const AtlasInputException('Invalid maximum atlas size.');
  checkAtlasNames([for (final i in inputs) i.name]);
  for (final i in inputs) {
    if (i.width < 1 || i.height < 1) throw AtlasInputException('Sprite "${i.name}" is empty.');
  }
  final e = o.extrude, p = o.padding;
  final boxes = [for (final i in inputs) (i.width + 2 * e + p, i.height + 2 * e + p)];

  // Deterministic orders: largest side first, then area, then name.
  final bySide = List<int>.generate(inputs.length, (i) => i)
    ..sort((a, b) {
      final c = math.max(boxes[b].$1, boxes[b].$2).compareTo(math.max(boxes[a].$1, boxes[a].$2));
      if (c != 0) return c;
      final d = (boxes[b].$1 * boxes[b].$2).compareTo(boxes[a].$1 * boxes[a].$2);
      return d != 0 ? d : inputs[a].name.compareTo(inputs[b].name);
    });
  final byHeight = List<int>.generate(inputs.length, (i) => i)
    ..sort((a, b) {
      final c = boxes[b].$2.compareTo(boxes[a].$2);
      if (c != 0) return c;
      final d = boxes[b].$1.compareTo(boxes[a].$1);
      return d != 0 ? d : inputs[a].name.compareTo(inputs[b].name);
    });

  final attempts = [
    (PackHeuristic.bestShortSideFit, bySide),
    (PackHeuristic.bestAreaFit, bySide),
    (PackHeuristic.bottomLeft, byHeight),
  ];

  _Candidate? found;
  for (final (h, order) in attempts) {
    found = _search(boxes, o, o.maxSize, h, order);
    if (found != null) break;
  }

  if (found == null) {
    var largest = 0;
    for (var i = 1; i < inputs.length; i++) {
      if (inputs[i].width * inputs[i].height > inputs[largest].width * inputs[largest].height) largest = i;
    }
    final li = inputs[largest];
    final widest = inputs.reduce((a, b) => a.width >= b.width ? a : b);
    final tallest = inputs.reduce((a, b) => a.height >= b.height ? a : b);
    final needSide = math.max(widest.width, tallest.height) + 2 * e + 2 * p;
    if (needSide > o.maxSize) {
      final culprit = widest.width >= tallest.height ? widest : tallest;
      throw AtlasDoesNotFit(
        'Sprite "${culprit.name}" (${culprit.width}x${culprit.height}) plus padding/extrusion needs a '
        '$needSide px side, larger than the ${o.maxSize} px maximum.',
        largestName: culprit.name,
        largestSize: (culprit.width, culprit.height),
      );
    }
    final probe = _search(
      boxes,
      o.copyWith(maxSize: atlasProbeLimit),
      atlasProbeLimit,
      PackHeuristic.bestShortSideFit,
      bySide,
    );
    final totalArea = boxes.fold<int>(0, (s, b) => s + b.$1 * b.$2);
    final lowerBound = math.sqrt(totalArea).ceil() + p;
    final needed = probe == null
        ? 'at least ${lowerBound}x$lowerBound px (more than the $atlasProbeLimit px probe limit)'
        : '${probe.width}x${probe.height} px';
    throw AtlasDoesNotFit(
      '${inputs.length} sprites do not fit in ${o.maxSize}x${o.maxSize}. They need $needed. '
      'Largest sprite: "${li.name}" (${li.width}x${li.height}). Raise the maximum size, reduce padding or split the set.',
      neededWidth: probe?.width,
      neededHeight: probe?.height,
      largestName: li.name,
      largestSize: (li.width, li.height),
    );
  }

  final frames = <AtlasFrame>[
    for (var i = 0; i < inputs.length; i++)
      AtlasFrame(
        name: inputs[i].name,
        x: found.positions[i].$1 + p + e,
        y: found.positions[i].$2 + p + e,
        w: inputs[i].width,
        h: inputs[i].height,
        sourceW: inputs[i].width,
        sourceH: inputs[i].height,
      ),
  ]..sort((a, b) => a.name.compareTo(b.name));
  return AtlasLayout(
    width: found.width,
    height: found.height,
    padding: p,
    extrude: e,
    frames: frames,
    heuristic: found.heuristic,
  );
}

/// Outcome of [validateAtlas].
class AtlasValidation {
  const AtlasValidation({required this.issues, required this.frameCount, required this.pairsChecked});
  final List<String> issues;
  final int frameCount;

  /// Number of candidate pairs whose padded boxes were compared.
  final int pairsChecked;
  bool get ok => issues.isEmpty;
}

/// Independently proves a layout is sound: every padded box (sprite +
/// extrusion, extended by the padding to the right/bottom) lies inside the
/// atlas with the padding border, and no two padded boxes overlap. Uses a
/// sweep over x so hundreds of frames are checked quickly.
AtlasValidation validateAtlas({
  required int width,
  required int height,
  required int padding,
  required int extrude,
  required List<AtlasFrame> frames,
}) {
  final issues = <String>[];
  final names = <String>{};
  final boxes = <(_Rect, String)>[];
  for (final f in frames) {
    if (!names.add(f.name)) issues.add('Duplicate frame name "${f.name}".');
    if (f.w < 1 || f.h < 1) {
      issues.add('"${f.name}" has an empty size ${f.w}x${f.h}.');
      continue;
    }
    final box = _Rect(f.x - extrude, f.y - extrude, f.w + 2 * extrude + padding, f.h + 2 * extrude + padding);
    if (box.x < padding || box.y < padding || box.right > width || box.bottom > height) {
      issues.add(
        '"${f.name}" at (${f.x}, ${f.y}) ${f.w}x${f.h} is outside the ${width}x$height atlas '
        '(with $padding px padding and $extrude px extrusion).',
      );
    }
    boxes.add((box, f.name));
  }
  boxes.sort((a, b) => a.$1.x.compareTo(b.$1.x));
  var pairs = 0;
  for (var i = 0; i < boxes.length; i++) {
    final a = boxes[i].$1;
    for (var j = i + 1; j < boxes.length && boxes[j].$1.x < a.right; j++) {
      pairs++;
      if (a.intersects(boxes[j].$1)) {
        issues.add('"${boxes[i].$2}" and "${boxes[j].$2}" overlap (including padding).');
        if (issues.length > 50) {
          return AtlasValidation(issues: issues, frameCount: frames.length, pairsChecked: pairs);
        }
      }
    }
  }
  return AtlasValidation(issues: issues, frameCount: frames.length, pairsChecked: pairs);
}

AtlasValidation validateLayout(AtlasLayout l) =>
    validateAtlas(width: l.width, height: l.height, padding: l.padding, extrude: l.extrude, frames: l.frames);

/// The `j3atlas` v1 JSON document (see docs/ATLAS_FORMAT.md).
Map<String, Object?> atlasJsonMap(AtlasLayout l, String imageName) => {
  'meta': {
    'app': 'J3NSONTOP Multitool',
    'format': 'j3atlas',
    'version': 1,
    'image': imageName,
    'size': {'w': l.width, 'h': l.height},
    'padding': l.padding,
    'extrude': l.extrude,
  },
  'frames': {for (final f in l.frames) f.name: f.toJson()},
};

String atlasJson(AtlasLayout l, String imageName) =>
    const JsonEncoder.withIndent('  ').convert(atlasJsonMap(l, imageName));

/// Parses a `j3atlas` document back (used by tests and for re-validation).
(int, int, int, int, List<AtlasFrame>) parseAtlasJson(String source) {
  final root = jsonDecode(source);
  if (root is! Map) throw const FormatException('Atlas JSON must be an object');
  final meta = root['meta'];
  if (meta is! Map || meta['format'] != 'j3atlas') throw const FormatException('Not a j3atlas document');
  if (meta['version'] != 1) throw FormatException('Unsupported j3atlas version ${meta['version']}');
  final size = meta['size'];
  if (size is! Map || size['w'] is! int || size['h'] is! int) throw const FormatException('meta.size is invalid');
  final padding = meta['padding'] is int ? meta['padding'] as int : 0;
  final extrude = meta['extrude'] is int ? meta['extrude'] as int : 0;
  final framesRaw = root['frames'];
  if (framesRaw is! Map) throw const FormatException('frames must be an object');
  final frames = <AtlasFrame>[];
  framesRaw.forEach((k, v) {
    if (v is! Map) throw FormatException('Frame "$k" is invalid');
    int field(String n) {
      final x = v[n];
      if (x is! int) throw FormatException('Frame "$k" has no integer "$n"');
      return x;
    }

    frames.add(
      AtlasFrame(
        name: k as String,
        x: field('x'),
        y: field('y'),
        w: field('w'),
        h: field('h'),
        sourceW: field('sourceW'),
        sourceH: field('sourceH'),
      ),
    );
  });
  return (size['w'] as int, size['h'] as int, padding, extrude, frames);
}

/// Draws the sprites into a transparent RGBA atlas, extruding edges when
/// the layout asks for it.
Raster composeAtlas(AtlasLayout l, Map<String, Raster> sprites) {
  final w = l.width, h = l.height;
  final out = Uint8List(w * h * 4);
  final e = l.extrude;
  for (final f in l.frames) {
    final s = sprites[f.name];
    if (s == null) throw StateError('Missing pixels for "${f.name}"');
    if (s.width != f.w || s.height != f.h) throw StateError('"${f.name}" changed size since packing');
    // Destination rows y-e .. y+h+e-1, columns x-e .. x+w+e-1, sampling the
    // clamped source pixel (identity inside, edge copy in the extrusion).
    for (var dy = -e; dy < f.h + e; dy++) {
      final sy = dy.clamp(0, f.h - 1);
      final rowOut = ((f.y + dy) * w + (f.x - e)) * 4;
      for (var dx = -e; dx < f.w + e; dx++) {
        final sx = dx.clamp(0, f.w - 1);
        final si = (sy * s.width + sx) * s.channels;
        final di = rowOut + (dx + e) * 4;
        out[di] = s.pixels[si];
        out[di + 1] = s.pixels[si + 1];
        out[di + 2] = s.pixels[si + 2];
        out[di + 3] = s.channels == 4 ? s.pixels[si + 3] : 255;
      }
    }
  }
  return Raster(w, h, 4, out);
}
