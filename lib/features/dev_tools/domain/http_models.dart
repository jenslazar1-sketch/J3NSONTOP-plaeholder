import 'dart:convert';
import 'dart:typed_data';

import 'common.dart';
import 'url_tools.dart';

enum HttpMethod {
  get('GET'),
  post('POST'),
  put('PUT'),
  patch('PATCH'),
  delete('DELETE'),
  head('HEAD'),
  options('OPTIONS');

  const HttpMethod(this.verb);
  final String verb;

  /// Whether the tool sends a request body for this method.
  bool get allowsBody => this != get && this != head;

  static HttpMethod? parse(String s) {
    for (final m in values) {
      if (m.verb == s.toUpperCase()) return m;
    }
    return null;
  }
}

enum BodyMode {
  raw('Raw text'),
  json('JSON');

  const BodyMode(this.label);
  final String label;
}

/// One editable request header row.
class HeaderEntry {
  const HeaderEntry({
    required this.id,
    this.name = '',
    this.value = '',
    this.enabled = true,
    this.needsReentry = false,
  });

  final int id;
  final String name;
  final String value;
  final bool enabled;

  /// Set when the row was restored from history with its value redacted.
  final bool needsReentry;

  bool get isSensitive => HttpRedaction.isSensitiveHeader(name);
  bool get isBlank => name.trim().isEmpty && value.isEmpty;

  HeaderEntry copyWith({String? name, String? value, bool? enabled, bool? needsReentry}) => HeaderEntry(
    id: id,
    name: name ?? this.name,
    value: value ?? this.value,
    enabled: enabled ?? this.enabled,
    needsReentry: needsReentry ?? this.needsReentry,
  );
}

/// Redaction rules shared by the UI, history and log export.
abstract final class HttpRedaction {
  static const String mask = '••••';
  static const String redacted = 'REDACTED';

  static const Set<String> _exactHeaders = {
    'authorization',
    'proxy-authorization',
    'cookie',
    'set-cookie',
    'x-api-key',
  };
  static const List<String> _headerFragments = [
    'token',
    'secret',
    'password',
    'api-key',
    'apikey',
    'api_key',
    'session',
  ];
  static const List<String> _queryFragments = ['token', 'key', 'secret', 'password', 'auth', 'sig'];

  /// Authorization, Proxy-Authorization, Cookie, Set-Cookie, X-Api-Key and
  /// any name containing token/secret/password/api-key/session.
  static bool isSensitiveHeader(String name) {
    final n = name.trim().toLowerCase();
    if (n.isEmpty) return false;
    return _exactHeaders.contains(n) || _headerFragments.any(n.contains);
  }

  /// Query parameter names containing token/key/secret/password/auth/sig.
  static bool isSensitiveQueryName(String name) {
    final n = name.toLowerCase();
    return _queryFragments.any(n.contains);
  }

  static String _decodeLenient(String s) {
    try {
      return UrlTools.decode(s, plusAsSpace: true);
    } on InputError {
      return s;
    }
  }

  static String _redactPairs(String pairs) => pairs
      .split('&')
      .map((piece) {
        final eq = piece.indexOf('=');
        final rawName = eq < 0 ? piece : piece.substring(0, eq);
        if (eq < 0 || !isSensitiveQueryName(_decodeLenient(rawName))) return piece;
        return '$rawName=$redacted';
      })
      .join('&');

  /// Replaces sensitive query (and fragment) parameter values and any
  /// user-info (`user:password@`) with REDACTED. Works on the raw text so
  /// the rest of the URL keeps its exact form.
  static String redactUrl(String url) {
    var rest = url;
    var fragment = '';
    final hash = rest.indexOf('#');
    if (hash >= 0) {
      fragment = rest.substring(hash + 1);
      rest = rest.substring(0, hash);
    }
    var query = '';
    final q = rest.indexOf('?');
    var hasQuery = false;
    if (q >= 0) {
      hasQuery = true;
      query = rest.substring(q + 1);
      rest = rest.substring(0, q);
    }
    final scheme = rest.indexOf('://');
    if (scheme >= 0) {
      final authStart = scheme + 3;
      final slash = rest.indexOf('/', authStart);
      final authority = slash < 0 ? rest.substring(authStart) : rest.substring(authStart, slash);
      final at = authority.lastIndexOf('@');
      if (at >= 0) {
        rest =
            '${rest.substring(0, authStart)}$redacted@${authority.substring(at + 1)}${slash < 0 ? '' : rest.substring(slash)}';
      }
    }
    final buf = StringBuffer(rest);
    if (hasQuery) buf.write('?${_redactPairs(query)}');
    if (hash >= 0) buf.write('#${fragment.contains('=') ? _redactPairs(fragment) : fragment}');
    return buf.toString();
  }

