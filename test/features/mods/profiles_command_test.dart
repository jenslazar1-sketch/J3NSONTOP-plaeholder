import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/commands/terminal_command.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/features/mods/mods_module.dart';
import 'package:j3nsontop_multitool/features/mods/profiles_command.dart';

import '../../helpers/harness.dart';
import 'mods_workspace_fixture.dart';

void main() {
  late TestEnv env;
  late ProviderContainer c;
  const cmd = ProfilesCommand();

  setUp(() async {
    env = await TestEnv.create();
    c = env.container(modules: [modsModule]);
  });
  tearDown(() async {
    c.dispose();
    await env.dispose();
  });

  CommandContext ctx() => CommandContext(read: c.read, navigate: (_) {}, token: CancellationToken());

  Future<CommandResult> run(List<String> tokens) => cmd.run(ctx(), parseArgs(tokens, valueOptions: cmd.valueOptions));

  String text(CommandResult r) => r.lines.map((l) => l.text).join('\n');

  test('metadata for help and completion', () {
    expect(cmd.name, 'profiles');
    expect(cmd.usage, contains('list|show|check|plan'));
    expect(cmd.args.first.values, ['list', 'show', 'check', 'plan']);
    expect(cmd.valueOptions, {'limit'});
    expect(cmd.examples, isNotEmpty);
  });

  test('no active workspace is an error', () async {
    final r = await run(['list']);
    expect(r.exitCode, 1);
    expect(text(r), contains('No active workspace'));
  });

  group('with the sample-like workspace', () {
    setUp(() async => createModsWorkspace(c));

    test('list shows every profile with its status', () async {
      final r = await run(['list']);
      expect(r.exitCode, 0);
      final t = text(r);
      expect(t, contains('hardcore-run'));
      expect(t, contains('conflict-demo'));
      expect(t, contains('broken-deps'));
      expect(r.lines.firstWhere((l) => l.text.startsWith('broken-deps')).style, TermStyle.error);
      expect(r.lines.firstWhere((l) => l.text.startsWith('conflict-demo')).text, contains('WARN'));
      expect(t, contains('Apply profiles from the Mods section'));
    });

    test('show lists the load order with versions', () async {
      final r = await run(['show', 'hardcore-run']);
      final t = text(r);
      expect(t, contains('Hardcore run (hardcore-run)'));
      expect(t, contains(' 1. [x] core-patch 1.0.0'));
      expect(t, contains(' 2. [x] hardcore-balance 2.0.1'));
      expect(t, contains('Neon Dungeon 1.4.2 (from game.json)'));
    });

    test('check reports errors with a failing exit code', () async {
      final r = await run(['check', 'broken-deps']);
      expect(r.exitCode, 1);
      final t = text(r);
      expect(t, contains('ERROR: Missing dependency: legacy-skin requires retro-core'));
      expect(t, contains('Dependency cycle: cycle-a -> cycle-b -> cycle-a'));
    });

    test('check reports overlaps with the winner', () async {
      final r = await run(['check', 'conflict-demo']);
      expect(r.exitCode, 0);
      expect(text(r), contains('config/balance.toml: hardcore-balance -> brutal-mode => brutal-mode wins'));
    });

    test('plan is a dry run summary', () async {
      final r = await run(['plan', 'hardcore-run']);
      expect(r.exitCode, 0, reason: text(r));
      final t = text(r);
      expect(t, contains('OVERWRITE config/balance.toml'));
      expect(t, contains('UNCHANGED data/items.csv'));
      expect(t, contains('CREATE    config/core.ini'));
      expect(t, contains('MKDIR     data/ui/neon/'));
      expect(t, contains('total: 2 create, 2 overwrite, 1 unchanged, 1 folder(s)'));
      expect(t, contains('nothing was written'));
    });

    test('plan honours --limit and refuses broken profiles', () async {
      final limited = await run(['plan', 'hardcore-run', '--limit', '1']);
      expect(text(limited), contains('... 4 more'));
      final broken = await run(['plan', 'broken-deps']);
      expect(broken.exitCode, 1);
      expect(text(broken), contains('Cannot plan broken-deps'));
      final bad = await run(['plan', 'hardcore-run', '--limit', 'x']);
      expect(bad.exitCode, 1);
    });

    test('unknown profile and subcommand errors', () async {
      expect((await run(['show', 'nope'])).exitCode, 1);
      expect((await run(['explode'])).exitCode, 1);
      expect((await run([])).exitCode, 1);
      expect((await run(['check'])).exitCode, 1);
    });

    test('completion suggests subcommands and profile ids', () {
      expect(cmd.complete(ctx(), []), ProfilesCommand.subcommands);
      expect(cmd.complete(ctx(), ['check', '']), ['broken-deps', 'conflict-demo', 'hardcore-run']);
      expect(cmd.complete(ctx(), ['list', '']), isEmpty);
    });
  });
}
