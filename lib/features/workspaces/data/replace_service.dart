import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

import '../../../core/tasks/cancellation.dart';
import '../../../core/tasks/isolate_runner.dart';
import '../../../core/text/diff.dart';
import '../../../core/utils/hashing.dart';
import '../../../core/utils/text_codec.dart';
import '../../../core/workspace/file_backup.dart';
import '../domain/fs_errors.dart';
import '../domain/glob.dart';
import '../domain/text_pattern.dart';
import 'fs_walker.dart';

class ReplaceOptions {
  const ReplaceOptions({
    required this.find,
    required this.replacement,
    this.includeGlob = '',
    this.includeHidden = false,
    this.maxFileBytes = 10 * 1024 * 1024,
    this.batchTimeout = const Duration(seconds: 10),
    this.diffContext = 2,
    this.maxDiffLines = 80,
  });

  final FindSpec find;
  final String replacement;
  final String includeGlob;
  final bool includeHidden;
  final int maxFileBytes;
  final Duration batchTimeout;
  final int diffContext;
  final int maxDiffLines;
}

/// Preview of the changes to one file.
class FileChangePreview {
  const FileChangePreview({
    required this.path,
    required this.relative,
    required this.count,
    required this.diff,
    required this.originalSha256,
    required this.encodingLabel,
    required this.lineEnding,
    this.diffTruncated = false,
  });

  final String path;
  final String relative;
  final int count;

  /// Unified diff snippet (limited to [ReplaceOptions.maxDiffLines]).
  final String diff;
  final bool diffTruncated;
  final String originalSha256;
  final String encodingLabel;
  final String lineEnding;
}

class ReplacePreview {
  ReplacePreview({required this.options});
  final ReplaceOptions options;
  final List<FileChangePreview> files = [];
  int filesScanned = 0;
  int skippedBinary = 0;
  int skippedLarge = 0;

  /// Files that match but cannot be rewritten without changing other bytes.
  final List<String> skippedUnsafe = [];
  final List<String> unreadable = [];

  int get totalReplacements => files.fold(0, (s, f) => s + f.count);
}

class ReplaceApplyResult {
  final List<String> changed = [];
  final List<String> skipped = [];
  final List<String> failed = [];
  int replacements = 0;
  String? backupDir;
}

class _PreviewJob {
  _PreviewJob(this.paths, this.find, this.replacement, this.context, this.maxDiffLines);
  final List<String> paths;
  final FindSpec find;
  final String replacement;
  final int context;
  final int maxDiffLines;
}

enum _Skip { binary, unsafe }

class _PreviewOut {
  final List<(int, int count, String diff, bool truncated, String sha, String enc, String le)> changes = [];
  final List<(int, _Skip, String)> skips = [];
  final List<(int, String)> errors = [];
}

/// Rewrites [bytes] with the replacement, keeping encoding (BOM, UTF-16)
/// and line endings. Returns null when there is nothing to replace, or
/// throws [FormatException] explaining why the file cannot be rewritten
/// losslessly. Pure; runs in worker isolates.
(Uint8List bytes, int count, DecodedText decoded, String newText)? transformBytes(
  List<int> bytes,
  FindSpec find,
  String replacement,
) {
  final decoded = TextCodec.decode(bytes);
  // Re-encoding the untouched text must reproduce the original bytes,
  // otherwise saving would alter bytes outside the replacements.
  final roundTrip = TextCodec.encode(decoded.text, decoded.encoding);
  if (!const ListEquality<int>().equals(roundTrip, bytes)) {
    throw FormatException('re-encoding as ${decoded.encodingLabel} would change bytes outside the matches');
  }
  final outcome = replaceAllCounting(decoded.text, find, replacement);
  if (outcome.count == 0) return null;
  if (decoded.encoding == TextEncodingKind.latin1 && outcome.text.codeUnits.any((c) => c > 255)) {
    throw const FormatException('the replacement contains characters that the file encoding (Latin-1) cannot store');
  }
  return (TextCodec.encode(outcome.text, decoded.encoding), outcome.count, decoded, outcome.text);
}

