import 'package:path/path.dart' as p;

import '../../core/commands/terminal_command.dart';
import '../../core/utils/format.dart';
import '../../core/utils/safe_path.dart';
import '../../core/workspace/workspace_controller.dart';
import 'data/asset_worker.dart';
import 'domain/color_model.dart';

/// `wcag <foreground> <background>`: WCAG 2.x contrast ratio.
class WcagCommand extends TerminalCommand {
  const WcagCommand();

  @override
  String get name => 'wcag';

  @override
  String get summary => 'WCAG contrast ratio of two colours with AA/AAA results';

  @override
  String get usage => 'wcag <foreground> <background>';

  @override
  List<CommandArg> get args => const [
    CommandArg('foreground', 'HEX (#FF163B), "rgb(...)", "hsl(...)" or "hsv(...)"'),
    CommandArg('background', 'Same notations; alpha is ignored for the background'),
  ];

  @override
  List<String> get examples => const ['wcag #FF163B #050507', 'wcag "rgb(255 255 255)" #000'];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    if (args.positional.length != 2) return CommandResult.error('Expected two colours', usage: usage);
    final Rgba fg, bg;
    try {
      fg = ColorFormat.parseAny(args.positional[0]);
      bg = ColorFormat.parseAny(args.positional[1]);
    } on FormatException catch (e) {
      return CommandResult.error(e.message, usage: usage);
    }
    final ratio = ColorMath.contrastRatio(fg, bg);
    return CommandResult.ok([
      TermLine('${ColorFormat.hex(fg)} on ${ColorFormat.hex(bg)}: ${ratio.toStringAsFixed(2)}:1', TermStyle.accent),
      for (final l in WcagLevel.values)
        l.passes(ratio)
            ? TermLine.ok('PASS ${l.grade} ${l.scope} (>= ${l.minRatio}:1)')
            : TermLine('FAIL ${l.grade} ${l.scope} (needs ${l.minRatio}:1)', TermStyle.warning),
      if (!fg.isOpaque) TermLine.dim('Foreground alpha was blended over the background first.'),
    ]);
  }
}

/// `colorfmt <colour>`: shows a colour in every notation.
class ColorFormatCommand extends TerminalCommand {
  const ColorFormatCommand();

  @override
  String get name => 'colorfmt';

  @override
  String get summary => 'Convert a colour between HEX, RGB, HSL and HSV';

  @override
  String get usage => 'colorfmt <colour> [--argb]';

  @override
  List<CommandArg> get args => const [CommandArg('colour', 'HEX, "rgb(...)", "hsl(...)" or "hsv(...)"')];

  @override
  List<String> get examples => const ['colorfmt #FF163B', 'colorfmt "hsl(350 100% 54%)"', 'colorfmt 80FF163B --argb'];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    if (args.positional.isEmpty) return CommandResult.error('Enter a colour', usage: usage);
    final order = args.flag('argb') ? HexAlphaOrder.argb : HexAlphaOrder.rgba;
    final Rgba c;
    try {
      c = ColorFormat.parseAny(args.rest(), order: order);
    } on FormatException catch (e) {
      return CommandResult.error(e.message, usage: usage);
    }
    return CommandResult.ok([
      TermLine('HEX   ${ColorFormat.hex(c, order: order)}', TermStyle.accent),
      TermLine('RGBA  ${ColorFormat.rgb(c)}'),
      TermLine('HSL   ${ColorFormat.hsl(c)}'),
      TermLine('HSV   ${ColorFormat.hsv(c)}'),
      TermLine('ARGB  0x${c.argb32.toRadixString(16).padLeft(8, '0').toUpperCase()}'),
    ]);
  }
}

/// `imginfo <path>`: image metadata for a file in the active workspace.
class ImageInfoCommand extends TerminalCommand {
  const ImageInfoCommand();

  @override
  String get name => 'imginfo';

  @override
  String get summary => 'Format, size, channels and frames of an image in the active workspace';

  @override
  String get usage => 'imginfo <workspace-relative path>';

  @override
  List<String> get examples => const ['imginfo game/textures/logo.png'];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final ws = ctx.read(activeWorkspaceProvider);
    if (ws == null) return CommandResult.error('No active workspace. Open or create one first.');
    final rel = args.rest();
    if (rel.isEmpty) return CommandResult.error('Enter a path inside the workspace', usage: usage);
    final String path;
    try {
      path = SafePath.resolveInside(ws.rootPath, rel);
    } on UnsafePathException catch (e) {
      return CommandResult.error(e.toString());
    }
    try {
      final decoded = await ctx
          .read(assetWorkerProvider)
          .run(decodeFileTask(path, p.basename(path), previewMax: 64), token: ctx.token);
      final m = decoded.metadata;
      return CommandResult.ok([
        TermLine('${p.basename(path)}: ${m.formatName}', TermStyle.accent),
        TermLine('size      ${m.width} x ${m.height} px'),
        TermLine(
          'channels  ${m.channels} (${m.hasAlpha ? 'alpha' : 'no alpha'})${m.indexed ? ', indexed palette' : ''}',
        ),
        TermLine('bits      ${m.bitsPerChannel} per channel'),
        TermLine('frames    ${m.frameCount}'),
        TermLine('file      ${Fmt.bytes(m.fileSize)}'),
        for (final (k, v) in m.exif) TermLine.dim('exif      $k: $v'),
        for (final n in m.notes) TermLine.dim('note      $n'),
      ]);
    } catch (e) {
      return CommandResult.error('Cannot read image: $e');
    }
  }
}
