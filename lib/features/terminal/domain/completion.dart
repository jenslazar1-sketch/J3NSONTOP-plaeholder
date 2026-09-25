import '../../../core/commands/terminal_command.dart';
import '../../../core/tools/tool_registry.dart';

/// Outcome of a Tab completion.
class CompletionResult {
  const CompletionResult({required this.text, required this.caret, this.candidates = const [], this.partial = ''});

  /// The new input text and caret offset.
  final String text;
  final int caret;

  /// All matching candidates when there is more than one (shown to the user
  /// as a clickable suggestion row). Empty when a single match was applied
  /// or nothing matched.
  final List<String> candidates;

  /// The word that was being completed (for "no completions" feedback).
  final String partial;
}

/// A token of a partially typed command line with its source offset.
class _Tok {
  const _Tok(this.value, this.start);
  final String value;
  final int start;
}

class _Scan {
  const _Scan(this.tokens, this.endsInToken);
  final List<_Tok> tokens;

  /// True when the text ends inside a token (the last token is still being
  /// typed); false when it is empty or ends with whitespace.
  final bool endsInToken;
}

/// Tolerant variant of [tokenizeCommandLine]: never throws (an unclosed
/// quote simply extends to the end) and records where each token starts.
_Scan _scan(String s) {
  final tokens = <_Tok>[];
  final buf = StringBuffer();
  var inToken = false;
  var start = 0;
  String? quote;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      } else if (c == r'\' && quote == '"' && i + 1 < s.length) {
        i++;
        buf.write(s[i]);
      } else {
        buf.write(c);
      }
      continue;
    }
    if (c == '"' || c == "'") {
      if (!inToken) start = i;
      quote = c;
      inToken = true;
    } else if (c == ' ' || c == '\t') {
      if (inToken) {
        tokens.add(_Tok(buf.toString(), start));
        buf.clear();
        inToken = false;
      }
    } else {
      if (!inToken) start = i;
      buf.write(c);
      inToken = true;
    }
  }
  if (inToken) tokens.add(_Tok(buf.toString(), start));
  return _Scan(tokens, inToken);
}

/// Quotes [value] for the command line when it contains whitespace or
/// quote characters. With [close] false the quote is left open so that the
/// user (or the next Tab) can keep typing inside it.
String quoteArg(String value, {bool close = true}) {
  final needs = value.isEmpty || value.contains(RegExp(r'''[\s"'\\]'''));
  if (!needs) return value;
  final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return close ? '"$escaped"' : '"$escaped';
}

/// Longest common prefix (case-insensitive; characters from the first item).
String commonPrefix(List<String> items) {
  if (items.isEmpty) return '';
  var p = items.first;
  for (final s in items.skip(1)) {
    var i = 0;
    while (i < p.length && i < s.length && p[i].toLowerCase() == s[i].toLowerCase()) {
      i++;
    }
    p = p.substring(0, i);
    if (p.isEmpty) break;
  }
  return p;
}

/// Tab completion for the terminal: command names (and aliases) first, then
/// arguments through [TerminalCommand.complete].
class TerminalCompleter {
  TerminalCompleter(this.registry, this.context);

  final ToolRegistry registry;
  final CommandContext context;

  /// Visible command names and aliases, sorted.
  List<String> commandNames() {
    final names = <String>{
      for (final c in registry.commands)
        if (!c.hidden) ...[c.name, ...c.aliases],
    };
    return names.toList()..sort();
  }

  /// Candidates for the word at [caret] in [text].
  List<String> candidatesFor(String text, int caret) => _analyse(text, caret).candidates;

  /// Completes the word at [caret]: a single match is inserted with a
  /// trailing space; several matches are narrowed to their common prefix and
  /// returned for display.
  CompletionResult complete(String text, int caret) {
    final a = _analyse(text, caret);
    final candidates = a.candidates;
    if (candidates.isEmpty) {
      return CompletionResult(text: text, caret: caret, partial: a.partial);
    }
    if (candidates.length == 1) return _insert(a, candidates.single, finished: true);
    final lcp = commonPrefix(candidates);
    if (lcp.length > a.partial.length) {
      final r = _insert(a, lcp, finished: false);
      return CompletionResult(text: r.text, caret: r.caret, candidates: candidates, partial: a.partial);
    }
    return CompletionResult(text: text, caret: caret, candidates: candidates, partial: a.partial);
  }

  /// Applies a candidate the user picked from the suggestion row.
  CompletionResult accept(String text, int caret, String candidate) =>
      _insert(_analyse(text, caret), candidate, finished: true);

  CompletionResult _insert(_Analysis a, String value, {required bool finished}) {
    final head = a.before.substring(0, a.partialStart);
    final quoted = quoteArg(value, close: finished);
    final needsSpace = finished && !a.after.startsWith(' ');
    final replacement = '$quoted${needsSpace ? ' ' : ''}';
    final caret = head.length + replacement.length + (finished && !needsSpace ? 1 : 0);
    final text = '$head$replacement${a.after}';
    return CompletionResult(text: text, caret: caret.clamp(0, text.length), partial: a.partial);
  }

  _Analysis _analyse(String text, int caret) {
    final at = caret.clamp(0, text.length);
    final before = text.substring(0, at);
    final after = text.substring(at);
    final scan = _scan(before);
    final String partial;
    final int partialStart;
    final List<_Tok> prior;
    if (scan.endsInToken) {
      partial = scan.tokens.last.value;
      partialStart = scan.tokens.last.start;
      prior = scan.tokens.sublist(0, scan.tokens.length - 1);
    } else {
      partial = '';
      partialStart = before.length;
      prior = scan.tokens;
    }

    List<String> raw;
    if (prior.isEmpty) {
      raw = commandNames();
    } else {
      final name = prior.first.value;
      final cmd = registry.command(name) ?? registry.command(name.toLowerCase());
      if (cmd == null) {
        raw = const [];
      } else {
        final typed = [for (final t in prior.skip(1)) t.value, partial];
        try {
          raw = cmd.complete(context, typed);
        } catch (_) {
          // A faulty completer must never break typing.
          raw = const [];
        }
      }
    }
    final lower = partial.toLowerCase();
    final seen = <String>{};
    final candidates = [
      for (final c in raw)
        if (c.toLowerCase().startsWith(lower) && seen.add(c)) c,
    ];
    return _Analysis(before, after, partial, partialStart, candidates);
  }
}

class _Analysis {
  const _Analysis(this.before, this.after, this.partial, this.partialStart, this.candidates);
  final String before;
  final String after;
  final String partial;
  final int partialStart;
  final List<String> candidates;
}
