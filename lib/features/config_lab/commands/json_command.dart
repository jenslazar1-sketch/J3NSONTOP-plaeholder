import 'dart:io';
import 'dart:isolate';

import '../../../core/commands/terminal_command.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/safe_path.dart';
import '../../../core/utils/text_codec.dart';
import '../../../core/workspace/workspace_controller.dart';
import '../domain/json_tools.dart';

/// Largest file the command reads.
const int kJsonCommandMaxBytes = 8 * 1024 * 1024;

/// `json validate|format|minify [--indent 2|4|tab] <text>` or
/// `--file <workspace-relative path>` (read-only, resolved inside the active
/// workspace).
class JsonCommand extends TerminalCommand {
  const JsonCommand();

  @override
  String get name => 'json';

  @override
  String get summary => 'Validate, format or minify JSON text or a workspace file (read-only).';

  @override
  String get usage => "json validate|format|minify [--indent 2|4|tab] ('<json text>' | --file <workspace path>)";

  @override
  List<CommandArg> get args => const [
    CommandArg('action', 'What to do', values: ['validate', 'format', 'minify']),
    CommandArg('text', 'JSON text (wrap it in single quotes)', optional: true),
  ];

  @override
  Set<String> get valueOptions => const {'indent', 'file'};

  @override
  List<String> get examples => const [
    'json validate \'{"hp": 10, "tags": ["a"]}\'',
    'json format --indent 4 \'{"a":[1,2]}\'',
    'json minify --file game/config/graphics.json',
  ];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final action = args.at(0);
    if (action == null || !const {'validate', 'format', 'minify'}.contains(action)) {
      return CommandResult.error(action == null ? 'Missing action' : 'Unknown action "$action"', usage: usage);
    }
    final indentArg = args.option('indent');
    final indent = indentArg == null ? JsonIndent.two : JsonIndent.parse(indentArg);
    if (indent == null) return CommandResult.error('--indent must be 2, 4 or tab', usage: usage);

    final String text;
    final String source;
    final file = args.option('file');
    if (file != null) {
      final ws = ctx.read(activeWorkspaceProvider);
      if (ws == null) return CommandResult.error('No active workspace: --file paths are resolved inside one.');
      final String path;
      try {
        path = SafePath.resolveInside(ws.rootPath, file);
      } on UnsafePathException catch (e) {
        return CommandResult.error('$e');
      }
      final f = File(path);
      if (!await f.exists()) return CommandResult.error('No such file in workspace "${ws.name}": $file');
      final length = await f.length();
      if (length > kJsonCommandMaxBytes) {
        return CommandResult.error(
          '$file is ${Fmt.bytes(length)}; the command reads up to ${Fmt.bytes(kJsonCommandMaxBytes)}.',
        );
      }
      final bytes = await f.readAsBytes();
      if (TextCodec.looksBinary(bytes)) return CommandResult.error('$file looks like a binary file.');
      text = TextCodec.decode(bytes).text;
      source = file;
    } else {
      text = args.rest(1);
      source = 'input';
      if (text.trim().isEmpty) return CommandResult.error('Provide JSON text or --file <path>', usage: usage);
    }
    ctx.token.throwIfCancelled();

    final a = text.length > kSyncParseLimit ? await Isolate.run(() => analyzeJson(text)) : analyzeJson(text);
    if (!a.valid) {
      final loc = a.error?.location;
      return CommandResult([
        TermLine.error(
          '$source${loc == null ? '' : ':${loc.line}:${loc.column}'}: ${a.error?.message ?? 'empty input'}',
        ),
        if (a.error?.snippet != null)
          for (final l in a.error!.snippet!.split('\n')) TermLine.dim(l),
      ], exitCode: 1);
    }
    final warnings = [for (final w in a.warnings) TermLine.warn('${w.location}: ${w.message}')];
    switch (action) {
      case 'validate':
        final s = a.stats!;
        return CommandResult([
          TermLine.ok(
            'VALID JSON ($source): ${s.objects} objects, ${s.arrays} arrays, ${s.keys} keys, depth ${s.depth}, ${Fmt.bytes(s.bytes)}',
          ),
          ...warnings,
        ]);
      case 'format':
        return CommandResult([
          ...warnings,
          for (final l in encodeJson(a.value, indent: indent).split('\n')) TermLine(l),
        ]);
      default:
        return CommandResult([...warnings, TermLine(encodeJson(a.value, indent: null))]);
    }
  }
}
