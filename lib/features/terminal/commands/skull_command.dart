import '../../../core/commands/terminal_command.dart';
import '../../intro/skull_art.dart';

/// The mini skull laughing: three frames side by side with the jaw dropped
/// by 0, 1 and 2 blank rows, captioned "HA", "HA HA", "HA HA HA".
List<String> skullLaughFrames() {
  const gap = '   ';
  const captions = ['HA', 'HA HA', 'HA HA HA'];
  final width = [...kMiniSkullCranium, ...kMiniSkullJaw].fold<int>(0, (m, l) => l.length > m ? l.length : m);
  final frames = [
    for (var drop = 0; drop < captions.length; drop++)
      [...kMiniSkullCranium, for (var i = 0; i < drop; i++) '', ...kMiniSkullJaw],
  ];
  final height = frames.fold<int>(0, (m, f) => f.length > m ? f.length : m);
  return [
    for (var r = 0; r < height; r++)
      [for (final f in frames) (r < f.length ? f[r] : '').padRight(width)].join(gap).trimRight(),
    '',
    [for (final c in captions) c.padLeft((width + c.length) ~/ 2).padRight(width)].join(gap).trimRight(),
  ];
}

/// Hidden easter egg: prints the full skull, then a short cosmetic laugh.
/// Pure ASCII output; nothing is executed.
class SkullCommand extends TerminalCommand {
  const SkullCommand();

  @override
  String get name => 'skull';

  @override
  String get summary => 'You found the skull';

  @override
  String get usage => 'skull';

  @override
  bool get hidden => true;

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async => CommandResult.ok([
    for (final l in [...kSkullCranium, ...kSkullJaw]) TermLine(l, TermStyle.ascii),
    const TermLine(''),
    for (final l in skullLaughFrames()) TermLine(l, TermStyle.ascii),
    const TermLine(''),
    TermLine.dim('(cosmetic ASCII easter egg - nothing was executed)'),
  ]);
}
