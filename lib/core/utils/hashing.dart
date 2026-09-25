import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import '../tasks/cancellation.dart';

enum HashAlgorithm {
  sha256('SHA-256'),
  sha1('SHA-1'),
  sha512('SHA-512'),
  md5('MD5');

  const HashAlgorithm(this.label);
  final String label;

  crypto.Hash get _hash => switch (this) {
    HashAlgorithm.sha256 => crypto.sha256,
    HashAlgorithm.sha1 => crypto.sha1,
    HashAlgorithm.sha512 => crypto.sha512,
    HashAlgorithm.md5 => crypto.md5,
  };

  /// MD5 and SHA-1 are offered for compatibility with published checksums
  /// only; they are not collision resistant.
  bool get isLegacy => this == md5 || this == sha1;

  static HashAlgorithm? parse(String s) {
    final n = s.toLowerCase().replaceAll('-', '');
    for (final a in values) {
      if (a.name == n) return a;
    }
    return null;
  }
}

abstract final class Hashing {
  static String text(String input, [HashAlgorithm algo = HashAlgorithm.sha256]) =>
      algo._hash.convert(utf8.encode(input)).toString();

  static String bytes(List<int> input, [HashAlgorithm algo = HashAlgorithm.sha256]) =>
      algo._hash.convert(input).toString();

  /// Streams a file through the hash in chunks so large files never load
  /// fully into memory. Reports progress and honours cancellation.
  static Future<String> file(
    String path, {
    HashAlgorithm algo = HashAlgorithm.sha256,
    CancellationToken? token,
    ProgressCallback? onProgress,
  }) async {
    final f = File(path);
    final total = await f.length();
    var done = 0;
    var lastReport = 0;
    final output = _DigestSink();
    final input = algo._hash.startChunkedConversion(output);
    await for (final chunk in f.openRead()) {
      token?.throwIfCancelled();
      input.add(chunk);
      done += chunk.length;
      if (onProgress != null && total > 0 && done - lastReport > 1 << 20) {
        lastReport = done;
        onProgress(done / total, null);
      }
    }
    input.close();
    onProgress?.call(1, null);
    return output.value.toString();
  }

  /// Constant-format comparison of hex digests (case-insensitive, trims
  /// whitespace and an optional `algo:` prefix).
  static bool digestsEqual(String a, String b) {
    String clean(String s) {
      var t = s.trim().toLowerCase();
      final colon = t.indexOf(':');
      if (colon >= 0 && colon < 8) t = t.substring(colon + 1);
      return t.replaceAll(RegExp(r'\s'), '');
    }

    return clean(a) == clean(b) && clean(a).isNotEmpty;
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}
