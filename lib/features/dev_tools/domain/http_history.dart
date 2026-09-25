import 'dart:convert';

import 'http_models.dart';

/// A redacted record of a sent request. Built only through
/// [HttpHistoryEntry.record], which applies every redaction rule, so raw
/// secrets never reach persistent storage.
class HttpHistoryEntry {
  const HttpHistoryEntry({
    required this.id,
    required this.time,
    required this.method,
    required this.url,
    required this.headers,
    this.status,
    this.reason,
    this.error,
    this.elapsedMs,
    this.size,
    this.body,
    this.bodyMode = BodyMode.raw,
    this.bodyOmitted,
  });

  final String id;
  final DateTime time;
  final HttpMethod method;

  /// Redacted URL (sensitive query values and user-info replaced).
  final String url;

  /// (name, value, enabled). Sensitive values are [HttpRedaction.mask].
  final List<(String, String, bool)> headers;
  final int? status;
  final String? reason;
  final String? error;
  final int? elapsedMs;
  final int? size;

  /// Stored request body, or null.
  final String? body;
  final BodyMode bodyMode;

  /// Why the body was not stored (sensitive headers, credential-like
  /// fields, too large).
  final String? bodyOmitted;

  static const int maxStoredBody = 32 * 1024;
  static const int limit = 50;

  bool get hasRedactions =>
      url.contains(HttpRedaction.redacted) || headers.any((h) => h.$2 == HttpRedaction.mask) || bodyOmitted != null;

  /// Creates a redacted entry from what was sent.
  static HttpHistoryEntry record({
    required String id,
    required DateTime time,
    required HttpMethod method,
    required String url,
    required List<HeaderEntry> headers,
    required String? body,
    required BodyMode bodyMode,
    HttpResponseData? response,
    HttpRequestFailure? failure,
  }) {
    final rows = <(String, String, bool)>[
      for (final h in headers)
        if (!h.isBlank) (h.name.trim(), h.isSensitive && h.value.isNotEmpty ? HttpRedaction.mask : h.value, h.enabled),
    ];
    final sentSensitive = headers.any((h) => h.enabled && h.isSensitive && h.value.isNotEmpty);
    String? storedBody;
    String? omitted;
    if (body != null && body.isNotEmpty) {
      if (sentSensitive) {
        omitted = 'Not stored: the request carried sensitive headers.';
      } else if (HttpRedaction.bodyLooksSensitive(body)) {
        omitted = 'Not stored: the body contains credential-like fields.';
      } else if (body.length > maxStoredBody) {
        omitted = 'Not stored: larger than ${maxStoredBody ~/ 1024} KiB.';
      } else {
        storedBody = body;
      }
    }
    return HttpHistoryEntry(
      id: id,
      time: time,
      method: method,
      url: HttpRedaction.redactUrl(url.trim()),
      headers: rows,
      status: response?.statusCode,
      reason: response?.reasonPhrase,
      error: failure?.message,
      elapsedMs: response?.elapsed.inMilliseconds,
      size: response?.body.length,
      body: storedBody,
      bodyMode: bodyMode,
      bodyOmitted: omitted,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'time': time.toUtc().toIso8601String(),
    'method': method.verb,
    'url': url,
    'headers': [
      for (final (n, v, e) in headers) {'name': n, 'value': v, 'enabled': e},
    ],
    'status': ?status,
    'reason': ?reason,
    'error': ?error,
    'elapsedMs': ?elapsedMs,
    'size': ?size,
    'body': ?body,
    'bodyMode': bodyMode.name,
    'bodyOmitted': ?bodyOmitted,
  };

  static HttpHistoryEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], time = raw['time'], method = raw['method'], url = raw['url'];
    if (id is! String || time is! String || method is! String || url is! String) return null;
    final t = DateTime.tryParse(time);
    final m = HttpMethod.parse(method);
    if (t == null || m == null) return null;
    final headers = <(String, String, bool)>[];
    final hs = raw['headers'];
    if (hs is List) {
      for (final h in hs) {
        if (h is Map && h['name'] is String && h['value'] is String) {
          final name = h['name'] as String;
          // Defence in depth: never trust stored data to be redacted.
          final value = HttpRedaction.isSensitiveHeader(name) && (h['value'] as String).isNotEmpty
              ? HttpRedaction.mask
              : h['value'] as String;
          headers.add((name, value, h['enabled'] != false));
        }
      }
    }
    int? asInt(Object? v) => v is int ? v : null;
    String? asStr(Object? v) => v is String ? v : null;
    return HttpHistoryEntry(
      id: id,
      time: t,
      method: m,
      url: HttpRedaction.redactUrl(url),
      headers: headers,
      status: asInt(raw['status']),
      reason: asStr(raw['reason']),
      error: asStr(raw['error']),
      elapsedMs: asInt(raw['elapsedMs']),
      size: asInt(raw['size']),
      body: asStr(raw['body']),
      bodyMode: raw['bodyMode'] == 'json' ? BodyMode.json : BodyMode.raw,
      bodyOmitted: asStr(raw['bodyOmitted']),
    );
  }

  /// Decodes the persisted `{"v":1,"items":[...]}` document.
  static List<HttpHistoryEntry> decodeList(Object? doc) {
    if (doc is! Map || doc['items'] is! List) return const [];
    return [for (final i in doc['items'] as List) ?fromJson(i)];
  }

  static Map<String, Object?> encodeList(List<HttpHistoryEntry> items) => {
    'v': 1,
    'items': [for (final e in items.take(limit)) e.toJson()],
  };

  String get summary {
    final result = status != null
        ? '$status${reason == null || reason!.isEmpty ? '' : ' $reason'}'
        : 'ERROR ${error ?? ''}';
    return '${method.verb} $url -> $result';
  }
}

/// Plain-text, redacted log of the history (newest first).
String exportHistoryLog(List<HttpHistoryEntry> items, {DateTime? now}) {
  final b = StringBuffer()
    ..writeln('# J3NSONTOP HTTP request log (redacted)')
    ..writeln('# exported ${(now ?? DateTime.now()).toUtc().toIso8601String()}')
    ..writeln('# ${items.length} request(s). Sensitive header values show ${HttpRedaction.mask};')
    ..writeln('# sensitive query parameters and credentials in URLs show ${HttpRedaction.redacted}.')
    ..writeln();
  for (final e in items) {
    b.writeln('[${e.time.toUtc().toIso8601String()}] ${e.method.verb} ${e.url}');
    if (e.status != null) {
      b.writeln('  status: ${e.status} ${e.reason ?? ''}'.trimRight());
    } else {
      b.writeln('  error: ${e.error ?? 'unknown'}');
    }
    if (e.elapsedMs != null) b.writeln('  time: ${e.elapsedMs} ms');
    if (e.size != null) b.writeln('  size: ${e.size} bytes');
    for (final (n, v, enabled) in e.headers) {
      b.writeln('  ${enabled ? '' : '# (disabled) '}$n: $v');
    }
    if (e.body != null) {
      b.writeln('  body (${e.bodyMode.label}, ${utf8.encode(e.body!).length} bytes):');
      for (final line in e.body!.split('\n')) {
        b.writeln('    $line');
      }
    } else if (e.bodyOmitted != null) {
      b.writeln('  body: ${e.bodyOmitted}');
    }
    b.writeln();
  }
  return b.toString();
}
