import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/app/app_info.dart';
import 'package:j3nsontop_multitool/core/activity/activity_controller.dart';
import 'package:j3nsontop_multitool/core/commands/terminal_command.dart';
import 'package:j3nsontop_multitool/core/platform/capabilities.dart';
import 'package:j3nsontop_multitool/core/settings/app_settings.dart';
import 'package:j3nsontop_multitool/core/settings/settings_controller.dart';
import 'package:j3nsontop_multitool/core/storage/user_data.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/theme/j3_colors.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/intro/skull_art.dart';
import 'package:j3nsontop_multitool/features/shell/destinations.dart';
import 'package:j3nsontop_multitool/features/terminal/commands/basic_commands.dart';
import 'package:j3nsontop_multitool/features/terminal/commands/builtin_commands.dart';
import 'package:j3nsontop_multitool/features/terminal/commands/skull_command.dart';
import 'package:j3nsontop_multitool/features/terminal/presentation/terminal_session.dart';
import 'package:j3nsontop_multitool/features/terminal/terminal_module.dart';

import '../../helpers/harness.dart';
import 'terminal_test_support.dart';

void main() {
  late TestEnv env;
  late TerminalDriver t;

  setUp(() async {
    env = await TestEnv.create();
    t = TerminalDriver(env);
  });

  tearDown(() async {
    await t.dispose();
    await disposeEnv(env);
  });

  group('module', () {
    test('registers the Terminal tool in System with its keywords', () {
      final tool = terminalModule.tools.single;
      expect(tool.id, kTerminalToolId);
      expect(tool.name, 'Terminal');
      expect(tool.route, kTerminalRoute);
      expect(tool.keywords, containsAll(['command', 'console', 'cli', 'prompt', 'run']));
      expect(tool.description, contains('Not a system shell'));
    });

    test('every built-in command has usage, summary and unique names', () {
      final names = <String>{};
      for (final c in kBuiltinCommands) {
        expect(c.usage, startsWith(c.name), reason: c.name);
        expect(c.summary, isNotEmpty);
        for (final n in [c.name, ...c.aliases]) {
          expect(names.add(n), isTrue, reason: 'duplicate $n');
        }
      }
    });
  });

  group('session', () {
    test('starts with the banner (mini skull + not-a-shell statement + hint)', () {
      final rows = t.state.rows;
      expect(rows.first.kind, TerminalRowKind.ascii);
      expect(rows.first.art, [...kMiniSkullCranium, ...kMiniSkullJaw]);
      final text = t.state.plainText;
      expect(text, contains('internal command interface'));
      expect(text, contains('This is not a system shell.'));
      expect(text, contains('Type `help`'));
    });

    test('echoes the command with the workspace prompt', () async {
      await t.session.submit('echo hi', navigate: t.routes.add);
      final echo = t.state.rows.firstWhere((r) => r.kind == TerminalRowKind.echo);
      expect(echo.plain, r'j3nsontop@~$ echo hi');
      await t.container.read(workspacesProvider.notifier).addAppOwned('Alpha');
      expect(t.session.prompt(), r'j3nsontop@Alpha$');
    });

    test('unknown command prints an error with "did you mean"', () async {
      final out = await t.run('hepl');
      expect(out.first, 'ERROR: Unknown command "hepl".');
      expect(out, contains('Did you mean: help?'));
      expect(out.last, contains('Type `help`'));
    });

    test('OS programs get an explicit not-a-system-shell explanation', () async {
      final out = await t.text('ls -la');
      expect(out, contains('ERROR: Unknown command "ls".'));
      expect(out, contains('This is not a system shell'));
    });

    test('tokenizer errors are reported, not thrown', () async {
      final out = await t.run('echo "unclosed');
      expect(out.first, startsWith('ERROR: Unclosed " quote'));
      expect(t.state.isRunning, isFalse);
    });

    test('exceptions in commands are contained (async and sync)', () async {
      final d = TerminalDriver(env, registry: buildTerminalRegistry(extra: const [BoomCommand(), SyncBoomCommand()]));
      addTearDown(d.dispose);
      final out = await d.text('boom');
      expect(out, contains('ERROR: "boom" failed: Bad state: kaput'));
      final sync = await d.text('syncboom');
      expect(sync, contains('ERROR: "syncboom" failed: Invalid argument(s): sync failure'));
      expect(await d.text('echo still alive'), 'still alive');
    });

    test('commands and aliases resolve case-insensitively; --help shows details', () async {
      expect(await t.text('ECHO loud'), 'loud');
      expect(await t.text('sha abc --algo md5'), 'hash:abc:md5');
      final help = await t.text('open --help');
      expect(help, contains('usage: open <tool-id|section|route>'));
      expect(t.routes, isEmpty);
    });

    test('Ctrl+C cancels a command that ignores the token; late output is dropped', () async {
      final slow = SlowCommand();
      final d = TerminalDriver(env, registry: buildTerminalRegistry(extra: [slow]));
      addTearDown(d.dispose);
      d.session.clear();
      final done = d.session.submit('slow', navigate: d.routes.add);
      await Future<void>.delayed(Duration.zero);
      expect(d.state.running, 'slow');
      expect(d.session.cancel(), isTrue);
      await done;
      expect(d.state.isRunning, isFalse);
      expect(d.state.rows.last.plain, '^C');
      slow.gate.complete(CommandResult.text('late'));
      await Future<void>.delayed(Duration.zero);
      expect(d.state.plainText, isNot(contains('late')));
      expect(d.session.cancel(), isFalse);
    });

    test('cooperative commands observe the CancellationToken', () async {
      final d = TerminalDriver(env, registry: buildTerminalRegistry(extra: const [CoopCommand()]));
      addTearDown(d.dispose);
      d.session.clear();
      final done = d.session.submit('coop', navigate: d.routes.add);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      d.session.cancel();
      await done;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(d.state.plainText, isNot(contains('finished')));
      expect(d.state.plainText, endsWith('^C'));
    });

    test('a second command is refused while one is running', () async {
      final slow = SlowCommand();
      final d = TerminalDriver(env, registry: buildTerminalRegistry(extra: [slow]));
      addTearDown(d.dispose);
      final done = d.session.submit('slow', navigate: d.routes.add);
      await Future<void>.delayed(Duration.zero);
      await d.session.submit('echo nope', navigate: d.routes.add);
      expect(d.state.plainText, isNot(contains('nope')));
      slow.gate.complete(CommandResult.text('released'));
      await done;
      expect(d.state.rows.last.plain, 'released');
    });

    test('Ctrl+C at the prompt echoes the abandoned line', () {
      t.session.interrupt('half typed');
      expect(t.state.rows.last.plain, r'j3nsontop@~$ half typed^C');
    });

    test('scrollback is capped with a dropped-lines count', () {
      t.session.clear();
      t.session.writeLines([for (var i = 0; i < TerminalSession.scrollbackLimit + 100; i++) TermLine('line $i')]);
      expect(t.state.lineCount, TerminalSession.scrollbackLimit);
      expect(t.state.droppedLines, 100);
      expect(t.state.rows.first.plain, 'line 100');
      t.session.clear();
      expect(t.state.rows, isEmpty);
      expect(t.state.droppedLines, 0);
    });

    test('consecutive ASCII lines are grouped into one block', () {
      final rows = rowsFromLines([
        const TermLine('a', TermStyle.ascii),
        const TermLine('b', TermStyle.ascii),
        const TermLine('text'),
        const TermLine('c', TermStyle.ascii),
      ]);
      expect(rows.map((r) => r.kind), [TerminalRowKind.ascii, TerminalRowKind.line, TerminalRowKind.ascii]);
      expect(rows.first.lineCount, 2);
    });

    test('command history is recorded and persisted to userdata.json', () async {
      await t.run('echo one');
      await t.run('echo two');
      expect(t.container.read(userDataProvider).commandHistory, ['echo one', 'echo two']);
      List<String> persisted = const [];
      for (var i = 0; i < 100 && persisted.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final loaded = await env.stores.userData.load();
        persisted = UserData.fromJson(loaded.data).commandHistory;
      }
      expect(persisted, ['echo one', 'echo two']);
    });
  });

  group('help', () {
    test('lists visible commands grouped by feature, with usage; hidden omitted', () async {
      final out = await t.run('help');
      final text = out.join('\n');
      expect(text, contains('not a system shell'));
      expect(out, contains('SYSTEM'));
      expect(out, contains('DEVELOPER TOOLS'));
      for (final c in kBuiltinCommands.where((c) => !c.hidden)) {
        expect(text, contains(c.usage), reason: c.name);
        expect(out.any((l) => l.trimLeft().startsWith('${c.name} ')), isTrue, reason: c.name);
      }
      expect(text, contains('hash <text> [--algo sha256|md5]'));
      expect(out.any((l) => l.trimLeft().startsWith('skull')), isFalse);
    });

    test('help <command> shows args, values, options and examples', () async {
      final out = await t.text('help hash');
      expect(out, contains('hash \u2014 Hash text'));
      expect(out, contains('usage: hash <text> [--algo sha256|md5]'));
      expect(out, contains('aliases: sha'));
      expect(out, contains('ARGUMENTS'));
      expect(out, contains('values: sha256, md5, sha1'));
      expect(out, contains('--algo <value>'));
      expect(out, contains('EXAMPLES'));
      expect(out, contains('hash abc --algo md5'));
      final theme = await t.text('help theme');
      expect(theme, contains('values: show, accent, effects, intensity'));
      expect(await t.text('? version'), contains('about \u2014'));
    });

    test('help for an unknown command suggests close names', () async {
      final out = await t.run('help opne');
      expect(out.first, 'ERROR: No command named "opne".');
      expect(out, contains('Did you mean: open?'));
    });
  });

  group('tools', () {
    test('lists every section with ids, names and availability', () async {
      final out = await t.text('tools');
      expect(out, contains('DEVELOPER TOOLS  [dev]  1 tool'));
      expect(out, contains('[ok]  dev.base64'));
      expect(out, contains('Base64'));
      expect(out, contains('[ok]  system.terminal'));
      expect(out, contains('5 tools, 5 available on Linux (dev/test)'));
    });

    test('marks tools unavailable on this platform with the reason', () async {
      final d = TerminalDriver(env, platform: AppPlatform.android);
      addTearDown(d.dispose);
      final out = await d.text('tools mods');
      expect(out, contains('[--]  mods.apply'));
      expect(out, contains('unavailable: needs Apply mods in place (not available on Android)'));
      expect(out, contains('1 tool, 0 available on Android'));
    });

    test('filters by section key or label, searches otherwise', () async {
      expect(await t.text('tools config'), contains('config.json'));
      expect(await t.text('tools "Config Lab"'), contains('config.json'));
      final search = await t.text('tools checksum');
      expect(search, contains('SEARCH "checksum"  1 match'));
      expect(search, contains('files.hash'));
      final none = await t.run('tools zzzz');
      expect(none.first, 'ERROR: No tool matches "zzzz".');
    });
  });

  group('open', () {
    test('navigates to tools, sections, pages and routes', () async {
      await t.run('open dev.base64');
      await t.run('open mods');
      await t.run('open settings');
      await t.run('open home');
      await t.run('open /activity');
      await t.run('open /tool/files.hash');
      await t.run('open "json formatter"');
      await t.run('open terminal');
      expect(t.routes, [
        '/tool/dev.base64',
        '/mods',
        '/settings',
        '/',
        '/activity',
        '/tool/files.hash',
        '/tool/config.json',
        kTerminalRoute,
      ]);
      expect(await t.text('open dev.base64'), contains('Opening Base64 (dev.base64)  ->  /tool/dev.base64'));
    });

    test('warns when the tool is unavailable on this platform', () async {
      final d = TerminalDriver(env, platform: AppPlatform.android);
      addTearDown(d.dispose);
      final out = await d.text('open mods.apply');
      expect(d.routes, ['/tool/mods.apply']);
      expect(out, contains('WARN: Apply Profile: needs Apply mods in place (not available on Android).'));
    });

    test('unknown targets get "did you mean" suggestions and no navigation', () async {
      final out = await t.run('open settngs');
      expect(out.first, 'ERROR: Nothing called "settngs" to open.');
      expect(out, contains('Did you mean: settings?'));
      final id = await t.run('open dev.base46');
      expect(id, contains('Did you mean: dev.base64?'));
      final route = await t.run('open /nowhere');
      expect(route.first, 'ERROR: Nothing called "/nowhere" to open.');
      final empty = await t.run('open');
      expect(empty.first, 'ERROR: Nothing to open.');
      expect(t.routes, isEmpty);
    });
  });

  group('history', () {
    test('lists operations newest first with status labels and errors', () async {
      final activity = t.container.read(activityProvider.notifier);
      activity.start(toolId: 'files.hash', title: 'Hash files').succeed('3 files hashed');
      activity.start(toolId: 'mods.apply', title: 'Apply profile').fail(StateError('folder missing'));
      activity.start(toolId: 'dev.base64', title: 'Decode').cancelled();
      final out = await t.run('history');
      expect(out[0], contains('CANCELLED'));
      expect(out[0], contains('Decode'));
      expect(out[1], contains('FAILED'));
      expect(out[1], contains('Apply profile \u2014 error: Bad state: folder missing'));
      expect(out[2], contains('DONE'));
      expect(out[2], contains('Hash files \u2014 3 files hashed'));
      expect(out.last, contains('showing 3 of 3 operations'));
      expect(t.state.rows[2].style, TermStyle.error);

      final failed = await t.run('history --failed');
      expect(failed.first, contains('Apply profile'));
      expect(failed.last, contains('showing 1 of 1 failed operation'));

      final one = await t.run('history 1');
      expect(one.last, contains('showing 1 of 3'));
    });

    test('empty history and invalid counts', () async {
      expect(await t.text('history'), contains('No operations recorded yet.'));
      expect(await t.text('history --failed'), contains('No failed operations recorded.'));
      final bad = await t.run('history abc');
      expect(bad.first, 'ERROR: "abc" is not a count between 1 and 300.');
      expect(bad.last, 'usage: history [n] [--failed]');
    });
  });

  group('theme', () {
    test('show prints the current settings', () async {
      final out = await t.text('theme');
      expect(out, contains('accent      Neon red (neon)'));
      expect(out, contains('effects     full'));
      expect(out, contains('intensity   75%'));
      expect(out, contains('motion      system'));
      expect(await t.text('theme show'), out);
    });

    test('changes are applied and persisted to settings.json', () async {
      expect(await t.text('theme accent crimson'), contains('OK: accent set to Crimson'));
      expect(await t.text('theme effects low'), contains('low-effects mode on'));
      expect(await t.text('theme intensity 40'), contains('40%'));
      await t.run('theme scanlines off');
      await t.run('theme particles off');
      await t.run('theme glow off');
      await t.run('theme motion reduced');
      final s = t.container.read(settingsProvider);
      expect(s.accent, AccentPreset.crimson);
      expect(s.lowEffects, isTrue);
      expect(s.intensity, closeTo(0.4, 1e-9));
      expect(s.scanlines || s.particles || s.glow, isFalse);
      expect(s.motion, MotionPreference.reduced);
      final saved = AppSettings.fromJson((await env.stores.settings.load()).data);
      expect(saved.accent, AccentPreset.crimson);
      expect(saved.lowEffects, isTrue);
      expect(saved.motion, MotionPreference.reduced);
      expect(await t.text('theme effects full'), contains('full effects restored'));
      expect(t.container.read(settingsProvider).lowEffects, isFalse);
    });

    test('invalid values are rejected with the allowed values', () async {
      final bad = await t.run('theme accent blue');
      expect(bad.first, 'ERROR: "blue" is not a valid accent.');
      expect(bad.last, 'usage: theme accent <neon|crimson|infrared|ember>');
      expect((await t.run('theme intensity 150')).first, startsWith('ERROR:'));
      expect((await t.run('theme glow maybe')).first, startsWith('ERROR:'));
      expect((await t.run('theme motion')).first, 'ERROR: `theme motion` needs a value: system|reduced|full.');
      expect((await t.run('theme wobble')).first, 'ERROR: Unknown theme setting "wobble".');
      expect(t.container.read(settingsProvider).accent, AccentPreset.neon);
    });
  });

  group('ws', () {
    test('list, use and info (with health check)', () async {
      expect(await t.text('ws'), contains('No workspaces yet.'));
      final ctl = t.container.read(workspacesProvider.notifier);
      final alpha = await ctl.addAppOwned('Alpha Project');
      final beta = await ctl.addAppOwned('Beta');
      expect(t.container.read(workspacesProvider).activeId, beta.id);

      final list = await t.text('ws list');
      expect(list, contains('* Beta  [Imported copy]'));
      expect(list, contains('  Alpha Project  [Imported copy]'));
      expect(list, contains(alpha.rootPath));

      expect(await t.text('ws use alpha project'), contains('OK: active workspace is now "Alpha Project"'));
      expect(t.container.read(workspacesProvider).activeId, alpha.id);
      await t.run('ws use ${beta.id}');
      expect(t.container.read(workspacesProvider).activeId, beta.id);

      final info = await t.text('ws info "Alpha Project"');
      expect(info, contains('id       ${alpha.id}'));
      expect(info, contains('health   OK: root folder is reachable'));

      await Directory(alpha.rootPath).delete(recursive: true);
      final missing = await t.run('ws info Alpha');
      expect(missing.last, '  health   MISSING: root folder was not found');
      expect(t.state.rows.last.style, TermStyle.error);
    });

    test('unknown workspace suggests names', () async {
      await t.container.read(workspacesProvider.notifier).addAppOwned('Sample Mods');
      final out = await t.run('ws use Sampel Mods');
      expect(out.first, 'ERROR: No workspace matches "Sampel Mods".');
      expect(out, contains('Did you mean: Sample Mods?'));
      expect((await t.run('ws use')).first, 'ERROR: Which workspace?');
      expect(await t.text('ws info'), contains('Sample Mods  (active)'));
    });
  });

  group('basics', () {
    test('clear empties the screen', () async {
      await t.session.submit('echo x', navigate: t.routes.add);
      await t.session.submit('clear', navigate: t.routes.add);
      expect(t.state.rows, isEmpty);
      await t.session.submit('cls', navigate: t.routes.add);
      expect(t.state.rows, isEmpty);
    });

    test('echo prints its arguments', () async {
      expect(await t.text('echo hello   world'), 'hello world');
      expect(await t.text('echo "  keep  "'), '  keep  ');
      expect(await t.text('echo -- --flag'), '--flag');
    });

    test('about/version report name, version, platform and counts', () async {
      final out = await t.text('about');
      expect(out, contains(AppInfo.fullName));
      expect(out, contains('version    ${AppInfo.version} (build ${AppInfo.buildNumber})'));
      expect(out, contains('platform   Linux (dev/test)'));
      expect(out, contains('tools      5 registered, 5 available here'));
      final visible = kBuiltinCommands.where((c) => !c.hidden).length + 1;
      expect(out, contains('commands   $visible'));
      expect(out, contains('not a system shell'));
      expect(await t.text('version'), out);
    });

    test('date prints local (with offset) and UTC ISO 8601', () async {
      final out = await t.run('date');
      expect(out[0], matches(RegExp(r'^local  \d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d')));
      expect(out[1], matches(RegExp(r'^utc    \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')));
      expect(out[2], matches(RegExp(r'^unix   \d+$')));
      final fixed = DateCommand(clock: () => DateTime.utc(2026, 9, 25, 16, 41, 7));
      final r = await fixed.run(
        CommandContext(read: t.container.read, navigate: (_) {}, token: CancellationToken.none),
        const ParsedArgs([], {}),
      );
      expect(r.lines[1].text, 'utc    2026-09-25T16:41:07Z');
    });

    test('skull is hidden but prints the full skull and a cosmetic laugh', () async {
      expect(const SkullCommand().hidden, isTrue);
      final out = await t.run('skull');
      expect(out.first, [...kSkullCranium, ...kSkullJaw].join('\n'));
      final frames = skullLaughFrames();
      expect(out, contains(frames.join('\n')));
      expect(frames.last, contains('HA HA HA'));
      // The jaw drops by one more blank row in each frame.
      expect(frames.length, kMiniSkullCranium.length + kMiniSkullJaw.length + 2 + 2);
      expect(out.last, contains('nothing was executed'));
      final unknown = await t.run('skul');
      expect(unknown, isNot(contains('Did you mean: skull?')));
    });
  });
}
