import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/tasks/cancellation.dart';
import '../../../core/tasks/isolate_runner.dart';
import '../../../core/utils/format.dart';
import 'line_endings.dart';

/// Lines loaded at most.
const int kMaxLogLines = 200000;

/// Bytes read at most.
const int kMaxLogBytes = 64 * 1024 * 1024;

/// Severity levels, most severe first.
enum LogSeverity {
  fatal('FATAL'),
  error('ERROR'),
  warn('WARN'),
  info('INFO'),
  debug('DEBUG'),
  trace('TRACE'),
  other('OTHER');

  const LogSeverity(this.label);
  final String label;
}

LogSeverity? _fromWord(String w) {
  switch (w.toLowerCase()) {
    case 'fatal':
    case 'critical':
    case 'crit':
    case 'emerg':
    case 'emergency':
    case 'alert':
    case 'panic':
    case 'f':
    case 'a':
      return LogSeverity.fatal;
    case 'error':
    case 'err':
    case 'severe':
    case 'e':
      return LogSeverity.error;
    case 'warning':
    case 'warn':
    case 'w':
      return LogSeverity.warn;
    case 'notice':
    case 'info':
    case 'information':
    case 'informational':
    case 'i':
      return LogSeverity.info;
    case 'debug':
    case 'dbg':
    case 'fine':
    case 'd':
      return LogSeverity.debug;
    case 'trace':
    case 'verbose':
    case 'finer':
    case 'finest':
    case 'v':
    case 't':
      return LogSeverity.trace;
  }
  return null;
}

LogSeverity _fromNumber(int n) {
  // bunyan / pino numeric levels.
  if (n >= 60) return LogSeverity.fatal;
  if (n >= 50) return LogSeverity.error;
  if (n >= 40) return LogSeverity.warn;
  if (n >= 30) return LogSeverity.info;
  if (n >= 20) return LogSeverity.debug;
  return LogSeverity.trace;
}

final RegExp _jsonLevel = RegExp(
  r'"(?:level|severity|lvl|loglevel|log\.level|levelname|@l|@level)"\s*:\s*(?:"([A-Za-z]+)"|(\d+))',
  caseSensitive: false,
);
final RegExp _logfmtLevel = RegExp(r'(?:^|\s)(?:level|lvl|severity)="?([A-Za-z]+)', caseSensitive: false);
final RegExp _logcatBrief = RegExp(r'^([VDIWEFA])/[^:(]*(?:\(\s*\d+\))?\s*:');
final RegExp _logcatThreadtime = RegExp(r'^\d\d-\d\d\s+\d\d:\d\d:\d\d\.\d+\s+\d+\s+\d+\s+([VDIWEFA])\s');
final RegExp _glog = RegExp(r'^([IWEF])\d{4} \d\d:\d\d:\d\d');
final RegExp _letterPrefix = RegExp(r'^([VDWEF])(?:\s|[:|]\s)');
final RegExp _infoLetterPrefix = RegExp(r'^I\s+[\d\[]');
final RegExp _upperKeyword = RegExp(
  r'(?<![A-Za-z0-9_])(FATAL|CRITICAL|CRIT|EMERG(?:ENCY)?|ALERT|PANIC|ERROR|ERR|SEVERE|WARNING|WARN|NOTICE|INFO|'
  r'INFORMATION|DEBUG|DBG|TRACE|VERBOSE|FINEST|FINER|FINE)(?![A-Za-z0-9_])',
);
final RegExp _bracketKeyword = RegExp(
  r'[\[<(|]\s*(fatal|critical|crit|emerg|alert|panic|error|err|severe|warning|warn|notice|info|debug|dbg|trace|'
  r'verbose)\s*[\]>)|]',
  caseSensitive: false,
);
final RegExp _prefixWord = RegExp(
  r'^\s*(fatal|critical|error|warning|warn|notice|info|debug|trace|verbose)\s*:',
  caseSensitive: false,
);
final RegExp _timestampStart = RegExp(r'^\[?\d{1,4}[-/.:T]\d');

