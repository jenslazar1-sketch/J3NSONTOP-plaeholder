import '../../../core/tasks/cancellation.dart';
import '../../../core/tasks/isolate_runner.dart';
import 'common.dart';

class RegexFlags {
  const RegexFlags({this.caseSensitive = true, this.multiLine = false, this.dotAll = false, this.unicode = false});
  final bool caseSensitive;
  final bool multiLine;
  final bool dotAll;
  final bool unicode;

  RegexFlags copyWith({bool? caseSensitive, bool? multiLine, bool? dotAll, bool? unicode}) => RegexFlags(
    caseSensitive: caseSensitive ?? this.caseSensitive,
    multiLine: multiLine ?? this.multiLine,
    dotAll: dotAll ?? this.dotAll,
    unicode: unicode ?? this.unicode,
  );

  /// JavaScript-style flag letters, e.g. `/pattern/imsu`.
  String get letters => '${caseSensitive ? '' : 'i'}${multiLine ? 'm' : ''}${dotAll ? 's' : ''}${unicode ? 'u' : ''}';

  RegExp compile(String pattern) =>
      RegExp(pattern, caseSensitive: caseSensitive, multiLine: multiLine, dotAll: dotAll, unicode: unicode);

  @override
  bool operator ==(Object other) =>
      other is RegexFlags &&
      other.caseSensitive == caseSensitive &&
      other.multiLine == multiLine &&
      other.dotAll == dotAll &&
      other.unicode == unicode;

  @override
  int get hashCode => Object.hash(caseSensitive, multiLine, dotAll, unicode);
}

/// One match. Texts are capped at [RegexJob.maxCapturedChars] characters.
class RegexMatchInfo {
  const RegexMatchInfo({
    required this.start,
    required this.end,
    required this.text,
    required this.groups,
    required this.named,
  });
  final int start;
  final int end;
  final String text;

  /// Numbered groups 1..n (null = group did not participate).
  final List<String?> groups;
  final Map<String, String?> named;
}

/// Everything the tester needs, computed in a worker isolate.
class RegexJob {
  const RegexJob({
    required this.pattern,
    required this.flags,
    required this.input,
    this.replacement,
    this.maxMatches = 10000,
  });

  final String pattern;
  final RegexFlags flags;
  final String input;

  /// Replacement template (null = no replace preview).
  final String? replacement;
  final int maxMatches;

  static const int maxCapturedChars = 2000;
}

class RegexRunResult {
  const RegexRunResult({
    required this.matches,
    required this.capped,
    required this.groupCount,
    required this.groupNames,
    this.replaced,
    this.replaceError,
  });

  final List<RegexMatchInfo> matches;

  /// True when matching stopped at [RegexJob.maxMatches].
  final bool capped;
  final int groupCount;
  final List<String> groupNames;
  final String? replaced;
  final InputError? replaceError;
}

/// A compiled replacement template. Syntax: `$1`..`$99` numbered group,
/// `${name}` or `${12}` named/numbered group, `$&` or `$0` whole match,
/// `$$` literal dollar. Any other `$` is copied literally.
class ReplacementTemplate {
  ReplacementTemplate._(this._parts);

  /// Literal strings, or int group numbers, or `(String name)` records.
  final List<Object> _parts;

