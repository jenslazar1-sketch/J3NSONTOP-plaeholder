import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/drafts/drafts.dart';
import 'package:j3nsontop_multitool/core/platform/file_access.dart';
import 'package:j3nsontop_multitool/core/utils/hashing.dart';
import 'package:j3nsontop_multitool/features/file_tools/presentation/hash/hash_controller.dart';
import 'package:j3nsontop_multitool/features/file_tools/presentation/hash/hash_page.dart';
import 'package:j3nsontop_multitool/features/file_tools/presentation/shared.dart';
import 'package:path/path.dart' as p;

import 'ft_harness.dart';

void main() {
  late FtHarness h;
  setUp(() async => h = await FtHarness.create());
  tearDown(() async => h.dispose());

  void setMode(HashMode m) => h.container.read(draftValueProvider('files.hash/mode').notifier).set(m);

  testWidgets('text mode renders and hashes live', (tester) async {
    await pumpPage(tester, h, const HashPage());
    expect(find.text('Hash & Checksum'), findsOneWidget);
    expect(find.text(Hashing.text('')), findsOneWidget, reason: 'empty input has a digest too');
    await tester.enterText(find.byKey(const Key('hash.text')).first, 'abc');
    await tester.pump();
    expect(find.text(Hashing.text('abc')), findsOneWidget);
    expect(find.text('3 bytes of UTF-8'), findsOneWidget);
    // Legacy algorithm is badged.
    await tester.tap(find.text('MD5 (legacy)'));
    await tester.pump();
    expect(find.text(Hashing.text('abc', HashAlgorithm.md5)), findsOneWidget);
    expect(find.textContaining('not collision resistant'), findsOneWidget);
  });

  testWidgets('expected digest shows MATCH / MISMATCH and suggests the algorithm', (tester) async {
    await pumpPage(tester, h, const HashPage());
    await tester.enterText(find.byKey(const Key('hash.text')).first, 'abc');
    await tester.enterText(find.byKey(const Key('hash.expected')), 'SHA256:${Hashing.text('abc').toUpperCase()}');
    await tester.pump();
    expect(find.textContaining('MATCH'), findsWidgets);
    await tester.enterText(find.byKey(const Key('hash.expected')), Hashing.text('abc', HashAlgorithm.sha1));
    await tester.pump();
    expect(find.textContaining('MISMATCH'), findsOneWidget);
    expect(find.text('Use SHA-1'), findsOneWidget);
    await tester.tap(find.text('Use SHA-1'));
    await tester.pump();
    expect(find.textContaining('MISMATCH'), findsNothing);
  });

  testWidgets('files mode hashes files with progress and saves SHA256SUMS next to them', (tester) async {
    final a = h.write('mods/a.txt', utf8.encode('alpha'));
    final b = h.write('mods/sub/b.txt', utf8.encode('beta'));
    setMode(HashMode.files);
    await pumpPage(tester, h, const HashPage());
    expect(find.text('No files yet'), findsOneWidget);
    h.container.read(hashFilesProvider.notifier).add([
      FileItem(path: a.path, label: 'mods/a.txt', inWorkspace: true, size: 5),
      FileItem(path: b.path, label: 'mods/sub/b.txt', inWorkspace: true, size: 4),
    ]);
    // A device import via the system picker.
    final dev = File(p.join(h.env.dir.path, 'device.bin'))..writeAsBytesSync([1, 2, 3]);
    h.files.queuedPicks.add([PickedLocalFile(name: 'device.bin', path: dev.path, size: 3)]);
    await tester.pump();
    await tapVisible(tester, find.text('From device'));
    await waitFor(tester, () => h.container.read(hashFilesProvider).files.length == 3);
    h.container.read(hashFilesProvider.notifier).remove(h.container.read(hashFilesProvider).files.last);
    await tester.pump();

    await tapVisible(tester, find.byKey(const Key('hash.run')));
    await waitFor(tester, () => h.container.read(hashFilesProvider).results != null);
    expect(find.text(Hashing.text('alpha')), findsOneWidget);
    expect(find.text(Hashing.text('beta')), findsOneWidget);
    expect(find.text('OK'), findsNWidgets(2));

    await tapVisible(tester, find.byKey(const Key('hash.saveNext')));
    final sums = File(p.join(h.root, 'mods', 'SHA256SUMS'));
    await waitFor(tester, sums.existsSync);
    expect(sums.existsSync(), isTrue);
    expect(sums.readAsStringSync(), '${Hashing.text('alpha')}  a.txt\n${Hashing.text('beta')}  sub/b.txt\n');
  });

  testWidgets('verify mode reports OK / FAILED / MISSING for pasted lines', (tester) async {
    h.write('ok.txt', utf8.encode('abc'));
    h.write('bad.txt', utf8.encode('abd'));
    setMode(HashMode.verify);
    h.container.read(draftValueProvider('files.hash/verifySource').notifier).set(VerifySource.paste);
    await pumpPage(tester, h, const HashPage());
    final digest = Hashing.text('abc');
    await tester.enterText(
      find.byKey(const Key('hash.verifyText')).first,
      '$digest  ok.txt\n$digest *bad.txt\n$digest  gone.txt\n',
    );
    await tapVisible(tester, find.byKey(const Key('hash.verify')));
    await waitFor(tester, () => h.container.read(verifyProvider).report != null);
    final report = h.container.read(verifyProvider).report!;
    expect(report.results.map((r) => r.status.label), ['OK', 'FAILED', 'MISSING']);
    expect(find.text('PROBLEMS FOUND'), findsNothing, reason: 'StatusBanner renders "ERROR // PROBLEMS FOUND"');
    expect(find.textContaining('PROBLEMS FOUND'), findsOneWidget);
  });

  testWidgets('malformed checksum input shows an error', (tester) async {
    setMode(HashMode.verify);
    h.container.read(draftValueProvider('files.hash/verifySource').notifier).set(VerifySource.paste);
    await pumpPage(tester, h, const HashPage());
    await tester.enterText(find.byKey(const Key('hash.verifyText')).first, 'this is not a checksum list');
    await tapVisible(tester, find.byKey(const Key('hash.verify')));
    await waitFor(tester, () => h.container.read(verifyProvider).error != null);
    expect(find.textContaining('No readable checksum lines'), findsOneWidget);
  });

  testWidgets('fits 320x568 at 2x text in every mode', (tester) async {
    for (final mode in HashMode.values) {
      setMode(mode);
      await pumpPage(tester, h, const HashPage(), size: const Size(320, 568), textScale: 2);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'mode $mode');
    }
  });
}
