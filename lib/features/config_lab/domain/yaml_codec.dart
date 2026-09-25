/// YAML validation, YAML -> JSON conversion with an itemised loss report, and
/// a block-style JSON -> YAML emitter whose output is verified by re-parsing.
library;

import 'dart:collection';
import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'conversion_report.dart';
import 'json_parser.dart';
import 'json_tools.dart';
import 'json_value.dart';
import 'source_location.dart';

/// Result of validating YAML. [documents] are display values (maps keep
/// non-string keys) so they can be shown in a read-only tree.
class YamlCheck {
  const YamlCheck({required this.valid, required this.empty, this.error, this.documents = const []});
  final bool valid;
  final bool empty;
  final LocatedError? error;
  final List<Object?> documents;
}

LocatedError _yamlError(String text, YamlException e) {
  final span = e.span;
  final loc = span == null
      ? null
      : SourceLocation(offset: span.start.offset, line: span.start.line + 1, column: span.start.column + 1);
  return LocatedError.at(text, e.message, loc);
}

/// Validates [text]. Top-level so it can run in `Isolate.run`.
YamlCheck checkYaml(String text) {
  if (text.trim().isEmpty) return const YamlCheck(valid: false, empty: true);
  try {
    final docs = loadYamlDocuments(text);
    final display = <Object?>[];
    for (final d in docs) {
      display.add(_toDisplay(d.contents, HashSet<YamlNode>.identity()));
    }
    return YamlCheck(valid: true, empty: false, documents: display);
  } on YamlException catch (e) {
    return YamlCheck(valid: false, empty: false, error: _yamlError(text, e));
  } on _RecursiveAlias catch (e) {
    return YamlCheck(valid: false, empty: false, error: LocatedError(e.message));
  }
}

class _RecursiveAlias implements Exception {
  const _RecursiveAlias(this.message);
  final String message;
}

Object? _toDisplay(YamlNode node, Set<YamlNode> ancestors) {
  if (node is YamlScalar) return node.value;
  if (!ancestors.add(node)) throw const _RecursiveAlias('Recursive alias: a node contains itself');
  try {
    if (node is YamlList) return <Object?>[for (final n in node.nodes) _toDisplay(n, ancestors)];
    if (node is YamlMap) {
      final m = <Object?, Object?>{};
      node.nodes.forEach((k, v) {
        m[_toDisplay(k as YamlNode, ancestors)] = _toDisplay(v, ancestors);
      });
      return m;
    }
    return null;
  } finally {
    ancestors.remove(node);
  }
}

/// How to convert a stream with several `---` documents.
enum YamlMultiDoc {
  array('Array of documents'),
  first('First document only');

  const YamlMultiDoc(this.label);
  final String label;
}

/// Syntax elements found outside scalar content.
class _YamlScan {
  final List<int> commentLines = [];
  final List<(String, int)> anchors = [];
  final List<(String, int)> aliases = [];
  final List<(String, int)> tags = [];
  final List<(String, int)> directives = [];
}

class _LineIndex {
  _LineIndex(String text) {
    starts.add(0);
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c == 10 || (c == 13 && (i + 1 >= text.length || text.codeUnitAt(i + 1) != 10))) starts.add(i + 1);
    }
  }
  final List<int> starts = [];

  int lineOf(int offset) {
    var lo = 0, hi = starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo + 1;
  }
}