  static ReplacementTemplate parse(String template, int groupCount, Iterable<String> groupNames) {
    final names = groupNames.toSet();
    final parts = <Object>[];
    final lit = StringBuffer();
    void flush() {
      if (lit.isNotEmpty) {
        parts.add(lit.toString());
        lit.clear();
      }
    }

    for (var i = 0; i < template.length; i++) {
      final c = template[i];
      if (c != r'$' || i + 1 >= template.length) {
        lit.write(c);
        continue;
      }
      final n = template[i + 1];
      if (n == r'$') {
        lit.write(r'$');
        i++;
      } else if (n == '&') {
        flush();
        parts.add(0);
        i++;
      } else if (n == '{') {
        final close = template.indexOf('}', i + 2);
        if (close < 0) {
          throw InputError(
            r'Unclosed "${" in the replacement',
            offset: i,
            source: template,
            hint: r'Use ${name} or $$ for a literal dollar.',
          );
        }
        final ref = template.substring(i + 2, close);
        final num = int.tryParse(ref);
        flush();
        if (num != null) {
          if (num > groupCount) {
            throw InputError('Group $num does not exist (the pattern has $groupCount)', offset: i, source: template);
          }
          parts.add(num);
        } else {
          if (!names.contains(ref)) {
            throw InputError(
              'Unknown group name "$ref"',
              offset: i,
              source: template,
              hint: names.isEmpty
                  ? 'The pattern has no named groups (?<name>...).'
                  : 'Named groups: ${names.join(', ')}',
            );
          }
          parts.add((ref,));
        }
        i = close;
      } else if (_isDigit(n)) {
        // Two digits when that group exists (like JavaScript), else one.
        var num = int.parse(n);
        var len = 1;
        if (i + 2 < template.length && _isDigit(template[i + 2])) {
          final two = int.parse(template.substring(i + 1, i + 3));
          if (two <= groupCount) {
            num = two;
            len = 2;
          }
        }
        if (num > groupCount) {
          throw InputError('Group $num does not exist (the pattern has $groupCount)', offset: i, source: template);
        }
        flush();
        parts.add(num);
        i += len;
      } else {
        lit.write(c);
      }
    }
    flush();
    return ReplacementTemplate._(parts);
  }

  static bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

  String expand(RegExpMatch m) {
    final out = StringBuffer();
    for (final p in _parts) {
      if (p is String) {
        out.write(p);
      } else if (p is int) {
        out.write(m.group(p) ?? '');
      } else if (p is (String,)) {
        out.write(m.namedGroup(p.$1) ?? '');
      }
    }
    return out.toString();
  }
}

/// Compile errors are reported as [InputError] (message from the engine).
InputError? regexCompileError(String pattern, RegexFlags flags) {
  try {
    flags.compile(pattern);
    return null;
  } on FormatException catch (e) {
    return InputError('Invalid pattern: ${e.message}', offset: e.offset, source: pattern);
  }
}

/// Runs a job synchronously. Call it through [runRegexBounded] so a
/// catastrophic pattern cannot freeze the app.
RegexRunResult executeRegexJob(RegexJob job) {
  final re = job.flags.compile(job.pattern);
  final matches = <RegexMatchInfo>[];
  var capped = false;
  final (groupCount, names) = regexStructure(re);
  String cap(String s) => s.length > RegexJob.maxCapturedChars ? s.substring(0, RegexJob.maxCapturedChars) : s;

  ReplacementTemplate? template;
  InputError? replaceError;
  if (job.replacement != null) {
    try {
      template = ReplacementTemplate.parse(job.replacement!, groupCount, names);
    } on InputError catch (e) {
      replaceError = e;
    }
  }
  final out = template == null ? null : StringBuffer();
  var last = 0;

  // One pass collects matches and builds the replacement preview.
  for (final m in re.allMatches(job.input)) {
    if (matches.length >= job.maxMatches) {
      capped = true;
      break;
    }
    matches.add(
      RegexMatchInfo(
        start: m.start,
        end: m.end,
        text: cap(m.group(0) ?? ''),
        groups: [for (var g = 1; g <= m.groupCount; g++) m.group(g) == null ? null : cap(m.group(g)!)],
        named: {for (final n in m.groupNames) n: m.namedGroup(n) == null ? null : cap(m.namedGroup(n)!)},
      ),
    );
    if (out != null) {
      out.write(job.input.substring(last, m.start));
      out.write(template!.expand(m));
      last = m.end;
    }
  }
  out?.write(job.input.substring(last));
  return RegexRunResult(
    matches: matches,
    capped: capped,
    groupCount: groupCount,
    groupNames: names,
    replaced: out?.toString(),
    replaceError: replaceError,
  );
}

