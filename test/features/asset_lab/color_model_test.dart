import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/asset_lab/domain/color_model.dart';

void main() {
  group('HEX parsing', () {
    test('accepts #RGB, #RGBA, #RRGGBB and both 8-digit orders', () {
      expect(ColorFormat.parseHex('#F0A'), const Rgba(255, 0, 170));
      expect(ColorFormat.parseHex('f0a8'), const Rgba(255, 0, 170, 136));
      expect(ColorFormat.parseHex('#FF163B'), const Rgba(255, 22, 59));
      expect(ColorFormat.parseHex('  ff163b  '), const Rgba(255, 22, 59));
      expect(ColorFormat.parseHex('#FF163B80'), const Rgba(255, 22, 59, 128));
      expect(ColorFormat.parseHex('#80FF163B', order: HexAlphaOrder.argb), const Rgba(255, 22, 59, 128));
      expect(ColorFormat.parseHex('0x80FF163B'), const Rgba(255, 22, 59, 128), reason: '0x is always ARGB');
      expect(ColorFormat.parseHex('0xFF163B'), const Rgba(255, 22, 59));
    });

    test('rejects malformed input with readable messages', () {
      expect(() => ColorFormat.parseHex(''), throwsFormatException);
      expect(
        () => ColorFormat.parseHex('#GG0000'),
        throwsA(isA<FormatException>().having((e) => e.message, 'm', contains('hex'))),
      );
      expect(
        () => ColorFormat.parseHex('#12345'),
        throwsA(isA<FormatException>().having((e) => e.message, 'm', contains('5'))),
      );
      expect(() => ColorFormat.parseHex('0x123'), throwsFormatException);
    });

    test('formats opaque as #RRGGBB and translucent in the chosen order', () {
      expect(ColorFormat.hex(const Rgba(255, 22, 59)), '#FF163B');
      expect(ColorFormat.hex(const Rgba(255, 22, 59, 128)), '#FF163B80');
      expect(ColorFormat.hex(const Rgba(255, 22, 59, 128), order: HexAlphaOrder.argb), '#80FF163B');
      expect(ColorFormat.hex(const Rgba(1, 2, 3), forceAlpha: true), '#010203FF');
    });
  });

  group('conversions', () {
    test('known values', () {
      final hsv = ColorMath.toHsv(const Rgba(255, 0, 0));
      expect(hsv.h, 0);
      expect(hsv.s, 1);
      expect(hsv.v, 1);
      expect(ColorMath.fromHsv(const Hsv(120, 1, 1)), const Rgba(0, 255, 0));
      expect(ColorMath.fromHsv(const Hsv(240, 1, 0.5)), const Rgba(0, 0, 128));
      final hsl = ColorMath.toHsl(const Rgba(0, 128, 255));
      expect(hsl.h, closeTo(209.9, 0.1));
      expect(hsl.s, closeTo(1, 1e-9));
      expect(hsl.l, closeTo(0.5, 0.001));
      expect(ColorMath.fromHsl(const Hsl(0, 0, 0.5)), const Rgba(128, 128, 128));
      expect(ColorMath.fromHsl(const Hsl(300, 1, 0.25)), const Rgba(128, 0, 128));
    });

    test('RGB -> HSV -> RGB and RGB -> HSL -> RGB round trip exactly', () {
      final rnd = math.Random(7);
      for (var i = 0; i < 2000; i++) {
        final c = Rgba(rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256));
        expect(ColorMath.fromHsv(ColorMath.toHsv(c)), c);
        expect(ColorMath.fromHsl(ColorMath.toHsl(c)), c);
      }
    });

    test('text notations parse and round trip', () {
      const c = Rgba(255, 22, 59, 128);
      expect(ColorFormat.parseRgb(ColorFormat.rgb(c)), c);
      expect(ColorFormat.parseRgb('rgb(255 22 59 / 50%)'), c);
      expect(ColorFormat.parseRgb('255, 22, 59'), const Rgba(255, 22, 59));
      expect(ColorFormat.parseRgb('rgb(100%, 0%, 0%)'), const Rgba(255, 0, 0));
      expect(ColorFormat.parseHsl(ColorFormat.hsl(const Rgba(255, 22, 59))), const Rgba(255, 22, 59));
      expect(ColorFormat.parseHsv(ColorFormat.hsv(const Rgba(12, 200, 90))), const Rgba(12, 200, 90));
      expect(ColorFormat.parseHsv('hsb(0, 100%, 100%)'), const Rgba(255, 0, 0));
      expect(ColorFormat.parseAny('hsl(120, 100%, 50%)'), const Rgba(0, 255, 0));
    });

    test('text notations report errors', () {
      expect(() => ColorFormat.parseRgb('rgb(300, 0, 0)'), throwsFormatException);
      expect(() => ColorFormat.parseRgb('rgb(1, 2)'), throwsFormatException);
      expect(() => ColorFormat.parseRgb('rgba(1, 2, 3, 2)'), throwsFormatException);
      expect(() => ColorFormat.parseHsl('hsl(10, 120%, 50%)'), throwsFormatException);
      expect(() => ColorFormat.parseHsv('rgb(1,2,3)'), throwsFormatException);
      expect(() => ColorFormat.parseRgb('rgb(a, b, c)'), throwsFormatException);
    });
  });

  group('WCAG contrast', () {
    test('white on black is 21:1, identical colours 1:1', () {
      expect(ColorMath.contrastRatio(Rgba.white, Rgba.black), closeTo(21, 1e-9));
      expect(ColorMath.contrastRatio(Rgba.black, Rgba.white), closeTo(21, 1e-9));
      expect(ColorMath.contrastRatio(const Rgba(80, 80, 80), const Rgba(80, 80, 80)), closeTo(1, 1e-9));
    });

    test('brand neon on the app background is about 5.27:1', () {
      final r = ColorMath.contrastRatio(const Rgba(0xFF, 0x16, 0x3B), const Rgba(0x05, 0x05, 0x07));
      expect(r, closeTo(5.27, 0.01));
      expect(WcagLevel.aaNormal.passes(r), isTrue);
      expect(WcagLevel.aaaNormal.passes(r), isFalse);
      expect(WcagLevel.aaaLarge.passes(r), isTrue);
    });

    test('known mid values and thresholds', () {
      // #767676 on white is the classic 4.54:1 AA boundary grey.
      final grey = ColorMath.contrastRatio(const Rgba(0x76, 0x76, 0x76), Rgba.white);
      expect(grey, closeTo(4.54, 0.01));
      expect(WcagLevel.aaNormal.passes(4.5), isTrue);
      expect(WcagLevel.aaNormal.passes(4.49), isFalse);
    });

    test('translucent foreground is composited over the background', () {
      const half = Rgba(255, 255, 255, 128);
      final r = ColorMath.contrastRatio(half, Rgba.black);
      final expected = ColorMath.contrastRatio(half.over(Rgba.black), Rgba.black);
      expect(r, closeTo(expected, 1e-9));
      expect(half.over(Rgba.black), const Rgba(128, 128, 128));
    });
  });
}