bool _ws(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
bool _tokenEnd(int c) => _ws(c) || c == 0x2C || c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D;

void _collectScalarSpans(YamlNode node, List<(int, int)> out, Set<YamlNode> seen) {
  if (!seen.add(node)) return;
  if (node is YamlScalar) {
    final s = node.span;
    if (s.end.offset > s.start.offset) out.add((s.start.offset, s.end.offset));
  } else if (node is YamlList) {
    for (final n in node.nodes) {
      _collectScalarSpans(n, out, seen);
    }
  } else if (node is YamlMap) {
    node.nodes.forEach((k, v) {
      _collectScalarSpans(k as YamlNode, out, seen);
      _collectScalarSpans(v, out, seen);
    });
  }
}

_YamlScan _scanYamlSyntax(String text, List<YamlDocument> docs, _LineIndex lines) {
  final spans = <(int, int)>[];
  final seen = HashSet<YamlNode>.identity();
  for (final d in docs) {
    _collectScalarSpans(d.contents, spans, seen);
  }
  spans.sort((a, b) => a.$1.compareTo(b.$1));
  final scan = _YamlScan();
  var k = 0;
  var i = 0;
  String readToken(int from) {
    var e = from + 1;
    while (e < text.length && !_tokenEnd(text.codeUnitAt(e))) {
      e++;
    }
    return text.substring(from, e);
  }

  while (i < text.length) {
    while (k < spans.length && spans[k].$2 <= i) {
      k++;
    }
    if (k < spans.length && spans[k].$1 <= i) {
      // Inside a scalar: only its property prefix (&anchor !tag) is syntax.
      var j = spans[k].$1;
      final end = spans[k].$2;
      while (j < end) {
        final c = text.codeUnitAt(j);
        if (c == 0x26 || c == 0x21) {
          final tok = readToken(j);
          (c == 0x26 ? scan.anchors : scan.tags).add((tok, lines.lineOf(j)));
          j += tok.length;
          while (j < end && _ws(text.codeUnitAt(j))) {
            j++;
          }
        } else {
          break;
        }
      }
      i = end;
      continue;
    }
    final c = text.codeUnitAt(i);
    final atLineStart = i == 0 || text.codeUnitAt(i - 1) == 10 || text.codeUnitAt(i - 1) == 13;
    if (c == 0x23 && (i == 0 || _ws(text.codeUnitAt(i - 1)))) {
      scan.commentLines.add(lines.lineOf(i));
      while (i < text.length && text.codeUnitAt(i) != 10 && text.codeUnitAt(i) != 13) {
        i++;
      }
      continue;
    }
    if (c == 0x25 && atLineStart) {
      var e = i;
      while (e < text.length && text.codeUnitAt(e) != 10 && text.codeUnitAt(e) != 13) {
        e++;
      }
      scan.directives.add((text.substring(i, e).trim(), lines.lineOf(i)));
      i = e;
      continue;
    }
    if (c == 0x26 || c == 0x2A || c == 0x21) {
      final tok = readToken(i);
      final list = c == 0x26
          ? scan.anchors
          : c == 0x2A
          ? scan.aliases
          : scan.tags;
      list.add((tok, lines.lineOf(i)));
      i += tok.length;
      continue;
    }
    i++;
  }
  return scan;
}

String _stringifyKey(Object? key) => switch (key) {
  null => 'null',
  String() => key,
  double() when !key.isFinite => key.isNaN ? '.nan' : (key > 0 ? '.inf' : '-.inf'),
  bool() || num() => '$key',
  _ => jsonEncode(key),
};

class _YamlToJson {
  _YamlToJson(this.text, this.lines);
  final String text;
  final _LineIndex lines;
  final issues = <ConversionIssue>[];
  final _visited = HashSet<YamlNode>.identity();
  final _ancestors = HashSet<YamlNode>.identity();
  final aliasUses = <(List<Object>, int)>[];

  int _line(YamlNode n) => n.span.start.line + 1;

  Object? convert(YamlNode node, List<Object> path) {
    final repeat = !_visited.add(node);
    if (repeat) aliasUses.add((path, _line(node)));
    if (node is YamlScalar) return _scalar(node, path);
    if (!_ancestors.add(node)) {
      throw _RecursiveAlias('Recursive alias at ${formatJsonPath(path)}: a node contains itself');
    }
    try {
      if (node is YamlList) {
        return <Object?>[
          for (var i = 0; i < node.nodes.length; i++) convert(node.nodes[i], [...path, i]),
        ];
      }
      if (node is YamlMap) {
        final out = <String, Object?>{};
        final origins = <String, String>{};
        node.nodes.forEach((k, v) {
          final keyNode = k as YamlNode;
          final raw = keyNode is YamlScalar ? keyNode.value : _plainOf(keyNode);
          final key = _stringifyKey(raw);
          if (raw is! String) {
            issues.add(
              ConversionIssue.loss(
                IssueKind.nonStringKeys,
                '${jsonDetailedType(raw)} key ${keyNode.span.text.trim()} became the string "$key"',
                path: formatJsonPath([...path, key]),
                line: _line(keyNode),
              ),
            );
          }
          if (key == '<<') {
            issues.add(
              ConversionIssue.loss(
                IssueKind.mergeKeyNotApplied,
                'YAML 1.1 merge key "<<" is not applied (YAML 1.2 has no merge keys); kept as a normal property named "<<"',
                path: formatJsonPath([...path, key]),
                line: _line(keyNode),
              ),
            );
          }
          if (out.containsKey(key)) {
            issues.add(
              ConversionIssue.loss(
                IssueKind.duplicateKeys,
                'Keys ${origins[key]} and ${keyNode.span.text.trim()} both become "$key"; the later value wins',
                path: formatJsonPath([...path, key]),
                line: _line(keyNode),
              ),
            );
          }
          origins[key] ??= keyNode.span.text.trim();
          out[key] = convert(v, [...path, key]);
        });
        return out;
      }
      return null;
    } finally {
      _ancestors.remove(node);
    }
  }

  Object? _plainOf(YamlNode n) => _toDisplay(n, HashSet<YamlNode>.identity()) is Map<Object?, Object?>
      ? jsonDeepCopy(_toDisplay(n, HashSet<YamlNode>.identity()))
      : _toDisplay(n, HashSet<YamlNode>.identity());

  Object? _scalar(YamlScalar node, List<Object> path) {
    final v = node.value;
    if (v is double && !v.isFinite) {
      final s = v.isNaN ? '.nan' : (v > 0 ? '.inf' : '-.inf');
      issues.add(
        ConversionIssue.loss(
          IssueKind.nonFiniteNumber,
          '$s cannot be represented in JSON; written as the string "$s"',
          path: formatJsonPath(path),
          line: _line(node),
        ),
      );
      return s;
    }
    if (v is num && node.style == ScalarStyle.PLAIN) {
      final src = _stripProperties(node.span.text);
      final canonical = jsonEncode(v);
      if (src != canonical) {
        issues.add(
          ConversionIssue.note(
            IssueKind.numberNotation,
            'Number written as $src is emitted as $canonical (same value)',
            path: formatJsonPath(path),
            line: _line(node),
          ),
        );
      }
      if (v is int && (v > kJsSafeInteger || v < -kJsSafeInteger)) {
        issues.add(
          ConversionIssue.note(
            IssueKind.numericPrecision,
            'Integer $v is beyond 2^53: exact in this output, but JavaScript-based tools may round it',
            path: formatJsonPath(path),
            line: _line(node),
          ),
        );
      }
    }
    return v;
  }

  static String _stripProperties(String s) {
    var t = s.trim();
    while (t.startsWith('&') || t.startsWith('!')) {
      final sp = t.indexOf(RegExp(r'\s'));
      if (sp < 0) return '';
      t = t.substring(sp).trim();
    }
    return t;
  }
}

/// Converts YAML [text] to JSON. Top-level so it can run in `Isolate.run`.
ConversionResult yamlToJson(
  String text, {
  YamlMultiDoc multiDoc = YamlMultiDoc.array,
  JsonIndent indent = JsonIndent.two,
}) {
  const from = 'YAML', to = 'JSON';
  final List<YamlDocument> docs;
  try {
    docs = loadYamlDocuments(text);
  } on YamlException catch (e) {
    final err = _yamlError(text, e);
    return ConversionResult.failed(
      ConversionReport(
        from: from,
        to: to,
        issues: [ConversionIssue.error(IssueKind.syntax, err.message, line: err.location?.line)],
      ),
    );
  }
  final lines = _LineIndex(text);
  final scan = _scanYamlSyntax(text, docs, lines);
  final conv = _YamlToJson(text, lines);
  final issues = <ConversionIssue>[];
  Object? value;
  try {
    if (docs.isEmpty) {
      issues.add(
        const ConversionIssue.note(IssueKind.emptyInput, 'The YAML stream contains no documents; output is null'),
      );
      value = null;
    } else if (docs.length == 1) {
      value = conv.convert(docs.first.contents, const []);
    } else if (multiDoc == YamlMultiDoc.array) {
      value = <Object?>[
        for (var d = 0; d < docs.length; d++) conv.convert(docs[d].contents, [d]),
      ];
      issues.add(
        ConversionIssue.loss(
          IssueKind.multiDocument,
          '${docs.length} documents (separated by ---) were combined into one JSON array; document boundaries become array items',
        ),
      );
    } else {
      value = conv.convert(docs.first.contents, const []);
      for (var d = 1; d < docs.length; d++) {
        issues.add(
          ConversionIssue.loss(
            IssueKind.multiDocument,
            'Document ${d + 1} was dropped (only the first document is converted)',
            line: docs[d].span.start.line + 1,
          ),
        );
      }
    }
  } on _RecursiveAlias catch (e) {
    return ConversionResult.failed(
      ConversionReport(from: from, to: to, issues: [ConversionIssue.error(IssueKind.anchorsExpanded, e.message)]),
    );
  }

  for (final line in scan.commentLines) {
    issues.add(ConversionIssue.loss(IssueKind.commentsDropped, 'Comment dropped (JSON has no comments)', line: line));
  }
  for (final (d, line) in scan.directives) {
    issues.add(ConversionIssue.loss(IssueKind.directivesDropped, 'Directive "$d" dropped', line: line));
  }
  final uses = conv.aliasUses;
  for (var a = 0; a < scan.aliases.length; a++) {
    final (name, line) = scan.aliases[a];
    final usePath = a < uses.length ? formatJsonPath(uses[a].$1) : null;
    issues.add(
      ConversionIssue.loss(
        IssueKind.anchorsExpanded,
        'Alias $name expanded into a full copy of the anchored value (shared structure is duplicated)',
        path: usePath,
        line: line,
      ),
    );
  }
  if (scan.aliases.isEmpty && scan.anchors.isNotEmpty) {
    for (final (name, line) in scan.anchors) {
      issues.add(
        ConversionIssue.note(IssueKind.anchorsExpanded, 'Anchor $name removed (it is never aliased)', line: line),
      );
    }
  }
  for (final (tag, line) in scan.tags) {
    issues.add(
      ConversionIssue.note(
        IssueKind.tagsResolved,
        'Explicit tag $tag was applied to the value and then dropped (JSON has no tags)',
        line: line,
      ),
    );
  }
  issues.addAll(conv.issues);
  issues.sort((a, b) => (a.line ?? 0).compareTo(b.line ?? 0));
  return ConversionResult(encodeJson(value, indent: indent), ConversionReport(from: from, to: to, issues: issues));
}

// ---------------------------------------------------------------------------
// JSON -> YAML emitter
// ---------------------------------------------------------------------------

const Set<String> _ambiguousWords = {'y', 'n', 'yes', 'no', 'on', 'off', 'true', 'false', 'null', '~', '<<', '='};
final RegExp _indicatorStart = RegExp('^[-?:,\\[\\]{}#&*!|>\'"%@`]');
final RegExp _numberLike = RegExp(r'^[-+]?(\.|[0-9])');
final RegExp _needsEscape = RegExp('[\\x00-\\x1F\\x7F-\\x9F\\u2028\\u2029\\uFEFF]');

/// Why a string was quoted (for the report); null when emitted plain.
String? _quoteReason(String s) {
  if (s.isEmpty) return 'empty string';
  if (_ambiguousWords.contains(s.toLowerCase())) {
    return 'would be read as ${s == '<<' ? 'a merge key' : 'a boolean/null'} by some YAML readers';
  }
  if (_numberLike.hasMatch(s)) return 'looks like a number or date';
  if (s != s.trim()) return 'leading/trailing whitespace';
  if (_indicatorStart.hasMatch(s)) return 'starts with a YAML indicator character';
  if (s.contains(': ') || s.contains(' #') || s.endsWith(':')) return 'contains ": ", " #" or ends with ":"';
  if (_needsEscape.hasMatch(s)) return 'contains control or line-break characters';
  return null;
}

String _doubleQuoted(String s) {
  final b = StringBuffer('"');
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    switch (c) {
      case 0x22:
        b.write(r'\"');
      case 0x5C:
        b.write(r'\\');
      case 0x0A:
        b.write(r'\n');
      case 0x09:
        b.write(r'\t');
      case 0x0D:
        b.write(r'\r');
      case 0x08:
        b.write(r'\b');
      case 0x0C:
        b.write(r'\f');
      case 0x2028:
        b.write(r'\L');
      case 0x2029:
        b.write(r'\P');
      default:
        if (c < 0x20 || (c >= 0x7F && c <= 0x9F) || c == 0xFEFF) {
          b.write('\\u${c.toRadixString(16).padLeft(4, '0')}');
        } else {
          b.writeCharCode(c);
        }
    }
  }
  b.write('"');
  return b.toString();
}

