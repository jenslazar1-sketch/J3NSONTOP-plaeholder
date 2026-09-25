import 'dart:math' as math;
import 'dart:typed_data';

import 'pixel_canvas.dart';

// Procedural pixel art for the Neon Dungeon sample. Everything is drawn from
// fixed tables and seeded generators, so the PNG bytes never change.

const int _outline = 0xFF1A0008;
const int _red = 0xFFFF1744;
const int _redDark = 0xFFB0002A;
const int _redDeep = 0xFF7A001C;
const int _redLight = 0xFFFF6E86;
const int _pink = 0xFFFFB3C1;
const int _white = 0xFFFFFFFF;
const int _bone = 0xFFF5F5F5;
const int _greyLight = 0xFFE3E7EA;
const int _grey = 0xFFB0BEC5;
const int _greyDark = 0xFF78909C;
const int _brown = 0xFF8D5A3B;
const int _brownDark = 0xFF5D3A26;
const int _glass = 0x99D8ECFF;
const int _black = 0xFF0A0A0A;

/// Colours used by [heroWalkSheet].
class HeroPalette {
  const HeroPalette({
    required this.outline,
    required this.hood,
    required this.hoodShade,
    required this.skull,
    required this.skullShade,
    required this.eye,
    required this.tunic,
    required this.tunicShade,
    required this.emblem,
    required this.belt,
    required this.buckle,
    required this.cape,
    required this.capeShade,
    required this.legNear,
    required this.legFar,
    required this.bootNear,
    required this.bootFar,
    required this.armNear,
    required this.armFar,
    required this.shadow,
  });

  final int outline;
  final int hood;
  final int hoodShade;
  final int skull;
  final int skullShade;
  final int eye;
  final int tunic;
  final int tunicShade;
  final int emblem;
  final int belt;
  final int buckle;
  final int cape;
  final int capeShade;
  final int legNear;
  final int legFar;
  final int bootNear;
  final int bootFar;
  final int armNear;
  final int armFar;
  final int shadow;

  /// Neon red / white (the game's own look).
  static const neon = HeroPalette(
    outline: _outline,
    hood: _red,
    hoodShade: _redDark,
    skull: _bone,
    skullShade: 0xFFC7C7CC,
    eye: _red,
    tunic: 0xFF3A3A46,
    tunicShade: 0xFF272730,
    emblem: _red,
    belt: _redDark,
    buckle: _bone,
    cape: _redDark,
    capeShade: _redDeep,
    legNear: 0xFF50505C,
    legFar: 0xFF30303A,
    bootNear: _red,
    bootFar: _redDark,
    armNear: _bone,
    armFar: 0xFFBDBDC4,
    shadow: 0x50000000,
  );

  /// Four-shade green handheld palette used by the legacy-skin package.
  static const retro = HeroPalette(
    outline: 0xFF0F380F,
    hood: 0xFF306230,
    hoodShade: 0xFF0F380F,
    skull: 0xFF9BBC0F,
    skullShade: 0xFF8BAC0F,
    eye: 0xFF9BBC0F,
    tunic: 0xFF8BAC0F,
    tunicShade: 0xFF306230,
    emblem: 0xFF0F380F,
    belt: 0xFF0F380F,
    buckle: 0xFF9BBC0F,
    cape: 0xFF306230,
    capeShade: 0xFF0F380F,
    legNear: 0xFF306230,
    legFar: 0xFF0F380F,
    bootNear: 0xFF0F380F,
    bootFar: 0xFF0F380F,
    armNear: 0xFF9BBC0F,
    armFar: 0xFF8BAC0F,
    shadow: 0x500F380F,
  );
}

// 8-frame walk cycle: contact, down, passing, up, contact, down, passing, up.
const List<int> _legNearDx = [4, 3, 0, -3, -4, -3, 0, 3];
const List<int> _legNearLift = [0, 0, 0, 0, 0, 1, 2, 1];
const List<int> _legFarLift = [0, 1, 2, 1, 0, 0, 0, 0];
const List<int> _bob = [0, 1, 0, -1, 0, 1, 0, -1];
const List<int> _armNearDx = [-3, -2, 0, 2, 3, 2, 0, -2];
const List<int> _capeFlutter = [1, 2, 1, 0, 1, 2, 1, 0];

const List<String> _heroHead = [
  '...RRRR...',
  '..RRRRRRR.',
  '.rRRRRRRRR',
  '.rRRWWWWWW',
  'rrRWWWWWWW',
  'rrRWooWooW',
  'rrRWoEWoEW',
  'rrRWWWoWWW',
  '.rRWoWoWoW',
  '..rwWWWWWw',
];

