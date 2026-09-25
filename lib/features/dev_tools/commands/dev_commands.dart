import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/commands/terminal_command.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/safe_path.dart';
import '../../../core/utils/text_codec.dart';
import '../../../core/workspace/workspace_controller.dart';
import '../dev_clock.dart';
import '../domain/base64_tools.dart';
import '../domain/common.dart';
import '../domain/text_diff.dart';
import '../domain/timestamp_tools.dart';
import '../domain/url_tools.dart';
import '../domain/uuid_tools.dart';

/// Inline texts may use the two-character escapes \n and \t for line
/// breaks and tabs (write them inside single quotes, or as \\n inside
/// double quotes, because the terminal tokenizer consumes one backslash).
String unescapeInline(String s) => s.replaceAll(r'\n', '\n').replaceAll(r'\t', '\t');

/// Error lines with a caret under the offending character for single-line
/// inputs.
CommandResult inputErrorResult(InputError e, String usage) {
  final lines = <TermLine>[TermLine.error(e.toString())];
  final src = e.source, off = e.offset;
  if (src != null && off != null && !src.contains('\n') && src.length <= 120) {
    lines.add(TermLine.dim('  $src'));
    lines.add(TermLine.dim('  ${' ' * off}^'));
  }
  if (e.hint != null) lines.add(TermLine.dim('hint: ${e.hint}'));
  lines.add(TermLine.dim('usage: $usage'));
  return CommandResult(lines, exitCode: 1);
}

List<TermLine> _rows(List<(String, String)> rows) {
  final w = rows.fold<int>(0, (m, r) => r.$1.length > m ? r.$1.length : m);
  return [for (final (k, v) in rows) TermLine('${k.padRight(w)}  $v')];
}

/// `diff <a> <b>` / `diff --file-a x --file-b y`
class DiffCommand extends TerminalCommand {
  const DiffCommand();

  static const int maxOutputLines = 2000;

  @override
  String get name => 'diff';

  @override
  String get summary => 'Unified diff of two texts or two workspace files';

  @override
  String get usage =>
      'diff <a> <b> | diff --file-a <path> --file-b <path> [--ignore-case] [--ignore-space] [--context N]';

  @override
  List<CommandArg> get args => const [
    CommandArg('a', r"left/old text (quote it; '\n' = line break)", optional: true),
    CommandArg('b', 'right/new text', optional: true),
  ];

  @override
  Set<String> get valueOptions => const {'file-a', 'file-b', 'context'};

  @override
  List<String> get examples => const [
    "diff 'alpha\\nbeta\\ngamma' 'alpha\\nBETA\\ngamma'",
    'diff --file-a config/old.json --file-b config/new.json',
    'diff --file-a notes.txt "replacement text" --ignore-case',
    'diff --file-a a.ini --file-b b.ini --context 0',
  ];

