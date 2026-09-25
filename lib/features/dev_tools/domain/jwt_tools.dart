import 'dart:convert';

import 'base64_tools.dart';
import 'common.dart';

enum JwtTimeStatus { valid, expired, notYetValid, noTimeClaims }

/// A time claim (`exp`, `iat`, `nbf`) decoded to a date.
class JwtTimeClaim {
  const JwtTimeClaim(this.name, this.label, this.seconds, this.time);
  final String name;
  final String label;
  final num seconds;
  final DateTime time;
}

class JwtDecoded {
  const JwtDecoded({
    required this.header,
    required this.payload,
    required this.headerJson,
    required this.payloadJson,
    required this.signature,
    required this.signatureBytes,
    required this.timeClaims,
    required this.warnings,
    required this.hadBearerPrefix,
  });

  final Map<String, Object?> header;

  /// Null for encrypted tokens (JWE), whose payload cannot be read.
  final Map<String, Object?>? payload;
  final String headerJson;
  final String? payloadJson;

  /// Base64URL signature text (empty for `alg: none`).
  final String signature;
  final int signatureBytes;
  final List<JwtTimeClaim> timeClaims;
  final List<String> warnings;
  final bool hadBearerPrefix;

  String? get algorithm => header['alg'] is String ? header['alg'] as String : null;
  bool get isEncrypted => payload == null;

  JwtTimeClaim? claim(String name) {
    for (final c in timeClaims) {
      if (c.name == name) return c;
    }
    return null;
  }

  JwtTimeStatus statusAt(DateTime now) {
    final exp = claim('exp'), nbf = claim('nbf');
    if (exp == null && nbf == null) return JwtTimeStatus.noTimeClaims;
    if (exp != null && !now.isBefore(exp.time)) return JwtTimeStatus.expired;
    if (nbf != null && now.isBefore(nbf.time)) return JwtTimeStatus.notYetValid;
    return JwtTimeStatus.valid;
  }
}

/// Decodes (never verifies) JSON Web Tokens.
abstract final class JwtTools {
  static const _pretty = JsonEncoder.withIndent('  ');

  static const Map<String, String> claimNames = {
    'iss': 'Issuer',
    'sub': 'Subject',
    'aud': 'Audience',
    'exp': 'Expires',
    'nbf': 'Not before',
    'iat': 'Issued at',
    'jti': 'Token ID',
    'scope': 'Scope',
    'azp': 'Authorized party',
    'name': 'Name',
    'email': 'Email',
  };

  static JwtDecoded decode(String input) {
    var s = input.trim();
    var bearer = false;
    var base = input.indexOf(s);
    if (s.toLowerCase().startsWith('bearer ')) {
      bearer = true;
      final rest = s.substring(7).trimLeft();
      base += s.length - rest.length;
      s = rest;
    }
    if (s.isEmpty) throw const InputError('Paste a JWT (three Base64URL parts separated by dots)');
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c <= 0x20) {
        throw InputError('Tokens cannot contain ${describeCharAt(s, i)}', offset: base + i, source: input);
      }
    }
    final parts = s.split('.');
    if (parts.length != 3 && parts.length != 5) {
      throw InputError(
        'Expected 3 parts (header.payload.signature) but found ${parts.length}',
        hint: parts.length == 1 ? 'This does not look like a JWT: there are no dots.' : null,
      );
    }
    final starts = <int>[];
    var at = base;
    for (final p in parts) {
      starts.add(at);
      at += p.length + 1;
    }

    Map<String, Object?> jsonPart(int index, String name) {
      final text = parts[index];
      if (text.isEmpty) throw InputError('The $name part is empty', offset: starts[index], source: input);
      final Base64Decoded d;
      try {
        d = Base64Tools.decode(text);
      } on InputError catch (e) {
        throw InputError(
          '$name: ${e.message}',
          offset: e.offset == null ? starts[index] : starts[index] + e.offset!,
          source: input,
        );
      }
      final str = d.text;
      if (str == null) {
        throw InputError('$name is not valid UTF-8 text', offset: starts[index], source: input);
      }
      final Object? json;
      try {
        json = jsonDecode(str);
      } on FormatException catch (e) {
        throw InputError('$name is not valid JSON: ${e.message}', offset: starts[index], source: input);
      }
      if (json is! Map<String, Object?>) {
        throw InputError('$name must be a JSON object', offset: starts[index], source: input);
      }
      return json;
    }

    final header = jsonPart(0, 'Header');
    final warnings = <String>[];
    if (parts.length == 5) {
      warnings.add('Encrypted token (JWE, 5 parts): the payload cannot be decoded without the key.');
      return JwtDecoded(
        header: header,
        payload: null,
        headerJson: _pretty.convert(header),
        payloadJson: null,
        signature: '',
        signatureBytes: 0,
        timeClaims: const [],
        warnings: warnings,
        hadBearerPrefix: bearer,
      );
    }
    final payload = jsonPart(1, 'Payload');
    final alg = header['alg'];
    if (alg is String && alg.toLowerCase() == 'none') {
      warnings.add('alg is "none": the token is unsigned and must never be trusted.');
    }
    if (alg == null) warnings.add('The header has no "alg" field.');
    var sigBytes = 0;
    if (parts[2].isNotEmpty) {
      try {
        sigBytes = Base64Tools.decode(parts[2]).bytes.length;
      } on InputError catch (e) {
        warnings.add('Signature is not valid Base64URL: ${e.message}');
      }
    } else if (alg is String && alg.toLowerCase() != 'none') {
      warnings.add('The signature part is empty although alg is "$alg".');
    }
    final claims = <JwtTimeClaim>[];
    for (final (name, label) in [('iat', 'Issued at'), ('nbf', 'Not before'), ('exp', 'Expires')]) {
      final v = payload[name];
      if (v == null) continue;
      if (v is! num || !v.isFinite) {
        warnings.add('"$name" should be a number of seconds (NumericDate) but is ${jsonEncode(v)}.');
        continue;
      }
      final ms = (v * 1000).round();
      if (ms.abs() > 8640000000000000) {
        warnings.add('"$name" is outside the representable date range.');
        continue;
      }
      if (v > 100000000000) {
        warnings.add('"$name" looks like milliseconds; JWT NumericDate values are seconds.');
      }
      claims.add(JwtTimeClaim(name, label, v, DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)));
    }
    return JwtDecoded(
      header: header,
      payload: payload,
      headerJson: _pretty.convert(header),
      payloadJson: _pretty.convert(payload),
      signature: parts[2],
      signatureBytes: sigBytes,
      timeClaims: claims,
      warnings: warnings,
      hadBearerPrefix: bearer,
    );
  }
}
