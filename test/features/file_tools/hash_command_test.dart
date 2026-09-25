import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/commands/terminal_command.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/tools/tool_registry.dart';
import 'package:j3nsontop_multitool/core/utils/hashing.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/file_tools/commands/hash_command.dart';
import 'package:j3nsontop_multitool/features/file_tools/file_tools_module.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';

void main() {
  late TestEnv env;
  late ProviderContainer c;
  const cmd = HashCommand();

  setUp(() async {
    env = await TestEnv.create();
    c = env.container(modules: [fileToolsModule]);
  });
  tearDown(() async {
    c.dispose();
    await env.dispose();
  });

  Future<CommandResult> run(String line, {CancellationToken? token}) {
    final tokens = tokenizeCommandLine(line);
    expect(tokens.first, 'hash');
    tokens.removeAt(0); // parseArgs takes the tokens after the command name
    return cmd.run(
      CommandContext(read: c.read, navigate: (_) {}, token: token ?? CancellationToken()),
      parseArgs(tokens, valueOptions: cmd.valueOptions),
    );
  }

  String all(CommandResult r) => r.lines.map((l) => l.text).join('\n');

  test('is registered in the File Tools module', () {
    final registry = c.read(toolRegistryProvider);
    expect(registry.command('hash'), isA<HashCommand>());
    expect(registry.inSection(fileToolsModule.tools.first.section).map((t) => t.id), [
      'files.hash',
      'files.duplicates',
      'files.line_endings',
      'files.whitespace',
      'files.zip',
      'files.logs',
    ]);
  });

  test('hashes text (default SHA-256) with algorithm and size', () async {
    final r = await run('hash hello world');
    expect(r.exitCode, 0);
    expect(r.lines.first.text, '${Hashing.text('hello world')}  -');
    expect(all(r), contains('algorithm: SHA-256'));
    expect(all(r), contains('11 bytes'));
  });

  test('quoted text keeps spacing; --algo and legacy warning', () async {
    final r = await run('hash "a  b" --algo md5');
    expect(r.lines.first.text, startsWith(Hashing.text('a  b', HashAlgorithm.md5)));
    expect(all(r), contains('not collision resistant'));
    final s = await run('hash x -a sha512');
    expect(s.lines.first.text, startsWith(Hashing.text('x', HashAlgorithm.sha512)));
    expect((await run('hash x --algo crc32')).exitCode, 1);
    expect((await run('hash')).exitCode, 1);
  });

  test('--check prints MATCH or MISMATCH', () async {
    final digest = Hashing.text('abc');
    final ok = await run('hash abc --check SHA256:${digest.toUpperCase()}');
    expect(ok.exitCode, 0);
    expect(all(ok), contains('MATCH'));
    final bad = await run('hash abd --check $digest');
    expect(bad.exitCode, 1);
    expect(bad.lines.last.text, startsWith('MISMATCH'));
    expect(bad.lines.last.style, TermStyle.error);
    expect((await run('hash abc --check')).exitCode, 1);
  });

  test('--file hashes inside the active workspace only', () async {
    final noWs = await run('hash --file a.txt');
    expect(noWs.exitCode, 1);
    expect(all(noWs), contains('No active workspace'));

    final Workspace ws = await c.read(workspacesProvider.notifier).addAppOwned('Hash WS');
    final f = File(p.join(ws.rootPath, 'game', 'game.json'))..createSync(recursive: true);
    f.writeAsStringSync('{"id":"neon-dungeon"}');
    final r = await run('hash --file game/game.json --algo sha1');
    expect(r.exitCode, 0, reason: all(r));
    expect(r.lines.first.text, '${Hashing.text('{"id":"neon-dungeon"}', HashAlgorithm.sha1)}  game/game.json');
    expect(all(r), contains('(21 bytes)'));

    final check = await run('hash --file game/game.json --check ${Hashing.text('{"id":"neon-dungeon"}')}');
    expect(all(check), contains('MATCH'));

    expect(all(await run('hash --file ../outside.txt')), contains('Refused path'));
    expect(all(await run('hash --file /etc/passwd')), contains('Refused path'));
    expect(all(await run('hash --file missing.txt')), contains('No such file'));
    expect(all(await run('hash --file game')), contains('Not a regular file'));
    expect(all(await run('hash --file game/game.json extra')), contains('not both'));
    final cancelled = await run('hash --file game/game.json', token: CancellationToken()..cancel());
    expect(cancelled.exitCode, 1);
  });

  test('completion suggests algorithms after --algo', () {
    final ctx = CommandContext(read: c.read, navigate: (_) {}, token: CancellationToken());
    expect(cmd.complete(ctx, ['x', '--algo', '']), ['sha256', 'sha512', 'sha1', 'md5']);
    expect(cmd.complete(ctx, ['--']), contains('--file'));
  });
}
