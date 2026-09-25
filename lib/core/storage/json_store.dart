import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'atomic_file.dart';

/// Upgrades the `data` payload of a document from version `n` to `n + 1`.
typedef JsonMigration =
    Map<String, dynamic> Function(Map<String, dynamic> data);

/// Describes how a stored document was loaded.
enum LoadOutcome {
  /// Loaded normally at the current schema version.
  loaded,

  /// The file did not exist; defaults were used.
  created,

  /// The file was at an older schema and has been migrated.
  migrated,

  /// The file was damaged. It was preserved under [LoadResult.backupPath]
  /// and defaults were used.
  recoveredFromCorruption,

  /// The file was written by a newer app version. It was preserved under
  /// [LoadResult.backupPath] and defaults were used so this version never
  /// writes data it does not understand over it.
  recoveredFromNewerVersion,

  /// The main file was missing but an intact temporary file from an
  /// interrupted save was recovered.
  recoveredFromTemp,
}

class LoadResult {
  const LoadResult({
    required this.data,
    required this.outcome,
    this.fromVersion,
    this.backupPath,
    this.message,
  });

  final Map<String, dynamic> data;
  final LoadOutcome outcome;
  final int? fromVersion;
  final String? backupPath;
  final String? message;

  bool get isRecovery =>
      outcome == LoadOutcome.recoveredFromCorruption ||
      outcome == LoadOutcome.recoveredFromNewerVersion ||
      outcome == LoadOutcome.recoveredFromTemp;
}

/// A versioned JSON document on disk:
///
/// ```json
/// { "schema": "j3nsontop.settings", "version": 2, "savedAt": "...", "data": {...} }
/// ```
///
/// * Loads run registered migrations in order (v1 -> v2 -> ...).
/// * Damaged files are renamed to `<name>.corrupt-<timestamp>.json` and never
///   silently deleted.
/// * Saves are atomic (see [atomicWriteBytes]) and serialised so concurrent
///   saves cannot interleave.
class JsonDocumentStore {
  JsonDocumentStore({
    required this.path,
    required this.schema,
    required this.currentVersion,
    required this.defaults,
    Map<int, JsonMigration>? migrations,
    DateTime Function()? clock,
  }) : migrations = migrations ?? const {},
       _clock = clock ?? DateTime.now;

  final String path;
  final String schema;
  final int currentVersion;
  final Map<String, dynamic> Function() defaults;

  /// Key `n` upgrades data from version `n` to `n + 1`.
  final Map<int, JsonMigration> migrations;
  final DateTime Function() _clock;

  Future<void> _saveChain = Future<void>.value();

  Future<LoadResult> load() async {
    final file = File(path);
    final tmp = File('$path.tmp');
    if (!await file.exists()) {
      if (await tmp.exists()) {
        final recovered = await _tryParse(tmp);
        if (recovered != null) {
          await tmp.rename(path);
          final result = await load();
          return LoadResult(
            data: result.data,
            outcome: LoadOutcome.recoveredFromTemp,
            fromVersion: result.fromVersion,
            message: 'Recovered ${_name()} from an interrupted save.',
          );
        }
      }
      return LoadResult(data: defaults(), outcome: LoadOutcome.created);
    }

    final String raw;
    try {
      raw = await file.readAsString();
    } on FileSystemException catch (e) {
      return _recoverCorrupt(file, 'unreadable (${e.message})');
    } on FormatException {
      return _recoverCorrupt(file, 'not valid UTF-8');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      return _recoverCorrupt(file, 'invalid JSON (${e.message})');
    }
    if (decoded is! Map<String, dynamic>) {
      return _recoverCorrupt(file, 'not a JSON object');
    }
    final version = decoded['version'];
    final data = decoded['data'];
    if (version is! int || data is! Map<String, dynamic>) {
      return _recoverCorrupt(file, 'missing version or data');
    }
    if (decoded['schema'] != null && decoded['schema'] != schema) {
      return _recoverCorrupt(file, 'unexpected schema ${decoded['schema']}');
    }
    if (version > currentVersion) {
      final backup = '$path.v$version.bak';
      await _copyReplacing(file, backup);
      return LoadResult(
        data: defaults(),
        outcome: LoadOutcome.recoveredFromNewerVersion,
        fromVersion: version,
        backupPath: backup,
        message:
            '${_name()} was written by a newer app version (schema v$version). '
            'It was preserved as ${_basename(backup)} and defaults are in use.',
      );
    }
    if (version == currentVersion) {
      return LoadResult(
        data: data,
        outcome: LoadOutcome.loaded,
        fromVersion: version,
      );
    }
    // Migrate step by step. Keep a copy of the pre-migration file.
    var migrated = data;
    try {
      for (var v = version; v < currentVersion; v++) {
        final step = migrations[v];
        if (step == null) {
          throw StateError('no migration registered from v$v');
        }
        migrated = step(Map<String, dynamic>.from(migrated));
      }
    } catch (e) {
      return _recoverCorrupt(file, 'migration from v$version failed: $e');
    }
    final backup = '$path.v$version.bak';
    await _copyReplacing(file, backup);
    await save(migrated);
    return LoadResult(
      data: migrated,
      outcome: LoadOutcome.migrated,
      fromVersion: version,
      backupPath: backup,
      message: 'Migrated ${_name()} from schema v$version to v$currentVersion.',
    );
  }

