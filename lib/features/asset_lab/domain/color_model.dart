import 'dart:math' as math;

/// Pure colour math for the Color Lab: RGBA <-> HSV/HSL, HEX/CSS parsing and
/// formatting, and WCAG 2.x contrast. No Flutter imports so it can be unit
/// tested and reused from scripts.

/// An 8-bit sRGB colour with an 8-bit alpha channel.
class Rgba {
  const Rgba(this.r, this.g, this.b, [this.a = 255])
    : assert(r >= 0 && r <= 255),
      assert(g >= 0 && g <= 255),
      assert(b >= 0 && b <= 255),
      assert(a >= 0 && a <= 255);

  /// From a Flutter-style 0xAARRGGBB integer.
  factory Rgba.fromArgb32(int argb) => Rgba((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF, (argb >> 24) & 0xFF);

  static const Rgba black = Rgba(0, 0, 0);
  static const Rgba white = Rgba(255, 255, 255);
  static const Rgba transparent = Rgba(0, 0, 0, 0);

  final int r;
  final int g;
  final int b;
  final int a;

  /// 0xAARRGGBB (Flutter `Color(int)` order).
  int get argb32 => (a << 24) | (r << 16) | (g << 8) | b;

  double get alpha => a / 255;
  bool get isOpaque => a == 255;

  Rgba withAlpha(int alpha) => Rgba(r, g, b, alpha.clamp(0, 255));
  Rgba get opaque => Rgba(r, g, b);

  /// Source-over composite of this colour onto an opaque [background].
  Rgba over(Rgba background) {
    if (a == 255) return this;
    final t = a / 255;
    int mix(int f, int bg) => (f * t + bg * (1 - t)).round().clamp(0, 255);
    return Rgba(mix(r, background.r), mix(g, background.g), mix(b, background.b));
  }

  @override
  bool operator ==(Object other) => other is Rgba && other.r == r && other.g == g && other.b == b && other.a == a;

  @override
  int get hashCode => Object.hash(r, g, b, a);

  @override
  String toString() => 'Rgba($r, $g, $b, $a)';
}

/// Hue/saturation/value. [h] in degrees 0..360 (exclusive), [s] and [v]
/// 0..1, [a] 0..1.
class Hsv {
  const Hsv(this.h, this.s, this.v, [this.a = 1]);
  final double h;
  final double s;
  final double v;
  final double a;

  Hsv copyWith({double? h, double? s, double? v, double? a}) =>
      Hsv(h ?? this.h, (s ?? this.s).clamp(0, 1), (v ?? this.v).clamp(0, 1), (a ?? this.a).clamp(0, 1));

  @override
  bool operator ==(Object other) => other is Hsv && other.h == h && other.s == s && other.v == v && other.a == a;

  @override
  int get hashCode => Object.hash(h, s, v, a);

  @override
  String toString() => 'Hsv($h, $s, $v, $a)';
}

/// Hue/saturation/lightness. Same ranges as [Hsv].
class Hsl {
  const Hsl(this.h, this.s, this.l, [this.a = 1]);
  final double h;
  final double s;
  final double l;
  final double a;

  @override
  String toString() => 'Hsl($h, $s, $l, $a)';
}

/// Byte order for 8-digit HEX colours. CSS Color 4 writes `#RRGGBBAA`;
/// Android resources and Flutter (`0xAARRGGBB`) put alpha first.
enum HexAlphaOrder {
  rgba('#RRGGBBAA (CSS)'),
  argb('#AARRGGBB (Android / Flutter)');

  const HexAlphaOrder(this.label);
  final String label;
}

abstract final class ColorMath {
  static double _wrapHue(double h) {
    final m = h % 360;
    return m < 0 ? m + 360 : m;
  }

  static int _byte(double unit) => (unit * 255).round().clamp(0, 255);

