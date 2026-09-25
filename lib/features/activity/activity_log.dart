import '../../app/app_info.dart';
import '../../core/activity/operation.dart';
import '../../core/utils/format.dart';

/// Replacement text for masked secret values.
const String kRedacted = '[REDACTED]';

// Header-style secrets: everything after the colon up to the end of the line
// is masked (`Authorization: Bearer abc`, `Cookie: a=1; b=2`).
final RegExp _headerSecret = RegExp(
  r'''\b((?:proxy-)?authorization|set-cookie|cookie)(["']?\s*:\s*)([^\r\n]+)''',
  caseSensitive: false,
);

// Secret-ish key names (also as suffixes: access_token, client_secret,
// x-api-key...).
const String _secretKey = r'[\w.-]*?(?:token|password|passwd|secret|api[_-]?key)';

// An already masked value (keeps the function idempotent).
const String _masked = r'\[REDACTED\]';

// Quoted or bare values.
const String _value = '($_masked|"[^"\\r\\n]*"|\'[^\'\\r\\n]*\'|[^\\s&;,"\'<>]+)';

// `token=abc`, `password = "x y"`, `?api_key=XYZ&x=1`.
final RegExp _assignSecret = RegExp('\\b($_secretKey)(\\s*=\\s*)$_value', caseSensitive: false);

// `"token": "abc"`, `password: hunter2`, `X-Api-Key: abc`.
final RegExp _colonSecret = RegExp(
  '\\b($_secretKey)(["\']?\\s*:\\s*)($_masked|"[^"\\r\\n]*"|\'[^\'\\r\\n]*\'|[^\\s,}\\]]+)',
  caseSensitive: false,
);

// A bearer credential that appears without its header name.
final RegExp _bearer = RegExp(r'\b(Bearer)(\s+)([A-Za-z0-9._~+/=-]{6,})', caseSensitive: false);

/// Masks credential values in free text before it leaves the app (log
/// export). Keys and separators are kept so the log stays readable; only the
/// values are replaced with [kRedacted]. Over-redaction is preferred to
/// leaking a secret.
String redactSecrets(String input) {
  var out = input.replaceAllMapped(_headerSecret, (m) => '${m[1]}${m[2]}$kRedacted');
  out = out.replaceAllMapped(_assignSecret, (m) => m[3] == kRedacted ? m[0]! : '${m[1]}${m[2]}$kRedacted');
  out = out.replaceAllMapped(_colonSecret, (m) => m[3] == kRedacted ? m[0]! : '${m[1]}${m[2]}$kRedacted');
  out = out.replaceAllMapped(_bearer, (m) => m[3] == kRedacted ? m[0]! : '${m[1]}${m[2]}$kRedacted');
  return out;
}

/// Current filter of the activity log. Survives navigation (kept in a
/// provider by the screen).
class ActivityFilter {
  const ActivityFilter({this.query = '', this.status, this.toolId});

  /// Matched against title, summary, error and tool id (case-insensitive).
  final String query;

  /// Null means every status.
  final OperationStatus? status;

  /// Null means every tool.
  final String? toolId;

  bool get isActive => query.trim().isNotEmpty || status != null || toolId != null;

  ActivityFilter copyWith({
    String? query,
    OperationStatus? status,
    bool clearStatus = false,
    String? toolId,
    bool clearTool = false,
  }) => ActivityFilter(
    query: query ?? this.query,
    status: clearStatus ? null : (status ?? this.status),
    toolId: clearTool ? null : (toolId ?? this.toolId),
  );

  /// Whether [op] passes the search text and tool filter (status ignored;
  /// used for the per-status chip counts).
  bool matchesIgnoringStatus(OperationRecord op, {String? toolName}) {
    if (toolId != null && op.toolId != toolId) return false;
    final terms = query.toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    if (terms.isEmpty) return true;
    final hay = [op.title, op.summary ?? '', op.error ?? '', op.toolId, toolName ?? ''].join('\n').toLowerCase();
    return terms.every(hay.contains);
  }

  bool matches(OperationRecord op, {String? toolName}) =>
      (status == null || op.status == status) && matchesIgnoringStatus(op, toolName: toolName);

  /// Human-readable description for the exported log header.
  String describe({String Function(String toolId)? toolName}) {
    if (!isActive) return 'none (full history)';
    return [
      if (query.trim().isNotEmpty) 'search "${query.trim()}"',
      if (status != null) 'status ${status!.label}',
      if (toolId != null) 'tool ${toolName?.call(toolId!) ?? toolId}',
    ].join(', ');
  }
}

/// Filters [ops] (newest first is preserved).
List<OperationRecord> filterOperations(
  List<OperationRecord> ops,
  ActivityFilter filter, {
  String Function(String toolId)? toolName,
}) => [
  for (final o in ops)
    if (filter.matches(o, toolName: toolName?.call(o.toolId))) o,
];

/// Formats a count value; keys mentioning bytes are shown human-readable.
String formatCount(String key, num value) {
  if (key.toLowerCase().contains('byte') && value is int) return '${Fmt.bytes(value)} ($value)';
  if (value is double) return value.toStringAsFixed(value.truncateToDouble() == value ? 0 : 2);
  return '$value';
}

/// Builds the plain-text activity log for export. The whole text passes
/// through [redactSecrets] before it is returned.
String buildActivityLog(
  List<OperationRecord> ops, {
  required DateTime now,
  required String platformLabel,
  String Function(String toolId)? toolName,
  String? Function(String? workspaceId)? workspaceName,
  String filterDescription = 'none (full history)',
}) {
  final b = StringBuffer()
    ..writeln('${AppInfo.fullName} - activity log')
    ..writeln('Exported:  ${Fmt.dateTime(now)}')
    ..writeln('App:       ${AppInfo.version}+${AppInfo.buildNumber} on $platformLabel')
    ..writeln('Filter:    $filterDescription')
    ..writeln('Entries:   ${ops.length}')
    ..writeln('Note:      credential-like values are masked as $kRedacted.')
    ..writeln('=' * 72);
  for (final o in ops) {
    final tool = toolName?.call(o.toolId);
    b
      ..writeln()
      ..writeln('[${Fmt.dateTime(o.startedAt)}] ${o.status.label.padRight(8)} ${o.title}')
      ..writeln('  Tool:      ${tool == null || tool == o.toolId ? o.toolId : '$tool (${o.toolId})'}');
    final ws = workspaceName?.call(o.workspaceId);
    if (ws != null) b.writeln('  Workspace: $ws');
    if (o.endedAt != null) b.writeln('  Ended:     ${Fmt.dateTime(o.endedAt!)}');
    if (o.elapsed != null) b.writeln('  Duration:  ${Fmt.duration(o.elapsed!)}');
    if (o.status == OperationStatus.running) {
      final pct = o.progress == null ? 'in progress' : '${(o.progress! * 100).round()} %';
      b.writeln('  Progress:  $pct${o.progressMessage == null ? '' : ' - ${o.progressMessage}'}');
    }
    if (o.summary != null) b.writeln('  Summary:   ${o.summary}');
    if (o.error != null) b.writeln('  Error:     ${o.error}');
    if (o.counts.isNotEmpty) {
      b.writeln(
        '  Counts:    ${[for (final e in o.counts.entries) '${e.key}=${formatCount(e.key, e.value)}'].join(', ')}',
      );
    }
    for (final d in o.details) {
      b.writeln('  > $d');
    }
  }
  return redactSecrets(b.toString());
}
