import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/commands/terminal_command.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/tools/tool_definition.dart';
import 'package:j3nsontop_multitool/core/tools/tool_registry.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/dev_tools/dev_clock.dart';
import 'package:j3nsontop_multitool/features/dev_tools/dev_tools_module.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';
import 'dev_test_utils.dart';

const expectedIds = [
  'dev.base64',
  'dev.url',
  'dev.uuid',
  'dev.timestamp',
  'dev.text_stats',
  'dev.json_escape',
  'dev.regex',
  'dev.diff',
  'dev.http',
  'dev.case',
  'dev.number_base',
  'dev.jwt',
];

void main() {
  group('module registration', () {
    final registry = ToolRegistry([devToolsModule]);

    test('registers every tool once in the Developer Tools section', () {
      expect(registry.all.map((t) => t.id).toList(), expectedIds);
      for (final t in registry.all) {
        expect(t.section, ToolSection.devTools, reason: t.id);
        expect(t.keywords.length, greaterThanOrEqualTo(6), reason: t.id);
        expect(t.description, isNotEmpty);
      }
    });

    test('only the HTTP tool needs the network', () {
      for (final t in registry.all) {
        final isHttp = t.id == 'dev.http';
        expect(t.worksOffline, !isHttp, reason: t.id);
        expect(t.requiredCapabilities, isHttp ? {Capability.networkRequests} : isEmpty, reason: t.id);
      }
      const noNet = CapabilityMatrix(AppPlatform.android, {Capability.networkRequests: false});
      expect(registry.byId('dev.http')!.availableOn(noNet), isFalse);
      expect(registry.byId('dev.base64')!.availableOn(noNet), isTrue);
    });

    test('search finds tools by keyword', () {
      expect(registry.search('jwt').first.tool.id, 'dev.jwt');
      expect(registry.search('b64').first.tool.id, 'dev.base64');
      expect(registry.search('epoch').first.tool.id, 'dev.timestamp');
      expect(registry.search('snake').first.tool.id, 'dev.case');
      expect(registry.search('curl').first.tool.id, 'dev.http');
    });

    test('commands are registered with usage and examples', () {
      for (final name in ['diff', 'uuid', 'b64', 'base64', 'url', 'ts', 'timestamp']) {
        final c = registry.command(name);
        expect(c, isNotNull, reason: name);
        expect(c!.usage, isNotEmpty);
        expect(c.examples, isNotEmpty);
      }
    });
  });

  group('terminal commands', () {
    late TestEnv env;
    late ProviderContainer container;
    late ToolRegistry registry;

    setUp(() async {
      env = await TestEnv.create();
      registry = ToolRegistry([devToolsModule]);
      container = ProviderContainer(
        overrides: [
          ...env.overrides(registry: registry),
          devClockProvider.overrideWithValue(() => fixedNow),
        ],
      );
    });
    tearDown(() async {
      container.dispose();
      await env.dispose();
    });

    CommandContext ctx() => CommandContext(read: container.read, navigate: (_) {}, token: CancellationToken());

    /// Runs a command line the way the terminal does.
    Future<CommandResult> run(String line) {
      final tokens = tokenizeCommandLine(line);
      final cmd = registry.command(tokens.first)!;
      return cmd.run(ctx(), parseArgs(tokens.sublist(1), valueOptions: cmd.valueOptions));
    }

    String text(CommandResult r) => r.lines.map((l) => l.text).join('\n');

    test('uuid', () async {
      final r = await run('uuid 3 --v7 --upper');
      expect(r.exitCode, 0);
      expect(r.lines.length, 3);
      for (final l in r.lines) {
        expect(l.text, matches(RegExp(r'^[0-9A-F]{8}-[0-9A-F]{4}-7[0-9A-F]{3}-')));
      }
      expect((await run('uuid 0')).exitCode, 1);
      expect(text(await run('uuid --braces --no-hyphens')), matches(RegExp(r'^\{[0-9a-f]{32}\}$')));
    });

    test('b64', () async {
      expect(text(await run('b64 enc "hello world"')), 'aGVsbG8gd29ybGQ=');
      expect(text(await run('b64 dec aGVsbG8gd29ybGQ')), 'hello world');
      expect(text(await run('base64 enc "a?b>" --url --no-pad')), 'YT9iPg');
      final bad = await run('b64 dec aGVs*G8=');
      expect(bad.exitCode, 1);
      expect(bad.lines.first.style, TermStyle.error);
      expect(text(bad), contains('  aGVs*G8=\n      ^'));
      final bin = await run('b64 dec //79');
      expect(text(bin), contains('not valid UTF-8'));
      expect((await run('b64 zip x')).exitCode, 1);
    });

    test('url', () async {
      expect(text(await run('url enc "a b&c"')), 'a%20b%26c');
      expect(text(await run('url enc "a b" --form')), 'a+b');
      expect(text(await run('url dec a%20b%26c')), 'a b&c');
      final bad = await run('url dec 100%zz');
      expect(bad.exitCode, 1);
      expect(text(bad), contains('Malformed percent sequence'));
    });

    test('ts', () async {
      final now = await run('ts');
      expect(text(now), contains('2026-09-25T19:41:07.123Z'));
      expect(text(now), contains('read as: now'));
      final conv = await run('ts 1758829267123');
      expect(text(conv), contains('Unix milliseconds (auto-detected by magnitude)'));
      expect(text(conv), contains('Thu, 25 Sep 2025 19:41:07 GMT'));
      expect(text(await run('ts 1758829267 --unit ms')), contains('1970-01-21T08:33:49.267Z'));
      final bad = await run('ts 2026-02-30');
      expect(bad.exitCode, 1);
      expect(text(bad), contains('Day 30 is out of range'));
      expect((await run('ts 1 --unit weeks')).exitCode, 1);
    });

    test('diff with inline texts styles +/- lines', () async {
      final r = await run(r"diff 'alpha\nbeta\ngamma' 'alpha\nBETA\ngamma'");
      expect(r.exitCode, 0);
      final minus = r.lines.firstWhere((l) => l.text == '-beta');
      final plus = r.lines.firstWhere((l) => l.text == '+BETA');
      expect(minus.style, TermStyle.error);
      expect(plus.style, TermStyle.success);
      expect(r.lines.first.style, TermStyle.dim);
      expect(r.lines.any((l) => l.text.startsWith('@@') && l.style == TermStyle.accent), isTrue);
      expect(text(await run('diff same same')), contains('Identical'));
      expect(text(await run('diff Hello hello --ignore-case')), contains('Identical'));
      expect((await run('diff onlyone')).exitCode, 1);
    });

    test('diff with workspace files resolves paths safely', () async {
      final root = Directory(p.join(env.dir.path, 'ws'))..createSync();
      File(p.join(root.path, 'old.ini')).writeAsStringSync('[main]\nspeed=1\n');
      Directory(p.join(root.path, 'cfg')).createSync();
      File(p.join(root.path, 'cfg', 'new.ini')).writeAsStringSync('[main]\nspeed=2\n');
      expect(text(await run('diff --file-a old.ini --file-b cfg/new.ini')), contains('No active workspace'));

      await container.read(workspacesProvider.notifier).addLinked('ws', root.path);
      final r = await run('diff --file-a old.ini --file-b cfg/new.ini');
      expect(r.exitCode, 0, reason: text(r));
      expect(text(r), contains('--- old.ini\n+++ cfg/new.ini'));
      expect(text(r), contains('-speed=1\n+speed=2'));

      final escape = await run('diff --file-a ../secret.txt --file-b old.ini');
      expect(escape.exitCode, 1);
      expect(text(escape), contains('parent-directory traversal'));
      expect(text(await run('diff --file-a missing.txt "x"')), contains('File not found'));

      final cmd = registry.command('diff')!;
      expect(cmd.complete(ctx(), ['--file-a', 'c']), ['cfg/']);
      expect(cmd.complete(ctx(), ['--file-a', 'cfg/']), ['cfg/new.ini']);
      expect(cmd.complete(ctx(), ['--ig']), ['--ignore-case', '--ignore-space']);
    });

    test('completion for enumerable arguments', () {
      expect(registry.command('b64')!.complete(ctx(), ['']), ['enc', 'dec']);
      expect(registry.command('ts')!.complete(ctx(), ['1', '--unit', '']), ['s', 'ms', 'us', 'ns']);
      expect(registry.command('uuid')!.complete(ctx(), ['3', '--v']), ['--v7']);
    });
  });
}
