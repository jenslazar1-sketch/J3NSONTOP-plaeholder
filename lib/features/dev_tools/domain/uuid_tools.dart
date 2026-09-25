import 'dart:math';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'common.dart';

enum UuidKind {
  v4('v4 random'),
  v7('v7 time-ordered');

  const UuidKind(this.label);
  final String label;
}

/// Output formatting for generated UUIDs.
class UuidFormat {
  const UuidFormat({this.uppercase = false, this.hyphens = true, this.braces = false});
  final bool uppercase;
  final bool hyphens;
  final bool braces;

  String apply(String canonical) {
    var s = hyphens ? canonical : canonical.replaceAll('-', '');
    if (uppercase) s = s.toUpperCase();
    return braces ? '{$s}' : s;
  }
}

enum UuidVariant {
  ncs('NCS (reserved, backward compatibility)'),
  rfc('RFC 9562 / RFC 4122 (OSF DCE)'),
  microsoft('Microsoft (reserved, legacy GUID)'),
  future('Reserved for future definition');

  const UuidVariant(this.label);
  final String label;
}

/// What an UUID string contains.
class UuidInfo {
  const UuidInfo({
    required this.canonical,
    required this.bytes,
    required this.version,
    required this.variant,
    required this.isNil,
    required this.isMax,
    this.timestamp,
    this.timestampNote,
    this.notes = const [],
  });

  final String canonical;
  final Uint8List bytes;

  /// Version nibble (0-15). Only meaningful for the RFC variant.
  final int version;
  final UuidVariant variant;
  final bool isNil;
  final bool isMax;

  /// Embedded creation time (v1, v6, v7), UTC.
  final DateTime? timestamp;
  final String? timestampNote;
  final List<String> notes;

  String get versionName {
    if (isNil) return 'Nil UUID (all zero)';
    if (isMax) return 'Max UUID (all ones)';
    if (variant != UuidVariant.rfc) return 'n/a (non-RFC variant)';
    return switch (version) {
      1 => 'v1 - time-based (Gregorian, MAC/node)',
      2 => 'v2 - DCE security',
      3 => 'v3 - name-based (MD5)',
      4 => 'v4 - random',
      5 => 'v5 - name-based (SHA-1)',
      6 => 'v6 - reordered time-based',
      7 => 'v7 - Unix epoch time-ordered',
      8 => 'v8 - custom / vendor-specific',
      _ => 'v$version - unknown/unassigned version',
    };
  }

  bool get isStandard => isNil || isMax || (variant == UuidVariant.rfc && version >= 1 && version <= 8);
}

abstract final class UuidTools {
  static const int maxCount = 1000;
  static final Random _secure = Random.secure();

  /// Generates [count] UUIDs. v4 uses a cryptographically secure RNG (via
  /// package:uuid). v7 embeds the current Unix time in milliseconds and uses
  /// the 12-bit `rand_a` field as a counter so a batch is strictly
  /// increasing (RFC 9562, section 6.2, method 1).
  static List<String> generate(
    UuidKind kind,
    int count, {
    UuidFormat format = const UuidFormat(),
    DateTime Function()? clock,
    Random? random,
  }) {
    if (count < 1 || count > maxCount) {
      throw InputError('Count must be between 1 and $maxCount (got $count)');
    }
    final rng = random ?? _secure;
    final out = <String>[];
    switch (kind) {
      case UuidKind.v4:
        const uuid = Uuid();
        for (var i = 0; i < count; i++) {
          out.add(format.apply(random == null ? uuid.v4() : _v4With(rng)));
        }
      case UuidKind.v7:
        var ms = (clock ?? DateTime.now)().toUtc().millisecondsSinceEpoch;
        var counter = rng.nextInt(0x800);
        for (var i = 0; i < count; i++) {
          if (counter > 0xFFF) {
            ms++;
            counter = rng.nextInt(0x800);
          }
          out.add(format.apply(v7Canonical(ms, counter, rng)));
          counter++;
        }
    }
    return out;
  }