  /// Saves [data] atomically. Calls are serialised in order.
  Future<void> save(Map<String, dynamic> data) {
    final envelope = <String, dynamic>{
      'schema': schema,
      'version': currentVersion,
      'savedAt': _clock().toUtc().toIso8601String(),
      'data': data,
    };
    final text = prettyJson.convert(envelope);
    final next = _saveChain.then((_) => atomicWriteString(path, text));
    _saveChain = next.catchError((Object _) {});
    return next;
  }

  Future<Map<String, dynamic>?> _tryParse(File f) async {
    try {
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is Map<String, dynamic> && decoded['data'] is Map) {
        return decoded;
      }
    } catch (_) {
      // Not recoverable; the caller falls back to defaults.
    }
    return null;
  }

  Future<LoadResult> _recoverCorrupt(File file, String reason) async {
    final stamp = _clock().toUtc().toIso8601String().replaceAll(':', '-');
    final backup = '$path.corrupt-$stamp.json';
    try {
      await file.rename(backup);
    } on FileSystemException {
      await _copyReplacing(file, backup);
    }
    return LoadResult(
      data: defaults(),
      outcome: LoadOutcome.recoveredFromCorruption,
      backupPath: backup,
      message:
          '${_name()} was damaged ($reason). It was preserved as '
          '${_basename(backup)} and defaults were restored.',
    );
  }

  static Future<void> _copyReplacing(File source, String target) async {
    final t = File(target);
    if (await t.exists()) await t.delete();
    await source.copy(target);
  }

  String _name() => _basename(path);

  static String _basename(String p) {
    final i = p.lastIndexOf(RegExp(r'[\\/]'));
    return i < 0 ? p : p.substring(i + 1);
  }
}

/// Helpers for tolerant, field-level decoding. A single bad field falls back
/// to its default instead of discarding the whole document.
abstract final class JsonRead {
  static bool boolean(Map<String, dynamic> m, String key, bool fallback) {
    final v = m[key];
    return v is bool ? v : fallback;
  }

  static double number(
    Map<String, dynamic> m,
    String key,
    double fallback, {
    double? min,
    double? max,
  }) {
    final v = m[key];
    if (v is! num || v.isNaN) return fallback;
    var d = v.toDouble();
    if (min != null && d < min) d = min;
    if (max != null && d > max) d = max;
    return d;
  }

  static int integer(Map<String, dynamic> m, String key, int fallback) {
    final v = m[key];
    return v is int ? v : fallback;
  }

  static String string(Map<String, dynamic> m, String key, String fallback) {
    final v = m[key];
    return v is String ? v : fallback;
  }

  static String? optString(Map<String, dynamic> m, String key) {
    final v = m[key];
    return v is String ? v : null;
  }

  static T enumByName<T extends Enum>(
    Map<String, dynamic> m,
    String key,
    List<T> values,
    T fallback,
  ) {
    final v = m[key];
    if (v is! String) return fallback;
    for (final e in values) {
      if (e.name == v) return e;
    }
    return fallback;
  }

  static List<String> stringList(Map<String, dynamic> m, String key) {
    final v = m[key];
    if (v is! List) return <String>[];
    return v.whereType<String>().toList();
  }

  static List<Map<String, dynamic>> objectList(
    Map<String, dynamic> m,
    String key,
  ) {
    final v = m[key];
    if (v is! List) return <Map<String, dynamic>>[];
    return v.whereType<Map<String, dynamic>>().toList();
  }

  static Map<String, dynamic> object(Map<String, dynamic> m, String key) {
    final v = m[key];
    return v is Map<String, dynamic> ? v : <String, dynamic>{};
  }

  static DateTime? dateTime(Map<String, dynamic> m, String key) {
    final v = m[key];
    return v is String ? DateTime.tryParse(v) : null;
  }
}
