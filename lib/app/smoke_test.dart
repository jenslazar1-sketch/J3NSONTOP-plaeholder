import 'dart:convert';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../core/archive/safe_zip.dart';
import '../core/diagnostics/error_log.dart';
import '../core/platform/app_paths.dart';
import '../core/platform/capabilities.dart';
import '../core/settings/settings_controller.dart';
import '../core/storage/app_stores.dart';
import '../core/storage/json_store.dart';
import '../core/tools/tool_definition.dart';
import '../core/tools/tool_registry.dart';
import '../core/utils/hashing.dart';
import '../core/workspace/workspace.dart';
import '../core/workspace/workspace_controller.dart';
import 'app_info.dart';
import 'smoke_steps.dart';

/// One recorded self-test step.
class SmokeStep {
  SmokeStep(this.name, this.ok, this.ms, [this.detail]);
  final String name;
  final bool ok;
  final int ms;
  final String? detail;

  Map<String, dynamic> toJson() => {'name': name, 'ok': ok, 'ms': ms, 'detail': ?detail};
}

/// Packaged-app self test, started with `--smoke-test=<report.json>`
/// (use together with `--data-dir=<dir>` so user data is never touched).
///
/// It exercises the real app: storage round trips, workspace file I/O with
/// a Unicode name, hashing, ZIP create/inspect/extract, feature operations
/// registered in [featureSmokeSteps], and navigation to every section and
/// every tool page, while counting uncaught errors. It writes a JSON report
/// and exits with 0 (all passed) or 1.
class SmokeTestRunner {
  SmokeTestRunner({required this.ref, required this.router, required this.reportPath});

  final WidgetRef ref;
  final GoRouter router;
  final String reportPath;
  final List<SmokeStep> _steps = [];

  Future<SmokeStep> _step(String name, Future<String?> Function() body) async {
    final sw = Stopwatch()..start();
    final errorsBefore = ErrorLog.instance.count;
    SmokeStep step;
    try {
      final detail = await body();
      await _settle();
      final newErrors = ErrorLog.instance.count - errorsBefore;
      step = newErrors == 0
          ? SmokeStep(name, true, sw.elapsedMilliseconds, detail)
          : SmokeStep(
              name,
              false,
              sw.elapsedMilliseconds,
              '$newErrors uncaught error(s): ${ErrorLog.instance.recent.last.split('\n').first}',
            );
    } catch (e) {
      step = SmokeStep(name, false, sw.elapsedMilliseconds, '$e');
    }
    _steps.add(step);
    return step;
  }

  /// Waits for a few rendered frames so builds/layouts actually run.
  static Future<void> _settle([int frames = 3]) async {
    for (var i = 0; i < frames; i++) {
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
    }
  }

