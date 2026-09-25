import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/commands/terminal_command.dart';
import '../../../core/diagnostics/error_log.dart';
import '../../../core/storage/user_data.dart';
import '../../../core/tasks/cancellation.dart';
import '../../../core/tools/tool_registry.dart';
import '../../../core/workspace/workspace_controller.dart';
import '../../intro/skull_art.dart';
import '../commands/help_command.dart';
import '../domain/suggest.dart';

/// Registry id of the terminal tool.
const String kTerminalToolId = 'system.terminal';

/// `draftTextProvider` key of the terminal's input line (survives navigation).
const String kTerminalInputDraftKey = '$kTerminalToolId/input';

/// `draftValueProvider` key through which other UI (the command palette's
/// `>` mode) hands the terminal a command line to run. The terminal screen
/// consumes the value (resets it to null) and runs it once.
const String kTerminalPendingCommandKey = '$kTerminalToolId/pending';

/// First line of the session banner.
const String kTerminalBannerTitle =
    "J3NSONTOP // internal command interface — runs this app's own tools. This is not a system shell.";

enum TerminalRowKind { line, echo, ascii }

/// One rendered output row: a text line, an echoed command (prompt + line)
/// or a block of consecutive ASCII-art lines (rendered as one unit so it can
/// be scaled to fit narrow screens without breaking alignment).
@immutable
class TerminalRow {
  const TerminalRow._(this.kind, this.text, this.style, this.prompt, this.art);

  factory TerminalRow.line(TermLine line) => TerminalRow._(TerminalRowKind.line, line.text, line.style, null, const []);

  factory TerminalRow.echo(String prompt, String command) =>
      TerminalRow._(TerminalRowKind.echo, command, TermStyle.command, prompt, const []);

  factory TerminalRow.ascii(List<String> lines) =>
      TerminalRow._(TerminalRowKind.ascii, lines.join('\n'), TermStyle.ascii, null, List.unmodifiable(lines));

  final TerminalRowKind kind;
  final String text;
  final TermStyle style;

  /// Prompt of an echoed command.
  final String? prompt;

  /// Lines of an ASCII block.
  final List<String> art;

  int get lineCount => kind == TerminalRowKind.ascii ? art.length : '\n'.allMatches(text).length + 1;

  /// The row as plain text (copy/export/tests).
  String get plain => kind == TerminalRowKind.echo ? '$prompt $text' : text;
}

@immutable
class TerminalState {
  const TerminalState({this.rows = const [], this.lineCount = 0, this.droppedLines = 0, this.running});

  final List<TerminalRow> rows;

  /// Lines currently held (ASCII blocks count each line).
  final int lineCount;

  /// Older lines removed because of the scrollback limit.
  final int droppedLines;

  /// The command line currently running, if any.
  final String? running;

  bool get isRunning => running != null;

  /// Full transcript as plain text.
  String get plainText => rows.map((r) => r.plain).join('\n');

  TerminalState copyWith({
    List<TerminalRow>? rows,
    int? lineCount,
    int? droppedLines,
    String? running,
    bool idle = false,
  }) => TerminalState(
    rows: rows ?? this.rows,
    lineCount: lineCount ?? this.lineCount,
    droppedLines: droppedLines ?? this.droppedLines,
    running: idle ? null : (running ?? this.running),
  );
}

/// Groups consecutive ASCII lines into blocks.
List<TerminalRow> rowsFromLines(List<TermLine> lines) {
  final out = <TerminalRow>[];
  List<String>? art;
  void flush() {
    if (art != null) {
      out.add(TerminalRow.ascii(art!));
      art = null;
    }
  }

  for (final l in lines) {
    if (l.style == TermStyle.ascii) {
      (art ??= <String>[]).addAll(l.text.split('\n'));
    } else {
      flush();
      out.add(TerminalRow.line(l));
    }
  }
  flush();
  return out;
}

/// The banner printed when a session starts.
List<TermLine> terminalBanner() => [
  for (final l in [...kMiniSkullCranium, ...kMiniSkullJaw]) TermLine(l, TermStyle.ascii),
  const TermLine(kTerminalBannerTitle, TermStyle.accent),
  TermLine.dim('Type `help` to list commands. Tab completes, Up/Down recall history, Ctrl+L clears.'),
];

/// Well-known OS shell programs. Typing one gets an explicit explanation
/// that this terminal cannot run operating-system commands.
final Set<String> _osPrograms = {
  ...'ls dir cd pwd cat rm del rmdir mkdir cp mv copy move chmod chown sudo su sh bash zsh fish cmd powershell pwsh '
          'python python3 node npm git curl wget ssh ping kill ps top exit start explorer adb'
      .split(' '),
};

/// Terminal session: output rows, the running command and the execution
/// engine. Deliberately not autoDispose so the transcript survives
/// navigating to other tools and back.
class TerminalSession extends Notifier<TerminalState> {
  /// Maximum number of output lines kept in memory.
  static const int scrollbackLimit = 5000;

  CancellationToken? _token;
  Future<void> _historyWrite = Future<void>.value();

  /// Completes when the most recent command-history write has finished
  /// (writes are serialised by the store, so all earlier ones have too).
  Future<void> get historySaved => _historyWrite;

  @override
  TerminalState build() => _appended(const TerminalState(), rowsFromLines(terminalBanner()));

  bool get isRunning => _token != null;