  static final RegExp _sensitiveBody = RegExp(
    r'''["']?(password|passwd|pwd|secret|client_secret|token|access_token|refresh_token|api[_-]?key|authorization)["']?\s*[:=]''',
    caseSensitive: false,
  );

  /// Heuristic: a body with credential-like fields is never persisted.
  static bool bodyLooksSensitive(String body) => _sensitiveBody.hasMatch(body);
}

/// Result of validating the URL field.
class RequestUrlCheck {
  const RequestUrlCheck({
    this.uri,
    this.error,
    this.warnings = const [],
    this.cleartext = false,
    this.loopback = false,
  });
  final Uri? uri;
  final InputError? error;
  final List<String> warnings;
  final bool cleartext;

  /// Host is localhost / 127.0.0.0/8 / ::1 / 0.0.0.0.
  final bool loopback;

  bool get ok => uri != null && error == null;
}

abstract final class HttpValidation {
  static final RegExp _schemeRe = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*):');
  static final RegExp _token = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");

  static bool isLoopbackHost(String host) {
    final h = host.toLowerCase();
    return h == 'localhost' || h.endsWith('.localhost') || h.startsWith('127.') || h == '::1' || h == '0.0.0.0';
  }

  static bool isPrivateLanHost(String host) {
    final h = host.toLowerCase();
    if (h.startsWith('10.') || h.startsWith('192.168.') || h.endsWith('.local')) return true;
    final m = RegExp(r'^172\.(\d+)\.').firstMatch(h);
    if (m != null) {
      final b = int.parse(m.group(1)!);
      return b >= 16 && b <= 31;
    }
    return false;
  }

  static RequestUrlCheck checkUrl(String raw) {
    final url = raw.trim();
    if (url.isEmpty) return const RequestUrlCheck(error: InputError('Enter a URL, e.g. https://example.com/api'));
    final lead = raw.indexOf(url);
    final sm = _schemeRe.firstMatch(url);
    // "localhost:8080/x" parses as scheme "localhost"; treat it as missing.
    final hostPortLike = sm != null && RegExp(r'^\d').hasMatch(url.substring(sm.end));
    if (sm == null || hostPortLike) {
      return RequestUrlCheck(
        error: InputError(
          'Missing scheme',
          offset: lead,
          source: raw,
          hint: 'Start with https:// (or http:// for a development server), e.g. http://192.168.1.23:8080/',
        ),
      );
    }
    final scheme = sm.group(1)!.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return RequestUrlCheck(
        error: InputError('Only http:// and https:// URLs are supported (got "$scheme:")', offset: lead, source: raw),
      );
    }
    try {
      UrlTools.checkUrlSyntax(url);
    } on InputError catch (e) {
      return RequestUrlCheck(
        error: InputError(e.message, offset: (e.offset ?? 0) + lead, source: raw, hint: e.hint),
      );
    }
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException catch (e) {
      return RequestUrlCheck(
        error: InputError(e.message, offset: e.offset == null ? null : e.offset! + lead, source: raw),
      );
    }
    if (uri.host.isEmpty) {
      return RequestUrlCheck(
        error: InputError('The URL has no host name', offset: lead + sm.end, source: raw),
      );
    }
    if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) {
      return RequestUrlCheck(error: InputError('Port ${uri.port} is out of range (1-65535)', source: raw));
    }
    final warnings = <String>[];
    final cleartext = scheme == 'http';
    if (cleartext) {
      warnings.add(
        'Cleartext http:// sends everything unencrypted. Use it only for development endpoints on your own '
        'computer or local network, never for real credentials.',
      );
    }
    final loopback = isLoopbackHost(uri.host);
    if (uri.host == '0.0.0.0') {
      warnings.add('0.0.0.0 is a bind address for servers, not a destination. Use 127.0.0.1 or the LAN IP.');
    }
    return RequestUrlCheck(uri: uri, warnings: warnings, cleartext: cleartext, loopback: loopback);
  }

  /// Validates a header name/value pair. Returns an error message or null.
  static String? headerError(String name, String value) {
    final n = name.trim();
    if (n.isEmpty) return value.isEmpty ? null : 'Header name is empty';
    if (!_token.hasMatch(n)) {
      final bad = n.split('').firstWhere((c) => !_token.hasMatch(c), orElse: () => ' ');
      return 'Invalid character ${describeCharAt(bad, 0)} in header name "$n"';
    }
    for (var i = 0; i < value.length; i++) {
      final c = value.codeUnitAt(i);
      if (c == 0x0D || c == 0x0A || c == 0x00) {
        return 'Header "$n" contains a line break or NUL (header injection is not allowed)';
      }
    }
    return null;
  }

  /// Parses [body] as JSON; throws [InputError] with line/column.
  static Object? checkJson(String body) {
    try {
      return jsonDecode(body);
    } on FormatException catch (e) {
      final off = e.offset;
      throw InputError(
        'Invalid JSON: ${e.message}',
        offset: off == null || off > body.length ? null : off,
        source: body,
      );
    }
  }

  static String formatJson(String body) => const JsonEncoder.withIndent('  ').convert(checkJson(body));
}