/// Detects the severity of one log line, or null when the line carries no
/// level marker. Understands `[ERROR]`, ` ERROR `, `ERROR:`, `level=error`,
/// JSON `"level":"error"` (and bunyan/pino numbers), Android logcat
/// (`E/Tag:` and threadtime), glog (`E0925 ...`) and single-letter
/// prefixes (`W ...`). When several markers appear, the earliest wins.
LogSeverity? detectSeverity(String line) {
  final head = line.length > 400 ? line.substring(0, 400) : line;
  final trimmed = head.trimLeft();
  if (trimmed.startsWith('{')) {
    final m = _jsonLevel.firstMatch(head);
    if (m != null) {
      if (m.group(1) != null) {
        final s = _fromWord(m.group(1)!);
        if (s != null) return s;
      } else {
        final n = int.tryParse(m.group(2)!);
        if (n != null && n >= 10) return _fromNumber(n);
      }
    }
  }
  final lf = _logfmtLevel.firstMatch(head);
  if (lf != null) {
    final s = _fromWord(lf.group(1)!);
    if (s != null) return s;
  }
  for (final re in [_logcatThreadtime, _logcatBrief, _glog]) {
    final m = re.firstMatch(head);
    if (m != null) return _fromWord(m.group(1)!);
  }
  final letter = _letterPrefix.firstMatch(head);
  if (letter != null) return _fromWord(letter.group(1)!);
  if (_infoLetterPrefix.hasMatch(head)) return LogSeverity.info;

  Match? best;
  for (final re in [_prefixWord, _bracketKeyword, _upperKeyword]) {
    final m = re.firstMatch(head);
    if (m != null && (best == null || m.start < best.start)) best = m;
  }
  return best == null ? null : _fromWord(best.group(1)!);
}

/// True when a line without a level starts a new record (it begins with a
/// timestamp) rather than continuing the previous one (stack frames,
/// wrapped messages, indented details).
bool startsNewRecord(String line) => _timestampStart.hasMatch(line);

/// Severity for every line: detected, or inherited from the previous line
/// for continuation lines, or [LogSeverity.other].
class SeverityTracker {
  LogSeverity _last = LogSeverity.other;

  LogSeverity next(String line) {
    final s = detectSeverity(line);
    if (s != null) {
      _last = s;
      return s;
    }
    if (line.isNotEmpty && startsNewRecord(line)) {
      _last = LogSeverity.other;
      return LogSeverity.other;
    }
    return _last;
  }
}

/// A loaded (possibly truncated) log.
class LogDocument {
  LogDocument({
    required this.name,
    required this.lines,
    required this.severities,
    required this.fileBytes,
    required this.bytesRead,
    required this.truncatedByLines,
    required this.truncatedByBytes,
    required this.encodingLabel,
    required this.malformed,
    required this.lineEndings,
    required this.longestLine,
  }) {
    for (final s in severities) {
      _counts[s]++;
    }
  }

  factory LogDocument.fromText(String name, String text) {
    final lines = const LineSplitter().convert(text);
    final t = SeverityTracker();
    final bytes = utf8.encode(text).length;
    return LogDocument(
      name: name,
      lines: lines,
      severities: Uint8List.fromList([for (final l in lines) t.next(l).index]),
      fileBytes: bytes,
      bytesRead: bytes,
      truncatedByLines: false,
      truncatedByBytes: false,
      encodingLabel: 'UTF-8',
      malformed: false,
      lineEndings: countLineEndings(text),
      longestLine: lines.fold(0, (m, l) => l.length > m ? l.length : m),
    );
  }

  /// Display name (workspace-relative path or file name).
  final String name;
  final List<String> lines;

  /// [LogSeverity.index] per line.
  final Uint8List severities;
  final int fileBytes;
  final int bytesRead;
  final bool truncatedByLines;
  final bool truncatedByBytes;
  final String encodingLabel;

  /// The file was not valid UTF-8 and was decoded as Latin-1.
  final bool malformed;
  final LineEndingCounts lineEndings;
  final int longestLine;
  final List<int> _counts = List<int>.filled(LogSeverity.values.length, 0);

  bool get truncated => truncatedByLines || truncatedByBytes;
  LogSeverity severityOf(int index) => LogSeverity.values[severities[index]];
  int count(LogSeverity s) => _counts[s.index];

