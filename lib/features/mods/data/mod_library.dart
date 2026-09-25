import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/utils/hashing.dart';
import '../../../core/utils/safe_path.dart';
import '../domain/manifest.dart';
import '../domain/package_inspector.dart';

/// A package stored in a workspace library.
class LibraryEntry {
  const LibraryEntry({required this.path, required this.report, required this.modified, required this.sizeBytes});

  /// Absolute path of the `.j3mod` inside `<meta>/mods/`.
  final String path;
  final PackageReport report;
  final DateTime modified;
  final int sizeBytes;

  String get fileName => p.basename(path);
  ModManifest? get manifest => report.manifest;
  bool get isValid => report.isValid;
  String get id => report.displayId;
  String get name => report.displayName;
  String? get version => report.displayVersion;
}

/// Result of [ModLibrary.importPackage]. Replacing an existing package is
/// never silent: the caller gets [ImportNeedsReplace] and must call again
/// with `replace: true` after asking the user.
sealed class ImportOutcome {
  const ImportOutcome();
}

/// Validation failed; nothing was copied.
class ImportRejected extends ImportOutcome {
  const ImportRejected(this.report);
  final PackageReport report;
}

/// A package with the same id is already in the library.
class ImportNeedsReplace extends ImportOutcome {
  const ImportNeedsReplace({required this.existing, required this.incoming});
  final LibraryEntry existing;
  final PackageReport incoming;

  /// `upgrade`, `downgrade` or `same version` (for the confirmation text).
  String get direction {
    final a = existing.manifest?.version;
    final b = incoming.manifest?.version;
    if (a == null || b == null) return 'replace';
    final c = b.compareTo(a);
    return c > 0 ? 'upgrade' : (c < 0 ? 'downgrade' : 'same version, different content');
  }
}

/// The identical package is already in the library.
class ImportIdentical extends ImportOutcome {
  const ImportIdentical(this.existing);
  final LibraryEntry existing;
}

class ImportCompleted extends ImportOutcome {
  const ImportCompleted({required this.entry, this.replaced});
  final LibraryEntry entry;

  /// The entry that was replaced (its file is gone), if any.
  final LibraryEntry? replaced;
}

/// A workspace's mod library at `<meta>/mods/` holding one version per id
/// as `<id>-<version>.j3mod`. Reports are cached by path, size and mtime.
class ModLibrary {
  ModLibrary(this.metaDir, {Future<List<PackageReport>> Function(List<String> paths)? inspector})
    : _inspect = inspector ?? inspectPackagesInBackground;

  final String metaDir;
  final Future<List<PackageReport>> Function(List<String> paths) _inspect;

  static final Map<String, (int, DateTime, PackageReport)> _cache = {};

  String get dir => p.join(metaDir, 'mods');

  static String fileNameFor(ModManifest m) => SafePath.sanitizeFileName('${m.id}-${m.version}.j3mod');

  /// Lists the library (sorted by name). Unchanged files reuse cached
  /// reports; new or modified files are inspected in the background.
  Future<List<LibraryEntry>> list() async {
    final d = Directory(dir);
    if (!await d.exists()) return const [];
    final stats = <String, FileStat>{};
    await for (final e in d.list(followLinks: false)) {
      if (e is! File) continue;
      if (p.extension(e.path).toLowerCase() != '.j3mod') continue;
      stats[e.path] = await e.stat();
    }
    final stale = <String>[];
    for (final e in stats.entries) {
      final c = _cache[e.key];
      if (c == null || c.$1 != e.value.size || c.$2 != e.value.modified) stale.add(e.key);
    }
    if (stale.isNotEmpty) {
      final reports = await _inspect(stale);
      for (var i = 0; i < stale.length; i++) {
        final st = stats[stale[i]]!;
        _cache[stale[i]] = (st.size, st.modified, reports[i]);
      }
    }
    final entries = [
      for (final e in stats.entries)
        LibraryEntry(path: e.key, report: _cache[e.key]!.$3, modified: e.value.modified, sizeBytes: e.value.size),
    ];
    entries.sort((a, b) {
      final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return c != 0 ? c : a.fileName.compareTo(b.fileName);
    });
    return entries;
  }

  /// Valid manifests by id. When a folder holds several versions of one id
  /// (e.g. copied in by hand) the highest version is used.
  static Map<String, ModManifest> manifestsById(List<LibraryEntry> entries) {
    final out = <String, ModManifest>{};
    for (final e in entries) {
      final m = e.manifest;
      if (m == null) continue;
      final prior = out[m.id];
      if (prior == null || m.version > prior.version) out[m.id] = m;
    }
    return out;
  }

  /// Ids present in the library only as invalid packages.
  static Set<String> invalidIds(List<LibraryEntry> entries) {
    final valid = manifestsById(entries).keys.toSet();
    return {
      for (final e in entries)
        if (!e.isValid && !valid.contains(e.id)) e.id,
    };
  }

  /// The library entry that provides [id] (highest valid version).
  static LibraryEntry? entryFor(List<LibraryEntry> entries, String id) {
    LibraryEntry? best;
    for (final e in entries) {
      final m = e.manifest;
      if (m == null || m.id != id) continue;
      if (best == null || m.version > best.manifest!.version) best = e;
    }
    return best;
  }

  /// Validates [sourcePath] and copies it into the library.
  Future<ImportOutcome> importPackage(String sourcePath, {bool replace = false}) async {
    final report = (await _inspect([sourcePath])).single;
    if (!report.isValid) return ImportRejected(report);
    final manifest = report.manifest!;
    final current = await list();
    final existing = [
      for (final e in current)
        if (e.id == manifest.id) e,
    ];
    final sourceHash = await Hashing.file(sourcePath);
    for (final e in existing) {
      if (e.manifest?.version == manifest.version && await Hashing.file(e.path) == sourceHash) {
        return ImportIdentical(e);
      }
    }
    if (existing.isNotEmpty && !replace) {
      return ImportNeedsReplace(existing: existing.first, incoming: report);
    }

    await Directory(dir).create(recursive: true);
    final dest = p.join(dir, fileNameFor(manifest));
    final tmp = SafePath.uniquePath('$dest.importing');
    try {
      await File(sourcePath).copy(tmp);
      if (await Hashing.file(tmp) != sourceHash) {
        throw FileSystemException('Copy verification failed (hash mismatch)', tmp);
      }
      await File(tmp).rename(dest);
    } catch (_) {
      final t = File(tmp);
      if (await t.exists()) await t.delete();
      rethrow;
    }
    for (final e in existing) {
      if (!p.equals(e.path, dest)) await _deleteInside(e.path);
      _cache.remove(e.path);
    }
    _cache.remove(dest);
    final after = await list();
    final entry = after.firstWhere((e) => p.equals(e.path, dest));
    return ImportCompleted(entry: entry, replaced: existing.isEmpty ? null : existing.first);
  }

  /// Deletes a package file from the library.
  Future<void> remove(LibraryEntry entry) async {
    await _deleteInside(entry.path);
    _cache.remove(entry.path);
  }

  Future<void> _deleteInside(String path) async {
    if (!SafePath.isWithin(dir, path) || p.equals(dir, path)) {
      throw FileSystemException('Refusing to delete outside the mod library', path);
    }
    final f = File(path);
    if (await f.exists()) await f.delete();
  }
}
