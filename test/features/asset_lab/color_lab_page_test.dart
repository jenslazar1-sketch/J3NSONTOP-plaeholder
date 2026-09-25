import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/widgets/widgets.dart';
import 'package:j3nsontop_multitool/features/asset_lab/presentation/color_lab/color_lab_page.dart';

import '../../helpers/harness.dart';
import 'asset_test_helpers.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  Finder field(String label) => find.widgetWithText(TextField, label);
  String text(WidgetTester tester, String label) => tester.widget<TextField>(field(label)).controller!.text;

  assetWidgetTest('renders picker, formats, contrast and an empty palette', (tester) async {
    await pumpAssetPage(tester, env, const ColorLabPage());
    expect(find.text('Color Lab'), findsWidgets);
    expect(text(tester, 'HEX'), '#FF163B');
    expect(text(tester, 'RGB(A)'), 'rgb(255, 22, 59)');
    expect(find.text('Contrast 5.27 : 1'), findsOneWidget);
    expect(find.textContaining('AA normal text: PASS'), findsOneWidget);
    expect(find.textContaining('AAA normal text: FAIL'), findsOneWidget);
    expect(find.text('Palette is empty'), findsOneWidget);
  });

  assetWidgetTest('typing HEX syncs every format, copy works, palette export', (tester) async {
    final files = FakeFileAccess();
    await pumpAssetPage(tester, env, const ColorLabPage(), files: files);
    await tester.enterText(field('HEX'), '#FFFFFF');
    await tester.pump();
    expect(text(tester, 'RGB(A)'), 'rgb(255, 255, 255)');
    expect(text(tester, 'HSL(A)'), 'hsl(0, 0%, 100%)');
    expect(find.text('Contrast 20.36 : 1'), findsOneWidget);

    await tester.enterText(field('RGB(A)'), 'rgba(0, 128, 255, 0.5)');
    await tester.pump();
    expect(text(tester, 'HEX'), '#0080FF80');

    await tapVisible(tester, find.byTooltip('Copy HEX'));
    expect(files.copied.single, '#0080FF80');

    await tapVisible(tester, find.widgetWithText(NeonButton, 'Add to palette'));
    await tester.pump();
    expect(find.text('Palette (1)'), findsOneWidget);
    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'CSS variables'));
    final css = tester.widget<ResultPanel>(find.byType(ResultPanel)).text;
    expect(css, contains(':root {'));
    expect(css, contains('#0080ff80'));
  });

  assetWidgetTest('malformed input shows a validation message and keeps the colour', (tester) async {
    await pumpAssetPage(tester, env, const ColorLabPage());
    await tester.enterText(field('HEX'), '#12G');
    await tester.pump();
    expect(find.textContaining('not hex digits'), findsOneWidget);
    expect(text(tester, 'RGB(A)'), 'rgb(255, 22, 59)');
    await tester.enterText(field('HSL(A)'), 'hsl(10, 150%, 50%)');
    await tester.pump();
    expect(find.textContaining('Saturation must be 0%-100%'), findsOneWidget);
  });

  assetWidgetTest('hue slider is keyboard adjustable', (tester) async {
    await pumpAssetPage(tester, env, const ColorLabPage());
    final hue = find.bySemanticsLabel('Hue');
    await tester.ensureVisible(hue);
    final inner = find.descendant(of: hue, matching: find.byType(Container)).first;
    Focus.of(tester.element(inner)).requestFocus();
    await tester.pump();
    final before = text(tester, 'HSV(A)');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(text(tester, 'HSV(A)'), isNot(before));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(text(tester, 'HEX'), isNot('#FF163B'));
  });

  assetWidgetTest('eyedropper picks a pixel; palette rename via menu', (tester) async {
    final files = FakeFileAccess()..queuedPicks.add([writePick(env, 'pal.png', pngOf(gradientImage(40, 20)))]);
    await pumpAssetPage(tester, env, const ColorLabPage(), files: files);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Load image'));
    await settle(tester);
    final viewport = find.bySemanticsLabel(RegExp('Eyedropper image'));
    await tester.ensureVisible(viewport);
    await tester.pump();
    final r = tester.getRect(viewport);
    await tester.tapAt(Offset(r.left + r.width * 0.9, r.top + 40));
    await tester.pump();
    expect(find.textContaining(RegExp(r'^Picked \(\d+, \d+\) -> #')), findsOneWidget);

    await tapVisible(tester, find.widgetWithText(NeonButton, 'Add to palette'));
    await tester.pump();
    final menu = find.byTooltip(RegExp('Actions for'));
    await tapVisible(tester, menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename...'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Sampled');
    await tester.tap(find.widgetWithText(NeonButton, 'OK'));
    await tester.pumpAndSettle();
    expect(find.text('Sampled'), findsOneWidget);
  });

  assetWidgetTest('malformed eyedropper image shows an error', (tester) async {
    final files = FakeFileAccess()..queuedPicks.add([writePick(env, 'x.png', utf8.encode('nope, not a picture'))]);
    await pumpAssetPage(tester, env, const ColorLabPage(), files: files);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Load image'));
    await settle(tester);
    expect(find.text('ERROR // Cannot load image'), findsOneWidget);
  });

  assetWidgetTest('no overflow at 320x568 with 2x text', (tester) async {
    await pumpAssetPage(tester, env, const ColorLabPage(), size: const Size(320, 568), textScale: 2);
    await tapVisible(tester, find.widgetWithText(NeonButton, 'Add to palette'));
    await tester.pump();
    await tapVisible(tester, find.widgetWithText(ChoiceChip, 'GIMP .gpl'));
    expect(tester.takeException(), isNull);
    expect(find.text('Palette (1)'), findsOneWidget);
  });
}