  String truncationNotice() {
    if (truncatedByLines) {
      return 'Showing the first ${lines.length} lines (limit $kMaxLogLines) of ${Fmt.bytes(fileBytes)}.';
    }
    if (truncatedByBytes) {
      return 'Showing the first ${Fmt.bytes(bytesRead)} (limit ${Fmt.bytes(kMaxLogBytes)}) of ${Fmt.bytes(fileBytes)}.';
    }
    return '';
  }
}

enum _Enc { utf8, utf16le, utf16be }

/// Moves a byte cut so it does not split a UTF-8 character or a UTF-16
/// code unit.
Future<int> _safeCut(String path, int cut, int start, _Enc enc) async {
  if (enc != _Enc.utf8) return start + ((cut - start) ~/ 2) * 2;
  final from = cut - 4 < start ? start : cut - 4;
  final raf = await File(path).open();
  try {
    await raf.setPosition(from);
    final tail = await raf.read(cut - from);
    for (var i = tail.length - 1; i >= 0; i--) {
      final b = tail[i];
      if (b & 0xC0 == 0x80) continue; // continuation byte
      final need = b < 0x80 ? 1 : (b >= 0xF0 ? 4 : (b >= 0xE0 ? 3 : (b >= 0xC0 ? 2 : 1)));
      return i + need > tail.length ? from + i : cut;
    }
    return cut;
  } finally {
    await raf.close();
  }
}

StreamTransformer<List<int>, String> _utf16Decoder(bool littleEndian) {
  int? carry;
  return StreamTransformer<List<int>, String>.fromHandlers(
    handleData: (chunk, sink) {
      final units = <int>[];
      var i = 0;
      if (carry != null && chunk.isNotEmpty) {
        units.add(littleEndian ? carry! | (chunk[0] << 8) : (carry! << 8) | chunk[0]);
        carry = null;
        i = 1;
      }
      for (; i + 1 < chunk.length; i += 2) {
        units.add(littleEndian ? chunk[i] | (chunk[i + 1] << 8) : (chunk[i] << 8) | chunk[i + 1]);
      }
      if (i < chunk.length) carry = chunk[i];
      sink.add(String.fromCharCodes(units));
    },
  );
}

class _LoadAttempt {
  final lines = <String>[];
  final severities = <int>[];
  var lf = 0, crlf = 0, cr = 0;
  var pendingCr = false;
  var longest = 0;
  var bytesRead = 0;
  var hitLineCap = false;

  void countEndings(String chunk) {
    for (var i = 0; i < chunk.length; i++) {
      final c = chunk.codeUnitAt(i);
      if (pendingCr) {
        pendingCr = false;
        if (c == 10) {
          crlf++;
          continue;
        }
        cr++;
      }
      if (c == 13) {
        pendingCr = true;
      } else if (c == 10) {
        lf++;
      }
    }
  }
}

