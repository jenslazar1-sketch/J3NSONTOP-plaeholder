import 'dart:io';

import 'package:path/path.dart' as p;

/// Why a relative path was rejected.
class UnsafePathException implements Exception {
  const UnsafePathException(this.path, this.reason);
  final String path;
  final String reason;
  @override
  String toString() => 'Unsafe path "$path": $reason';
}

/// Path validation shared by archive extraction, mod packages and batch
/// operations. All archive/manifest paths are treated as untrusted input.
abstract final class SafePath {
  static final RegExp _drive = RegExp(r'^[a-zA-Z]:');

  /// Windows reserved device names (checked case-insensitively, with or
  /// without extension).
  static const Set<String> _reserved = {
    'con', 'prn', 'aux', 'nul', //
    'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
    'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
  };

  /// Normalises an untrusted relative path to forward-slash form and
  /// validates it. Rejects absolute paths, drive letters, UNC paths,
  /// `..` traversal, empty segments, NUL/control characters, Windows
  /// reserved names and trailing dots/spaces.
  static String normalizeRelative(String raw) {
    if (raw.isEmpty) throw UnsafePathException(raw, 'empty path');
    if (raw.contains('\u0000')) {
      throw UnsafePathException(raw, 'contains NUL byte');
    }
    final unified = raw.replaceAll('\\', '/');
    if (unified.startsWith('/')) {
      throw UnsafePathException(raw, 'absolute path');
    }
    if (_drive.hasMatch(unified)) {
      throw UnsafePathException(raw, 'drive-qualified path');
    }
    final parts = <String>[];
    for (final seg in unified.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        throw UnsafePathException(raw, 'parent-directory traversal');
      }
      if (seg.codeUnits.any((c) => c < 32)) {
        throw UnsafePathException(raw, 'control character in name');
      }
      if (RegExp(r'[<>:"|?*]').hasMatch(seg)) {
        throw UnsafePathException(raw, 'character not allowed on Windows');
      }
      if (seg.endsWith('.') || seg.endsWith(' ')) {
        throw UnsafePathException(raw, 'name ends with dot or space');
      }
      final stem = seg.split('.').first.toLowerCase();
      if (_reserved.contains(stem)) {
        throw UnsafePathException(raw, 'reserved device name "$seg"');
      }
      parts.add(seg);
    }
    if (parts.isEmpty) throw UnsafePathException(raw, 'empty path');
    return parts.join('/');
  }

  /// Case-folded key for duplicate/collision detection (Windows and default
  /// macOS filesystems are case-insensitive).
  static String collisionKey(String relative) =>
      relative.replaceAll('\\', '/').toLowerCase();

  /// Returns true when [candidate] is [root] or inside it (lexically).
  static bool isWithin(String root, String candidate) {
    final r = p.normalize(p.absolute(root));
    final c = p.normalize(p.absolute(candidate));
    return r == c || p.isWithin(r, c);
  }

  /// Joins [root] with a validated relative path and verifies the result
  /// stays inside [root], including after resolving symbolic links of the
  /// existing parent directories (prevents symlink escapes).
  static String resolveInside(String root, String relative) {
    final rel = normalizeRelative(relative);
    final joined = p.normalize(p.join(root, rel));
    if (!isWithin(root, joined)) {
      throw UnsafePathException(relative, 'resolves outside the target');
    }
    final realRoot = _realPathOfExisting(root);
    final realParent = _realPathOfExisting(p.dirname(joined));
    if (!isWithin(realRoot, realParent)) {
      throw UnsafePathException(
        relative,
        'a parent directory is a link that points outside the target',
      );
    }
    final existing = Link(joined);
    if (existing.existsSync()) {
      throw UnsafePathException(relative, 'target is a symbolic link');
    }
    return joined;
  }

  /// Resolves the deepest existing ancestor of [path] through symlinks and
  /// re-appends the non-existing remainder.
  static String _realPathOfExisting(String path) {
    var current = p.normalize(p.absolute(path));
    final tail = <String>[];
    while (true) {
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        final resolved = Directory(current).resolveSymbolicLinksSync();
        return tail.isEmpty ? resolved : p.joinAll([resolved, ...tail.reversed]);
      }
      final parent = p.dirname(current);
      if (parent == current) return p.normalize(p.absolute(path));
      tail.add(p.basename(current));
      current = parent;
    }
  }

  /// Makes a user-entered file name safe for all target filesystems.
  static String sanitizeFileName(String name, {String fallback = 'file'}) {
    var s = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    while (s.endsWith('.') || s.endsWith(' ')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.isEmpty) return fallback;
    if (_reserved.contains(s.split('.').first.toLowerCase())) s = '_$s';
    return s;
  }

  /// Returns a path that does not exist yet by appending ` (2)`, ` (3)`...
  static String uniquePath(String desired) {
    if (FileSystemEntity.typeSync(desired) == FileSystemEntityType.notFound) {
      return desired;
    }
    final dir = p.dirname(desired);
    final ext = p.extension(desired);
    final stem = p.basenameWithoutExtension(desired);
    for (var i = 2; i < 10000; i++) {
      final candidate = p.join(dir, '$stem ($i)$ext');
      if (FileSystemEntity.typeSync(candidate) ==
          FileSystemEntityType.notFound) {
        return candidate;
      }
    }
    throw StateError('Could not find a free name for $desired');
  }
}
