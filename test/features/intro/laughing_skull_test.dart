import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/theme/effects.dart';
import 'package:j3nsontop_multitool/features/intro/intro_timeline.dart';
import 'package:j3nsontop_multitool/features/intro/laughing_skull.dart';
import 'package:j3nsontop_multitool/features/intro/skull_art.dart';
import 'package:j3nsontop_multitool/features/intro/skull_rig.dart';

import '../../helpers/harness.dart';
import 'intro_test_utils.dart';

const _cranium = ValueKey<String>('cranium');
const _jaw = ValueKey<String>('jaw');

Widget _host(Widget child, {EffectsConfig fx = fullFx}) => themed(
  Center(child: SizedBox(width: 240, height: 240, child: child)),
  effects: fx,
);

void main() {
  group('skull art', () {
    test('every row fits the grid and the teeth rows share columns', () {
      for (final art in [SkullArt.full, SkullArt.mini]) {
        for (final row in [...art.cranium, ...art.jaw]) {
          expect(row.length, lessThanOrEqualTo(art.columns), reason: row);
        }
        // Upper and lower teeth: the `|` separators line up column for column.
        final upper = art.cranium.last;
        final lower = art.jaw.first;
        final (from, to) = art.mouthSpan;
        for (var c = from; c <= to; c++) {
          expect(upper[c] == '|', lower[c] == '|', reason: 'column $c: "${upper[c]}" vs "${lower[c]}"');
        }
        expect(upper[from], '|');
        expect(upper[to], '|');
      }
    });

    test('eye centres sit inside the sockets and the hinge is centred', () {
      expect(kSkullEyeCentres, hasLength(2));
      for (final art in [SkullArt.full, SkullArt.mini]) {
        final (l, r) = (art.eyeCentres[0], art.eyeCentres[1]);
        // Mirror-symmetric about the grid centre (cell centres at c + 0.5).
        expect((l.$1 + 0.5) + (r.$1 + 0.5), closeTo(art.columns.toDouble(), 1e-9));
        expect(art.jawHinge.$1, closeTo(art.columns / 2, 1e-9));
        expect(art.jawHinge.$2, 0);
        // The eye centre cell is blank (a hollow socket) in the full skull.
        if (identical(art, SkullArt.full)) {
          for (final (c, row) in art.eyeCentres) {
            expect(art.cranium[row.round()][c.round()], ' ');
          }
        }
      }
    });

    testWidgets('measured metrics equal the rendered layers (with and without app fonts)', (tester) async {
      for (final fontsLoaded in [false, true]) {
        if (fontsLoaded) await tester.runAsync(loadAppFonts);
        final style = skullTextStyle(color: const Color(0xFFFF163B));
        final m = SkullMetrics.measure(style);
        expect(m.advance, greaterThan(0));
        expect(m.lineHeight, greaterThan(style.fontSize!));
        for (final rows in [kSkullCranium, kSkullJaw]) {
          await tester.pumpWidget(
            Align(
              alignment: Alignment.topLeft,
              child: SkullLayerText(rows: rows, columns: kSkullColumns, style: style),
            ),
          );
          final size = tester.getSize(find.byType(SkullLayerText));
          expect(size.height, closeTo(rows.length * m.lineHeight, 0.01), reason: 'fonts loaded: $fontsLoaded');
          expect(size.width, closeTo(kSkullColumns * m.advance, 0.01), reason: 'fonts loaded: $fontsLoaded');
        }
        final size = SkullRig.sizeFor(SkullArt.full, m);
        expect(size.width, closeTo(kSkullColumns * m.advance, 1e-6));
        expect(size.height, greaterThan(SkullArt.full.rows * m.lineHeight));
      }
    });
  });

  group('LaughingSkull', () {
    testWidgets('laughs on demand via controller with the intro jaw mechanics', (tester) async {
      final controller = LaughingSkullController();
      addTearDown(controller.dispose);
      var completed = 0;
      await tester.pumpWidget(
        _host(
          LaughingSkull(controller: controller, craniumKey: _cranium, jawKey: _jaw, onLaughComplete: () => completed++),
        ),
      );
      final rest = tester.getTopLeft(find.byKey(_jaw));
      final crRect = tester.getRect(find.byKey(_cranium));
      final lineHeight = crRect.height / kSkullCranium.length;
      expect(rest.dy, closeTo(crRect.bottom, 0.01));
      // Fits the 240x240 box without reflowing.
      final outer = tester.getRect(find.byType(LaughingSkull));
      expect(outer.width, lessThanOrEqualTo(240.01));
      expect(outer.height, lessThanOrEqualTo(240.01));
      expect(tester.binding.transientCallbackCount, 0, reason: 'idle skull does not tick');

      controller.laugh();
      await tester.pump();
      await tester.pump(Duration(milliseconds: (kLaughPulses[2].peak * 1000).round()));
      final peak = tester.getTopLeft(find.byKey(_jaw));
      expect((peak.dy - rest.dy) / lineHeight, greaterThan(0.8));
      await tester.pump(const Duration(seconds: 2));
      expect(tester.getTopLeft(find.byKey(_jaw)), rest);
      expect(completed, 1);
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('laughTrigger changes and laughOnMount start a laugh; mini art works', (tester) async {
      Widget build(int trigger) => _host(
        LaughingSkull(mini: true, laughTrigger: trigger, laughOnMount: true, craniumKey: _cranium, jawKey: _jaw),
      );
      await tester.pumpWidget(build(0));
      final crRect = tester.getRect(find.byKey(_cranium));
      final lineHeight = crRect.height / kMiniSkullCranium.length;
      final rest = crRect.bottom;
      await tester.pump(Duration(milliseconds: (kLaughPulses[0].peak * 1000).round()));
      expect((tester.getTopLeft(find.byKey(_jaw)).dy - rest) / lineHeight, greaterThan(0.8));
      await tester.pump(const Duration(seconds: 2));
      expect(tester.getTopLeft(find.byKey(_jaw)).dy, closeTo(rest, 0.01));
      await tester.pumpWidget(build(1));
      await tester.pump(Duration(milliseconds: (kLaughPulses[0].peak * 1000).round()));
      expect(tester.getTopLeft(find.byKey(_jaw)).dy, greaterThan(rest + 0.8 * lineHeight));
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('reduced motion: a laugh request moves nothing', (tester) async {
      final controller = LaughingSkullController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _host(
          LaughingSkull(controller: controller, craniumKey: _cranium, jawKey: _jaw),
          fx: reducedFx,
        ),
      );
      final jaw = tester.getTopLeft(find.byKey(_jaw));
      final cranium = tester.getTopLeft(find.byKey(_cranium));
      controller.laugh();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 60));
        expect(tester.getTopLeft(find.byKey(_jaw)), jaw);
        expect(tester.getTopLeft(find.byKey(_cranium)), cranium);
      }
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.transientCallbackCount, 0);
    });

    testWidgets('has an image semantics label and disposes cleanly', (tester) async {
      final controller = LaughingSkullController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(LaughingSkull(controller: controller)));
      expect(find.bySemanticsLabel('J3NSONTOP laughing skull'), findsOneWidget);
      controller.laugh();
      await tester.pump(const Duration(milliseconds: 200));
      // Unmount mid-laugh: the ticker is disposed, the listener removed.
      await tester.pumpWidget(const SizedBox());
      controller.laugh();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