/// Capture group count and names, independent of the input: the pattern is
/// wrapped as `(?:pattern)|`, which always matches the empty string.
(int, List<String>) regexStructure(RegExp re) {
  final wrapped = RegExp(
    '(?:${re.pattern})|',
    multiLine: re.isMultiLine,
    caseSensitive: re.isCaseSensitive,
    unicode: re.isUnicode,
    dotAll: re.isDotAll,
  );
  final m = wrapped.firstMatch('');
  if (m == null) return (0, const []);
  return (m.groupCount, m.groupNames.toList());
}

/// Executes [job] in a killable isolate with [timeout] (default 1.5 s).
/// Throws [OperationTimedOut] or [OperationCancelled].
Future<RegexRunResult> runRegexBounded(
  RegexJob job, {
  CancellationToken? token,
  Duration timeout = const Duration(milliseconds: 1500),
}) => runBounded(() => executeRegexJob(job), timeout: timeout, token: token, debugName: 'j3-regex');

/// Maps named capture groups to their group numbers by scanning the pattern
/// (named groups are numbered in order of their opening parenthesis, like
/// unnamed ones). Escapes and character classes are skipped.
Map<String, int> namedGroupNumbers(String pattern) {
  final out = <String, int>{};
  var group = 0;
  var inClass = false;
  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == r'\') {
      i++;
      continue;
    }
    if (inClass) {
      if (c == ']') inClass = false;
      continue;
    }
    if (c == '[') {
      inClass = true;
      continue;
    }
    if (c != '(') continue;
    if (i + 1 < pattern.length && pattern[i + 1] == '?') {
      // (?<name>...) is capturing; (?:...), (?=...), (?!...), (?<=...), (?<!...) are not.
      if (i + 2 < pattern.length && pattern[i + 2] == '<' && i + 3 < pattern.length) {
        final next = pattern[i + 3];
        if (next != '=' && next != '!') {
          final end = pattern.indexOf('>', i + 3);
          if (end > 0) {
            group++;
            out[pattern.substring(i + 3, end)] = group;
          }
        }
      }
      continue;
    }
    group++;
  }
  return out;
}

/// A ready-made pattern for the example library.
class RegexExample {
  const RegexExample(this.name, this.pattern, this.flags, this.sample, this.description);
  final String name;
  final String pattern;
  final RegexFlags flags;
  final String sample;
  final String description;
}

const List<RegexExample> regexExamples = [
  RegexExample(
    'Email-ish',
    r'[\w.+-]+@[\w-]+(?:\.[\w-]+)+',
    RegexFlags(caseSensitive: false),
    'Contact: modder@example.com, j3.test+dev@mail.example.org or not-an-email@',
    'A pragmatic address matcher (not RFC 5322 complete).',
  ),
  RegexExample(
    'IPv4 address',
    r'\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b',
    RegexFlags(),
    'Server 192.168.1.23 and 10.0.2.2 are fine, 256.1.1.1 and 1.2.3 are not.',
    'Dotted quad with each octet 0-255.',
  ),
  RegexExample(
    'Semantic version',
    r'\bv?(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)'
        r'(?:-(?<pre>[0-9A-Za-z.-]+))?(?:\+(?<build>[0-9A-Za-z.-]+))?\b',
    RegexFlags(),
    'Released v1.4.2, beta 2.0.0-rc.1+build.7, legacy 01.2.3',
    'SemVer 2.0 with named groups major/minor/patch/pre/build.',
  ),
  RegexExample(
    'ISO date',
    r'\b(?<year>\d{4})-(?<month>0[1-9]|1[0-2])-(?<day>0[1-9]|[12]\d|3[01])\b',
    RegexFlags(),
    'Created 2026-09-25, updated 2026-10-01, invalid 2026-13-40.',
    'YYYY-MM-DD with month and day ranges.',
  ),
  RegexExample(
    'Log level',
    r'^\s*\[?(?<level>TRACE|DEBUG|INFO|WARN(?:ING)?|ERROR|FATAL)\]?\s*[:-]?\s*(?<message>.*)$',
    RegexFlags(multiLine: true),
    '[INFO] Mod loader started\nWARN: texture pack missing mipmaps\n  ERROR - failed to parse config.json\nplain line',
    'Level and message per line (multiLine on).',
  ),
];