  static String _v4With(Random rng) {
    final b = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      b[i] = rng.nextInt(256);
    }
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    return Uuid.unparse(b);
  }

  /// Builds a v7 UUID from a millisecond timestamp and a 12-bit counter.
  static String v7Canonical(int ms, int counter, Random rng) {
    final b = Uint8List(16);
    for (var i = 0; i < 6; i++) {
      b[i] = (ms >> (8 * (5 - i))) & 0xFF;
    }
    b[6] = 0x70 | ((counter >> 8) & 0x0F);
    b[7] = counter & 0xFF;
    b[8] = 0x80 | rng.nextInt(0x40);
    for (var i = 9; i < 16; i++) {
      b[i] = rng.nextInt(256);
    }
    return Uuid.unparse(b);
  }

  static bool _hex(int c) => (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);

  /// Parses and explains a UUID. Accepts canonical form, uppercase, no
  /// hyphens, `{braces}` and a `urn:uuid:` prefix. Throws [InputError] with
  /// the position of the first problem.
  static UuidInfo inspect(String input) {
    var start = 0;
    var end = input.length;
    while (start < end && input.codeUnitAt(start) <= 0x20) {
      start++;
    }
    while (end > start && input.codeUnitAt(end - 1) <= 0x20) {
      end--;
    }
    if (start == end) throw const InputError('Enter a UUID to inspect');
    final notes = <String>[];
    if (input.substring(start, end).toLowerCase().startsWith('urn:uuid:')) {
      start += 9;
      notes.add('URN form (urn:uuid:...)');
    }
    if (start < end && input.codeUnitAt(start) == 0x7B) {
      if (input.codeUnitAt(end - 1) != 0x7D) {
        throw InputError('Opening "{" without a closing "}"', offset: start, source: input);
      }
      start++;
      end--;
      notes.add('Braced (Microsoft GUID style)');
    }
    final hex = StringBuffer();
    final hyphenAt = <int>[];
    for (var i = start; i < end; i++) {
      final c = input.codeUnitAt(i);
      if (c == 0x2D) {
        hyphenAt.add(hex.length);
        continue;
      }
      if (!_hex(c)) {
        throw InputError(
          'Invalid character ${describeCharAt(input, i)} (UUIDs contain only hex digits 0-9, a-f and hyphens)',
          offset: i,
          source: input,
        );
      }
      if (hex.length == 32) {
        throw InputError('Too long: more than 32 hex digits', offset: i, source: input);
      }
      hex.writeCharCode(c);
    }
    if (hex.length != 32) {
      throw InputError('Too short: expected 32 hex digits, found ${hex.length}', offset: end, source: input);
    }
    if (hyphenAt.isNotEmpty && !(hyphenAt.length == 4 && hyphenAt.join(',') == '8,12,16,20')) {
      throw InputError(
        'Hyphens are not in the 8-4-4-4-12 positions',
        offset: start,
        source: input,
        hint: 'Canonical form: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',
      );
    }
    if (hyphenAt.isEmpty) notes.add('Written without hyphens');
    final h = hex.toString().toLowerCase();
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    final canonical =
        '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
    final isNil = bytes.every((b) => b == 0);
    final isMax = bytes.every((b) => b == 0xFF);
    final v = bytes[8];
    final variant = (v & 0x80) == 0
        ? UuidVariant.ncs
        : (v & 0xC0) == 0x80
        ? UuidVariant.rfc
        : (v & 0xE0) == 0xC0
        ? UuidVariant.microsoft
        : UuidVariant.future;
    final version = bytes[6] >> 4;
    DateTime? ts;
    String? tsNote;
    if (!isNil && !isMax && variant == UuidVariant.rfc) {
      switch (version) {
        case 7:
          var ms = 0;
          for (var i = 0; i < 6; i++) {
            ms = (ms << 8) | bytes[i];
          }
          ts = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
          tsNote = '48-bit Unix time in milliseconds';
        case 1:
          final low = _int(bytes, 0, 4), mid = _int(bytes, 4, 2), hi = _int(bytes, 6, 2) & 0x0FFF;
          ts = _gregorian((hi << 48) | (mid << 32) | low);
          tsNote = '60-bit count of 100 ns intervals since 1582-10-15';
        case 6:
          final high = _int(bytes, 0, 4), mid = _int(bytes, 4, 2), low = _int(bytes, 6, 2) & 0x0FFF;
          ts = _gregorian((high << 28) | (mid << 12) | low);
          tsNote = '60-bit count of 100 ns intervals since 1582-10-15';
      }
    }
    return UuidInfo(
      canonical: canonical,
      bytes: bytes,
      version: version,
      variant: variant,
      isNil: isNil,
      isMax: isMax,
      timestamp: ts,
      timestampNote: tsNote,
      notes: notes,
    );
  }

  static int _int(Uint8List b, int at, int len) {
    var v = 0;
    for (var i = 0; i < len; i++) {
      v = (v << 8) | b[at + i];
    }
    return v;
  }

  /// 100 ns ticks since 1582-10-15 (Gregorian reform) to UTC DateTime.
  static DateTime _gregorian(int ticks) {
    const gregorianOffset = 0x01B21DD213814000; // ticks between 1582-10-15 and 1970-01-01
    return DateTime.fromMicrosecondsSinceEpoch((ticks - gregorianOffset) ~/ 10, isUtc: true);
  }
}