_PreviewOut _previewBatch(_PreviewJob job) {
  final out = _PreviewOut();
  for (var i = 0; i < job.paths.length; i++) {
    Uint8List bytes;
    try {
      bytes = File(job.paths[i]).readAsBytesSync();
    } on FileSystemException catch (e) {
      out.errors.add((i, e.osError?.message ?? e.message));
      continue;
    }
    if (TextCodec.looksBinary(bytes)) {
      out.skips.add((i, _Skip.binary, 'binary'));
      continue;
    }
    try {
      final t = transformBytes(bytes, job.find, job.replacement);
      if (t == null) continue;
      final (_, count, decoded, newText) = t;
      final diff = LineDiff.diffText(decoded.text, newText);
      final lines = LineDiff.unified(diff, oldName: 'before', newName: 'after', context: job.context).split('\n');
      final truncated = lines.length > job.maxDiffLines;
      out.changes.add((
        i,
        count,
        (truncated ? lines.sublist(0, job.maxDiffLines) : lines).join('\n'),
        truncated,
        Hashing.bytes(bytes),
        decoded.encodingLabel,
        TextCodec.detectLineEnding(decoded.text).label,
      ));
    } on FormatException catch (e) {
      out.skips.add((i, _Skip.unsafe, e.message));
    }
  }
  return out;
}

class _ApplyJob {
  _ApplyJob(this.paths, this.hashes, this.find, this.replacement);
  final List<String> paths;
  final List<String> hashes;
  final FindSpec find;
  final String replacement;
}

/// (index, new bytes or null, count, problem)
typedef _ApplyOut = List<(int, Uint8List?, int, String?)>;

_ApplyOut _applyBatch(_ApplyJob job) {
  final out = <(int, Uint8List?, int, String?)>[];
  for (var i = 0; i < job.paths.length; i++) {
    try {
      final bytes = File(job.paths[i]).readAsBytesSync();
      if (Hashing.bytes(bytes) != job.hashes[i]) {
        out.add((i, null, 0, 'changed since the preview; preview again'));
        continue;
      }
      final t = transformBytes(bytes, job.find, job.replacement);
      if (t == null) {
        out.add((i, null, 0, 'no matches any more'));
      } else {
        out.add((i, t.$1, t.$2, null));
      }
    } on FileSystemException catch (e) {
      out.add((i, null, 0, e.osError?.message ?? e.message));
    } on FormatException catch (e) {
      out.add((i, null, 0, e.message));
    }
  }
  return out;
}

// Worker closures capture only their job (see search_service.dart).
_PreviewOut Function() _previewTask(_PreviewJob job) =>
    () => _previewBatch(job);
_ApplyOut Function() _applyTask(_ApplyJob job) =>
    () => _applyBatch(job);

/// Replace in files: preview first, then apply with backups.
abstract final class ReplaceService {
  static const int _batchFiles = 16;
  static const int _batchBytes = 2 * 1024 * 1024;

