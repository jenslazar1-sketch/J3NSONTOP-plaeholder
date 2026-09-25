import 'dart:convert';

import 'common.dart';

/// Which characters survive percent-encoding.
enum UrlEncodeMode {
  /// RFC 3986 unreserved only (`A-Z a-z 0-9 - . _ ~`). For one query value
  /// or path segment (like JavaScript's `encodeURIComponent`, but also
  /// encoding `! ' ( ) *`).
  component('Component', 'Encodes everything except A-Z a-z 0-9 - . _ ~'),

  /// Keeps URL structure characters (`: / ? # [ ] @ ! $ & ' ( ) * + , ; =`)
  /// and existing valid `%XX` escapes (no double-encoding).
  fullUri('Full URI', 'Keeps : / ? # [ ] @ ! \$ & \' ( ) * + , ; = and existing %XX'),

  /// `application/x-www-form-urlencoded`: space becomes `+`; keeps
  /// `A-Z a-z 0-9 * - . _`.
  form('Form (+ for spaces)', 'HTML form encoding: space -> +, keeps A-Z a-z 0-9 * - . _');

  const UrlEncodeMode(this.label, this.description);
  final String label;
  final String description;
}

/// One decoded query parameter (order and duplicates preserved).
class QueryParam {
  const QueryParam({
    required this.rawName,
    required this.rawValue,
    required this.name,
    required this.value,
    this.error,
  });
  final String rawName;

  /// Null when the parameter has no `=` (a bare flag such as `?debug`).
  final String? rawValue;
  final String name;
  final String? value;

  /// Decoding problem (the raw text is shown instead).
  final String? error;
}

/// Parsed parts of a URL for the inspector.
class UrlInspection {
  const UrlInspection({
    required this.uri,
    required this.scheme,
    required this.userInfo,
    required this.host,
    required this.port,
    required this.portIsDefault,
    required this.path,
    required this.segments,
    required this.query,
    required this.rawQuery,
    required this.fragment,
    required this.warnings,
  });

  final Uri uri;
  final String scheme;
  final String userInfo;
  final String host;
  final int? port;
  final bool portIsDefault;
  final String path;
  final List<String> segments;
  final List<QueryParam> query;
  final String rawQuery;
  final String? fragment;
  final List<String> warnings;

  String get origin {
    if (host.isEmpty) return '';
    final p = port == null || portIsDefault ? '' : ':$port';
    final h = host.contains(':') ? '[$host]' : host;
    return '$scheme://$h$p';
  }
}

