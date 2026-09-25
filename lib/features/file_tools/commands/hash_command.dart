import 'dart:convert';
import 'dart:io';

import '../../../core/commands/terminal_command.dart';
import '../../../core/tasks/cancellation.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/hashing.dart';
import '../../../core/utils/safe_path.dart';
import '../../../core/workspace/workspace_controller.dart';

/// `hash`: digest of text or of a file in the active workspace.
class HashCommand extends TerminalCommand {
  const HashCommand();

  static const _algos = ['sha256', 'sha512', 'sha1', 'md5'];

  @override
  String get name => 'hash';

  @override
  String get summary => 'Hash text or a workspace file (SHA-256 by default), optionally checking a digest';

  @override
  String get usage =>
      'hash <text...> [--algo sha256|sha512|sha1|md5] [--check <digest>]  |  '
      'hash --file <workspace path> [--algo ...] [--check <digest>]';

  @override
  List<CommandArg> get args => const [
    CommandArg('text', 'Text to hash as UTF-8 (quote it to keep spacing)', optional: true),
  ];

  @override
  List<String> get examples => const [
    'hash hello world',
    'hash "exact  spacing" --algo sha512',
    'hash --file game/game.json',
    'hash --file game/game.json --check sha256:<expected digest>',
  ];

  @override
  Set<String> get valueOptions => const {'algo', 'file', 'check', 'a'};

  @override
  List<String> complete(CommandContext ctx, List<String> typedArgs) {
    if (typedArgs.length >= 2) {
      final prev = typedArgs[typedArgs.length - 2];
      if (prev == '--algo' || prev == '-a') return _algos;
    }
    final current = typedArgs.isEmpty ? '' : typedArgs.last;
    if (current.startsWith('-')) return const ['--algo', '--file', '--check'];
    return const [];
  }

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final algoName = args.option('algo', 'a') ?? 'sha256';
    final algo = HashAlgorithm.parse(algoName);
    if (algo == null) {
      return CommandResult.error('Unknown algorithm "$algoName" (use ${_algos.join(', ')})', usage: usage);
    }
    if (args.options.containsKey('check') && (args.option('check') ?? '').trim().isEmpty) {
      return CommandResult.error('--check needs the expected digest', usage: usage);
    }
    final expected = args.option('check');

    final String digest;
    final String subject;
    final String sizeText;
    if (args.flag('file')) {
      final rel = args.option('file');
      if (rel == null || rel.isEmpty) {
        return CommandResult.error('--file needs a path inside the active workspace', usage: usage);
      }
      if (args.positional.isNotEmpty) {
        return CommandResult.error('Give either text or --file, not both', usage: usage);
      }
      final ws = ctx.read(activeWorkspaceProvider);
      if (ws == null) {
        return CommandResult.error('No active workspace. Open or create one first (Workspaces section).');
      }
      String path;
      try {
        path = SafePath.resolveInside(ws.rootPath, rel);
      } on UnsafePathException catch (e) {
        return CommandResult.error('Refused path "$rel": ${e.reason}. Paths are relative to "${ws.name}".');
      }
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return CommandResult.error('No such file in workspace "${ws.name}": $rel');
      }
      if (type != FileSystemEntityType.file) {
        return CommandResult.error('Not a regular file: $rel');
      }
      try {
        final size = await File(path).length();
        digest = await Hashing.file(path, algo: algo, token: ctx.token);
        sizeText = '${Fmt.bytes(size)} ($size bytes)';
      } on OperationCancelled {
        return CommandResult.error('Cancelled');
      } on FileSystemException catch (e) {
        return CommandResult.error('Cannot read $rel: ${e.osError?.message ?? e.message}');
      }
      subject = SafePath.normalizeRelative(rel);
    } else {
      if (args.positional.isEmpty) {
        return CommandResult.error('Nothing to hash', usage: usage);
      }
      final text = args.rest();
      final bytes = utf8.encode(text);
      digest = Hashing.bytes(bytes, algo);
      subject = '-';
      sizeText = '${bytes.length} bytes of UTF-8 text';
    }

    final lines = <TermLine>[
      TermLine('$digest  $subject', TermStyle.accent),
      TermLine.dim('algorithm: ${algo.label} | size: $sizeText'),
      if (algo.isLegacy) TermLine.warn('${algo.label} is for compatibility only - not collision resistant'),
    ];
    if (expected != null) {
      if (Hashing.digestsEqual(digest, expected)) {
        lines.add(TermLine.ok('MATCH  expected digest equals the ${algo.label} digest'));
      } else {
        lines.add(TermLine('MISMATCH  expected ${expected.trim()}', TermStyle.error));
        return CommandResult(lines, exitCode: 1);
      }
    }
    return CommandResult(lines);
  }
}
