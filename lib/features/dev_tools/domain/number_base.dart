import 'dart:typed_data';

import 'common.dart';

/// A parsed integer and how it was read.
class ParsedNumber {
  const ParsedNumber(this.value, this.base, {this.prefix});
  final BigInt value;
  final int base;

  /// `0x`, `0b` or `0o` when a prefix was recognised.
  final String? prefix;
}

/// How [value] looks in a fixed-width two's complement register.
class WidthView {
  const WidthView({
    required this.bits,
    required this.pattern,
    required this.signed,
    required this.fitsUnsigned,
    required this.fitsSigned,
  });

  final int bits;

  /// The low [bits] bits of the value (two's complement for negatives).
  final BigInt pattern;

  /// [pattern] read as a signed integer.
  final BigInt signed;
  final bool fitsUnsigned;
  final bool fitsSigned;

  bool get overflows => !fitsUnsigned && !fitsSigned;

  /// Big-endian bytes of [pattern].
  List<int> get bytesBigEndian {
    final n = bits ~/ 8;
    final out = List<int>.filled(n, 0);
    var p = pattern;
    final mask = BigInt.from(0xFF);
    for (var i = n - 1; i >= 0; i--) {
      out[i] = (p & mask).toInt();
      p = p >> 8;
    }
    return out;
  }

  List<int> get bytesLittleEndian => bytesBigEndian.reversed.toList();

  /// IEEE 754 interpretation of the bit pattern (32/64-bit only).
  double? get asFloat {
    if (bits != 32 && bits != 64) return null;
    final bd = ByteData(bits ~/ 8);
    final be = bytesBigEndian;
    for (var i = 0; i < be.length; i++) {
      bd.setUint8(i, be[i]);
    }
    return bits == 32 ? bd.getFloat32(0) : bd.getFloat64(0);
  }
}

abstract final class NumberBase {
  static const int maxDigits = 4096;
  static const List<int> widths = [8, 16, 32, 64, 128];

  static int _digitValue(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30;
    final l = c | 0x20;
    if (l >= 0x61 && l <= 0x7A) return l - 0x61 + 10;
    return -1;
  }

  /// Parses [input] in [base] (2-36), or auto-detects `0x`/`0b`/`0o`
  /// prefixes (decimal otherwise) when [base] is null. Accepts a sign and
  /// `_`/space digit separators. Throws [InputError] at the offending
  /// character.
  static ParsedNumber parse(String input, int? base) {
    if (base != null && (base < 2 || base > 36)) {
      throw InputError('Base must be between 2 and 36 (got $base)');
    }
    var i = 0;
    var end = input.length;
    while (i < end && input.codeUnitAt(i) <= 0x20) {
      i++;
    }
    while (end > i && input.codeUnitAt(end - 1) <= 0x20) {
      end--;
    }
    if (i == end) throw const InputError('Enter a number');
    var negative = false;
    if (input[i] == '-' || input[i] == '+') {
      negative = input[i] == '-';
      i++;
    }
    String? prefix;
    var effective = base;
    if (i + 1 < end && input[i] == '0') {
      final p = input[i + 1].toLowerCase();
      final pb = switch (p) {
        'x' => 16,
        'b' => 2,
        'o' => 8,
        _ => null,
      };
      // "0b" is ambiguous in base 16 (0b = 11): only a prefix when it fits.
      if (pb != null && (base == null || base == pb)) {
        prefix = '0$p';
        effective = pb;
        i += 2;
      }
    }
    final radix = effective ?? 10;
    final digits = StringBuffer();
    for (var k = i; k < end; k++) {
      final c = input.codeUnitAt(k);
      if (c == 0x5F || c == 0x20) continue;
      final v = _digitValue(c);
      if (v < 0 || v >= radix) {
        throw InputError(
          'Invalid base-$radix digit ${describeCharAt(input, k)}',
          offset: k,
          source: input,
          hint: radix <= 10
              ? 'Base $radix uses the digits 0-${radix - 1}.'
              : 'Base $radix uses 0-9 and A-${String.fromCharCode(0x41 + radix - 11)}.',
        );
      }
      digits.writeCharCode(c);
    }
    if (digits.isEmpty) throw InputError('Expected digits', offset: end, source: input);
    if (digits.length > maxDigits) throw InputError('Too many digits (limit $maxDigits)');
    var value = BigInt.parse(digits.toString(), radix: radix);
    if (negative) value = -value;
    return ParsedNumber(value, radix, prefix: prefix);
  }

  /// Formats [v] in [base]; [group] > 0 inserts a space every [group]
  /// digits from the right.
  static String format(BigInt v, int base, {bool upper = true, int group = 0}) {
    var s = v.abs().toRadixString(base);
    if (upper) s = s.toUpperCase();
    if (group > 0 && s.length > group) {
      final b = StringBuffer();
      final first = s.length % group;
      if (first > 0) b.write(s.substring(0, first));
      for (var k = first; k < s.length; k += group) {
        if (b.isNotEmpty) b.write(' ');
        b.write(s.substring(k, k + group));
      }
      s = b.toString();
    }
    return v.isNegative ? '-$s' : s;
  }

  /// Fixed-width view of [v] for [bits] (a multiple of 8).
  static WidthView view(BigInt v, int bits) {
    final mod = BigInt.one << bits;
    final half = BigInt.one << (bits - 1);
    final pattern = v % mod; // Euclidean: always 0..mod-1
    final signed = pattern >= half ? pattern - mod : pattern;
    return WidthView(
      bits: bits,
      pattern: pattern,
      signed: signed,
      fitsUnsigned: !v.isNegative && v < mod,
      fitsSigned: v >= -half && v < half,
    );
  }

  /// Smallest standard width that holds [v] (signed or unsigned), or null.
  static int? smallestWidth(BigInt v) {
    for (final w in widths) {
      final x = view(v, w);
      if (x.fitsSigned || x.fitsUnsigned) return w;
    }
    return null;
  }
}