  static Hsv toHsv(Rgba c) {
    final r = c.r / 255, g = c.g / 255, b = c.b / 255;
    final maxC = math.max(r, math.max(g, b));
    final minC = math.min(r, math.min(g, b));
    final d = maxC - minC;
    double h;
    if (d == 0) {
      h = 0;
    } else if (maxC == r) {
      h = 60 * (((g - b) / d) % 6);
    } else if (maxC == g) {
      h = 60 * (((b - r) / d) + 2);
    } else {
      h = 60 * (((r - g) / d) + 4);
    }
    final s = maxC == 0 ? 0.0 : d / maxC;
    return Hsv(_wrapHue(h), s, maxC, c.alpha);
  }

  static Rgba fromHsv(Hsv hsv) {
    final h = _wrapHue(hsv.h);
    final s = hsv.s.clamp(0.0, 1.0);
    final v = hsv.v.clamp(0.0, 1.0);
    final c = v * s;
    final x = c * (1 - ((h / 60) % 2 - 1).abs());
    final m = v - c;
    final (r1, g1, b1) = _sector(h, c, x);
    return Rgba(_byte(r1 + m), _byte(g1 + m), _byte(b1 + m), _byte(hsv.a.clamp(0.0, 1.0)));
  }

  static Hsl toHsl(Rgba c) {
    final r = c.r / 255, g = c.g / 255, b = c.b / 255;
    final maxC = math.max(r, math.max(g, b));
    final minC = math.min(r, math.min(g, b));
    final d = maxC - minC;
    final l = (maxC + minC) / 2;
    final s = d == 0 ? 0.0 : d / (1 - (2 * l - 1).abs());
    final h = toHsv(c).h;
    return Hsl(h, s.clamp(0.0, 1.0), l, c.alpha);
  }

  static Rgba fromHsl(Hsl hsl) {
    final h = _wrapHue(hsl.h);
    final s = hsl.s.clamp(0.0, 1.0);
    final l = hsl.l.clamp(0.0, 1.0);
    final c = (1 - (2 * l - 1).abs()) * s;
    final x = c * (1 - ((h / 60) % 2 - 1).abs());
    final m = l - c / 2;
    final (r1, g1, b1) = _sector(h, c, x);
    return Rgba(_byte(r1 + m), _byte(g1 + m), _byte(b1 + m), _byte(hsl.a.clamp(0.0, 1.0)));
  }

  static (double, double, double) _sector(double h, double c, double x) {
    if (h < 60) return (c, x, 0);
    if (h < 120) return (x, c, 0);
    if (h < 180) return (0, c, x);
    if (h < 240) return (0, x, c);
    if (h < 300) return (x, 0, c);
    return (c, 0, x);
  }

  // ---------------------------------------------------------------- WCAG

  static double _channel(int v) {
    final s = v / 255;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  /// WCAG 2.x relative luminance of the opaque colour (alpha ignored).
  static double relativeLuminance(Rgba c) => 0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

  /// Contrast ratio 1..21. A translucent [foreground] is composited over
  /// [background] first; the background is treated as opaque.
  static double contrastRatio(Rgba foreground, Rgba background) {
    final bg = background.opaque;
    final fg = foreground.over(bg);
    final l1 = relativeLuminance(fg);
    final l2 = relativeLuminance(bg);
    final hi = math.max(l1, l2);
    final lo = math.min(l1, l2);
    return (hi + 0.05) / (lo + 0.05);
  }
}

/// WCAG 2.x success criteria checked by the contrast checker.
enum WcagLevel {
  aaNormal('AA', 'normal text', 4.5),
  aaLarge('AA', 'large text (18pt / 14pt bold)', 3.0),
  aaaNormal('AAA', 'normal text', 7.0),
  aaaLarge('AAA', 'large text', 4.5),
  uiComponents('AA', 'UI components & graphics', 3.0);

  const WcagLevel(this.grade, this.scope, this.minRatio);
  final String grade;
  final String scope;
  final double minRatio;

  bool passes(double ratio) => ratio + 1e-9 >= minRatio;
}

/// Parsing and formatting of textual colour notations.
abstract final class ColorFormat {
  static final RegExp _hexDigits = RegExp(r'^[0-9a-fA-F]+$');