const List<String> _heroTorso = [
  'ttTTTTTt',
  'tTTTTTTt',
  'tTTETTTt',
  'tTEEETTt',
  'tTTETTTt',
  'tTTTTTTt',
  'BBBBBKBB',
  'tTTTTTTt',
];

/// Draws one 32x32 walk frame (facing right).
PixelCanvas heroFrame(int frame, HeroPalette pal) {
  final c = PixelCanvas(32, 32);
  final f = frame % 8;
  final bob = _bob[f];
  final nearDx = _legNearDx[f];
  final farDx = -nearDx;
  final armDx = _armNearDx[f];

  // Far arm (behind the body).
  c.line(13, 14 + bob, 13 - armDx, 20 + bob, pal.armFar, size: 2);

  // Cape, flowing back and fluttering with the step.
  final flutter = _capeFlutter[f];
  for (var row = 0; row <= 9; row++) {
    final y = 13 + bob + row;
    final left = 11 - (row * (2 + flutter)) ~/ 6;
    for (var x = left; x <= 12; x++) {
      if (row == 9 && (x - left).isOdd) continue; // ragged hem
      c.set(x, y, x == left || row == 9 ? pal.capeShade : pal.cape);
    }
  }

  // Legs: far leg first, near leg over it.
  void leg(int hipX, int dx, int lift, int legColour, int bootColour) {
    final footX = hipX + dx;
    final footY = 28 - lift;
    c.line(hipX, 21 + bob, footX, footY, legColour, size: 2);
    c.fillRect(footX - 1, footY + 1, 4, 2, bootColour);
  }

  leg(14, farDx, _legFarLift[f], pal.legFar, pal.bootFar);

  c.drawArt(
    _heroTorso,
    {'T': pal.tunic, 't': pal.tunicShade, 'E': pal.emblem, 'B': pal.belt, 'K': pal.buckle},
    12,
    13 + bob,
  );

  leg(17, nearDx, _legNearLift[f], pal.legNear, pal.bootNear);

  c.drawArt(
    _heroHead,
    {'R': pal.hood, 'r': pal.hoodShade, 'W': pal.skull, 'w': pal.skullShade, 'o': pal.outline, 'E': pal.eye},
    11,
    3 + bob,
  );

  // Near arm (in front) with a bony hand.
  final handX = 18 + armDx;
  c.line(18, 14 + bob, handX, 19 + bob, pal.armNear, size: 2);
  c.fillRect(handX, 20 + bob, 2, 2, pal.skullShade);

  c.outline(pal.outline);

  // Ground shadow (translucent) after the outline so it is not outlined.
  for (var x = 10; x <= 22; x++) {
    if (c.alphaAt(x, 31) == 0) c.set(x, 31, x == 10 || x == 22 ? withAlpha(pal.shadow, 0x28) : pal.shadow);
  }
  return c;
}

/// 128x64 sheet: 4 columns x 2 rows of 32x32 frames, one continuous 8-frame
/// walk cycle read left-to-right, top-to-bottom.
Uint8List heroWalkSheet([HeroPalette pal = HeroPalette.neon]) {
  final sheet = PixelCanvas(128, 64);
  for (var f = 0; f < 8; f++) {
    sheet.blit(heroFrame(f, pal), (f % 4) * 32, (f ~/ 4) * 32);
  }
  return sheet.toPng();
}

void _finishIcon(PixelCanvas c) {
  c.outline(_outline);
  c.dropShadow();
}

Uint8List potionIcon() {
  final c = PixelCanvas(32, 32);
  c.fillCircle(16, 21, 8, _glass);
  c.fillRect(13, 9, 6, 6, _glass);
  for (var y = 17; y <= 28; y++) {
    for (var x = 8; x <= 24; x++) {
      final dx = x - 16;
      final dy = y - 21;
      if (dx * dx + dy * dy > 42) continue;
      final colour = y == 17 ? _redLight : (dx + dy > 5 ? _redDark : _red);
      c.set(x, y, colour);
    }
  }
  c.fillRect(12, 7, 8, 2, _grey);
  c.fillRect(12, 7, 8, 1, _greyLight);
  c.fillRect(13, 2, 6, 5, _brown);
  c.fillRect(17, 2, 2, 5, _brownDark);
  c.fillRect(13, 2, 4, 1, 0xFFB07A55);
  c.set(11, 20, _white);
  c.set(11, 21, _white);
  c.set(12, 19, _white);
  c.set(14, 11, _white);
  c.set(14, 12, _white);
  c.set(18, 22, _pink);
  c.set(15, 25, _pink);
  c.set(19, 19, _redLight);
  _finishIcon(c);
  return c.toPng();
}

