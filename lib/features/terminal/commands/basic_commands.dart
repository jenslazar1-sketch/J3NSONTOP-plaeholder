import '../../../app/app_info.dart';
import '../../../core/commands/terminal_command.dart';
import '../../../core/platform/capabilities.dart';
import '../../../core/tools/tool_registry.dart';

/// `clear` (also Ctrl+L)
class ClearCommand extends TerminalCommand {
  const ClearCommand();

  @override
  String get name => 'clear';

  @override
  List<String> get aliases => const ['cls'];

  @override
  String get summary => 'Clear the screen (Ctrl+L)';

  @override
  String get usage => 'clear';

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async => const CommandResult([], clearScreen: true);
}

/// `echo <text...>`
class EchoCommand extends TerminalCommand {
  const EchoCommand();

  @override
  String get name => 'echo';

  @override
  String get summary => 'Print text';

  @override
  String get usage => 'echo <text...>';

  @override
  List<CommandArg> get args => const [CommandArg('text', 'Words to print (quote to keep spacing)', optional: true)];

  @override
  List<String> get examples => const ['echo hello world', 'echo "  keeps   spacing  "', 'echo -- --not-an-option'];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async => CommandResult.ok([TermLine(args.rest())]);
}

/// `about` / `version`
class AboutCommand extends TerminalCommand {
  const AboutCommand();

  @override
  String get name => 'about';

  @override
  List<String> get aliases => const ['version'];

  @override
  String get summary => 'App name, version, platform, tool and command counts';

  @override
  String get usage => 'about';

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final registry = ctx.read(toolRegistryProvider);
    final caps = ctx.read(capabilitiesProvider);
    final tools = registry.all.toList();
    final available = tools.where((t) => t.availableOn(caps)).length;
    final commands = registry.commands.where((c) => !c.hidden).length;
    return CommandResult.ok([
      const TermLine(AppInfo.fullName, TermStyle.accent),
      const TermLine('  version    ${AppInfo.version} (build ${AppInfo.buildNumber})'),
      TermLine('  platform   ${caps.platform.label}'),
      TermLine('  tools      ${tools.length} registered, $available available here'),
      TermLine('  commands   $commands (type `help`)'),
      TermLine.dim(AppInfo.scopeStatement),
      TermLine.dim('This terminal is an internal command interface for the app\'s own tools, not a system shell.'),
    ]);
  }
}

/// `date`
class DateCommand extends TerminalCommand {
  const DateCommand({this.clock = DateTime.now});

  /// Injectable for tests.
  final DateTime Function() clock;

  @override
  String get name => 'date';

  @override
  String get summary => 'Current local and UTC time (ISO 8601)';

  @override
  String get usage => 'date';

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final now = clock();
    final local = now.toLocal();
    final utc = now.toUtc();
    final zone = local.timeZoneName.isEmpty ? '' : '  (${local.timeZoneName})';
    return CommandResult.ok([
      TermLine('local  ${isoWithOffset(local)}$zone'),
      TermLine('utc    ${_seconds(utc.toIso8601String())}Z'),
      TermLine.dim('unix   ${utc.millisecondsSinceEpoch ~/ 1000}'),
    ]);
  }

  static String _seconds(String iso) {
    final dot = iso.indexOf('.');
    final base = dot < 0 ? iso : iso.substring(0, dot);
    return base.endsWith('Z') ? base.substring(0, base.length - 1) : base;
  }

  /// `2026-09-25T18:41:07+02:00`
  static String isoWithOffset(DateTime local) {
    final o = local.timeZoneOffset;
    final sign = o.isNegative ? '-' : '+';
    final h = o.inHours.abs().toString().padLeft(2, '0');
    final m = (o.inMinutes.abs() % 60).toString().padLeft(2, '0');
    return '${_seconds(local.toIso8601String())}$sign$h:$m';
  }
}