  Future<(String, String)> _readWorkspaceFile(CommandContext ctx, String rel) async {
    final ws = ctx.read(activeWorkspaceProvider);
    if (ws == null) {
      throw const InputError('No active workspace', hint: 'Open or create one in Workspaces, or pass the text inline.');
    }
    final String path;
    try {
      path = SafePath.resolveInside(ws.rootPath, rel);
    } on UnsafePathException catch (e) {
      throw InputError(e.toString());
    }
    final f = File(path);
    if (!await f.exists()) throw InputError('File not found in workspace "${ws.name}": $rel');
    final size = await f.length();
    if (size > TextDiff.maxBytes) {
      throw InputError('$rel is ${Fmt.bytes(size)}; the diff limit is ${Fmt.bytes(TextDiff.maxBytes)}');
    }
    final bytes = await f.readAsBytes();
    if (TextCodec.looksBinary(bytes)) throw InputError('$rel looks like a binary file');
    return (p.relative(path, from: ws.rootPath).replaceAll(r'\', '/'), TextCodec.decode(bytes).text);
  }

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final queue = [...args.positional];
    String nameA = 'a', nameB = 'b';
    String a, b;
    try {
      final fa = args.option('file-a'), fb = args.option('file-b');
      if (fa != null) {
        (nameA, a) = await _readWorkspaceFile(ctx, fa);
      } else if (queue.isNotEmpty) {
        a = unescapeInline(queue.removeAt(0));
      } else {
        return CommandResult.error('Missing the left text or --file-a', usage: usage);
      }
      if (fb != null) {
        (nameB, b) = await _readWorkspaceFile(ctx, fb);
      } else if (queue.isNotEmpty) {
        b = unescapeInline(queue.removeAt(0));
      } else {
        return CommandResult.error('Missing the right text or --file-b', usage: usage);
      }
    } on InputError catch (e) {
      return inputErrorResult(e, usage);
    }
    if (queue.isNotEmpty) {
      return CommandResult.error('Unexpected extra argument "${queue.first}" (quote texts with spaces)', usage: usage);
    }
    final ctxOpt = args.option('context');
    final context = ctxOpt == null ? 3 : int.tryParse(ctxOpt);
    if (context == null || context < 0) return CommandResult.error('--context must be 0 or more', usage: usage);
    ctx.token.throwIfCancelled();
    final TextDiffOutcome o;
    try {
      o = await TextDiff.computeAsync(
        a,
        b,
        ignoreCase: args.flag('ignore-case', 'i'),
        ignoreWhitespace: args.flag('ignore-space', 'w'),
      );
    } on InputError catch (e) {
      return inputErrorResult(e, usage);
    }
    final r = o.result;
    if (r.identical) {
      return CommandResult.ok([TermLine.ok('Identical (${Fmt.count(o.linesA, 'line')}).')]);
    }
    final text = o.unified(oldName: nameA, newName: nameB, context: context);
    final all = text.split('\n');
    if (all.isNotEmpty && all.last.isEmpty) all.removeLast();
    final lines = <TermLine>[];
    for (final l in all.take(maxOutputLines)) {
      final style = l.startsWith('+++') || l.startsWith('---')
          ? TermStyle.dim
          : l.startsWith('@@')
          ? TermStyle.accent
          : l.startsWith('+')
          ? TermStyle.success
          : l.startsWith('-')
          ? TermStyle.error
          : TermStyle.normal;
      lines.add(TermLine(l, style));
    }
    if (all.length > maxOutputLines) {
      lines.add(TermLine.dim('... ${all.length - maxOutputLines} more lines (open dev.diff for the full view)'));
    }
    lines.add(TermLine.dim('+${r.insertions} -${r.deletions} =${o.unchanged}'));
    if (r.truncated) lines.add(TermLine.warn('edit budget reached: part of the diff is shown as a whole block'));
    return CommandResult(lines);
  }

  @override
  List<String> complete(CommandContext ctx, List<String> typedArgs) {
    if (typedArgs.length >= 2) {
      final prev = typedArgs[typedArgs.length - 2];
      if (prev == '--file-a' || prev == '--file-b') return _workspacePaths(ctx, typedArgs.last);
    }
    final last = typedArgs.isEmpty ? '' : typedArgs.last;
    if (last.startsWith('-')) {
      return [
        for (final o in const ['--file-a', '--file-b', '--ignore-case', '--ignore-space', '--context'])
          if (o.startsWith(last)) o,
      ];
    }
    return const [];
  }

  /// Workspace-relative entries matching [prefix] (at most 50).
  static List<String> _workspacePaths(CommandContext ctx, String prefix) {
    final ws = ctx.read(activeWorkspaceProvider);
    if (ws == null) return const [];
    final norm = prefix.replaceAll(r'\', '/');
    final slash = norm.lastIndexOf('/');
    final dirRel = slash < 0 ? '' : norm.substring(0, slash);
    try {
      final dir = dirRel.isEmpty ? ws.rootPath : SafePath.resolveInside(ws.rootPath, dirRel);
      final out = <String>[];
      for (final e in Directory(dir).listSync(followLinks: false)) {
        final rel = p.relative(e.path, from: ws.rootPath).replaceAll(r'\', '/');
        if (!rel.startsWith(norm)) continue;
        out.add(e is Directory ? '$rel/' : rel);
        if (out.length >= 50) break;
      }
      out.sort();
      return out;
    } on Object {
      return const [];
    }
  }
}

/// `uuid [count] [--v7] [--upper] [--no-hyphens] [--braces]`
class UuidCommand extends TerminalCommand {
  const UuidCommand();

  @override
  String get name => 'uuid';

  @override
  String get summary => 'Generate UUIDs (v4 random or v7 time-ordered)';

  @override
  String get usage => 'uuid [count 1-1000] [--v7] [--upper] [--no-hyphens] [--braces]';

  @override
  List<CommandArg> get args => const [
    CommandArg('count', 'how many (default 1)', optional: true, values: ['1', '5', '10']),
  ];

  @override
  List<String> get examples => const ['uuid', 'uuid 5 --v7', 'uuid 3 --upper --no-hyphens', 'uuid --braces'];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final raw = args.at(0);
    final count = raw == null ? 1 : int.tryParse(raw);
    if (count == null || count < 1 || count > UuidTools.maxCount) {
      return CommandResult.error('count must be a whole number from 1 to ${UuidTools.maxCount}', usage: usage);
    }
    final ids = UuidTools.generate(
      args.flag('v7') ? UuidKind.v7 : UuidKind.v4,
      count,
      format: UuidFormat(uppercase: args.flag('upper'), hyphens: !args.flag('no-hyphens'), braces: args.flag('braces')),
      clock: ctx.read(devClockProvider),
    );
    return CommandResult.ok([for (final id in ids) TermLine(id)]);
  }

  @override
  List<String> complete(CommandContext ctx, List<String> typedArgs) {
    final last = typedArgs.isEmpty ? '' : typedArgs.last;
    if (last.startsWith('-')) {
      return [
        for (final o in const ['--v7', '--upper', '--no-hyphens', '--braces'])
          if (o.startsWith(last)) o,
      ];
    }
    return super.complete(ctx, typedArgs);
  }
}

/// `b64 enc|dec <text> [--url] [--no-pad]`
class B64Command extends TerminalCommand {
  const B64Command();

  @override
  String get name => 'b64';

  @override
  List<String> get aliases => const ['base64'];

  @override
  String get summary => 'Base64 encode/decode UTF-8 text';

  @override
  String get usage => 'b64 enc|dec <text> [--url] [--no-pad]';

  @override
  List<CommandArg> get args => const [
    CommandArg('mode', 'enc or dec', values: ['enc', 'dec']),
    CommandArg('text', 'text to convert (quote spaces)'),
  ];

  @override
  List<String> get examples => const [
    'b64 enc "hello world"',
    'b64 dec aGVsbG8gd29ybGQ=',
    'b64 enc "a?b>c" --url --no-pad',
  ];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final mode = args.at(0);
    if (mode != 'enc' && mode != 'dec') return CommandResult.error('first argument must be enc or dec', usage: usage);
    if (args.positional.length < 2) return CommandResult.error('missing text', usage: usage);
    final text = args.rest(1);
    if (mode == 'enc') {
      return CommandResult.ok([
        TermLine(Base64Tools.encodeText(text, urlSafe: args.flag('url'), padding: !args.flag('no-pad'))),
      ]);
    }
    try {
      final d = Base64Tools.decode(text);
      final t = d.text;
      final lines = <TermLine>[for (final w in d.warnings) TermLine.warn(w)];
      if (t != null) return CommandResult.ok([...lines, for (final l in t.split('\n')) TermLine(l)]);
      lines.add(TermLine.warn('decoded ${Fmt.count(d.bytes.length, 'byte')} are not valid UTF-8 text (hex preview):'));
      for (final l in hexDump(d.bytes, maxBytes: 256).split('\n')) {
        lines.add(TermLine(l, TermStyle.dim));
      }
      lines.add(TermLine.dim('open dev.base64 to save the bytes as a file'));
      return CommandResult.ok(lines);
    } on InputError catch (e) {
      return inputErrorResult(e, usage);
    }
  }
}

/// `url enc|dec <text> [--form] [--full]`
class UrlCommand extends TerminalCommand {
  const UrlCommand();