  /// Parses HEX: `#RGB`, `#RGBA`, `#RRGGBB` and 8 digits in [order]
  /// (`#RRGGBBAA` or `#AARRGGBB`). The `#` is optional. `0xAARRGGBB`
  /// (Flutter/Dart literal) is always alpha-first. Throws [FormatException].
  static Rgba parseHex(String input, {HexAlphaOrder order = HexAlphaOrder.rgba}) {
    var s = input.trim();
    var forceArgb = false;
    if (s.toLowerCase().startsWith('0x')) {
      s = s.substring(2);
      forceArgb = true;
      if (s.length != 8 && s.length != 6) {
        throw const FormatException('0x notation needs 6 or 8 hex digits (0xRRGGBB / 0xAARRGGBB)');
      }
    } else if (s.startsWith('#')) {
      s = s.substring(1);
    }
    if (s.isEmpty) throw const FormatException('Enter a colour such as #FF163B');
    if (!_hexDigits.hasMatch(s)) {
      throw FormatException('"$input" contains characters that are not hex digits (0-9, A-F)');
    }
    int h(int i) => int.parse(s.substring(i, i + 2), radix: 16);
    int d(int i) => int.parse(s[i] * 2, radix: 16);
    switch (s.length) {
      case 3:
        return Rgba(d(0), d(1), d(2));
      case 4:
        return Rgba(d(0), d(1), d(2), d(3));
      case 6:
        return Rgba(h(0), h(2), h(4));
      case 8:
        if (forceArgb || order == HexAlphaOrder.argb) return Rgba(h(2), h(4), h(6), h(0));
        return Rgba(h(0), h(2), h(4), h(6));
      default:
        throw FormatException('HEX colours have 3, 4, 6 or 8 digits; "$input" has ${s.length}');
    }
  }