  static Future<ReplacePreview> preview({
    required String root,
    required ReplaceOptions options,
    CancellationToken? token,
    void Function(int scanned, int changedFiles)? onProgress,
  }) async {
    options.find.compile();
    final glob = options.includeGlob.trim().isEmpty ? null : Glob(options.includeGlob.trim(), caseSensitive: false);
    final result = ReplacePreview(options: options);
    final batch = <WalkEntry>[];
    var bytesInBatch = 0;

    Future<void> flush() async {
      if (batch.isEmpty) return;
      final entries = [...batch];
      batch.clear();
      bytesInBatch = 0;
      final job = _PreviewJob(
        [for (final e in entries) e.path],
        options.find,
        options.replacement,
        options.diffContext,
        options.maxDiffLines,
      );
      _PreviewOut r;
      try {
        r = await runBounded(_previewTask(job), timeout: options.batchTimeout, token: token);
      } on OperationTimedOut {
        throw PatternTimeoutException(options.batchTimeout, [for (final e in entries) e.relative]);
      }
      result.filesScanned += entries.length;
      for (final (i, count, diff, truncated, sha, enc, le) in r.changes) {
        result.files.add(
          FileChangePreview(
            path: entries[i].path,
            relative: entries[i].relative,
            count: count,
            diff: diff,
            diffTruncated: truncated,
            originalSha256: sha,
            encodingLabel: enc,
            lineEnding: le,
          ),
        );
      }
      for (final (i, kind, why) in r.skips) {
        if (kind == _Skip.binary) {
          result.skippedBinary++;
        } else {
          result.skippedUnsafe.add('${entries[i].relative}: $why');
        }
      }
      for (final (i, err) in r.errors) {
        result.unreadable.add('${entries[i].relative}: $err');
      }
      onProgress?.call(result.filesScanned, result.files.length);
    }

    await for (final e in FsWalker.walk(root, includeHidden: options.includeHidden, token: token)) {
      if (glob != null && !glob.matches(e.relative)) continue;
      int size;
      try {
        size = await File(e.path).length();
      } on FileSystemException catch (err) {
        result.unreadable.add('${e.relative}: ${err.osError?.message ?? err.message}');
        continue;
      }
      if (size > options.maxFileBytes) {
        result.skippedLarge++;
        continue;
      }
      batch.add(e);
      bytesInBatch += size;
      if (batch.length >= _batchFiles || bytesInBatch >= _batchBytes) await flush();
    }
    await flush();
    return result;
  }

  /// Writes the selected [files] (from a preview) through [writer], which
  /// backs up every original first. Files changed since the preview are
  /// skipped, never overwritten blindly.
  static Future<ReplaceApplyResult> apply({
    required List<FileChangePreview> files,
    required ReplaceOptions options,
    required WorkspaceFileWriter writer,
    CancellationToken? token,
    void Function(int done, int total)? onProgress,
  }) async {
    final result = ReplaceApplyResult();
    for (var start = 0; start < files.length; start += _batchFiles) {
      token?.throwIfCancelled();
      final chunk = files.sublist(start, start + _batchFiles > files.length ? files.length : start + _batchFiles);
      final job = _ApplyJob(
        [for (final f in chunk) f.path],
        [for (final f in chunk) f.originalSha256],
        options.find,
        options.replacement,
      );
      _ApplyOut out;
      try {
        out = await runBounded(_applyTask(job), timeout: options.batchTimeout, token: token);
      } on OperationTimedOut {
        throw PatternTimeoutException(options.batchTimeout, [for (final f in chunk) f.relative]);
      }
      for (final (i, bytes, count, problem) in out) {
        final f = chunk[i];
        if (bytes == null) {
          result.skipped.add('${f.relative}: $problem');
          continue;
        }
        try {
          final w = await writer.replaceWithBackup(f.path, bytes);
          if (w.backupPath != null) {
            result.backupDir ??= _snapshotDir(writer.backupsRoot, w.backupPath!);
          }
          result.changed.add(f.relative);
          result.replacements += count;
        } on FileSystemException catch (e) {
          await _cleanupTemp(f.path);
          if (classifyFsError(e) == FsProblem.noSpace) rethrow;
          result.failed.add('${f.relative}: ${describeError(e).message}');
        }
        onProgress?.call(result.changed.length + result.skipped.length + result.failed.length, files.length);
      }
    }
    return result;
  }

  static String _snapshotDir(String backupsRoot, String backupPath) {
    final rel = p.relative(backupPath, from: backupsRoot);
    return p.join(backupsRoot, p.split(rel).first);
  }

  /// `atomicWriteBytes` stages into `<path>.tmp`; remove it after a failure.
  static Future<void> _cleanupTemp(String path) async {
    try {
      final t = File('$path.tmp');
      if (await t.exists()) await t.delete();
    } catch (_) {
      // Best effort.
    }
  }
}