  Future<bool> run() async {
    final paths = ref.read(appPathsProvider);
    final sw = Stopwatch()..start();

    await _step('first frame rendered', () async {
      await _settle(5);
      return 'errors at start: ${ErrorLog.instance.count}';
    });

    await _step('settings persist and reload from disk', () async {
      final ctrl = ref.read(settingsProvider.notifier);
      final before = ref.read(settingsProvider);
      await ctrl.update((s) => s.copyWith(intensity: 0.42, lowEffects: !before.lowEffects));
      final reloaded = await ref.read(appStoresProvider).settings.load();
      if (reloaded.outcome != LoadOutcome.loaded) throw StateError('reload outcome ${reloaded.outcome}');
      if (reloaded.data['intensity'] != 0.42) throw StateError('intensity not persisted');
      await ctrl.update((_) => before);
      return 'settings.json round trip ok';
    });

    Workspace? ws;
    await _step('workspace create + Unicode file I/O', () async {
      ws = await ref.read(workspacesProvider.notifier).addAppOwned('SMOKE ünïcødé 测试');
      final dir = Directory(p.join(ws!.rootPath, 'data', 'ünïcødé 名前'));
      await dir.create(recursive: true);
      final f = File(p.join(dir.path, 'hello ✓.txt'));
      await f.writeAsString('J3NSONTOP SYSTEM ONLINE\n');
      final back = await f.readAsString();
      if (back != 'J3NSONTOP SYSTEM ONLINE\n') throw StateError('read-back mismatch');
      return ws!.rootPath;
    });

    await _step('streamed SHA-256 of a file', () async {
      final f = File(p.join(ws!.rootPath, 'data', 'blob.bin'));
      final bytes = List<int>.generate(2 * 1024 * 1024 + 3, (i) => (i * 7) & 0xFF);
      await f.writeAsBytes(bytes);
      final h = await Hashing.file(f.path);
      if (h != Hashing.bytes(bytes)) throw StateError('hash mismatch');
      return h;
    });

    await _step('ZIP create, inspect and extract', () async {
      final zip = p.join(paths.cacheDir, 'smoke.zip');
      await SafeZip.create(zip, [
        ZipSource.file('data/blob.bin', p.join(ws!.rootPath, 'data', 'blob.bin')),
        ZipSource.bytes('readme ✓.txt', utf8.encode('smoke')),
      ]);
      final inspection = SafeZip.inspect(zip);
      if (!inspection.isSafe) throw StateError(inspection.issues.join('; '));
      final out = p.join(ws!.rootPath, 'extracted');
      final r = await SafeZip.extract(zip, out);
      await File(zip).delete();
      return '${r.written.length} files, ${r.bytes} bytes';
    });

    for (final step in featureSmokeSteps) {
      await _step(step.name, () => step.run(ref, ws!));
    }

    final registry = ref.read(toolRegistryProvider);
    final caps = ref.read(capabilitiesProvider);
    final routes = <String>[
      '/',
      for (final s in ToolSection.values)
        if (s != ToolSection.system) s.route,
      '/tools',
      '/activity',
      '/settings',
      '/about',
    ];
    await _step('navigate every section (${routes.length})', () async {
      for (final r in routes) {
        router.go(r);
        await _settle();
      }
      return routes.join(' ');
    });

    final tools = registry.all.where((t) => t.availableOn(caps)).toList();
    await _step('open every tool page (${tools.length})', () async {
      final failed = <String>[];
      for (final t in tools) {
        final before = ErrorLog.instance.count;
        router.go(t.route);
        await _settle();
        if (ErrorLog.instance.count != before) failed.add(t.id);
      }
      router.go('/');
      await _settle();
      if (failed.isNotEmpty) throw StateError('errors while building: ${failed.join(', ')}');
      return '${tools.length} tools rendered';
    });

    await _step('remove smoke workspace (app-owned copy deleted)', () async {
      await ref.read(workspacesProvider.notifier).remove(ws!.id, deleteAppOwnedFiles: true);
      if (await Directory(ws!.rootPath).exists()) throw StateError('workspace files still present');
      return 'removed';
    });

    final ok = _steps.every((s) => s.ok);
    final report = <String, dynamic>{
      'ok': ok,
      'app': AppInfo.fullName,
      'version': '${AppInfo.version}+${AppInfo.buildNumber}',
      'platform': caps.platform.name,
      'os': Platform.operatingSystemVersion,
      'dataDir': paths.root,
      'durationMs': sw.elapsedMilliseconds,
      'toolCount': registry.all.length,
      'uncaughtErrors': ErrorLog.instance.count,
      'steps': [for (final s in _steps) s.toJson()],
      if (ErrorLog.instance.recent.isNotEmpty) 'errors': ErrorLog.instance.recent,
    };
    final file = File(reportPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln(
      'SMOKE TEST ${ok ? 'PASSED' : 'FAILED'}: ${_steps.where((s) => s.ok).length}/${_steps.length} steps',
    );
    for (final s in _steps) {
      stdout.writeln('  [${s.ok ? ' OK ' : 'FAIL'}] ${s.name} (${s.ms} ms)${s.detail != null ? ' - ${s.detail}' : ''}');
    }
    return ok;
  }
}