  static String _hh(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();

  /// `#RRGGBB` when opaque (or [forceAlpha] false and opaque), otherwise
  /// 8 digits in [order].
  static String hex(Rgba c, {HexAlphaOrder order = HexAlphaOrder.rgba, bool forceAlpha = false}) {
    if (c.isOpaque && !forceAlpha) return '#${_hh(c.r)}${_hh(c.g)}${_hh(c.b)}';
    return order == HexAlphaOrder.rgba
        ? '#${_hh(c.r)}${_hh(c.g)}${_hh(c.b)}${_hh(c.a)}'
        : '#${_hh(c.a)}${_hh(c.r)}${_hh(c.g)}${_hh(c.b)}';
  }

  static String _num(double v, [int decimals = 2]) {
    final s = v.toStringAsFixed(decimals);
    if (!s.contains('.')) return s;
    return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }

  static String rgb(Rgba c) =>
      c.isOpaque ? 'rgb(${c.r}, ${c.g}, ${c.b})' : 'rgba(${c.r}, ${c.g}, ${c.b}, ${_num(c.alpha, 3)})';

  static String hsl(Rgba c) {
    final v = ColorMath.toHsl(c);
    final core = '${_num(v.h, 1)}, ${_num(v.s * 100, 1)}%, ${_num(v.l * 100, 1)}%';
    return c.isOpaque ? 'hsl($core)' : 'hsla($core, ${_num(c.alpha, 3)})';
  }

  static String hsv(Rgba c) {
    final v = ColorMath.toHsv(c);
    final core = '${_num(v.h, 1)}, ${_num(v.s * 100, 1)}%, ${_num(v.v * 100, 1)}%';
    return c.isOpaque ? 'hsv($core)' : 'hsva($core, ${_num(c.alpha, 3)})';
  }

  static final RegExp _func = RegExp(r'^\s*([a-zA-Z]*)\s*\(\s*(.*?)\s*\)\s*$');

  /// Splits `name(a, b, c[, d])`, `name(a b c / d)` or a bare `a, b, c`.
  static (String, List<String>) _args(String input, String expectedName) {
    final m = _func.firstMatch(input);
    String name;
    String body;
    if (m != null) {
      name = m.group(1)!.toLowerCase();
      body = m.group(2)!;
    } else {
      name = expectedName;
      body = input.trim();
    }
    final parts = body
        .replaceAll('/', ' ')
        .split(RegExp(r'[\s,]+'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    return (name, parts);
  }

  static double _parseNum(String raw, String what) {
    final v = double.tryParse(raw.replaceAll('%', '').replaceAll('°', '').replaceAll('deg', ''));
    if (v == null || v.isNaN || v.isInfinite) throw FormatException('$what "$raw" is not a number');
    return v;
  }

  /// Alpha as `0..1` or `0%..100%`.
  static int _parseAlpha(String raw) {
    final v = _parseNum(raw, 'Alpha');
    final unit = raw.endsWith('%') ? v / 100 : v;
    if (unit < 0 || unit > 1) throw FormatException('Alpha must be between 0 and 1 (or 0%-100%), got "$raw"');
    return (unit * 255).round();
  }

  /// Parses `rgb(255, 22, 59)`, `rgba(255, 22, 59, 0.5)`, `rgb(255 22 59 / 50%)`
  /// or a bare `255, 22, 59[, 0.5]`. Channels 0..255 or percentages.
  static Rgba parseRgb(String input) {
    final (name, parts) = _args(input, 'rgb');
    if (name != 'rgb' && name != 'rgba') throw FormatException('Expected rgb(...) or rgba(...), got "$name(...)"');
    if (parts.length != 3 && parts.length != 4) {
      throw FormatException('RGB needs 3 channels plus optional alpha, got ${parts.length} values');
    }
    int channel(String raw, String label) {
      final v = _parseNum(raw, label);
      final value = raw.endsWith('%') ? v * 255 / 100 : v;
      if (value < 0 || value > 255.0001) throw FormatException('$label must be 0-255 (or 0%-100%), got "$raw"');
      return value.round().clamp(0, 255);
    }

    return Rgba(
      channel(parts[0], 'Red'),
      channel(parts[1], 'Green'),
      channel(parts[2], 'Blue'),
      parts.length == 4 ? _parseAlpha(parts[3]) : 255,
    );
  }

  static (double, double, double, int) _hueTriple(String input, List<String> names, String what) {
    final (name, parts) = _args(input, names.first);
    if (!names.contains(name)) throw FormatException('Expected ${names.first}(...), got "$name(...)"');
    if (parts.length != 3 && parts.length != 4) {
      throw FormatException('$what needs hue, two percentages and optional alpha');
    }
    final h = _parseNum(parts[0], 'Hue');
    double pct(String raw, String label) {
      final v = _parseNum(raw, label);
      final unit = raw.endsWith('%') ? v / 100 : (v > 1 ? v / 100 : v);
      if (unit < 0 || unit > 1.00001) throw FormatException('$label must be 0%-100%, got "$raw"');
      return unit.clamp(0.0, 1.0);
    }

    return (
      h,
      pct(parts[1], 'Saturation'),
      pct(parts[2], names.first == 'hsl' ? 'Lightness' : 'Value'),
      parts.length == 4 ? _parseAlpha(parts[3]) : 255,
    );
  }

  /// Parses `hsl(350, 100%, 54%)` / `hsla(...)` / bare triple.
  static Rgba parseHsl(String input) {
    final (h, s, l, a) = _hueTriple(input, const ['hsl', 'hsla'], 'HSL');
    return ColorMath.fromHsl(Hsl(h, s, l, a / 255));
  }

  /// Parses `hsv(350, 91%, 100%)` / `hsb(...)` / `hsva(...)` / bare triple.
  static Rgba parseHsv(String input) {
    final (h, s, v, a) = _hueTriple(input, const ['hsv', 'hsva', 'hsb', 'hsba'], 'HSV');
    return ColorMath.fromHsv(Hsv(h, s, v, a / 255));
  }

  /// Best-effort parse of any supported notation (terminal command).
  static Rgba parseAny(String input, {HexAlphaOrder order = HexAlphaOrder.rgba}) {
    final t = input.trim().toLowerCase();
    if (t.startsWith('rgb')) return parseRgb(input);
    if (t.startsWith('hsl')) return parseHsl(input);
    if (t.startsWith('hsv') || t.startsWith('hsb')) return parseHsv(input);
    return parseHex(input, order: order);
  }
}
