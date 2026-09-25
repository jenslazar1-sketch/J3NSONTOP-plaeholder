import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/workspaces/presentation/hex/hex_page.dart';
import 'package:j3nsontop_multitool/features/workspaces/presentation/shared/requests.dart';
import 'package:path/path.dart' as p;

import 'ws_test_utils.dart';

List<int> _data() {
  final out = List<int>.generate(70000, (i) => i % 251 == 0 ? 0 : 0x41 + (i % 26));
  // "NEON" marker across the first 64 KiB page boundary.
  out.setRange(65534, 65538, [0x4E, 0x45, 0x4F, 0x4E]);
  return out;
}

void main() {
  testWidgets('empty state before a file is opened', (tester) async {
    final h = await WsHarness.create(tester);
    await h.pump(tester, const HexViewerPage(), size: const Size(1280, 900));
    expect(find.text('No file open'), findsOneWidget);
  });

  testWidgets('shows rows, jumps to offsets and rejects bad ones', (tester) async {
    final h = await WsHarness.create(tester);
    final w = await h.workspace(tester, files: {'data.bin': _data()});
    await h.pump(tester, const HexViewerPage(), size: const Size(1400, 1000));
    h.container.read(hexRequestProvider.notifier).open(p.join(w.rootPath, 'data.bin'));
    await pumpUntil(tester, find.textContaining('00000000 | 00 42 43 44'));
    expect(find.textContaining('68.4 KB (70000 bytes)'), findsOneWidget);
    expect(find.text('READ-ONLY'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Offset (dec or 0x hex)'), '0xZZ');
    await tester.tap(find.text('Go'));
    await tester.pump();
    expect(find.textContaining('not a hexadecimal offset'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Offset (dec or 0x hex)'), '999999');
    await tester.tap(find.text('Go'));
    await tester.pump();
    expect(find.textContaining('beyond the end'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Offset (dec or 0x hex)'), '0x100');
    await tester.tap(find.text('Go'));
    await pumpUntil(tester, find.textContaining('selected 0x00000100..0x0000010F'));
    await pumpUntil(tester, find.textContaining('00000100 | '));
  });

  testWidgets('text search finds a match across the page boundary; copy rows', (tester) async {
    final h = await WsHarness.create(tester);
    final w = await h.workspace(tester, files: {'data.bin': _data()});
    await h.pump(tester, const HexViewerPage(), size: const Size(1400, 1000));
    h.container.read(hexRequestProvider.notifier).open(p.join(w.rootPath, 'data.bin'));
    await pumpUntil(tester, find.textContaining('00000000 | '));
    await tester.tap(find.text('Text (UTF-8)'));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, 'Text'), 'neon');
    await tester.tap(find.text('Aa'));
    await tester.pump();
    await tester.tap(find.byTooltip('Next match'));
    await pumpUntil(tester, find.textContaining('Match at 0x0000FFFE (65534)'));
    await tester.tap(find.text('Copy rows'));
    await settle(tester);
    expect(h.files.copied.single, startsWith('0000FFF0 | '));
    expect(h.files.copied.single, contains('4E 45'));
  });

  testWidgets('invalid hex pattern is explained', (tester) async {
    final h = await WsHarness.create(tester);
    final w = await h.workspace(tester, files: {'data.bin': _data()});
    await h.pump(tester, const HexViewerPage(), size: const Size(1400, 1000));
    h.container.read(hexRequestProvider.notifier).open(p.join(w.rootPath, 'data.bin'));
    await pumpUntil(tester, find.textContaining('00000000 | '));
    await tester.enterText(find.widgetWithText(TextField, 'Bytes, e.g. DE AD ?? EF'), 'ABC');
    await tester.tap(find.byTooltip('Next match'));
    await tester.pump();
    expect(find.textContaining('odd number of hex digits'), findsOneWidget);
  });

  testWidgets('phone layout: no overflow at 320x568 with 2x text', (tester) async {
    final h = await WsHarness.create(tester);
    final w = await h.workspace(tester, files: {'data.bin': _data()});
    await h.pump(tester, const HexViewerPage(), size: const Size(320, 568), textScale: 2);
    h.container.read(hexRequestProvider.notifier).open(p.join(w.rootPath, 'data.bin'));
    await pumpUntil(tester, find.textContaining('00000000 | '));
    expect(tester.takeException(), isNull);
  });
}