bool _literalBlockOk(String s) {
  if (!s.contains('\n') || s.contains('\r')) return false;
  if (s.replaceAll('\n', '').trim().isEmpty) return false;
  final withoutNl = s.replaceAll('\n', '');
  if (_needsEscape.hasMatch(withoutNl)) return false;
  for (final line in s.split('\n')) {
    if (line.isEmpty) continue;
    if (line.startsWith(' ') || line.startsWith('\t')) return false;
    if (line.trim().isEmpty) return false;
  }
  return true;
}

class _YamlEmitter {
  final StringBuffer out = StringBuffer();
  final List<ConversionIssue> notes = [];

  void emitDocument(Object? v) {
    if (v is Map<String, Object?> && v.isNotEmpty) {
      _map(v, 0, const []);
    } else if (v is List<Object?> && v.isNotEmpty) {
      _list(v, 0, const []);
    } else {
      _inlineValue(v, 0, const [], leadingSpace: false);
    }
  }

  String _scalarText(Object? v, List<Object> path) {
    return switch (v) {
      null => 'null',
      bool() => '$v',
      int() => '$v',
      double() =>
        v.isNaN
            ? '.nan'
            : v.isInfinite
            ? (v > 0 ? '.inf' : '-.inf')
            : jsonEncode(v),
      String() => _string(v, path),
      Map<Object?, Object?>() => '{}',
      List<Object?>() => '[]',
      _ => _string('$v', path),
    };
  }

