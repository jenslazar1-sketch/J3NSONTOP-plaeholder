import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/activity/activity_controller.dart';
import 'package:j3nsontop_multitool/core/activity/operation.dart';
import 'package:j3nsontop_multitool/core/archive/safe_zip.dart';
import 'package:j3nsontop_multitool/core/platform/app_paths.dart';
import 'package:j3nsontop_multitool/core/settings/settings_controller.dart';
import 'package:j3nsontop_multitool/core/storage/app_stores.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/sample/sample_content.dart';
import 'package:j3nsontop_multitool/features/sample/sample_smoke.dart';
import 'package:j3nsontop_multitool/features/sample/sample_workspace.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';

File _file(String root, String rel) => File(p.joinAll([root, ...rel.split('/')]));

/// Lets unawaited history/settings saves finish before the temp dir goes.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  late SampleBundle bundle;
  setUpAll(() => bundle = buildSampleBundle());

  late TestEnv env;
  late ProviderContainer container;
  setUp(() async {
    env = await TestEnv.create();
    container = env.container();
  });
  tearDown(() async {
    await _settle();
    container.dispose();
    await env.dispose();
  });

  SampleWorkspaceService service() => SampleWorkspaceService(container.read);
  List<Workspace> samples() =>
      container.read(workspacesProvider).workspaces.where((w) => w.kind == WorkspaceKind.sample).toList();

  void expectFullContent(Workspace w) {
    for (final e in bundle.files.entries) {
      final f = _file(w.rootPath, e.key);
      expect(f.existsSync(), isTrue, reason: e.key);
      expect(f.readAsBytesSync(), e.value, reason: e.key);
    }
    final meta = container.read(workspacesProvider.notifier).metaDir(w);
    for (final e in bundle.packages.entries) {
      final path = p.join(meta, 'mods', e.key);
      expect(File(path).readAsBytesSync(), e.value, reason: e.key);
      expect(SafeZip.inspect(path).isSafe, isTrue);
    }
    for (final e in bundle.profiles.entries) {
      expect(File(p.join(meta, 'profiles', e.key)).readAsBytesSync(), e.value, reason: e.key);
    }
  }

  test('createSampleWorkspace writes an app-owned sample workspace and records the operation', () async {
    final w = await service().create();
    expect(w.kind, WorkspaceKind.sample);
    expect(w.name, sampleWorkspaceName);
    expect(p.equals(w.rootPath, env.paths.workspaceFilesDir(w.id)), isTrue);
    expect(p.isWithin(env.paths.workspacesDir, w.rootPath), isTrue);
    expectFullContent(w);
    expect(
      Directory(p.join(env.paths.workspaceMetaDir(w.id), 'mods')).listSync().map((e) => p.basename(e.path)).toSet(),
      {
        'core-patch-1.0.0.j3mod',
        'neon-hud-1.2.0.j3mod',
        'hardcore-balance-2.0.1.j3mod',
        'brutal-mode-0.9.0.j3mod',
        'legacy-skin-0.3.0.j3mod',
        'cycle-a-1.0.0.j3mod',
        'cycle-b-1.0.0.j3mod',
      },
    );
    expect(container.read(workspacesProvider).activeId, w.id, reason: 'no workspace was active before');

    final op = container.read(activityProvider).operations.first;
    expect(op.title, 'Create sample workspace');
    expect(op.status, OperationStatus.succeeded);
    expect(op.workspaceId, w.id);
    expect(op.counts['files'], bundle.files.length);
    expect(op.counts['packages'], 7);
    expect(op.counts['profiles'], 4);
    expect(op.counts['bytes'], bundle.totalBytes);
    expect(container.read(activityProvider).notices.map((n) => n.kind), contains(NoticeKind.success));

    // The record is persisted.
    final stored = await env.stores.workspaces.load();
    expect((stored.data['workspaces'] as List<dynamic>).cast<Map<String, dynamic>>().single['kind'], 'sample');
  });

  test('an already active workspace stays active', () async {
    final mine = await container.read(workspacesProvider.notifier).addAppOwned('Mine');
    final w = await service().create();
    expect(container.read(workspacesProvider).activeId, mine.id);
    expect(container.read(workspacesProvider).byId(w.id), isNotNull);
  });

  test('ensureSampleWorkspaceOnFirstRun runs once, persists the flag and is idempotent', () async {
    expect(container.read(settingsProvider).sampleWorkspaceCreated, isFalse);
    final results = await Future.wait([service().ensureOnFirstRun(), service().ensureOnFirstRun()]);
    expect(results, [true, true], reason: 'concurrent calls share one run and its result');
    expect(samples(), hasLength(1), reason: 'only one workspace was created');
    expect(container.read(settingsProvider).sampleWorkspaceCreated, isTrue);
    final settingsFile = jsonDecode(File(env.paths.settingsFile).readAsStringSync()) as Map<String, dynamic>;
    expect((settingsFile['data'] as Map<String, dynamic>)['sampleWorkspaceCreated'], isTrue);

    expect(await service().ensureOnFirstRun(), isFalse);
    expect(samples(), hasLength(1));

    // A fresh app start (stores reloaded from disk) does not create another.
    await _settle();
    final boot = await BootData.load(env.stores);
    final restarted = ProviderContainer(
      overrides: [
        appPathsProvider.overrideWithValue(env.paths),
        appStoresProvider.overrideWithValue(env.stores),
        bootDataProvider.overrideWithValue(boot),
      ],
    );
    addTearDown(restarted.dispose);
    expect(await SampleWorkspaceService(restarted.read).ensureOnFirstRun(), isFalse);
    expect(restarted.read(workspacesProvider).workspaces.where((w) => w.kind == WorkspaceKind.sample), hasLength(1));
  });

  test('ensureSampleWorkspaceOnFirstRun adopts an existing sample instead of duplicating it', () async {
    await service().create();
    expect(container.read(settingsProvider).sampleWorkspaceCreated, isFalse);
    expect(await service().ensureOnFirstRun(), isFalse);
    expect(samples(), hasLength(1));
    expect(container.read(settingsProvider).sampleWorkspaceCreated, isTrue);
  });

  test('a failure is recorded in Activity and the flag stays unset for a retry', () async {
    // Make app storage unwritable for workspaces: a file where the folder goes.
    Directory(env.paths.workspacesDir).deleteSync(recursive: true);
    File(env.paths.workspacesDir).writeAsStringSync('blocked');

    expect(await service().ensureOnFirstRun(), isFalse);
    expect(container.read(settingsProvider).sampleWorkspaceCreated, isFalse);
    expect(container.read(workspacesProvider).workspaces, isEmpty);
    final op = container.read(activityProvider).operations.first;
    expect(op.title, 'Create sample workspace');
    expect(op.status, OperationStatus.failed);
    expect(op.error, isNotNull);
    expect(op.details.join('\n'), contains('Create sample workspace'));
    expect(container.read(activityProvider).notices.map((n) => n.kind), contains(NoticeKind.error));

    // Retry after the problem is gone.
    File(env.paths.workspacesDir).deleteSync();
    expect(await service().ensureOnFirstRun(), isTrue);
    expect(samples(), hasLength(1));
    expect(container.read(settingsProvider).sampleWorkspaceCreated, isTrue);
  });

  test('resetSampleWorkspace restores deleted and edited files and drops extras', () async {
    final w = await service().create();
    final meta = env.paths.workspaceMetaDir(w.id);
    _file(w.rootPath, 'game/data/ui/hud.json').writeAsStringSync('{"edited": true}');
    _file(w.rootPath, 'game/config/balance.toml').deleteSync();
    _file(w.rootPath, 'notes/unicode-名前-ünïcødé.txt').deleteSync();
    _file(w.rootPath, 'junk/extra.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('user file');
    File(p.join(meta, 'mods', 'neon-hud-1.2.0.j3mod')).deleteSync();
    File(p.join(meta, 'operations', 'op1', 'journal.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{}');
    final outside = File(p.join(env.dir.path, 'outside.txt'))..writeAsStringSync('keep');

    final stats = await service().reset(w.id);
    expect(stats.files, bundle.files.length);
    expectFullContent(w);
    expect(_file(w.rootPath, 'junk/extra.txt').existsSync(), isFalse);
    expect(Directory(p.join(meta, 'operations')).existsSync(), isFalse);
    expect(outside.readAsStringSync(), 'keep');
    expect(container.read(workspacesProvider).byId(w.id), isNotNull, reason: 'same record, same id');
    final op = container.read(activityProvider).operations.first;
    expect(op.title, 'Reset sample workspace');
    expect(op.status, OperationStatus.succeeded);
    expect(op.counts['files'], bundle.files.length);
  });

  test('resetSampleWorkspace refuses other workspace kinds and unknown ids', () async {
    final imported = await container.read(workspacesProvider.notifier).addAppOwned('Imported');
    final keep = _file(imported.rootPath, 'mine.txt')..writeAsStringSync('mine');
    final linkedDir = Directory(p.join(env.dir.path, 'my-game'))..createSync();
    final linkedFile = File(p.join(linkedDir.path, 'save.dat'))..writeAsStringSync('precious');
    final linked = await container.read(workspacesProvider.notifier).addLinked('My game', linkedDir.path);

    await expectLater(service().reset(imported.id), throwsStateError);
    await expectLater(service().reset(linked.id), throwsStateError);
    await expectLater(service().reset('nope'), throwsArgumentError);
    expect(keep.readAsStringSync(), 'mine');
    expect(linkedFile.readAsStringSync(), 'precious');
  });

  testWidgets('WidgetRef entry points work from a widget', (tester) async {
    final wEnv = (await tester.runAsync(TestEnv.create))!;
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: wEnv.overrides(),
        child: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.runAsync(() => ensureSampleWorkspaceOnFirstRun(captured));
    final first = captured.read(workspacesProvider).workspaces.single;
    expect(first.kind, WorkspaceKind.sample);
    expect(captured.read(settingsProvider).sampleWorkspaceCreated, isTrue);

    final second = (await tester.runAsync(() => createSampleWorkspace(captured)))!;
    expect(second.id, isNot(first.id));
    expect(captured.read(workspacesProvider).activeId, first.id);

    _file(second.rootPath, 'README.txt').deleteSync();
    await tester.runAsync(() => resetSampleWorkspace(captured, second.id));
    expect(_file(second.rootPath, 'README.txt').existsSync(), isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await _settle();
      await wEnv.dispose();
    });
  });

  testWidgets('sampleSmokeStep writes and verifies the content in the smoke workspace', (tester) async {
    final wEnv = (await tester.runAsync(TestEnv.create))!;
    late WidgetRef captured;
    await tester.pumpWidget(
      ProviderScope(
        overrides: wEnv.overrides(),
        child: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox();
          },
        ),
      ),
    );
    final ws = (await tester.runAsync(
      () => captured.read(workspacesProvider.notifier).addAppOwned('SMOKE ünïcødé 测试'),
    ))!;
    final detail = await tester.runAsync(() => sampleSmokeStep.run(captured, ws));
    expect(detail, contains('${bundle.files.length} files verified'));
    expect(_file(ws.rootPath, 'game/game.json').existsSync(), isTrue, reason: 'written into the smoke root');
    expect(captured.read(workspacesProvider).workspaces, hasLength(1), reason: 'no extra workspace');
    expect(Directory(p.join(wEnv.paths.workspaceMetaDir(ws.id), 'mods')).listSync(), hasLength(7));

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await _settle();
      await wEnv.dispose();
    });
  });
}
