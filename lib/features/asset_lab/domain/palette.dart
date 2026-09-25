import 'dart:convert';

import 'color_model.dart';

/// One named colour in the saved palette.
class Swatch {
  const Swatch({required this.id, required this.name, required this.color});
  final String id;
  final String name;
  final Rgba color;

  Swatch copyWith({String? name, Rgba? color}) => Swatch(id: id, name: name ?? this.name, color: color ?? this.color);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'hex': ColorFormat.hex(color, forceAlpha: true)};

  static Swatch? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    final hex = raw['hex'];
    if (id is! String || hex is! String) return null;
    try {
      return Swatch(id: id, name: name is String ? name : '', color: ColorFormat.parseHex(hex));
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) => other is Swatch && other.id == id && other.name == name && other.color == color;

  @override
  int get hashCode => Object.hash(id, name, color);
}

/// The saved palette, persisted under the feature-data key
/// [PaletteDocument.storageKey] as a versioned payload:
/// `{"v": 1, "swatches": [{"id", "name", "hex": "#RRGGBBAA"}]}`.
class PaletteDocument {
  const PaletteDocument({this.swatches = const []});

  static const String storageKey = 'asset_lab.palette';
  static const int version = 1;
  static const int maxSwatches = 256;

  final List<Swatch> swatches;

  Map<String, dynamic> toJson() => {
    'v': version,
    'swatches': [for (final s in swatches) s.toJson()],
  };

  /// Tolerant loader: unknown/damaged entries are skipped, a newer payload
  /// version is read on a best-effort basis (fields are additive).
  static PaletteDocument fromJson(Object? raw) {
    if (raw is! Map) return const PaletteDocument();
    final list = raw['swatches'];
    if (list is! List) return const PaletteDocument();
    final seen = <String>{};
    final out = <Swatch>[];
    for (final item in list) {
      final s = Swatch.fromJson(item);
      if (s != null && seen.add(s.id) && out.length < maxSwatches) out.add(s);
    }
    return PaletteDocument(swatches: out);
  }

  PaletteDocument add(Swatch s) {
    if (swatches.length >= maxSwatches) {
      throw StateError('The palette is full ($maxSwatches colours). Remove some first.');
    }
    return PaletteDocument(swatches: [...swatches, s]);
  }

  PaletteDocument remove(String id) => PaletteDocument(swatches: swatches.where((s) => s.id != id).toList());

  PaletteDocument rename(String id, String name) =>
      PaletteDocument(swatches: [for (final s in swatches) s.id == id ? s.copyWith(name: name.trim()) : s]);

  /// Moves the swatch at [from] to [to] (indices into the current list).
  PaletteDocument move(int from, int to) {
    if (from < 0 || from >= swatches.length) return this;
    final list = [...swatches];
    final item = list.removeAt(from);
    list.insert(to.clamp(0, list.length), item);
    return PaletteDocument(swatches: list);
  }
}

/// Export formats offered for the palette.
enum PaletteExportFormat {
  json('JSON', 'palette.json', 'application/json'),
  gpl('GIMP .gpl', 'palette.gpl', 'text/plain'),
  hexList('HEX list', 'palette.txt', 'text/plain'),
  css('CSS variables', 'palette.css', 'text/css');

  const PaletteExportFormat(this.label, this.fileName, this.mimeType);
  final String label;
  final String fileName;
  final String mimeType;
}

abstract final class PaletteExport {
  static String render(
    List<Swatch> swatches,
    PaletteExportFormat format, {
    String title = 'J3NSONTOP Palette',
    HexAlphaOrder order = HexAlphaOrder.rgba,
  }) => switch (format) {
    PaletteExportFormat.json => json(swatches, title: title),
    PaletteExportFormat.gpl => gpl(swatches, title: title),
    PaletteExportFormat.hexList => hexList(swatches, order: order),
    PaletteExportFormat.css => css(swatches),
  };

  static String _displayName(Swatch s, int i) => s.name.trim().isEmpty ? 'Colour ${i + 1}' : s.name.trim();

  /// `{"format":"j3palette","version":1,"name":...,"colors":[...]}`.
  static String json(List<Swatch> swatches, {String title = 'J3NSONTOP Palette'}) {
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'j3palette',
      'version': 1,
      'name': title,
      'colors': [
        for (var i = 0; i < swatches.length; i++)
          {
            'name': _displayName(swatches[i], i),
            'hex': ColorFormat.hex(swatches[i].color, forceAlpha: !swatches[i].color.isOpaque),
            'rgba': [swatches[i].color.r, swatches[i].color.g, swatches[i].color.b, swatches[i].color.a],
          },
      ],
    });
  }

  /// GIMP palette. GPL has no alpha channel: translucent colours are written
  /// with their RGB values and the alpha noted in a comment.
  static String gpl(List<Swatch> swatches, {String title = 'J3NSONTOP Palette'}) {
    final b = StringBuffer()
      ..writeln('GIMP Palette')
      ..writeln('Name: ${title.replaceAll(RegExp(r'[\r\n]'), ' ')}')
      ..writeln('Columns: ${swatches.isEmpty ? 1 : (swatches.length < 8 ? swatches.length : 8)}')
      ..writeln('# Exported by J3NSONTOP Multitool. GPL stores RGB only.');
    for (var i = 0; i < swatches.length; i++) {
      final c = swatches[i].color;
      if (!c.isOpaque) b.writeln('# alpha of the next colour: ${c.a}/255 (dropped)');
      final name = _displayName(swatches[i], i).replaceAll(RegExp(r'[\r\n\t]'), ' ');
      b.writeln('${c.r.toString().padLeft(3)} ${c.g.toString().padLeft(3)} ${c.b.toString().padLeft(3)}\t$name');
    }
    return b.toString();
  }

  /// One HEX colour per line (`#RRGGBB`, or 8 digits in [order] when
  /// translucent).
  static String hexList(List<Swatch> swatches, {HexAlphaOrder order = HexAlphaOrder.rgba}) =>
      swatches.map((s) => ColorFormat.hex(s.color, order: order)).join('\n') + (swatches.isEmpty ? '' : '\n');

  /// CSS custom properties on `:root`. Names are slugified and made unique;
  /// translucent colours use CSS Color 4 `#RRGGBBAA`.
  static String css(List<Swatch> swatches) {
    final used = <String>{};
    final b = StringBuffer()..writeln(':root {');
    for (var i = 0; i < swatches.length; i++) {
      var slug = cssSlug(_displayName(swatches[i], i));
      if (slug.isEmpty) slug = 'color-${i + 1}';
      var unique = slug;
      var n = 2;
      while (!used.add(unique)) {
        unique = '$slug-${n++}';
      }
      b.writeln('  --$unique: ${ColorFormat.hex(swatches[i].color).toLowerCase()};');
    }
    b.writeln('}');
    return b.toString();
  }

  static String cssSlug(String name) {
    var s = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]+'), '-');
    s = s.replaceAll(RegExp(r'-{2,}'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    if (s.isNotEmpty && RegExp(r'^[0-9]').hasMatch(s)) s = 'c-$s';
    return s;
  }
}
