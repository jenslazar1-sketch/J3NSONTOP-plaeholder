import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZLibEncoderWeb, getCrc32;

/// Deterministic xorshift32 generator. `dart:math` `Random(seed)` is not
/// guaranteed to produce the same sequence across SDK versions/platforms, so
/// the sample generator uses its own.
class SampleRng {
  SampleRng(int seed) : _state = (seed & 0xFFFFFFFF) == 0 ? 0x9E3779B9 : seed & 0xFFFFFFFF;

  int _state;

  int nextUint32() {
    var x = _state;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _state = x & 0xFFFFFFFF;
    return _state;
  }

  /// Uniform integer in `[0, max)`.
  int nextInt(int max) => nextUint32() % max;

  /// Uniform integer in `[min, max]`.
  int range(int min, int max) => min + nextInt(max - min + 1);

  double nextDouble() => nextUint32() / 4294967296.0;

  bool chance(double p) => nextDouble() < p;

  T pick<T>(List<T> items) => items[nextInt(items.length)];
}

/// A small RGBA canvas for procedural pixel art. Colours are `0xAARRGGBB`.
class PixelCanvas {
  PixelCanvas(this.width, this.height) : rgba = Uint8List(width * height * 4);

  final int width;
  final int height;
  final Uint8List rgba;

  bool inside(int x, int y) => x >= 0 && y >= 0 && x < width && y < height;

  int get(int x, int y) {
    if (!inside(x, y)) return 0;
    final i = (y * width + x) * 4;
    return (rgba[i + 3] << 24) | (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2];
  }

  int alphaAt(int x, int y) => inside(x, y) ? rgba[(y * width + x) * 4 + 3] : 0;

  /// Replaces the pixel (no blending).
  void set(int x, int y, int argb) {
    if (!inside(x, y)) return;
    final i = (y * width + x) * 4;
    rgba[i] = (argb >> 16) & 0xFF;
    rgba[i + 1] = (argb >> 8) & 0xFF;
    rgba[i + 2] = argb & 0xFF;
    rgba[i + 3] = (argb >> 24) & 0xFF;
  }

  /// Source-over compositing of [argb] onto the pixel.
  void blend(int x, int y, int argb) {
    if (!inside(x, y)) return;
    final sa = ((argb >> 24) & 0xFF) / 255.0;
    if (sa <= 0) return;
    final i = (y * width + x) * 4;
    final da = rgba[i + 3] / 255.0;
    final oa = sa + da * (1 - sa);
    int mix(int s, int d) => ((s * sa + d * da * (1 - sa)) / oa).round().clamp(0, 255);
    rgba[i] = mix((argb >> 16) & 0xFF, rgba[i]);
    rgba[i + 1] = mix((argb >> 8) & 0xFF, rgba[i + 1]);
    rgba[i + 2] = mix(argb & 0xFF, rgba[i + 2]);
    rgba[i + 3] = (oa * 255).round().clamp(0, 255);
  }

  void fillRect(int x, int y, int w, int h, int argb) {
    for (var yy = y; yy < y + h; yy++) {
      for (var xx = x; xx < x + w; xx++) {
        set(xx, yy, argb);
      }
    }
  }

  void fillCircle(int cx, int cy, int r, int argb) {
    for (var y = cy - r; y <= cy + r; y++) {
      for (var x = cx - r; x <= cx + r; x++) {
        final dx = x - cx;
        final dy = y - cy;
        if (dx * dx + dy * dy <= r * r + r) set(x, y, argb);
      }
    }
  }

  /// Bresenham line with a square brush of [size] pixels.
  void line(int x0, int y0, int x1, int y1, int argb, {int size = 1}) {
    final dx = (x1 - x0).abs();
    final dy = -(y1 - y0).abs();
    final sx = x0 < x1 ? 1 : -1;
    final sy = y0 < y1 ? 1 : -1;
    var err = dx + dy;
    var x = x0;
    var y = y0;
    final lo = -(size - 1) ~/ 2;
    while (true) {
      for (var oy = 0; oy < size; oy++) {
        for (var ox = 0; ox < size; ox++) {
          set(x + lo + ox, y + lo + oy, argb);
        }
      }
      if (x == x1 && y == y1) break;
      final e2 = 2 * err;
      if (e2 >= dy) {
        err += dy;
        x += sx;
      }
      if (e2 <= dx) {
        err += dx;
        y += sy;
      }
    }
  }