  String _string(String s, List<Object> path) {
    final reason = _quoteReason(s);
    if (reason == null) return s;
    if (reason.startsWith('would') || reason.startsWith('looks')) {
      notes.add(
        ConversionIssue.note(
          IssueKind.quotingAdded,
          'String "${s.length > 40 ? '${s.substring(0, 39)}…' : s}" quoted: $reason',
          path: formatJsonPath(path),
        ),
      );
    }
    return _doubleQuoted(s);
  }

  String _key(String k, List<Object> path) {
    final reason = _quoteReason(k);
    return reason == null ? k : _doubleQuoted(k);
  }

  /// Writes a scalar or empty container after "key:" / "-" and ends the line.
  void _inlineValue(Object? v, int indent, List<Object> path, {bool leadingSpace = true}) {
    if (v is String && _literalBlockOk(v)) {
      final parts = v.split('\n');
      var trailing = 0;
      for (var i = parts.length - 1; i >= 0 && parts[i].isEmpty; i--) {
        trailing++;
      }
      final String chomp;
      List<String> content;
      if (trailing == 0) {
        chomp = '-';
        content = parts;
      } else if (trailing == 1) {
        chomp = '';
        content = parts.sublist(0, parts.length - 1);
      } else {
        chomp = '+';
        content = parts.sublist(0, parts.length - 1);
      }
      notes.add(
        ConversionIssue.note(
          IssueKind.structureNote,
          'Multi-line string written as a literal block (|$chomp)',
          path: formatJsonPath(path),
        ),
      );
      out.write('${leadingSpace ? ' ' : ''}|$chomp\n');
      final pad = ' ' * (indent + 2 > 2 ? indent : 2);
      for (final line in content) {
        out.write(line.isEmpty ? '\n' : '$pad$line\n');
      }
      return;
    }
    out.write('${leadingSpace ? ' ' : ''}${_scalarText(v, path)}\n');
  }

