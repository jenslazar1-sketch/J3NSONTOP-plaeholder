import '../../../core/commands/terminal_command.dart';
import '../../../core/platform/capabilities.dart';
import '../../../core/tools/tool_definition.dart';
import '../../../core/tools/tool_registry.dart';
import 'command_support.dart';

/// `tools [section|query]`
class ToolsCommand extends TerminalCommand {
  const ToolsCommand();

  @override
  String get name => 'tools';

  @override
  String get summary => 'List tools by section, or search them';

  @override
  String get usage => 'tools [section|query]';

  @override
  List<CommandArg> get args => const [
    CommandArg(
      'section|query',
      'Section key (workspaces, mods, config, assets, files, dev, system) or search words',
      optional: true,
    ),
  ];

  @override
  List<String> get examples => const ['tools', 'tools dev', 'tools json format'];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final registry = ctx.read(toolRegistryProvider);
    final caps = ctx.read(capabilitiesProvider);
    if (registry.all.isEmpty) {
      return CommandResult.ok([TermLine.dim('No tools are registered in this build.')]);
    }
    final query = args.rest().trim();
    if (query.isEmpty) {
      final lines = <TermLine>[];
      for (final s in ToolSection.values) {
        final tools = registry.inSection(s);
        if (tools.isEmpty) continue;
        if (lines.isNotEmpty) lines.add(const TermLine(''));
        lines.addAll(_section(s, tools, caps));
      }
      return CommandResult.ok([...lines, const TermLine(''), _footer(registry.all.toList(), caps)]);
    }
    final section = sectionFromText(query);
    if (section != null) {
      final tools = registry.inSection(section);
      if (tools.isEmpty) {
        return CommandResult.ok([TermLine.dim('No tools in ${section.label} yet.')]);
      }
      return CommandResult.ok([..._section(section, tools, caps), const TermLine(''), _footer(tools, caps)]);
    }
    final hits = registry.search(query);
    if (hits.isEmpty) {
      return CommandResult([
        TermLine.error('No tool matches "$query".'),
        TermLine.dim('Sections: ${sectionKeys.join(', ')}. Type `tools` for the full list.'),
      ], exitCode: 1);
    }
    final tools = [for (final h in hits) h.tool];
    return CommandResult.ok([
      TermLine('SEARCH "$query"  ${tools.length} match${tools.length == 1 ? '' : 'es'}', TermStyle.accent),
      ..._rows(tools, caps, showSection: true),
      const TermLine(''),
      _footer(tools, caps),
    ]);
  }

  @override
  List<String> complete(CommandContext ctx, List<String> typedArgs) => typedArgs.length <= 1 ? sectionKeys : const [];

  List<TermLine> _section(ToolSection s, List<ToolDefinition> tools, CapabilityMatrix caps) => [
    TermLine(
      '${s.label.toUpperCase()}  [${sectionKey(s)}]  ${tools.length} tool${tools.length == 1 ? '' : 's'}',
      TermStyle.accent,
    ),
    ..._rows(tools, caps),
  ];

  List<TermLine> _rows(List<ToolDefinition> tools, CapabilityMatrix caps, {bool showSection = false}) {
    final w = columnWidth(tools.map((t) => t.id));
    return [
      for (final t in tools)
        () {
          final reason = unavailableReason(t, caps);
          final section = showSection ? '  (${t.section.label})' : '';
          return reason == null
              ? TermLine('  [ok]  ${t.id.padRight(w)}  ${t.name}$section')
              : TermLine.dim('  [--]  ${t.id.padRight(w)}  ${t.name}$section  unavailable: $reason');
        }(),
    ];
  }

  TermLine _footer(List<ToolDefinition> tools, CapabilityMatrix caps) {
    final available = tools.where((t) => t.availableOn(caps)).length;
    return TermLine.dim(
      '${tools.length} tool${tools.length == 1 ? '' : 's'}, $available available on ${caps.platform.label}. '
      '[ok] = usable here. Open one with `open <tool-id>`.',
    );
  }
}
