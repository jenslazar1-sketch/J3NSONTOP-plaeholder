import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:j3nsontop_multitool/core/commands/terminal_command.dart';
import 'package:j3nsontop_multitool/core/tasks/cancellation.dart';
import 'package:j3nsontop_multitool/core/tools/tool_definition.dart';
import 'package:j3nsontop_multitool/core/tools/tool_registry.dart';
import 'package:j3nsontop_multitool/core/workspace/workspace_controller.dart';
import 'package:j3nsontop_multitool/features/asset_lab/asset_lab_module.dart';
import 'package:path/path.dart' as p;

import '../../helpers/harness.dart';
import 'asset_test_helpers.dart';

void main() {
  late TestEnv env;
  late ProviderContainer c;

  setUp(() async {
    env = await TestEnv.create();
    c = env.container(modules: [assetLabModule]);
  });

  tearDown(() async {
    c.dispose();
    await env.dispose();
  });

  Future<CommandResult> run(String line) {
    final tokens = tokenizeCommandLine(line);
    final cmd = c.read(toolRegistryProvider).command(tokens.first)!;
    final ctx = CommandContext(read: c.read, navigate: (_) {}, token: CancellationToken());
    return cmd.run(ctx, parseArgs(tokens.sublist(1), valueOptions: cmd.valueOptions));
  }

  String text(CommandResult r) => r.lines.map((l) => l.text).join('\n');

  group('module', () {
    test('registers the five tools with stable ids in the Asset Lab section', () {
      final reg = ToolRegistry([assetLabModule]);
      expect(reg.inSection(ToolSection.assetLab).map((t) => t.id), [
        'assets.image',
        'assets.sprites',
        'assets.atlas',
        'assets.color',
        'assets.icons',
      ]);
      expect(reg.landingFor(ToolSection.assetLab), isNotNull);
      expect(reg.search('contrast').first.tool.id, 'assets.color');
      expect(reg.search('crop').first.tool.id, 'assets.image');
      expect(reg.search('atlas').first.tool.id, 'assets.atlas');
      expect(reg.search('mipmap').first.tool.id, 'assets.icons');
      expect(reg.search('spritesheet').map((m) => m.tool.id), contains('assets.sprites'));
    });
  });

  group('commands', () {
    test('wcag', () async {
      final r = await run('wcag #FF163B #050507');
      expect(r.exitCode, 0);
      expect(text(r), contains('5.27:1'));
      expect(text(r), contains('PASS AA normal text'));
      expect(text(r), contains('FAIL AAA normal text'));
      final bad = await run('wcag #FF163B');
      expect(bad.exitCode, 1);
      final junk = await run('wcag #XYZ #000');
      expect(text(junk), contains('ERROR'));
    });

    test('colorfmt', () async {
      final r = await run('colorfmt "rgb(255 22 59 / 50%)"');
      expect(text(r), contains('HEX   #FF163B80'));
      expect(text(r), contains('HSL   hsla('));
      final argb = await run('colorfmt 80FF163B --argb');
      expect(text(argb), contains('HEX   #80FF163B'));
      expect(text(argb), contains('ARGB  0x80FF163B'));
      expect((await run('colorfmt')).exitCode, 1);
    });

    test('imginfo reads workspace images and refuses paths outside it', () async {
      expect(text(await run('imginfo a.png')), contains('No active workspace'));
      final ws = await c.read(workspacesProvider.notifier).addAppOwned('Test');
      final file = File(p.join(ws.rootPath, 'textures', 'logo.png'))..createSync(recursive: true);
      file.writeAsBytesSync(img.encodePng(gradientImage(256, 128)));
      final r = await run('imginfo textures/logo.png');
      expect(r.exitCode, 0, reason: text(r));
      expect(text(r), contains('logo.png: PNG'));
      expect(text(r), contains('256 x 128 px'));
      expect(text(r), contains('alpha'));
      final escape = await run('imginfo ../../secret.png');
      expect(escape.exitCode, 1);
      expect(text(escape), contains('traversal'));
      final missing = await run('imginfo nope.png');
      expect(missing.exitCode, 1);
    });
  });
}