  void _map(Map<String, Object?> m, int indent, List<Object> path, {bool firstInline = false}) {
    var first = true;
    for (final e in m.entries) {
      final childPath = [...path, e.key];
      final key = _key(e.key, childPath);
      final pad = (first && firstInline) ? '' : ' ' * indent;
      first = false;
      if (key.length > 1000) {
        out.write('$pad? $key\n${' ' * indent}:');
      } else {
        out.write('$pad$key:');
      }
      _value(e.value, indent, childPath);
    }
  }

  void _value(Object? v, int indent, List<Object> path) {
    if (v is Map<String, Object?> && v.isNotEmpty) {
      out.write('\n');
      _map(v, indent + 2, path);
    } else if (v is List<Object?> && v.isNotEmpty) {
      out.write('\n');
      _list(v, indent + 2, path);
    } else {
      _inlineValue(v, indent + 2, path);
    }
  }

  void _list(List<Object?> l, int indent, List<Object> path, {bool firstInline = false}) {
    for (var i = 0; i < l.length; i++) {
      final item = l[i];
      final childPath = [...path, i];
      final pad = (i == 0 && firstInline) ? '' : ' ' * indent;
      out.write('$pad-');
      if (item is Map<String, Object?> && item.isNotEmpty) {
        out.write(' ');
        _map(item, indent + 2, childPath, firstInline: true);
      } else if (item is List<Object?> && item.isNotEmpty) {
        out.write(' ');
        _list(item, indent + 2, childPath, firstInline: true);
      } else {
        _inlineValue(item, indent + 2, childPath);
      }
    }
  }
}

