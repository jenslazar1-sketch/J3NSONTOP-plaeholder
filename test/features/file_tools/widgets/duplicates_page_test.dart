import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/features/file_tools/presentation/duplicates/duplicates_controller.dart';
import 'package:j3nsontop_multitool/features/file_tools/presentation/duplicates/duplicates_page.dart';
import 'package:path/path.dart' as p;

import 'ft_harness.dart';

void main() {
  group('with workspace', () {
    late FtHarness h;
    setUp(() async {
      h = await FtHarness.create();
      h.write('game/data/items.csv', utf8.encode('id,name\n1,sword\n'));
      h.write('duplicates/items.csv', utf8.encode('id,name\n1,sword\n'));
      h.write('duplicates/deeper/items copy.csv', utf8.encode('id,name\n1,sword\n'));
      h.write('game/unique.txt', utf8.encode('unique'));
      h.write('game/same-size-a.txt', utf8.encode('aaaa'));
      h.write('game/same-size-b.txt', utf8.encode('bbbb'));
    });
    tearDown(() async => h.dispose());

    DuplicatesState st() => h.container.read(duplicatesProvider);

    testWidgets('renders, scans, quarantines the selected copies and restores them', (tester) async {
      await pumpPage(tester, h, const DuplicatesPage());
      await waitFor(tester, () => st().sessionsLoaded);
      expect(find.text('Duplicate Finder'), findsOneWidget);
      expect(find.text('No scan yet'), findsOneWidget);
      expect(find.text('Nothing in quarantine.'), findsOneWidget);

      await tapVisible(tester, find.byKey(const Key('dup.scan')));
      await waitFor(tester, () => st().result != null);
      final r = st().result!;
      expect(r.groups, hasLength(1));
      expect(r.groups.single.files, hasLength(3));
      expect(find.text('1 duplicate group'), findsOneWidget);
      expect(find.text('KEEP'), findsOneWidget);
      expect(find.text('MOVE'), findsNWidgets(2));

      // Keep the copy in duplicates/ instead (radio) and leave one copy in place (checkbox).
      final keepIndex = r.groups.single.files.indexWhere((f) => f.relativePath == 'duplicates/items.csv');
      h.container.read(duplicatesProvider.notifier).setKeeper(r.groups.single, keepIndex);
      await tester.pump();
      final gameIndex = r.groups.single.files.indexWhere((f) => f.relativePath == 'game/data/items.csv');
      h.container.read(duplicatesProvider.notifier).toggleCopy(r.groups.single, gameIndex, false);
      await tester.pump();
      expect(find.text('LEAVE'), findsOneWidget);

      await tapVisible(tester, find.byKey(const Key('dup.quarantine')));
      await tester.pumpAndSettle();
      expect(find.text('Move 1 copy to quarantine?'), findsOneWidget);
      await tester.tap(find.text('Move to quarantine'));
      await tester.pump();
      await waitFor(tester, () => !st().running && st().sessions.isNotEmpty);
      expect(File(p.join(h.root, 'duplicates', 'deeper', 'items copy.csv')).existsSync(), isFalse);
      expect(File(p.join(h.root, 'duplicates', 'items.csv')).existsSync(), isTrue);
      expect(File(p.join(h.root, 'game', 'data', 'items.csv')).existsSync(), isTrue);
      expect(st().sessions.single.inQuarantine, hasLength(1));
      expect(st().result!.groups.single.files, hasLength(2), reason: 'moved copy leaves the group');

      await tester.ensureVisible(find.textContaining('HELD 1'));
      await tester.tap(find.textContaining('HELD 1'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('Restore all 1'));
      await waitFor(tester, () => !st().running && st().sessions.single.fullyRestored);
      expect(File(p.join(h.root, 'duplicates', 'deeper', 'items copy.csv')).readAsStringSync(), 'id,name\n1,sword\n');
    });

    testWidgets('exports the report through the save dialog', (tester) async {
      await pumpPage(tester, h, const DuplicatesPage());
      await tapVisible(tester, find.byKey(const Key('dup.scan')));
      await waitFor(tester, () => st().result != null);
      await tapVisible(tester, find.text('CSV'));
      await tapVisible(tester, find.byKey(const Key('dup.export')));
      await chooseExport(tester);
      final (name, bytes) = h.files.savedBytes.single;
      expect(name, endsWith('.csv'));
      final csv = utf8.decode(bytes);
      expect(csv, startsWith('group,sha256,size_bytes,role,path'));
      expect(csv, contains(',keep,'));
      expect(csv, contains(',quarantine,'));
    });

    testWidgets('invalid glob shows inline validation and a scan error', (tester) async {
      await pumpPage(tester, h, const DuplicatesPage());
      await tester.enterText(find.widgetWithText(TextField, 'Include (globs, comma separated)'), '[abc');
      await tester.pump();
      expect(find.textContaining('Unclosed "["'), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('dup.scan')));
      await tester.pump();
      expect(st().error, contains('Invalid pattern'));
      expect(st().result, isNull);
    });

    testWidgets('fits 320x568 at 2x text before and after a scan', (tester) async {
      await pumpPage(tester, h, const DuplicatesPage(), size: const Size(320, 568), textScale: 2);
      await waitFor(tester, () => st().sessionsLoaded);
      await tapVisible(tester, find.byKey(const Key('dup.scan')));
      await waitFor(tester, () => st().result != null);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('without a workspace it explains what is needed', (tester) async {
    final h = await tester.runAsync(() => FtHarness.create(withWorkspace: false));
    addTearDown(() => tester.runAsync(h!.dispose));
    await pumpPage(tester, h!, const DuplicatesPage());
    expect(find.text('No active workspace'), findsOneWidget);
  });
}
