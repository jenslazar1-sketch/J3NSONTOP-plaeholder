import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/color_model.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/palette.dart';

void main() {
  const swatches = [
    Swatch(id: 'a', name: 'Neon', color: Rgba(255, 22, 59)),
    Swatch(id: 'b', name: 'Void black', color: Rgba(5, 5, 7)),
    Swatch(id: 'c', name: 'Neon', color: Rgba(255, 255, 255, 128)),
    Swatch(id: 'd', name: '', color: Rgba(0, 128, 255)),
  ];

  group('document', () {
    test('versioned payload round trips and skips damaged entries', () {
      const doc = PaletteDocument(swatches: swatches);
      final json = jsonDecode(jsonEncode(doc.toJson())) as Map<String, dynamic>;
      expect(json['v'], PaletteDocument.version);
      expect(PaletteDocument.fromJson(json).swatches, swatches);

      final damaged = {
        'v': 1,
        'swatches': [
          {'id': 'x', 'name': 'ok', 'hex': '#010203FF'},
          {'id': 'y', 'name': 'bad', 'hex': 'zzz'},
          'garbage',
          {'id': 'x', 'name': 'dup', 'hex': '#000000FF'},
        ],
      };
      final loaded = PaletteDocument.fromJson(damaged);
      expect(loaded.swatches.map((s) => s.name), ['ok']);
      expect(PaletteDocument.fromJson(null).swatches, isEmpty);
      expect(PaletteDocument.fromJson({'v': 99}).swatches, isEmpty);
    });

    test('add, rename, move and remove', () {
      var doc = const PaletteDocument();
      for (final s in swatches) {
        doc = doc.add(s);
      }
      doc = doc.rename('b', '  Background ');
      expect(doc.swatches[1].name, 'Background');
      doc = doc.move(3, 0);
      expect(doc.swatches.map((s) => s.id), ['d', 'a', 'b', 'c']);
      doc = doc.move(0, 99);
      expect(doc.swatches.map((s) => s.id), ['a', 'b', 'c', 'd']);
      doc = doc.remove('c');
      expect(doc.swatches.map((s) => s.id), ['a', 'b', 'd']);
    });
  });

  group('exports', () {
    test('JSON', () {
      final out = jsonDecode(PaletteExport.json(swatches, title: 'Test')) as Map<String, dynamic>;
      expect(out['format'], 'j3palette');
      expect(out['name'], 'Test');
      final colors = out['colors'] as List;
      expect(colors, hasLength(4));
      expect(colors[0], {
        'name': 'Neon',
        'hex': '#FF163B',
        'rgba': [255, 22, 59, 255],
      });
      expect((colors[2] as Map)['hex'], '#FFFFFF80');
      expect((colors[3] as Map)['name'], 'Colour 4');
    });

    test('GIMP .gpl', () {
      final gpl = PaletteExport.gpl(swatches, title: 'Test');
      final lines = gpl.trim().split('\n');
      expect(lines[0], 'GIMP Palette');
      expect(lines[1], 'Name: Test');
      expect(lines[2], 'Columns: 4');
      expect(gpl, contains('255  22  59\tNeon'));
      expect(gpl, contains('  5   5   7\tVoid black'));
      expect(gpl, contains('# alpha of the next colour: 128/255 (dropped)'));
      final colourLines = lines.where((l) => RegExp(r'^\s*\d+\s+\d+\s+\d+\t').hasMatch(l));
      expect(colourLines, hasLength(4));
    });

    test('HEX list', () {
      expect(PaletteExport.hexList(swatches), '#FF163B\n#050507\n#FFFFFF80\n#0080FF\n');
      expect(PaletteExport.hexList(swatches, order: HexAlphaOrder.argb).split('\n')[2], '#80FFFFFF');
      expect(PaletteExport.hexList(const []), '');
    });

    test('CSS custom properties with unique slugs', () {
      final css = PaletteExport.css(swatches);
      expect(css, startsWith(':root {'));
      expect(css, contains('  --neon: #ff163b;'));
      expect(css, contains('  --void-black: #050507;'));
      expect(css, contains('  --neon-2: #ffffff80;'));
      expect(css, contains('  --colour-4: #0080ff;'));
      expect(css.trim(), endsWith('}'));
      expect(PaletteExport.cssSlug('3D Blue!'), 'c-3d-blue');
    });

    test('render dispatches on the format', () {
      for (final f in PaletteExportFormat.values) {
        expect(PaletteExport.render(swatches, f), isNotEmpty);
      }
    });
  });
}