  @override
  String get name => 'url';

  @override
  String get summary => 'Percent-encode or decode text';

  @override
  String get usage => 'url enc|dec <text> [--form] [--full]';

  @override
  List<CommandArg> get args => const [
    CommandArg('mode', 'enc or dec', values: ['enc', 'dec']),
    CommandArg('text', 'text to convert (quote spaces)'),
  ];

  @override
  List<String> get examples => const [
    'url enc "name=J3 & friends"',
    'url dec name%3DJ3%20%26%20friends',
    'url enc "a b" --form',
    'url enc "https://x.dev/a b?q=1" --full',
  ];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final mode = args.at(0);
    if (mode != 'enc' && mode != 'dec') return CommandResult.error('first argument must be enc or dec', usage: usage);
    if (args.positional.length < 2) return CommandResult.error('missing text', usage: usage);
    final text = args.rest(1);
    final form = args.flag('form');
    if (mode == 'enc') {
      final m = form
          ? UrlEncodeMode.form
          : args.flag('full')
          ? UrlEncodeMode.fullUri
          : UrlEncodeMode.component;
      return CommandResult.ok([TermLine(UrlTools.encode(text, m))]);
    }
    try {
      return CommandResult.ok([TermLine(UrlTools.decode(text, plusAsSpace: form))]);
    } on InputError catch (e) {
      return inputErrorResult(e, usage);
    }
  }
}