/// Streams a log file line by line. Reads at most [maxBytes] and keeps at
/// most [maxLines] lines; both limits are reported on the document. UTF-8
/// (with or without BOM) and UTF-16 with BOM are decoded; invalid UTF-8
/// falls back to Latin-1 with [LogDocument.malformed] set.
Future<LogDocument> loadLogFile(
  String path, {
  String? displayName,
  int maxLines = kMaxLogLines,
  int maxBytes = kMaxLogBytes,
  CancellationToken? token,
  void Function(double fraction, int lines)? onProgress,
}) async {
  final file = File(path);
  final size = await file.length();
  final head = size == 0 ? const <int>[] : await file.openRead(0, size < 4 ? size : 4).expand((c) => c).toList();
  var enc = _Enc.utf8;
  var start = 0;
  var label = 'UTF-8';
  if (head.length >= 2 && head[0] == 0xFF && head[1] == 0xFE) {
    enc = _Enc.utf16le;
    start = 2;
    label = 'UTF-16 LE';
  } else if (head.length >= 2 && head[0] == 0xFE && head[1] == 0xFF) {
    enc = _Enc.utf16be;
    start = 2;
    label = 'UTF-16 BE';
  } else if (head.length >= 3 && head[0] == 0xEF && head[1] == 0xBB && head[2] == 0xBF) {
    start = 3;
    label = 'UTF-8 with BOM';
  }
  final truncatedByBytes = size > maxBytes;
  final end = truncatedByBytes ? await _safeCut(path, maxBytes, start, enc) : size;
  final span = end - start <= 0 ? 1 : end - start;

  Future<_LoadAttempt> attempt({required bool latin}) async {
    final a = _LoadAttempt();
    final tracker = SeverityTracker();
    final bytes = file.openRead(start, end).map((chunk) {
      a.bytesRead += chunk.length;
      return chunk;
    });
    final Stream<String> text = switch (enc) {
      _Enc.utf16le => bytes.transform(_utf16Decoder(true)),
      _Enc.utf16be => bytes.transform(_utf16Decoder(false)),
      _Enc.utf8 => latin ? bytes.transform(latin1.decoder) : bytes.transform(const Utf8Decoder()),
    };
    var sinceReport = 0;
    await for (final line
        in text
            .map((chunk) {
              a.countEndings(chunk);
              return chunk;
            })
            .transform(const LineSplitter())) {
      if (a.lines.length >= maxLines) {
        a.hitLineCap = true;
        break;
      }
      a.lines.add(line);
      a.severities.add(tracker.next(line).index);
      if (line.length > a.longest) a.longest = line.length;
      if (++sinceReport >= 2000) {
        sinceReport = 0;
        token?.throwIfCancelled();
        onProgress?.call(a.bytesRead / span, a.lines.length);
      }
    }
    if (a.pendingCr) a.cr++;
    return a;
  }

  _LoadAttempt result;
  var malformed = false;
  try {
    result = await attempt(latin: false);
  } on FormatException {
    malformed = true;
    label = 'Latin-1 (fallback)';
    result = await attempt(latin: true);
  }
  token?.throwIfCancelled();
  onProgress?.call(1, result.lines.length);
  return LogDocument(
    name: displayName ?? p.basename(path),
    lines: result.lines,
    severities: Uint8List.fromList(result.severities),
    fileBytes: size,
    bytesRead: start + result.bytesRead,
    truncatedByLines: result.hitLineCap,
    truncatedByBytes: truncatedByBytes && !result.hitLineCap,
    encodingLabel: label,
    malformed: malformed,
    lineEndings: LineEndingCounts(lf: result.lf, crlf: result.crlf, cr: result.cr),
    longestLine: result.longest,
  );
}

