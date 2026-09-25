import '../../../core/commands/terminal_command.dart';
import '../../../core/tools/tool_registry.dart';
import '../domain/suggest.dart';
import 'command_support.dart';

/// `help [command]`
class HelpCommand extends TerminalCommand {
  const HelpCommand();

  @override
  String get name => 'help';

  @override
  List<String> get aliases => const ['?'];

  @override
  String get summary => 'List commands, or show details for one';

  @override
  String get usage => 'help [command]';

  @override
  List<CommandArg> get args => const [CommandArg('command', 'Command name or alias to describe', optional: true)];

  @override
  List<String> get examples => const ['help', 'help open', 'open --help'];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final registry = ctx.read(toolRegistryProvider);
    final target = args.at(0);
    if (target == null) return CommandResult.ok(commandOverview(registry));
    final command = registry.command(target) ?? registry.command(target.toLowerCase());
    if (command == null) {
      final close = didYouMean(target, visibleCommandNames(registry));
      return CommandResult([
        TermLine.error('No command named "$target".'),
        if (close.isNotEmpty) TermLine('Did you mean: ${joinAlternatives(close)}?', TermStyle.accent),
        TermLine.dim('Type `help` to list the available commands.'),
      ], exitCode: 1);
    }
    return CommandResult.ok(describeCommand(command));
  }

  @override
  List<String> complete(CommandContext ctx, List<String> typedArgs) =>
      typedArgs.length <= 1 ? visibleCommandNames(ctx.read(toolRegistryProvider)) : const [];
}

/// Names and aliases of commands shown in `help` (hidden ones excluded).
List<String> visibleCommandNames(ToolRegistry registry) {
  final names = <String>{
    for (final c in registry.commands)
      if (!c.hidden) ...[c.name, ...c.aliases],
  };
  return names.toList()..sort();
}

String _groupLabel(String moduleId, ToolRegistry registry) {
  for (final m in registry.modules) {
    if (m.id == moduleId && m.tools.isNotEmpty) return m.tools.first.section.label;
  }
  final words = moduleId.replaceAll(RegExp(r'[_\-.]+'), ' ').trim();
  if (words.isEmpty) return 'Other';
  return '${words[0].toUpperCase()}${words.substring(1)}';
}

/// The grouped command list printed by `help`. Groups follow the feature
/// modules that registered the commands (labelled by their section).
List<TermLine> commandOverview(ToolRegistry registry) {
  final groups = <String, List<TerminalCommand>>{};
  final seen = <TerminalCommand>{};
  for (final m in registry.modules) {
    for (final c in m.commands) {
      if (c.hidden || !seen.add(c)) continue;
      groups.putIfAbsent(_groupLabel(m.id, registry), () => []).add(c);
    }
  }
  if (groups.isEmpty) {
    return [TermLine.dim('No commands are registered in this build.')];
  }
  final width = columnWidth([for (final g in groups.values) ...g.map((c) => c.name)], max: 12);
  final lines = <TermLine>[
    const TermLine('COMMANDS // internal command interface (not a system shell)', TermStyle.accent),
  ];
  for (final entry in groups.entries) {
    final cmds = [...entry.value]..sort((a, b) => a.name.compareTo(b.name));
    lines
      ..add(const TermLine(''))
      ..add(TermLine(entry.key.toUpperCase(), TermStyle.accent));
    for (final c in cmds) {
      final alias = c.aliases.isEmpty ? '' : '  (alias: ${c.aliases.join(', ')})';
      lines
        ..add(TermLine('  ${c.name.padRight(width)}  ${c.summary}$alias'))
        ..add(TermLine.dim('  ${''.padRight(width)}  ${c.usage}'));
    }
  }
  lines
    ..add(const TermLine(''))
    ..add(TermLine.dim('`help <command>` or `<command> --help` shows arguments and examples.'))
    ..add(TermLine.dim('Keys: Tab complete | Up/Down history | Ctrl+L clear | Ctrl+C cancel | Esc clear input'));
  return lines;
}

/// Detailed help for one command: usage, aliases, arguments (with their
/// completion values), value options and examples.
List<TermLine> describeCommand(TerminalCommand c) {
  final lines = <TermLine>[
    TermLine('${c.name} — ${c.summary}', TermStyle.accent),
    TermLine('usage: ${c.usage}'),
    if (c.aliases.isNotEmpty) TermLine('aliases: ${c.aliases.join(', ')}'),
  ];
  if (c.args.isNotEmpty) {
    final w = columnWidth(c.args.map((a) => a.name), max: 16);
    lines
      ..add(const TermLine(''))
      ..add(const TermLine('ARGUMENTS', TermStyle.accent));
    for (final a in c.args) {
      lines.add(TermLine('  ${a.name.padRight(w)}  ${a.optional ? '(optional) ' : ''}${a.description}'));
      if (a.values.isNotEmpty) {
        final shown = a.values.take(12).join(', ');
        final more = a.values.length > 12 ? ', ... (+${a.values.length - 12})' : '';
        lines.add(TermLine.dim('  ${''.padRight(w)}  values: $shown$more'));
      }
    }
  }
  if (c.valueOptions.isNotEmpty) {
    lines
      ..add(const TermLine(''))
      ..add(const TermLine('OPTIONS', TermStyle.accent));
    for (final o in c.valueOptions) {
      lines.add(TermLine('  --$o <value>'));
    }
  }
  if (c.examples.isNotEmpty) {
    lines
      ..add(const TermLine(''))
      ..add(const TermLine('EXAMPLES', TermStyle.accent));
    for (final e in c.examples) {
      lines.add(TermLine('  $e'));
    }
  }
  return lines;
}