  /// `j3nsontop@<active workspace name or ~>$`
  String prompt() => promptFor(ref.read(activeWorkspaceProvider)?.name);

  static String promptFor(String? workspaceName) => 'j3nsontop@${workspaceName ?? '~'}\$';

  /// Appends lines to the transcript.
  void writeLines(List<TermLine> lines) {
    if (lines.isEmpty) return;
    state = _appended(state, rowsFromLines(lines));
  }

  /// Clears the screen (Ctrl+L / `clear`). A running command keeps running.
  void clear() {
    state = TerminalState(running: state.running);
  }

  /// Ctrl+C at an idle prompt: echoes the abandoned input followed by `^C`.
  void interrupt(String draft) {
    state = _appended(state, [TerminalRow.echo(prompt(), '$draft^C')]);
  }

  /// Cancels the running command. Returns false when nothing was running.
  bool cancel() {
    final t = _token;
    if (t == null) return false;
    _token = null;
    t.cancel();
    state = _appended(state.copyWith(idle: true), [TerminalRow.line(const TermLine('^C', TermStyle.warning))]);
    return true;
  }

  /// Echoes and runs [rawLine]. Completes when the command finished or was
  /// cancelled. Never throws: every failure is printed as an error line.
  Future<void> submit(String rawLine, {required void Function(String route) navigate}) async {
    if (_token != null) return;
    final line = rawLine.trim();
    state = _appended(state, [TerminalRow.echo(prompt(), line)]);
    if (line.isEmpty) return;
    unawaited(_historyWrite = _remember(line));

    final List<String> tokens;
    try {
      tokens = tokenizeCommandLine(line);
    } on FormatException catch (e) {
      writeLines([
        TermLine.error('${e.message} in the command line.'),
        TermLine.dim(r'Close the quote, or escape a literal quote inside double quotes with \".'),
      ]);
      return;
    }
    if (tokens.isEmpty) return;

    final registry = ref.read(toolRegistryProvider);
    final name = tokens.first;
    final command = registry.command(name) ?? registry.command(name.toLowerCase());
    if (command == null) {
      writeLines(_unknown(name, registry));
      return;
    }
    final args = parseArgs(tokens.sublist(1), valueOptions: command.valueOptions);
    if (args.options.containsKey('help') && !command.valueOptions.contains('help')) {
      writeLines(describeCommand(command));
      return;
    }

    final token = CancellationToken();
    _token = token;
    state = state.copyWith(running: line);
    final ctx = CommandContext(read: ref.read, navigate: navigate, token: token);

    CommandResult? result;
    List<TermLine>? failure;
    try {
      result = await Future.any<CommandResult?>([
        Future<CommandResult?>.sync(() => command.run(ctx, args)),
        token.whenCancelled.then((_) => null),
      ]);
    } on OperationCancelled {
      result = null;
    } catch (e, st) {
      ErrorLog.instance.record(e, st, source: 'terminal:${command.name}');
      failure = [
        TermLine.error('"${command.name}" failed: $e'),
        TermLine.dim('The error was contained; the terminal is still usable.'),
      ];
    }

    // Cancelled (Ctrl+C already printed ^C) or superseded: discard output.
    if (!identical(_token, token)) return;
    _token = null;
    if (token.isCancelled || (result == null && failure == null)) {
      state = _appended(state.copyWith(idle: true), [TerminalRow.line(const TermLine('^C', TermStyle.warning))]);
      return;
    }
    if (failure != null) {
      state = _appended(state.copyWith(idle: true), rowsFromLines(failure));
      return;
    }
    final r = result!;
    final base = r.clearScreen ? const TerminalState() : state.copyWith(idle: true);
    state = _appended(base, rowsFromLines(r.lines));
  }

  Future<void> _remember(String line) async {
    try {
      await ref.read(userDataProvider.notifier).recordCommand(line);
    } catch (e) {
      if (ref.mounted) writeLines([TermLine.warn('Command history could not be saved: $e')]);
    }
  }

  List<TermLine> _unknown(String name, ToolRegistry registry) {
    final names = <String>{
      for (final c in registry.commands)
        if (!c.hidden) ...[c.name, ...c.aliases],
    };
    final close = didYouMean(name, names);
    return [
      TermLine.error('Unknown command "$name".'),
      if (close.isNotEmpty) TermLine('Did you mean: ${joinAlternatives(close)}?', TermStyle.accent),
      if (_osPrograms.contains(name.toLowerCase()))
        TermLine.dim('This is not a system shell: OS programs such as "$name" cannot run here.'),
      TermLine.dim('Type `help` to list the available commands.'),
    ];
  }

  TerminalState _appended(TerminalState s, List<TerminalRow> rows) {
    if (rows.isEmpty) return s;
    final list = [...s.rows, ...rows];
    var count = s.lineCount;
    for (final r in rows) {
      count += r.lineCount;
    }
    var dropped = s.droppedLines;
    var start = 0;
    while (count > scrollbackLimit && start < list.length - 1) {
      count -= list[start].lineCount;
      dropped += list[start].lineCount;
      start++;
    }
    return TerminalState(
      rows: start == 0 ? list : list.sublist(start),
      lineCount: count,
      droppedLines: dropped,
      running: s.running,
    );
  }
}

final terminalSessionProvider = NotifierProvider<TerminalSession, TerminalState>(TerminalSession.new);