Uint8List swordIcon() {
  final c = PixelCanvas(32, 32);
  // Blade along the diagonal from (11,20) to the tip at (26,5).
  for (var t = 0; t < 15; t++) {
    final x = 11 + t;
    final y = 20 - t;
    c.set(x + 1, y, _greyDark);
    c.set(x, y + 1, _greyDark);
  }
  for (var t = 0; t < 15; t++) {
    final x = 11 + t;
    final y = 20 - t;
    c.set(x - 1, y, _white);
    c.set(x, y - 1, _white);
  }
  for (var t = 0; t <= 15; t++) {
    c.set(11 + t, 20 - t, t >= 2 && t <= 12 ? _red : _greyLight);
  }
  c.set(26, 5, _white);
  // Cross guard, grip and pommel.
  c.line(6, 17, 13, 24, _red, size: 2);
  c.set(6, 17, _pink);
  c.set(7, 18, _redLight);
  c.line(9, 23, 5, 27, _brown, size: 2);
  c.set(7, 25, _brownDark);
  c.fillCircle(4, 28, 2, _red);
  c.set(3, 27, _pink);
  _finishIcon(c);
  return c.toPng();
}

const List<String> _shieldEmblem = ['.WWWWWW.', 'WWWWWWWW', 'WooWWooW', 'WoRWWoRW', 'WWWooWWW', '.WoWoWo.', '..WWWW..'];

Uint8List shieldIcon() {
  final c = PixelCanvas(32, 32);
  int halfWidth(int y, double full, double curveStart, double curveLen) {
    if (y <= curveStart) return full.toInt();
    final t = (y - curveStart) / curveLen;
    if (t >= 1) return 0;
    return (full * math.sqrt(1 - t * t)).floor();
  }

  for (var y = 3; y <= 29; y++) {
    final hw = halfWidth(y, 11, 14, 16);
    for (var x = 16 - hw; x <= 15 + hw; x++) {
      c.set(x, y, y == 3 ? _white : _grey);
    }
  }
  for (var y = 5; y <= 27; y++) {
    final hw = halfWidth(y, 9, 14, 14);
    for (var x = 16 - hw; x <= 15 + hw; x++) {
      c.set(x, y, x < 16 ? _red : _redDark);
    }
  }
  c.drawArt(_shieldEmblem, {'W': _bone, 'o': _outline, 'R': _red}, 12, 11);
  c.set(8, 6, _pink);
  c.set(8, 7, _redLight);
  _finishIcon(c);
  return c.toPng();
}

Uint8List keyIcon() {
  final c = PixelCanvas(32, 32);
  for (var y = 2; y <= 18; y++) {
    for (var x = 2; x <= 18; x++) {
      final dx = x - 10;
      final dy = y - 10;
      final d = dx * dx + dy * dy;
      if (d <= 42 && d > 12) c.set(x, y, dx + dy > 2 ? _grey : _greyLight);
    }
  }
  c.line(14, 14, 26, 26, _greyLight, size: 2);
  c.line(15, 14, 27, 26, _grey);
  c.line(22, 22, 19, 25, _grey, size: 2);
  c.line(26, 26, 23, 29, _grey, size: 2);
  c.fillCircle(15, 15, 1, _red);
  c.set(14, 14, _pink);
  c.set(6, 7, _white);
  c.set(7, 6, _white);
  _finishIcon(c);
  return c.toPng();
}

Uint8List gemIcon() {
  final c = PixelCanvas(32, 32);
  for (var y = 8; y <= 13; y++) {
    final grow = y - 8;
    for (var x = 11 - grow; x <= 20 + grow; x++) {
      int colour;
      if (y <= 9) {
        colour = x < 13 || x > 18 ? _redLight : _pink;
      } else if (x < 12) {
        colour = _redLight;
      } else if (x <= 19) {
        colour = _red;
      } else {
        colour = _redDark;
      }
      c.set(x, y, colour);
    }
  }
  for (var y = 14; y <= 27; y++) {
    final hw = 10 - ((y - 14) * 9) ~/ 13;
    for (var x = 16 - hw; x <= 15 + hw; x++) {
      final u = (x - 15.5) / (hw == 0 ? 1 : hw);
      final colour = u < -0.5
          ? _redLight
          : u < 0
          ? _red
          : u < 0.5
          ? _redDark
          : _redDeep;
      c.set(x, y, colour);
    }
  }
  for (var x = 6; x <= 25; x++) {
    c.set(x, 13, x < 16 ? _pink : _redLight);
  }
  c.set(12, 9, _white);
  c.set(13, 9, _white);
  c.set(12, 10, _white);
  c.set(9, 15, _white);
  // Sparkle.
  c.set(26, 5, _white);
  c.set(25, 5, _pink);
  c.set(27, 5, _pink);
  c.set(26, 4, _pink);
  c.set(26, 6, _pink);
  _finishIcon(c);
  return c.toPng();
}