/// Plain Dart value of a parsed YAML node with stringified keys (for
/// verification and semantic comparison).
Object? yamlNodeToJsonLike(YamlNode node) {
  final display = _toDisplay(node, HashSet<YamlNode>.identity());
  Object? norm(Object? v) {
    if (v is Map<Object?, Object?>) {
      return <String, Object?>{for (final e in v.entries) _stringifyKey(norm(e.key)): norm(e.value)};
    }
    if (v is List<Object?>) return <Object?>[for (final x in v) norm(x)];
    return v;
  }

  return norm(display);
}

/// Converts JSON text to YAML and verifies the result round-trips.
ConversionResult jsonToYaml(String jsonText) {
  const from = 'JSON', to = 'YAML';
  final JsonParseOutput parsed;
  try {
    parsed = parseJsonStrict(jsonText);
  } on JsonSyntaxError catch (e) {
    final loc = SourceLocation.fromOffset(jsonText, e.offset);
    return ConversionResult.failed(
      ConversionReport(
        from: from,
        to: to,
        issues: [ConversionIssue.error(IssueKind.syntax, '${loc.label}: ${e.message}', line: loc.line)],
      ),
    );
  }
  final issues = <ConversionIssue>[
    for (final d in parsed.duplicates)
      ConversionIssue.loss(
        IssueKind.duplicateKeys,
        'Duplicate JSON key "${d.key}": only the last value is written',
        path: formatJsonPath(d.path),
        line: SourceLocation.fromOffset(jsonText, d.offset).line,
      ),
    for (final n in parsed.numberNotes)
      ConversionIssue.loss(
        IssueKind.numericPrecision,
        '${n.literal}: ${n.message}',
        path: formatJsonPath(n.path),
        line: SourceLocation.fromOffset(jsonText, n.offset).line,
      ),
  ];
  final emitter = _YamlEmitter()..emitDocument(parsed.value);
  final yaml = emitter.out.toString();
  issues.addAll(emitter.notes);

  // Verification: re-parse and deep-compare (types and key order).
  try {
    final back = yamlNodeToJsonLike(loadYamlNode(yaml));
    if (!jsonDeepEquals(back, parsed.value, orderedKeys: true)) {
      final where = firstDifference(parsed.value, back);
      return ConversionResult.failed(
        ConversionReport(
          from: from,
          to: to,
          issues: [
            ...issues,
            ConversionIssue.error(
              IssueKind.verification,
              'Emitted YAML does not re-parse to the same data (first difference at ${where == null ? 'key order' : formatJsonPath(where)}); output withheld',
            ),
          ],
        ),
      );
    }
  } on YamlException catch (e) {
    return ConversionResult.failed(
      ConversionReport(
        from: from,
        to: to,
        issues: [
          ...issues,
          ConversionIssue.error(
            IssueKind.verification,
            'Emitted YAML failed to re-parse: ${e.message}; output withheld',
          ),
        ],
      ),
    );
  }
  return ConversionResult(yaml, ConversionReport(from: from, to: to, issues: issues, verified: true));
}

/// Makes a display value (as produced by [checkYaml]) JSON-encodable:
/// non-string keys are stringified like the YAML -> JSON conversion and
/// non-finite floats become `.inf` / `-.inf` / `.nan` strings.
Object? yamlDisplayToJsonLike(Object? v) {
  if (v is Map<Object?, Object?>) {
    return <String, Object?>{for (final e in v.entries) _stringifyKey(e.key): yamlDisplayToJsonLike(e.value)};
  }
  if (v is List<Object?>) return <Object?>[for (final x in v) yamlDisplayToJsonLike(x)];
  if (v is double && !v.isFinite) return _stringifyKey(v);
  return v;
}