/// Indices of lines whose severity is in [enabled].
List<int> filterBySeverity(LogDocument doc, Set<LogSeverity> enabled) {
  if (enabled.length == LogSeverity.values.length) return List<int>.generate(doc.lines.length, (i) => i);
  final mask = List<bool>.generate(LogSeverity.values.length, (i) => enabled.contains(LogSeverity.values[i]));
  final out = <int>[];
  for (var i = 0; i < doc.severities.length; i++) {
    if (mask[doc.severities[i]]) out.add(i);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Search

class LogQuery {
  const LogQuery(this.text, {this.regex = false, this.caseSensitive = false});
  final String text;
  final bool regex;
  final bool caseSensitive;

  bool get isEmpty => text.isEmpty;

  /// Compiles the query. Throws [FormatException] for an invalid regex.
  RegExp compile() => RegExp(regex ? text : RegExp.escape(text), caseSensitive: caseSensitive);

  String describe() => regex
      ? '/$text/ (regex, ${caseSensitive ? 'case-sensitive' : 'ignore case'})'
      : '"$text" (${caseSensitive ? 'case-sensitive' : 'ignore case'})';

  @override
  bool operator ==(Object other) =>
      other is LogQuery && other.text == text && other.regex == regex && other.caseSensitive == caseSensitive;

  @override
  int get hashCode => Object.hash(text, regex, caseSensitive);
}

class LogSearchResult {
  LogSearchResult(this.query, this.matches, this.firstRange);

  final LogQuery query;

  /// Matching line indices, ascending.
  final List<int> matches;

  /// First match range per matching line (start, end).
  final Map<int, (int, int)> firstRange;

  late final Set<int> matchSet = matches.toSet();
  int get count => matches.length;
}

/// Worker body for regex search. Top level so it can run in an isolate.
Int32List searchChunk(String pattern, bool caseSensitive, List<String> lines, int offset) {
  final re = RegExp(pattern, caseSensitive: caseSensitive);
  final out = <int>[];
  for (var i = 0; i < lines.length; i++) {
    final m = re.firstMatch(lines[i]);
    if (m != null) {
      out
        ..add(offset + i)
        ..add(m.start)
        ..add(m.end);
    }
  }
  return Int32List.fromList(out);
}

LogSearchResult _fromTriples(LogQuery q, Iterable<Int32List> parts) {
  final matches = <int>[];
  final ranges = <int, (int, int)>{};
  for (final t in parts) {
    for (var i = 0; i + 2 < t.length; i += 3) {
      matches.add(t[i]);
      ranges[t[i]] = (t[i + 1], t[i + 2]);
    }
  }
  return LogSearchResult(q, matches, ranges);
}

/// Plain-text search on the calling isolate (plain patterns cannot
/// backtrack catastrophically).
LogSearchResult searchPlain(List<String> lines, LogQuery q) {
  assert(!q.regex);
  return _fromTriples(q, [searchChunk(RegExp.escape(q.text), q.caseSensitive, lines, 0)]);
}

/// Regex search in bounded worker isolates, [chunkSize] lines at a time,
/// with a total time [budget]. A runaway pattern is killed and
/// [OperationTimedOut] is thrown; an invalid one throws [FormatException]
/// before any worker starts.
Future<LogSearchResult> searchRegex(
  List<String> lines,
  LogQuery q, {
  Duration budget = const Duration(seconds: 4),
  int chunkSize = 20000,
  CancellationToken? token,
  void Function(double fraction)? onProgress,
}) async {
  q.compile(); // validate on this isolate first
  final sw = Stopwatch()..start();
  final parts = <Int32List>[];
  for (var offset = 0; offset < lines.length; offset += chunkSize) {
    token?.throwIfCancelled();
    final remaining = budget - sw.elapsed;
    if (remaining <= Duration.zero) throw OperationTimedOut(budget);
    final end = offset + chunkSize > lines.length ? lines.length : offset + chunkSize;
    final chunk = lines.sublist(offset, end);
    final pattern = q.text;
    final cs = q.caseSensitive;
    final start = offset;
    try {
      parts.add(
        await runBounded(
          () => searchChunk(pattern, cs, chunk, start),
          timeout: remaining,
          token: token,
          debugName: 'j3-log-search',
        ),
      );
    } on OperationTimedOut {
      throw OperationTimedOut(budget);
    }
    onProgress?.call(end / lines.length);
  }
  return _fromTriples(q, parts);
}

// ---------------------------------------------------------------------------
// Export

/// Formats 1-based line numbers as compact ranges: `1-3, 7, 10-12`.
String formatLineRanges(List<int> lineNumbers) {
  if (lineNumbers.isEmpty) return '(none)';
  final sorted = [...lineNumbers]..sort();
  final parts = <String>[];
  var start = sorted.first;
  var prev = start;
  for (final n in sorted.skip(1)) {
    if (n == prev + 1 || n == prev) {
      prev = n;
      continue;
    }
    parts.add(start == prev ? '$start' : '$start-$prev');
    start = prev = n;
  }
  parts.add(start == prev ? '$start' : '$start-$prev');
  return parts.join(', ');
}

/// Export text: a `#` header describing source, filters and line ranges,
/// then the raw lines of [indices] (ascending document order).
String buildLogExport({
  required LogDocument doc,
  required List<int> indices,
  required String scope,
  required Set<LogSeverity> severities,
  LogQuery? query,
  bool onlyMatches = false,
  DateTime? now,
}) {
  final sorted = [...indices]..sort();
  final levels = severities.length == LogSeverity.values.length
      ? 'all levels'
      : LogSeverity.values.where(severities.contains).map((s) => s.label).join(', ');
  final b = StringBuffer()
    ..writeln('# J3NSONTOP log export')
    ..writeln('# source: ${doc.name}${doc.truncated ? ' (truncated: ${doc.truncationNotice()})' : ''}')
    ..writeln('# exported: ${Fmt.dateTime(now ?? DateTime.now())}')
    ..writeln('# scope: $scope, ${sorted.length} line(s)')
    ..writeln('# severity filter: $levels');
  if (query != null && !query.isEmpty) {
    b.writeln('# search: ${query.describe()}${onlyMatches ? ', only matching lines' : ''}');
  }
  b
    ..writeln('# line ranges (original numbering): ${formatLineRanges([for (final i in sorted) i + 1])}')
    ..writeln('#');
  for (final i in sorted) {
    b.writeln(doc.lines[i]);
  }
  return b.toString();
}