Uint8List skullIcon() {
  final c = PixelCanvas(32, 32);
  c.fillCircle(16, 13, 10, _bone);
  c.fillRect(10, 19, 13, 8, _bone);
  for (var y = 0; y < 32; y++) {
    for (var x = 0; x < 32; x++) {
      if (c.get(x, y) == _bone && (x - 16) + (y - 13) > 13) c.set(x, y, _grey);
    }
  }
  c.fillCircle(12, 14, 3, _outline);
  c.fillCircle(20, 14, 3, _outline);
  c.fillRect(11, 14, 2, 2, _red);
  c.fillRect(19, 14, 2, 2, _red);
  c.set(11, 14, _pink);
  c.set(19, 14, _pink);
  c.set(16, 18, _outline);
  c.fillRect(15, 19, 3, 1, _outline);
  for (var x = 12; x <= 20; x += 2) {
    c.set(x, 21, _outline);
  }
  c.fillRect(11, 22, 11, 1, _outline);
  c.fillRect(12, 23, 9, 1, _outline);
  for (var x = 13; x <= 19; x += 2) {
    c.set(x, 24, _outline);
  }
  c.set(20, 5, _outline);
  c.set(21, 6, _outline);
  c.set(21, 7, _outline);
  c.set(22, 8, _outline);
  c.set(9, 9, _white);
  c.set(10, 8, _white);
  _finishIcon(c);
  return c.toPng();
}

const Map<String, List<String>> _font5x7 = {
  'N': ['X...X', 'XX..X', 'X.X.X', 'X..XX', 'X...X', 'X...X', 'X...X'],
  'E': ['XXXXX', 'X....', 'X....', 'XXXX.', 'X....', 'X....', 'XXXXX'],
  'O': ['.XXX.', 'X...X', 'X...X', 'X...X', 'X...X', 'X...X', '.XXX.'],
  'D': ['XXXX.', 'X...X', 'X...X', 'X...X', 'X...X', 'X...X', 'XXXX.'],
  'U': ['X...X', 'X...X', 'X...X', 'X...X', 'X...X', 'X...X', '.XXX.'],
  'G': ['.XXXX', 'X....', 'X....', 'X.XXX', 'X...X', 'X...X', '.XXXX'],
};

