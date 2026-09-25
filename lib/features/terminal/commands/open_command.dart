import '../../../core/commands/terminal_command.dart';
import '../../../core/platform/capabilities.dart';
import '../../../core/tools/tool_definition.dart';
import '../../../core/tools/tool_registry.dart';
import '../domain/suggest.dart';
import 'command_support.dart';

/// A resolved `open` target.
class OpenTarget {
  const OpenTarget(this.route, this.label, {this.warning});
  final String route;
  final String label;
  final String? warning;
}

/// Resolves [text] to a route: a tool id, a named target (`settings`,
/// `mods`...), an app route (`/activity`, `/tool/<id>`), a tool name or a
/// section label. Returns null when nothing matches.
OpenTarget? resolveOpenTarget(String text, ToolRegistry registry, CapabilityMatrix caps) {
  final target = text.trim();
  if (target.isEmpty) return null;
  final lower = target.toLowerCase();

  OpenTarget forTool(ToolDefinition t) {
    final reason = unavailableReason(t, caps);
    return OpenTarget(t.route, '${t.name} (${t.id})', warning: reason == null ? null : '${t.name}: $reason.');
  }

  final byId = registry.byId(target) ?? registry.byId(lower);
  if (byId != null) return forTool(byId);

  final named = openTargets()[lower];
  if (named != null) return OpenTarget(named, lower);

  if (target.startsWith('/')) {
    final uri = Uri.tryParse(target);
    if (uri == null) return null;
    final path = uri.path.length > 1 && uri.path.endsWith('/') ? uri.path.substring(0, uri.path.length - 1) : uri.path;
    if (path.startsWith('/tool/')) {
      final tool = registry.byId(Uri.decodeComponent(path.substring('/tool/'.length)));
      return tool == null ? null : forTool(tool);
    }
    if (knownRoutes().contains(path)) return OpenTarget(target, path);
    return null;
  }

  final byName = [
    for (final t in registry.all)
      if (t.name.toLowerCase() == lower) t,
  ];
  if (byName.length == 1) return forTool(byName.single);

  final section = sectionFromText(target);
  if (section != null) return OpenTarget(section.route, section.label);
  return null;
}

/// `open <tool-id|section|route>`
class OpenCommand extends TerminalCommand {
  const OpenCommand();

  @override
  String get name => 'open';

  @override
  String get summary => 'Open a tool, section or page';

  @override
  String get usage => 'open <tool-id|section|route>';

  @override
  List<CommandArg> get args => const [
    CommandArg('target', 'Tool id (e.g. dev.base64), tool name, section/page (mods, settings...) or route (/activity)'),
  ];

  @override
  List<String> get examples => const ['open settings', 'open dev', 'open /activity', 'open system.terminal'];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final registry = ctx.read(toolRegistryProvider);
    final caps = ctx.read(capabilitiesProvider);
    final target = args.rest().trim();
    if (target.isEmpty) {
      return CommandResult([
        TermLine.error('Nothing to open.'),
        TermLine.dim('usage: $usage'),
        TermLine.dim('Pages and sections: ${openTargets().keys.join(', ')}'),
        TermLine.dim('Tools: type `tools` to list tool ids.'),
      ], exitCode: 1);
    }
    final resolved = resolveOpenTarget(target, registry, caps);
    if (resolved == null) {
      final candidates = [...openTargets().keys, for (final t in registry.all) t.id];
      final close = didYouMean(target, candidates);
      final hits = registry.search(target, limit: 3);
      return CommandResult([
        TermLine.error('Nothing called "$target" to open.'),
        if (close.isNotEmpty) TermLine('Did you mean: ${joinAlternatives(close)}?', TermStyle.accent),
        if (hits.isNotEmpty) TermLine.dim('Matching tools: ${hits.map((h) => h.tool.id).join(', ')}'),
        TermLine.dim('Type `tools` to list tool ids, or use a section: ${openTargets().keys.join(', ')}.'),
      ], exitCode: 1);
    }
    ctx.navigate(resolved.route);
    return CommandResult.ok([
      TermLine.ok('Opening ${resolved.label}  ->  ${resolved.route}'),
      if (resolved.warning != null) TermLine.warn(resolved.warning!),
    ]);
  }

  @override
  List<String> complete(CommandContext ctx, List<String> typedArgs) {
    if (typedArgs.length > 1) return const [];
    final registry = ctx.read(toolRegistryProvider);
    final ids = [for (final t in registry.all) t.id]..sort();
    return [...openTargets().keys, ...ids];
  }
}