/// A validated request ready to send.
class HttpRequestSpec {
  const HttpRequestSpec({
    required this.method,
    required this.url,
    required this.headers,
    this.body,
    this.timeout = const Duration(seconds: 20),
    this.followRedirects = true,
  });

  final HttpMethod method;
  final Uri url;

  /// Enabled headers, merged case-insensitively.
  final Map<String, String> headers;
  final List<int>? body;
  final Duration timeout;
  final bool followRedirects;
}

enum HttpStatusClass {
  informational('1xx Informational'),
  success('2xx Success'),
  redirect('3xx Redirect'),
  clientError('4xx Client error'),
  serverError('5xx Server error'),
  unknown('Non-standard status');

  const HttpStatusClass(this.label);
  final String label;

  static HttpStatusClass of(int code) => switch (code) {
    >= 100 && < 200 => informational,
    >= 200 && < 300 => success,
    >= 300 && < 400 => redirect,
    >= 400 && < 500 => clientError,
    >= 500 && < 600 => serverError,
    _ => unknown,
  };
}

class HttpResponseData {
  const HttpResponseData({
    required this.method,
    required this.requestUrl,
    required this.finalUrl,
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.body,
    required this.bodyCapped,
    required this.elapsed,
    required this.timeToHeaders,
    required this.contentLength,
  });

  final HttpMethod method;
  final Uri requestUrl;
  final Uri finalUrl;
  final int statusCode;
  final String reasonPhrase;

  /// Lower-case names; repeated headers are joined with ", ".
  final List<(String, String)> headers;
  final Uint8List body;

  /// True when reading stopped at the service's hard limit.
  final bool bodyCapped;
  final Duration elapsed;
  final Duration timeToHeaders;
  final int? contentLength;

  HttpStatusClass get statusClass => HttpStatusClass.of(statusCode);
  bool get redirected => finalUrl != requestUrl;

  String? header(String name) {
    final n = name.toLowerCase();
    for (final (k, v) in headers) {
      if (k == n) return v;
    }
    return null;
  }

  String? get contentType => header('content-type');

  bool get looksJson {
    final ct = contentType?.toLowerCase() ?? '';
    if (ct.contains('json')) return true;
    if (body.isEmpty) return false;
    var i = 0;
    while (i < body.length && i < 64 && (body[i] == 0x20 || body[i] == 0x0A || body[i] == 0x0D || body[i] == 0x09)) {
      i++;
    }
    return i < body.length && (body[i] == 0x7B || body[i] == 0x5B);
  }
}

enum HttpFailureKind { timeout, cancelled, connection, tls, protocol, invalidRequest }

class HttpRequestFailure implements Exception {
  const HttpRequestFailure(this.kind, this.message, {this.hint});
  final HttpFailureKind kind;
  final String message;
  final String? hint;

  @override
  String toString() => message;
}