  /// Draws character art: each character of [rows] maps to a colour in
  /// [palette]; characters missing from the palette are left untouched.
  void drawArt(List<String> rows, Map<String, int> palette, int ox, int oy, {bool mirror = false}) {
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      for (var c = 0; c < row.length; c++) {
        final colour = palette[row[c]];
        if (colour == null) continue;
        set(mirror ? ox + row.length - 1 - c : ox + c, oy + r, colour);
      }
    }
  }

  /// Adds a 1 px outline around everything drawn inside the given region:
  /// fully transparent pixels next to any drawn pixel become [argb].
  void outline(int argb, {int x0 = 0, int y0 = 0, int? x1, int? y1}) {
    final xe = x1 ?? width;
    final ye = y1 ?? height;
    final marks = <int>[];
    for (var y = y0; y < ye; y++) {
      for (var x = x0; x < xe; x++) {
        if (alphaAt(x, y) != 0) continue;
        bool solid(int nx, int ny) => nx >= x0 && ny >= y0 && nx < xe && ny < ye && alphaAt(nx, ny) != 0;
        if (solid(x - 1, y) || solid(x + 1, y) || solid(x, y - 1) || solid(x, y + 1)) {
          marks.add(y * width + x);
        }
      }
    }
    for (final m in marks) {
      set(m % width, m ~/ width, argb);
    }
  }

  /// Soft drop shadow: transparent pixels whose up-left neighbour is opaque
  /// get a translucent black, which gives icons real partial alpha.
  void dropShadow({int alpha = 0x60, int dx = 1, int dy = 1}) {
    final marks = <int>[];
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (alphaAt(x, y) != 0) continue;
        if (alphaAt(x - dx, y - dy) == 255) marks.add(y * width + x);
      }
    }
    for (final m in marks) {
      set(m % width, m ~/ width, alpha << 24);
    }
  }

  /// Copies [src] into this canvas at ([dx], [dy]) (replacing pixels).
  void blit(PixelCanvas src, int dx, int dy) {
    for (var y = 0; y < src.height; y++) {
      for (var x = 0; x < src.width; x++) {
        final c = src.get(x, y);
        if ((c >> 24) & 0xFF == 0) continue;
        set(dx + x, dy + y, c);
      }
    }
  }

  /// Nearest-neighbour upscale (pixel art stays crisp).
  PixelCanvas scaled(int factor) {
    final out = PixelCanvas(width * factor, height * factor);
    for (var y = 0; y < out.height; y++) {
      for (var x = 0; x < out.width; x++) {
        out.set(x, y, get(x ~/ factor, y ~/ factor));
      }
    }
    return out;
  }

  Uint8List toPng({Map<String, String> text = const {}}) => encodePngRgba(width, height, rgba, text: text);
}

/// Linear interpolation between two `0xAARRGGBB` colours.
int lerpColor(int a, int b, double t) {
  final tt = t.clamp(0.0, 1.0);
  int ch(int shift) {
    final ca = (a >> shift) & 0xFF;
    final cb = (b >> shift) & 0xFF;
    return (ca + (cb - ca) * tt).round() & 0xFF;
  }

  return (ch(24) << 24) | (ch(16) << 16) | (ch(8) << 8) | ch(0);
}

/// Replaces the alpha channel of [argb].
int withAlpha(int argb, int alpha) => ((alpha.clamp(0, 255)) << 24) | (argb & 0xFFFFFF);

/// Minimal, fully deterministic PNG encoder (8-bit RGBA, adaptive filters,
/// pure-Dart deflate). The platform zlib used by `package:image` can produce
/// different compressed bytes on different CPUs/OSes; this one cannot, so the
/// committed `samples/SHA256SUMS.txt` is reproducible everywhere.
Uint8List encodePngRgba(int width, int height, Uint8List rgba, {Map<String, String> text = const {}}) {
  if (rgba.length != width * height * 4) {
    throw ArgumentError('RGBA buffer has ${rgba.length} bytes, expected ${width * height * 4}');
  }
  final stride = width * 4;
  final filtered = BytesBuilder(copy: false);
  final prev = Uint8List(stride);
  for (var y = 0; y < height; y++) {
    final row = Uint8List.sublistView(rgba, y * stride, (y + 1) * stride);
    Uint8List? best;
    var bestType = 0;
    var bestScore = 1 << 62;
    for (final type in const [0, 1, 2, 4]) {
      final out = Uint8List(stride);
      for (var i = 0; i < stride; i++) {
        final a = i >= 4 ? row[i - 4] : 0;
        final b = prev[i];
        final c = i >= 4 ? prev[i - 4] : 0;
        final predictor = switch (type) {
          1 => a,
          2 => b,
          4 => _paeth(a, b, c),
          _ => 0,
        };
        out[i] = (row[i] - predictor) & 0xFF;
      }
      var score = 0;
      for (final v in out) {
        score += v < 128 ? v : 256 - v;
      }
      if (score < bestScore) {
        bestScore = score;
        best = out;
        bestType = type;
      }
    }
    filtered
      ..addByte(bestType)
      ..add(best!);
    prev.setAll(0, row);
  }
  final idat = const ZLibEncoderWeb().encodeBytes(filtered.takeBytes(), level: 9);

  final out = BytesBuilder(copy: false)..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final typeBytes = ascii.encode(type);
    final len = ByteData(4)..setUint32(0, data.length);
    out
      ..add(len.buffer.asUint8List())
      ..add(typeBytes)
      ..add(data);
    final crc = getCrc32(<int>[...typeBytes, ...data]);
    final crcBytes = ByteData(4)..setUint32(0, crc);
    out.add(crcBytes.buffer.asUint8List());
  }

  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6) // colour type RGBA
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  chunk('IHDR', ihdr.buffer.asUint8List());
  for (final e in text.entries) {
    chunk('tEXt', <int>[...latin1.encode(e.key), 0, ...latin1.encode(e.value)]);
  }
  chunk('IDAT', idat);
  chunk('IEND', const []);
  return out.takeBytes();
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

/// Separable box blur of a single-channel float mask (used for glows).
List<double> boxBlur(List<double> src, int width, int height, int radius) {
  var cur = List<double>.of(src);
  final tmp = List<double>.filled(src.length, 0);
  final span = radius * 2 + 1;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var sum = 0.0;
      for (var k = -radius; k <= radius; k++) {
        final xx = x + k;
        if (xx >= 0 && xx < width) sum += cur[y * width + xx];
      }
      tmp[y * width + x] = sum / span;
    }
  }
  cur = List<double>.filled(src.length, 0);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var sum = 0.0;
      for (var k = -radius; k <= radius; k++) {
        final yy = y + k;
        if (yy >= 0 && yy < height) sum += tmp[yy * width + x];
      }
      cur[y * width + x] = sum / span;
    }
  }
  return cur;
}

/// Rounds half away from zero (stable across platforms for our small values).
int roundHalfAway(double v) => v < 0 ? -(-v + 0.5).floor() : (v + 0.5).floor();
