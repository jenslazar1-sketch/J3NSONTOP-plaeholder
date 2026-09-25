import 'dart:convert';

import '../../../core/utils/safe_path.dart';

/// Name rules shared by rename, new folder and batch rename. Names must be
/// valid on every delivered platform (Windows is the strictest), so a
/// workspace stays portable when exported or moved.
abstract final class FileNames {
  /// Most file systems limit a single name to 255 bytes/UTF-16 units.
  static const int maxNameBytes = 255;

  /// Returns a readable reason when [name] is not a valid single file or
  /// folder name, otherwise null.
  static String? validate(String name) {
    if (name.isEmpty) return 'Name is empty';
    if (name.trim().isEmpty) return 'Name is only whitespace';
    if (name == '.' || name == '..') return '"$name" is reserved';
    if (name.contains('/') || name.contains('\\')) return 'Name must not contain / or \\';
    if (utf8.encode(name).length > maxNameBytes) return 'Name is longer than $maxNameBytes bytes';
    if (name.startsWith(' ')) return 'Name must not start with a space';
    final sanitized = SafePath.sanitizeFileName(name, fallback: '');
    if (sanitized != name) {
      final bad = <String>{
        for (final ch in name.split(''))
          if (RegExp(r'[<>:"|?*\x00-\x1F]').hasMatch(ch)) ch.codeUnitAt(0) < 32 ? 'control character' : '"$ch"',
      };
      if (bad.isNotEmpty) return 'Not allowed on Windows: ${bad.join(', ')}';
      if (name.endsWith('.') || name.endsWith(' ')) return 'Name must not end with a dot or space';
    }
    try {
      SafePath.normalizeRelative(name);
    } on UnsafePathException catch (e) {
      return _capitalize(e.reason);
    }
    return null;
  }

  static String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// Splits `name.ext` into (stem, extension-with-dot). Dotfiles like
  /// `.gitignore` have no extension; `a.tar.gz` -> (`a.tar`, `.gz`).
  static (String stem, String ext) split(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return (name, '');
    return (name.substring(0, dot), name.substring(dot));
  }

  /// Natural ordering: `img2` < `img10`, case-insensitive with a stable
  /// case-sensitive tie break.
  static int compareNatural(String a, String b) {
    final la = a.toLowerCase();
    final lb = b.toLowerCase();
    var i = 0, j = 0;
    while (i < la.length && j < lb.length) {
      final ca = la.codeUnitAt(i);
      final cb = lb.codeUnitAt(j);
      if (_isDigit(ca) && _isDigit(cb)) {
        var ei = i, ej = j;
        while (ei < la.length && _isDigit(la.codeUnitAt(ei))) {
          ei++;
        }
        while (ej < lb.length && _isDigit(lb.codeUnitAt(ej))) {
          ej++;
        }
        final na = la.substring(i, ei).replaceFirst(RegExp('^0+(?=.)'), '');
        final nb = lb.substring(j, ej).replaceFirst(RegExp('^0+(?=.)'), '');
        if (na.length != nb.length) return na.length - nb.length;
        final c = na.compareTo(nb);
        if (c != 0) return c;
        final lenDiff = (ei - i) - (ej - j);
        if (lenDiff != 0) return lenDiff;
        i = ei;
        j = ej;
      } else {
        if (ca != cb) return ca - cb;
        i++;
        j++;
      }
    }
    final rem = (la.length - i) - (lb.length - j);
    if (rem != 0) return rem;
    return a.compareTo(b);
  }

  static bool _isDigit(int c) => c >= 48 && c <= 57;
}
