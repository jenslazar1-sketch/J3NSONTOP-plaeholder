import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../tasks/cancellation.dart';

/// Visual style of a terminal output line. Styles are always paired with a
/// textual prefix for errors/warnings so colour is never the only signal.
enum TermStyle { normal, dim, accent, success, warning, error, ascii, command }

class TermLine {
  const TermLine(this.text, [this.style = TermStyle.normal]);
  final String text;
  final TermStyle style;

  static TermLine error(String t) => TermLine('ERROR: $t', TermStyle.error);
  static TermLine warn(String t) => TermLine('WARN: $t', TermStyle.warning);
  static TermLine ok(String t) => TermLine(t, TermStyle.success);
  static TermLine dim(String t) => TermLine(t, TermStyle.dim);
}

class CommandResult {
  const CommandResult(this.lines, {this.exitCode = 0, this.clearScreen = false});

  final List<TermLine> lines;
  final int exitCode;
  final bool clearScreen;

  static CommandResult ok(List<TermLine> lines) => CommandResult(lines);
  static CommandResult text(String s) => CommandResult([for (final l in s.split('\n')) TermLine(l)]);
  static CommandResult error(String message, {String? usage}) =>
      CommandResult([TermLine.error(message), if (usage != null) TermLine.dim('usage: $usage')], exitCode: 1);
}

/// Parsed arguments: positionals plus `--key value`, `--key=value`, `--flag`
/// and `-f` short flags.
class ParsedArgs {
  const ParsedArgs(this.positional, this.options);

  final List<String> positional;
  final Map<String, String?> options;

  bool flag(String name, [String? short]) => options.containsKey(name) || (short != null && options.containsKey(short));

  String? option(String name, [String? short]) => options[name] ?? (short != null ? options[short] : null);

  String? at(int i) => i < positional.length ? positional[i] : null;

  /// Positionals from [start] joined back with spaces (for free text).
  String rest([int start = 0]) => start >= positional.length ? '' : positional.sublist(start).join(' ');
}

/// Argument spec used for `help` output and autocomplete.
class CommandArg {
  const CommandArg(this.name, this.description, {this.optional = false, this.values = const []});
  final String name;
  final String description;
  final bool optional;

  /// Allowed literal values (for autocomplete), if enumerable.
  final List<String> values;
}

/// What a command can use while running.
class CommandContext {
  CommandContext({required this.read, required this.navigate, required this.token});

  /// Reads a provider (the terminal passes `ref.read`).
  final T Function<T>(ProviderListenable<T> provider) read;

  /// Navigates the app to a route (e.g. `/tool/dev.base64`).
  final void Function(String route) navigate;
  final CancellationToken token;
}

/// A typed command of the internal command interface. This is NOT a system
/// shell: commands only call the app's own implemented tools.
abstract class TerminalCommand {
  const TerminalCommand();

  String get name;
  List<String> get aliases => const [];
  String get summary;

  /// One-line usage, e.g. `hash <text> [--algo sha256|sha1|sha512|md5]`.
  String get usage;
  List<CommandArg> get args => const [];

  /// Worked examples shown by `help <command>`.
  List<String> get examples => const [];

  /// Long options that take a value (`--algo sha256`). Options not listed
  /// here are flags unless written as `--key=value`.
  Set<String> get valueOptions => const {};

  /// Hidden commands are omitted from `help` (easter eggs).
  bool get hidden => false;

  Future<CommandResult> run(CommandContext ctx, ParsedArgs args);

  /// Suggestions for the argument currently being typed.
  List<String> complete(CommandContext ctx, List<String> typedArgs) {
    final index = typedArgs.isEmpty ? 0 : typedArgs.length - 1;
    if (index < args.length) return args[index].values;
    return const [];
  }
}

/// Splits a command line into tokens, honouring single/double quotes and
/// backslash escapes inside double quotes.
List<String> tokenizeCommandLine(String line) {
  final tokens = <String>[];
  final buf = StringBuffer();
  var inToken = false;
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else if (c == r'\' && quote == '"' && i + 1 < line.length) {
        i++;
        buf.write(line[i]);
      } else {
        buf.write(c);
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      inToken = true;
    } else if (c == ' ' || c == '\t') {
      if (inToken) {
        tokens.add(buf.toString());
        buf.clear();
        inToken = false;
      }
    } else {
      buf.write(c);
      inToken = true;
    }
  }
  if (quote != null) {
    throw FormatException('Unclosed $quote quote');
  }
  if (inToken) tokens.add(buf.toString());
  return tokens;
}

/// Parses tokens (excluding the command name) into [ParsedArgs].
/// `--` ends option parsing.
ParsedArgs parseArgs(List<String> tokens, {Set<String> valueOptions = const {}}) {
  final pos = <String>[];
  final opts = <String, String?>{};
  var optionsDone = false;
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (optionsDone || !t.startsWith('-') || t == '-' || _isNumber(t)) {
      pos.add(t);
      continue;
    }
    if (t == '--') {
      optionsDone = true;
      continue;
    }
    if (t.startsWith('--')) {
      final eq = t.indexOf('=');
      if (eq > 0) {
        opts[t.substring(2, eq)] = t.substring(eq + 1);
      } else {
        final key = t.substring(2);
        if (valueOptions.contains(key) && i + 1 < tokens.length) {
          opts[key] = tokens[++i];
        } else {
          opts[key] = null;
        }
      }
    } else {
      final key = t.substring(1);
      if (valueOptions.contains(key) && i + 1 < tokens.length) {
        opts[key] = tokens[++i];
      } else {
        for (final ch in key.split('')) {
          opts[ch] = null;
        }
      }
    }
  }
  return ParsedArgs(pos, opts);
}

bool _isNumber(String s) => num.tryParse(s) != null;