abstract final class UrlTools {
  static bool _alnum(int c) => (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

  static bool _hex(int c) => (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);

  static int _hexValue(int c) => c <= 0x39 ? c - 0x30 : (c | 0x20) - 0x61 + 10;

  static const String _unreserved = '-._~';
  static const String _reserved = ":/?#[]@!\$&'()*+,;=";
  static const String _formSafe = '*-._';

  static bool _keep(int c, UrlEncodeMode mode) {
    if (_alnum(c)) return true;
    final ch = String.fromCharCode(c);
    return switch (mode) {
      UrlEncodeMode.component => _unreserved.contains(ch),
      UrlEncodeMode.fullUri => _unreserved.contains(ch) || _reserved.contains(ch),
      UrlEncodeMode.form => _formSafe.contains(ch),
    };
  }

  static void _pct(StringBuffer out, int byte) {
    out.write('%');
    out.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
  }

  /// Percent-encodes [text] as UTF-8 according to [mode].
  static String encode(String text, UrlEncodeMode mode) {
    final out = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c < 0x80) {
        if (mode == UrlEncodeMode.form && c == 0x20) {
          out.write('+');
        } else if (c == 0x25 &&
            mode == UrlEncodeMode.fullUri &&
            i + 2 < text.length &&
            _hex(text.codeUnitAt(i + 1)) &&
            _hex(text.codeUnitAt(i + 2))) {
          out.write('%');
        } else if (_keep(c, mode)) {
          out.writeCharCode(c);
        } else {
          _pct(out, c);
        }
        continue;
      }
      // Non-ASCII: take the whole code point (surrogate pair) as UTF-8.
      var end = i + 1;
      if (c >= 0xD800 && c <= 0xDBFF && end < text.length) {
        final lo = text.codeUnitAt(end);
        if (lo >= 0xDC00 && lo <= 0xDFFF) end++;
      }
      for (final b in utf8.encode(text.substring(i, end))) {
        _pct(out, b);
      }
      i = end - 1;
    }
    return out.toString();
  }

  /// Strict percent-decoding. `%` must be followed by two hex digits and
  /// the resulting bytes must be valid UTF-8; otherwise [InputError] points
  /// at the offending sequence. With [plusAsSpace] (form decoding) `+`
  /// becomes a space.
  static String decode(String text, {bool plusAsSpace = false}) {
    if (!text.contains('%') && !(plusAsSpace && text.contains('+'))) return text;
    final bytes = <int>[];
    final src = <int>[];
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x25) {
        if (i + 2 >= text.length) {
          final seq = text.substring(i);
          throw InputError(
            'Incomplete percent sequence "$seq"',
            offset: i,
            source: text,
            hint: '"%" must be followed by two hex digits, e.g. %20. Encode a literal percent sign as %25.',
          );
        }
        final a = text.codeUnitAt(i + 1), b = text.codeUnitAt(i + 2);
        if (!_hex(a) || !_hex(b)) {
          throw InputError(
            'Malformed percent sequence "${text.substring(i, i + 3)}"',
            offset: i,
            source: text,
            hint: '"%" must be followed by two hex digits (0-9, A-F). Encode a literal percent sign as %25.',
          );
        }
        bytes.add(_hexValue(a) * 16 + _hexValue(b));
        src.add(i);
        i += 2;
      } else if (c == 0x2B && plusAsSpace) {
        bytes.add(0x20);
        src.add(i);
      } else if (c < 0x80) {
        bytes.add(c);
        src.add(i);
      } else {
        var end = i + 1;
        if (c >= 0xD800 && c <= 0xDBFF && end < text.length) {
          final lo = text.codeUnitAt(end);
          if (lo >= 0xDC00 && lo <= 0xDFFF) end++;
        }
        for (final b in utf8.encode(text.substring(i, end))) {
          bytes.add(b);
          src.add(i);
        }
        i = end - 1;
      }
    }
    final bad = firstInvalidUtf8(bytes);
    if (bad != null) {
      final at = src[bad];
      throw InputError(
        'Percent-decoded bytes are not valid UTF-8 (byte ${hexBytes([bytes[bad]])})',
        offset: at,
        source: text,
        hint: 'The text may use a legacy encoding such as Latin-1 (for example %E9 for "é" instead of %C3%A9).',
      );
    }
    return utf8.decode(bytes);
  }

  static const Map<String, int> defaultPorts = {'http': 80, 'https': 443, 'ws': 80, 'wss': 443, 'ftp': 21};

  /// Strict character checks that `Uri.parse` does not do (it accepts
  /// spaces and malformed escapes).
  static void checkUrlSyntax(String url) {
    for (var i = 0; i < url.length; i++) {
      final c = url.codeUnitAt(i);
      if (c <= 0x20 || c == 0x7F) {
        throw InputError(
          'URLs cannot contain ${describeCharAt(url, i)}',
          offset: i,
          source: url,
          hint: c == 0x20 ? 'Encode spaces as %20 (or + inside a form-encoded query).' : null,
        );
      }
      if (c == 0x25) {
        if (i + 2 >= url.length || !_hex(url.codeUnitAt(i + 1)) || !_hex(url.codeUnitAt(i + 2))) {
          final end = i + 3 > url.length ? url.length : i + 3;
          throw InputError(
            'Malformed percent sequence "${url.substring(i, end)}"',
            offset: i,
            source: url,
            hint: 'Encode a literal percent sign as %25.',
          );
        }
      }
      if (c == 0x22 ||
          c == 0x3C ||
          c == 0x3E ||
          c == 0x5C ||
          c == 0x5E ||
          c == 0x60 ||
          c == 0x7B ||
          c == 0x7C ||
          c == 0x7D) {
        throw InputError('Character ${describeCharAt(url, i)} must be percent-encoded', offset: i, source: url);
      }
    }
  }

  /// Parses a query string (without `?`) preserving order and duplicates.
  static List<QueryParam> parseQuery(String raw) {
    final out = <QueryParam>[];
    if (raw.isEmpty) return out;
    for (final piece in raw.split('&')) {
      if (piece.isEmpty) continue;
      final eq = piece.indexOf('=');
      final rn = eq < 0 ? piece : piece.substring(0, eq);
      final rv = eq < 0 ? null : piece.substring(eq + 1);
      String name = rn;
      String? value = rv;
      String? error;
      try {
        name = decode(rn, plusAsSpace: true);
        value = rv == null ? null : decode(rv, plusAsSpace: true);
      } on InputError catch (e) {
        error = e.message;
      }
      out.add(QueryParam(rawName: rn, rawValue: rv, name: name, value: value, error: error));
    }
    return out;
  }

  /// Splits a URL into its parts, decoding path segments, query parameters
  /// and the fragment. Throws [InputError] for unparseable URLs.
  static UrlInspection inspect(String input) {
    final url = input.trim();
    if (url.isEmpty) throw const InputError('Enter a URL to inspect');
    final lead = input.indexOf(url);
    try {
      checkUrlSyntax(url);
    } on InputError catch (e) {
      throw InputError(e.message, offset: (e.offset ?? 0) + lead, source: input, hint: e.hint);
    }
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException catch (e) {
      throw InputError(e.message, offset: e.offset == null ? null : e.offset! + lead, source: input);
    }
    final warnings = <String>[];
    if (!uri.hasScheme) warnings.add('No scheme: this is a relative reference, not an absolute URL.');
    if (uri.hasScheme && uri.host.isEmpty && (uri.scheme == 'http' || uri.scheme == 'https')) {
      warnings.add('${uri.scheme} URL without a host.');
    }
    if (uri.userInfo.contains(':')) {
      warnings.add('The URL contains a password in the user-info part. Avoid sharing it.');
    }
    final segments = <String>[];
    final rawSegments = uri.path.split('/').where((s) => s.isNotEmpty);
    for (final s in rawSegments) {
      try {
        segments.add(decode(s));
      } on InputError catch (e) {
        segments.add(s);
        warnings.add('Path segment "$s": ${e.message}');
      }
    }
    String? fragment;
    if (uri.hasFragment) {
      try {
        fragment = decode(uri.fragment);
      } on InputError catch (e) {
        fragment = uri.fragment;
        warnings.add('Fragment: ${e.message}');
      }
    }
    final query = parseQuery(uri.query);
    for (final q in query) {
      if (q.error != null) warnings.add('Query parameter "${q.rawName}": ${q.error}');
    }
    final defaultPort = defaultPorts[uri.scheme];
    final int? port = uri.hasPort ? uri.port : defaultPort;
    String userInfo = uri.userInfo;
    try {
      userInfo = decode(uri.userInfo);
    } on InputError {
      // keep raw
    }
    return UrlInspection(
      uri: uri,
      scheme: uri.scheme,
      userInfo: userInfo,
      host: uri.host,
      port: port,
      portIsDefault: !uri.hasPort && defaultPort != null,
      path: uri.path,
      segments: segments,
      query: query,
      rawQuery: uri.query,
      fragment: fragment,
      warnings: warnings,
    );
  }
}