/// `ts [value] [--unit s|ms|us|ns] [--utc]`
class TsCommand extends TerminalCommand {
  const TsCommand();

  @override
  String get name => 'ts';

  @override
  List<String> get aliases => const ['timestamp'];

  @override
  String get summary => 'Current time, or convert a Unix timestamp / ISO / HTTP date';

  @override
  String get usage => 'ts [value] [--unit s|ms|us|ns] [--utc]';

  @override
  List<CommandArg> get args => const [CommandArg('value', 'timestamp or date (omit for now)', optional: true)];

  @override
  Set<String> get valueOptions => const {'unit'};

  @override
  List<String> get examples => const [
    'ts',
    'ts 1758829267',
    'ts 1758829267123 --unit ms',
    'ts 2026-09-25T21:41:07+02:00',
    'ts "Fri, 25 Sep 2026 19:41:07 GMT"',
    'ts 2026-09-25T10:00 --utc',
  ];

  @override
  Future<CommandResult> run(CommandContext ctx, ParsedArgs args) async {
    final now = ctx.read(devClockProvider)();
    final unitOpt = args.option('unit');
    final unit = unitOpt == null ? null : EpochUnit.parse(unitOpt);
    if (unitOpt != null && unit == null) return CommandResult.error('--unit must be s, ms, us or ns', usage: usage);
    final value = args.rest();
    final ParsedInstant parsed;
    if (value.isEmpty) {
      parsed = ParsedInstant(utc: now.toUtc(), interpretation: 'now');
    } else {
      try {
        final kind = switch (unit) {
          EpochUnit.seconds => TimestampInput.seconds,
          EpochUnit.milliseconds => TimestampInput.milliseconds,
          EpochUnit.microseconds => TimestampInput.microseconds,
          EpochUnit.nanoseconds => TimestampInput.nanoseconds,
          null => TimestampInput.auto,
        };
        parsed = Timestamps.parse(value, kind: kind, assumeUtc: args.flag('utc'));
      } on InputError catch (e) {
        return inputErrorResult(e, usage);
      }
    }
    return CommandResult.ok([
      TermLine('read as: ${parsed.interpretation}', TermStyle.accent),
      for (final n in parsed.notes) TermLine.dim(n),
      ..._rows(Timestamps.describe(parsed, now)),
    ]);
  }

  @override
  List<String> complete(CommandContext ctx, List<String> typedArgs) {
    if (typedArgs.length >= 2 && typedArgs[typedArgs.length - 2] == '--unit') return const ['s', 'ms', 'us', 'ns'];
    final last = typedArgs.isEmpty ? '' : typedArgs.last;
    if (last.startsWith('-')) {
      return [
        for (final o in const ['--unit', '--utc'])
          if (o.startsWith(last)) o,
      ];
    }
    return const [];
  }
}

const List<TerminalCommand> devToolsCommands = [DiffCommand(), UuidCommand(), B64Command(), UrlCommand(), TsCommand()];