/// 256x128 RGBA logo: "NEON" / "DUNGEON" as neon tubes with a red glow on a
/// transparent background.
Uint8List logoTexture() {
  const w = 256;
  const h = 128;
  final mask = List<bool>.filled(w * h, false);
  void word(String text, int scale, int top) {
    final width = text.length * 6 * scale - scale;
    var x0 = (w - width) ~/ 2;
    for (final ch in text.split('')) {
      final glyph = _font5x7[ch]!;
      bool on(int gx, int gy) => gx >= 0 && gy >= 0 && gx < 5 && gy < 7 && glyph[gy][gx] == 'X';
      void block(int px, int py) {
        for (var sy = 0; sy < scale; sy++) {
          for (var sx = 0; sx < scale; sx++) {
            mask[(py + sy) * w + px + sx] = true;
          }
        }
      }

      for (var gy = 0; gy < 7; gy++) {
        for (var gx = 0; gx < 5; gx++) {
          if (!on(gx, gy)) continue;
          block(x0 + gx * scale, top + gy * scale);
          // Bridge diagonal neighbours so strokes like the N stay one tube.
          for (final dx in const [-1, 1]) {
            if (on(gx + dx, gy + 1) && !on(gx + dx, gy) && !on(gx, gy + 1)) {
              for (var s = 1; s < scale; s++) {
                block(x0 + gx * scale + dx * s, top + gy * scale + s);
              }
            }
          }
        }
      }
      x0 += 6 * scale;
    }
  }

  word('NEON', 6, 20);
  word('DUNGEON', 5, 73);

  // Depth inside the strokes (chamfer distance, capped at 3).
  final depth = List<int>.filled(w * h, 0);
  for (var i = 0; i < w * h; i++) {
    if (mask[i]) depth[i] = 3;
  }
  for (var pass = 1; pass <= 2; pass++) {
    final next = List<int>.of(depth);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        if (depth[i] == 0) continue;
        var edge = false;
        for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
          final nx = x + dx;
          final ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h || depth[ny * w + nx] < pass) edge = true;
        }
        if (edge && depth[i] > pass) next[i] = pass;
      }
    }
    depth.setAll(0, next);
  }

  final glow = boxBlur(boxBlur([for (final m in mask) m ? 1.0 : 0.0], w, h, 4), w, h, 4);
  final c = PixelCanvas(w, h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      final g = (glow[i] * 2.4).clamp(0.0, 1.0);
      if (g > 0.004) {
        final scan = y.isOdd ? 0.78 : 1.0;
        c.set(x, y, withAlpha(_red, (g * 215 * scan).round()));
      }
      switch (depth[i]) {
        case 1:
          c.set(x, y, _red);
        case 2:
          c.set(x, y, 0xFFFF7A90);
        case 3:
          c.set(x, y, 0xFFFFE6EB);
      }
    }
  }
  // Divider between the words: a thin tube with a tiny laughing skull.
  for (var x = 40; x < 216; x++) {
    if (x > 118 && x < 138) continue;
    c.blend(x, 67, withAlpha(_red, 0xE0));
  }
  c.drawArt(_shieldEmblem, {'W': _bone, 'o': _outline, 'R': _red}, 124, 64);
  return c.toPng();
}

/// Small preview image shipped inside the neon-hud package.
Uint8List neonHudPreview() {
  final c = PixelCanvas(96, 48);
  c.fillRect(0, 0, 96, 48, _black);
  // Health and mana bars.
  c.fillRect(4, 4, 44, 6, _redDeep);
  c.fillRect(4, 4, 34, 6, _red);
  c.fillRect(4, 4, 34, 1, _pink);
  c.fillRect(4, 13, 30, 4, 0xFF3A0010);
  c.fillRect(4, 13, 20, 4, _redLight);
  // Gold counter.
  for (var i = 0; i < 3; i++) {
    c.fillRect(4 + i * 5, 21, 3, 3, 0xFFFFC23D);
  }
  // Minimap.
  c.fillRect(70, 4, 22, 22, 0xFF140008);
  for (var i = 0; i < 22; i++) {
    c.set(70 + i, 4, _red);
    c.set(70 + i, 25, _red);
    c.set(70, 4 + i, _red);
    c.set(91, 4 + i, _red);
  }
  c.fillRect(80, 14, 2, 2, _white);
  // Hotbar.
  for (var i = 0; i < 6; i++) {
    final x = 21 + i * 9;
    c.fillRect(x, 38, 8, 8, i == 0 ? _red : 0xFF2A0A12);
    c.fillRect(x + 1, 39, 6, 6, i == 0 ? _redDark : 0xFF120408);
  }
  return c.toPng();
}

/// Small opaque "photos" for the batch-rename demo (seeded noise tiles).
Uint8List renameDemoImage(int index) {
  const themes = [
    (0xFF2B2B35, 0xFF5A5A6A, 'stone'),
    (0xFF3A0A00, 0xFFFF5A1F, 'lava'),
    (0xFF0E2A14, 0xFF4CAF50, 'moss'),
    (0xFF08203A, 0xFF4FC3F7, 'water'),
    (0xFF3A3530, 0xFFE8E0D0, 'bone'),
    (0xFF120006, 0xFFFF1744, 'neon'),
  ];
  final theme = themes[index % themes.length];
  final rng = SampleRng(0x51A7E + index * 7919);
  final c = PixelCanvas(24, 24);
  for (var y = 0; y < 24; y++) {
    for (var x = 0; x < 24; x++) {
      final t = (y / 23.0) * 0.6 + rng.nextDouble() * 0.4;
      c.set(x, y, lerpColor(theme.$1, theme.$2, t));
    }
  }
  // A small light source so the "photos" are distinguishable at a glance.
  final cx = 4 + rng.nextInt(16);
  final cy = 4 + rng.nextInt(10);
  c.fillCircle(cx, cy, 2, lerpColor(theme.$2, _white, 0.6));
  return c.toPng(text: {'Title': 'IMG_000${index + 1} (${theme.$3})'});
}
