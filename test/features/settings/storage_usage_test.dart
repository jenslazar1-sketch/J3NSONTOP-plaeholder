import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/features/settings/storage_usage.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('j3_storage_');
    Future<void> write(String rel, int size) async {
      final f = File(p.join(root.path, rel));
      await f.parent.create(recursive: true);
      await f.writeAsBytes(List<int>.filled(size, 7));
    }

    await write('settings.json', 10);
    await write('history.json', 5);
    await write(p.join('workspaces', 'w1', 'files', 'a.bin'), 1000);
    await write(p.join('workspaces', 'w1', 'meta', 'mods', 'x.j3mod'), 24);
    await write(p.join('workspaces', 'w2', 'files', 'b.bin'), 100);
    await write(p.join('cache', 'picked', 'c.bin'), 50);
    await Directory(p.join(root.path, 'cache', 'export')).create(recursive: true);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('sums real file sizes per top-level folder', () async {
    final r = await measureBreakdown(root.path);
    expect(r.total.bytes, 1189);
    expect(r.total.files, 6);
    expect(r.total.unreadable, 0);
    expect(r.of('workspaces').bytes, 1124);
    expect(r.of('workspaces').files, 3);
    expect(r.of('cache').bytes, 50);
    expect(r.of('cache').files, 1);
    expect(r.of('cache').directories, 2);
    expect(r.of(StorageBreakdown.rootFiles).bytes, 15);
    expect(r.excluding(const ['workspaces', 'cache']).bytes, 15);
    expect(r.excluding(const ['workspaces', 'cache']).files, 2);
    expect(r.of('missing').bytes, 0);
  });

  test('reports progress with running totals', () async {
    final seen = <int>[];
    await measureBreakdown(root.path, progressEvery: 2, onProgress: (u) => seen.add(u.files));
    expect(seen, [2, 4, 6]);
  });

  test('stops when cancelled', () async {
    final token = CancellationToken()..cancel();
    expect(measureBreakdown(root.path, token: token), throwsA(isA<OperationCancelled>()));

    final midway = CancellationToken();
    await expectLater(
      measureBreakdown(root.path, progressEvery: 1, token: midway, onProgress: (_) => midway.cancel()),
      throwsA(isA<OperationCancelled>()),
    );
  });

  test('a missing directory is reported, not guessed', () async {
    final r = await measureBreakdown(p.join(root.path, 'nope'));
    expect(r.total.exists, isFalse);
    expect(r.total.bytes, 0);
    expect(r.byTopLevel, isEmpty);
  });

  test('symbolic links are not followed', () async {
    if (Platform.isWindows) return;
    final outside = await Directory.systemTemp.createTemp('j3_outside_');
    addTearDown(() => outside.delete(recursive: true));
    await File(p.join(outside.path, 'big.bin')).writeAsBytes(List<int>.filled(5000, 1));
    await Link(p.join(root.path, 'cache', 'link')).create(outside.path);
    final r = await measureBreakdown(root.path);
    expect(r.total.bytes, 1189);
  });
}
