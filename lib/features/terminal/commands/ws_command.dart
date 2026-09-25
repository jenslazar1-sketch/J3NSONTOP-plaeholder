import '../../../core/commands/terminal_command.dart';
import '../../../core/utils/format.dart';
import '../../../core/workspace/workspace.dart';
import '../../../core/workspace/workspace_controller.dart';
import '../domain/suggest.dart';

/// `ws [list] | ws use <name|id> | ws info [name|id]`
class WsCommand extends TerminalCommand {
  const WsCommand();

  static const List<String> subcommands = ['list', 'use', 'info'];

  @override
  String get name => 'ws';

  @override
  List<String> get aliases => const ['workspace'];

  @override
  String get summary => 'List workspaces, switch the active one, check its folder';

  @override
  String get usage => 'ws [list] | ws use <name|id> | ws info [name|id]';

  @override
  List<CommandArg> get args => const [
    CommandArg('action', 'list (default), use or info', optional: true, values: subcommands),
    CommandArg('workspace', 'Workspace name or id (for use/info)', optional: true),
  ];

  @override
  List<String> get examples => const ['ws', 'ws use "Sample Mod Project"', 'ws info'];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final sub = (args.at(0) ?? 'list').toLowerCase();
    final state = ctx.read(workspacesProvider);
    switch (sub) {
      case 'list' || 'ls':
        return CommandResult.ok(_list(state));
      case 'use':
        final query = args.rest(1).trim();
        if (query.isEmpty) return CommandResult.error('Which workspace?', usage: 'ws use <name|id>');
        final w = _find(state, query);
        if (w == null) return _notFound(state, query);
        await ctx.read(workspacesProvider.notifier).setActive(w.id);
        return CommandResult.ok([TermLine.ok('OK: active workspace is now "${w.name}" (${w.kind.label}).')]);
      case 'info':
        final query = args.rest(1).trim();
        final w = query.isEmpty ? state.active : _find(state, query);
        if (w == null) {
          return query.isEmpty
              ? CommandResult.ok([
                  TermLine.dim('No active workspace.'),
                  TermLine.dim('Create or import one in Workspaces (`open workspaces`).'),
                ])
              : _notFound(state, query);
        }
        final health = await WorkspaceController.checkHealth(w);
        ctx.token.throwIfCancelled();
        return CommandResult.ok(_info(w, health, active: w.id == state.activeId));
      default:
        return CommandResult.error('Unknown ws action "$sub".', usage: usage);
    }
  }

  List<TermLine> _list(WorkspacesState state) {
    if (state.workspaces.isEmpty) {
      return [
        TermLine.dim('No workspaces yet.'),
        TermLine.dim('Create or import one in Workspaces (`open workspaces`).'),
      ];
    }
    return [
      TermLine('WORKSPACES  ${state.workspaces.length}', TermStyle.accent),
      for (final w in state.recent) ...[
        TermLine(
          '${w.id == state.activeId ? '* ' : '  '}${w.name}  [${w.kind.label}]',
          w.id == state.activeId ? TermStyle.success : TermStyle.normal,
        ),
        TermLine.dim('    ${w.rootPath}'),
      ],
      TermLine.dim('* = active. Switch with `ws use <name>`.'),
    ];
  }

  /// Exact id, exact name (case-insensitive), then a unique name prefix.
  Workspace? _find(WorkspacesState state, String query) {
    final byId = state.byId(query);
    if (byId != null) return byId;
    final q = query.toLowerCase();
    final exact = state.workspaces.where((w) => w.name.toLowerCase() == q).toList();
    if (exact.length == 1) return exact.single;
    final prefix = state.workspaces.where((w) => w.name.toLowerCase().startsWith(q)).toList();
    return prefix.length == 1 ? prefix.single : null;
  }

  CommandResult _notFound(WorkspacesState state, String query) {
    final close = didYouMean(query, [for (final w in state.workspaces) w.name]);
    return CommandResult([
      TermLine.error('No workspace matches "$query".'),
      if (close.isNotEmpty) TermLine('Did you mean: ${joinAlternatives(close)}?', TermStyle.accent),
      TermLine.dim('Type `ws` to list workspaces.'),
    ], exitCode: 1);
  }

  List<TermLine> _info(Workspace w, WorkspaceHealth health, {required bool active}) {
    final (label, style) = switch (health) {
      WorkspaceHealth.ok => ('OK: root folder is reachable', TermStyle.success),
      WorkspaceHealth.missing => ('MISSING: root folder was not found', TermStyle.error),
      WorkspaceHealth.notADirectory => ('NOT A FOLDER: the root path is a file', TermStyle.error),
      WorkspaceHealth.permissionDenied => ('NO ACCESS: permission denied', TermStyle.error),
    };
    return [
      TermLine('${w.name}${active ? '  (active)' : ''}', TermStyle.accent),
      TermLine('  id       ${w.id}'),
      TermLine('  kind     ${w.kind.label} — ${w.kind.explanation}'),
      TermLine('  root     ${w.rootPath}'),
      TermLine('  created  ${Fmt.dateTime(w.createdAt)}'),
      TermLine('  opened   ${Fmt.dateTime(w.lastOpenedAt)}'),
      if (w.note != null) TermLine('  note     ${w.note}'),
      TermLine('  health   $label', style),
    ];
  }

  @override
  List<String> complete(CommandContext ctx, List<String> typedArgs) {
    if (typedArgs.length <= 1) return subcommands;
    final sub = typedArgs.first.toLowerCase();
    if (typedArgs.length == 2 && (sub == 'use' || sub == 'info')) {
      return [for (final w in ctx.read(workspacesProvider).recent) w.name];
    }
    return const [];
  }
}
