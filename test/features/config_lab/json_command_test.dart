import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j3nsontop_multitool/core/commands/terminal_command.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/tools/tool_registry.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/config_lab/commands/json_command.dart';
import 'package:j3nsontop_multitool/features/config_lab/config_lab_module.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';

/// Runs a command line the way the terminal does (tokenize + parse).
Future<CommandResult> _run(ProviderContainer c, String line) {
  final tokens = tokenizeCommandLine(line);
  final cmd = c.read(toolRegistryProvider).command(tokens.first)!;
  final ctx = CommandContext(read: c.read, navigate: (_) {}, token: CancellationToken());
  return cmd.run(ctx, parseArgs(tokens.skip(1).toList(), valueOptions: cmd.valueOptions));
}

String _text(CommandResult r) => r.lines.map((l) => l.text).join('\n');

void main() {
  late TestEnv env;
  late ProviderContainer c;
  setUp(() async {
    env = await TestEnv.create();
    c = env.container(modules: [configLabModule]);
  });
  tearDown(() async {
    c.dispose();
    await env.dispose();
  });

  test('is registered with usage, args and examples', () {
    final cmd = c.read(toolRegistryProvider).command('json');
    expect(cmd, isA<JsonCommand>());
    expect(cmd!.usage, contains('--file'));
    expect(cmd.args.first.values, ['validate', 'format', 'minify']);
    expect(cmd.examples, isNotEmpty);
  });

  test('validate reports stats; warnings for duplicate keys', () async {
    final r = await _run(c, '''json validate '{"a": 1, "b": [true], "a": 2}' ''');
    expect(r.exitCode, 0);
    expect(r.lines.first.text, startsWith('VALID JSON (input): 1 objects, 1 arrays, 2 keys'));
    expect(r.lines.first.style, TermStyle.success);
    expect(_text(r), contains('WARN: 1:23: Duplicate key "a"'));
  });

  test('invalid JSON: exit code 1 with line:column and caret snippet', () async {
    final r = await _run(c, """json validate '{"a": 1,}'""");
    expect(r.exitCode, 1);
    expect(r.lines.first.text, 'ERROR: input:1:8: Trailing comma is not allowed in JSON');
    expect(r.lines.last.text, contains('^'));
  });

  test('format with indent options and minify', () async {
    final two = await _run(c, """json format '{"a":[1,2]}'""");
    expect(_text(two), '{\n  "a": [\n    1,\n    2\n  ]\n}');
    final four = await _run(c, """json format --indent 4 '{"a":1}'""");
    expect(_text(four), '{\n    "a": 1\n}');
    final tab = await _run(c, """json format --indent=tab '{"a":1}'""");
    expect(_text(tab), '{\n\t"a": 1\n}');
    final min = await _run(c, """json minify '{ "a" : [ 1 , 2 ] }'""");
    expect(_text(min), '{"a":[1,2]}');
    final bad = await _run(c, """json format --indent 3 '{}'""");
    expect(bad.exitCode, 1);
    expect(bad.lines.first.text, contains('--indent must be 2, 4 or tab'));
  });

  test('usage errors', () async {
    expect((await _run(c, 'json')).lines.first.text, 'ERROR: Missing action');
    expect((await _run(c, 'json explode {}')).lines.first.text, 'ERROR: Unknown action "explode"');
    expect((await _run(c, 'json validate')).lines.first.text, contains('Provide JSON text or --file'));
  });

  test('--file is resolved inside the active workspace, read-only', () async {
    expect((await _run(c, 'json validate --file a.json')).lines.first.text, contains('No active workspace'));
    final ws = await c.read(workspacesProvider.notifier).addAppOwned('WS');
    final f = File(p.join(ws.rootPath, 'game', 'config', 'graphics.json'));
    await f.parent.create(recursive: true);
    await f.writeAsString('{"quality":"high"}');
    final before = await f.readAsString();
    final r = await _run(c, 'json format --file game/config/graphics.json');
    expect(_text(r), '{\n  "quality": "high"\n}');
    expect(await f.readAsString(), before, reason: 'the command never writes');
    final v = await _run(c, 'json validate --file game/config/graphics.json');
    expect(v.lines.first.text, contains('VALID JSON (game/config/graphics.json)'));
    expect(
      (await _run(c, 'json validate --file ../outside.json')).lines.first.text,
      contains('parent-directory traversal'),
    );
    expect((await _run(c, 'json validate --file missing.json')).lines.first.text, contains('No such file'));
    await File(p.join(ws.rootPath, 'bin.dat')).writeAsBytes([0, 1, 2, 3, 0, 0]);
    expect((await _run(c, 'json validate --file bin.dat')).lines.first.text, contains('binary'));
    await File(p.join(ws.rootPath, 'bad.json')).writeAsString('{\n  "x": tru\n}');
    final bad = await _run(c, 'json validate --file bad.json');
    expect(bad.exitCode, 1);
    expect(bad.lines.first.text, startsWith('ERROR: bad.json:2:8:'));
  });
}
