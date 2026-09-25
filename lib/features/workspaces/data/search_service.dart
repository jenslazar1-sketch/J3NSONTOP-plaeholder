import 'dart:io';

import '../../../core/tasks/cancellation.dart';
import '../../../core/tasks/isolate_runner.dart';
import '../../../core/utils/text_codec.dart';
import '../domain/fs_errors.dart';
import '../domain/glob.dart';
import '../domain/name_query.dart';
import '../domain/text_pattern.dart';
import 'fs_walker.dart';

// Worker closures are built by top-level factories so they capture only
// their (sendable) job, never the caller's context (progress callbacks,
// activity handles, providers), which could not be sent to an isolate.
List<int> Function() _regexTask(String pattern, bool cs, List<String> paths) =>
    () => regexMatchIndices(pattern, cs, paths);

_SearchBatchResult Function() _searchTask(_SearchJob job) =>
    () => _searchBatch(job);

/// A file-name search hit.
class FoundFile {
  const FoundFile({required this.path, required this.relative, required this.size, required this.isDirectory});
  final String path;
  final String relative;
  final int size;
  final bool isDirectory;
}

class FindFilesResult {
  const FindFilesResult({
    required this.hits,
    required this.scanned,
    required this.truncated,
    required this.skippedLinks,
    required this.unreadable,
    required this.elapsed,
  });

  final List<FoundFile> hits;
  final int scanned;

  /// True when [hits] stopped at the result limit.
  final bool truncated;
  final int skippedLinks;
  final List<String> unreadable;
  final Duration elapsed;

  String toReport() {
    final b = StringBuffer();
    for (final h in hits) {
      b.writeln(h.isDirectory ? '${h.relative}/' : '${h.relative}\t${h.size}');
    }
    return b.toString();
  }
}

/// File-name search. Never follows symbolic links (loop-safe). Regex
/// matching runs in bounded worker isolates.
abstract final class FindFilesService {
  static const int _regexBatch = 2000;

  static Future<FindFilesResult> run({
    required String root,
    required NameQuery query,
    bool includeHidden = false,
    bool includeFolders = false,
    int maxResults = 5000,
    CancellationToken? token,
    void Function(int scanned, int found)? onProgress,
    Duration regexTimeout = const Duration(seconds: 5),
  }) async {
    final watch = Stopwatch()..start();
    final hits = <FoundFile>[];
    final stats = WalkStats();
    var scanned = 0;
    var truncated = false;
    final pending = <WalkEntry>[];

    Future<void> addHit(WalkEntry e) async {
      var size = 0;
      if (!e.isDirectory) {
        try {
          size = await File(e.path).length();
        } on FileSystemException {
          size = 0;
        }
      }
      hits.add(FoundFile(path: e.path, relative: e.relative, size: size, isDirectory: e.isDirectory));
    }

    Future<void> flushRegex() async {
      if (pending.isEmpty) return;
      final paths = [for (final e in pending) e.relative];
      final pattern = query.pattern;
      final cs = query.caseSensitive;
      List<int> idx;
      try {
        idx = await runBounded(_regexTask(pattern, cs, paths), timeout: regexTimeout, token: token);
      } on OperationTimedOut {
        throw PatternTimeoutException(regexTimeout, [paths.first]);
      }
      for (final i in idx) {
        if (hits.length >= maxResults) {
          truncated = true;
          break;
        }
        await addHit(pending[i]);
      }
      pending.clear();
    }

    await for (final e in FsWalker.walk(
      root,
      includeHidden: includeHidden,
      yieldDirectories: includeFolders,
      token: token,
      stats: stats,
    )) {
      scanned++;
      if (scanned % 250 == 0) onProgress?.call(scanned, hits.length);
      if (query.needsBoundedEvaluation) {
        pending.add(e);
        if (pending.length >= _regexBatch) await flushRegex();
      } else if (query.matches(e.relative)) {
        await addHit(e);
      }
      if (hits.length >= maxResults) {
        truncated = true;
        break;
      }
    }
    if (!truncated) await flushRegex();
    onProgress?.call(scanned, hits.length);
    return FindFilesResult(
      hits: hits,
      scanned: scanned,
      truncated: truncated,
      skippedLinks: stats.skippedLinks,
      unreadable: stats.unreadable,
      elapsed: watch.elapsed,
    );
  }
}

/// Text-search hits in one file.
class FileHits {
  const FileHits({required this.path, required this.relative, required this.matches, required this.matchCount});
  final String path;
  final String relative;
  final List<LineMatch> matches;

  /// Total individual matches (may exceed the lines kept in [matches]).
  final int matchCount;
}

class TextSearchResult {
  TextSearchResult();

  final List<FileHits> files = [];
  int filesScanned = 0;
  int skippedBinary = 0;
  int skippedLarge = 0;
  int skippedFilter = 0;
  final List<String> unreadable = [];
  int totalMatches = 0;
  bool truncated = false;
  Duration elapsed = Duration.zero;

  int get matchingLines => files.fold(0, (s, f) => s + f.matches.length);

  String toReport() {
    final b = StringBuffer();
    for (final f in files) {
      for (final m in f.matches) {
        b.writeln('${f.relative}:${m.line}:${m.column}: ${m.snippet}');
      }
    }
    return b.toString();
  }
}

class TextSearchOptions {
  const TextSearchOptions({
    required this.find,
    this.includeGlob = '',
    this.includeHidden = false,
    this.maxFileBytes = 10 * 1024 * 1024,
    this.maxMatchingLines = 10000,
    this.maxLinesPerFile = 500,
    this.batchTimeout = const Duration(seconds: 10),
  });

  final FindSpec find;

  /// Glob filter on file names/paths; empty = all files.
  final String includeGlob;
  final bool includeHidden;
  final int maxFileBytes;
  final int maxMatchingLines;
  final int maxLinesPerFile;

  /// Time limit for evaluating one batch of files in a worker isolate.
  final Duration batchTimeout;
}

class _SearchJob {
  _SearchJob(this.paths, this.find, this.maxLinesPerFile);
  final List<String> paths;
  final FindSpec find;
  final int maxLinesPerFile;
}

class _SearchBatchResult {
  final List<(int index, List<LineMatch> lines, int count)> hits = [];
  int binary = 0;
  final List<(int index, String error)> errors = [];
}

_SearchBatchResult _searchBatch(_SearchJob job) {
  final re = job.find.compile();
  final out = _SearchBatchResult();
  for (var i = 0; i < job.paths.length; i++) {
    List<int> bytes;
    try {
      bytes = File(job.paths[i]).readAsBytesSync();
    } on FileSystemException catch (e) {
      out.errors.add((i, e.osError?.message ?? e.message));
      continue;
    }
    if (TextCodec.looksBinary(bytes)) {
      out.binary++;
      continue;
    }
    final text = TextCodec.decode(bytes).text;
    var count = 0;
    final lines = searchLines(text, re, maxLines: job.maxLinesPerFile, totalMatches: (n) => count = n);
    if (lines.isNotEmpty) out.hits.add((i, lines, count));
  }
  return out;
}

/// Content search over a workspace folder. Files are processed in small
/// batches inside `runBounded` workers with a time limit, so neither huge
/// files nor catastrophic regular expressions can block the UI.
abstract final class TextSearchService {
  static const int _batchFiles = 24;
  static const int _batchBytes = 2 * 1024 * 1024;

  static Future<TextSearchResult> run({
    required String root,
    required TextSearchOptions options,
    CancellationToken? token,
    void Function(int filesScanned, int matches, String current)? onProgress,
  }) async {
    // Validate before touching any file.
    options.find.compile();
    final glob = options.includeGlob.trim().isEmpty ? null : Glob(options.includeGlob.trim(), caseSensitive: false);
    final watch = Stopwatch()..start();
    final result = TextSearchResult();
    final batch = <WalkEntry>[];
    var batchBytes = 0;
    var linesSoFar = 0;

    Future<void> flush() async {
      if (batch.isEmpty) return;
      final entries = [...batch];
      batch.clear();
      batchBytes = 0;
      final job = _SearchJob([for (final e in entries) e.path], options.find, options.maxLinesPerFile);
      _SearchBatchResult r;
      try {
        r = await runBounded(_searchTask(job), timeout: options.batchTimeout, token: token);
      } on OperationTimedOut {
        throw PatternTimeoutException(options.batchTimeout, [for (final e in entries) e.relative]);
      }
      result.filesScanned += entries.length;
      result.skippedBinary += r.binary;
      for (final (i, err) in r.errors) {
        result.unreadable.add('${entries[i].relative}: $err');
      }
      for (final (i, lines, count) in r.hits) {
        if (linesSoFar >= options.maxMatchingLines) {
          result.truncated = true;
          break;
        }
        var kept = lines;
        if (linesSoFar + lines.length > options.maxMatchingLines) {
          kept = lines.sublist(0, options.maxMatchingLines - linesSoFar);
          result.truncated = true;
        }
        linesSoFar += kept.length;
        result.totalMatches += count;
        result.files.add(
          FileHits(path: entries[i].path, relative: entries[i].relative, matches: kept, matchCount: count),
        );
      }
      onProgress?.call(result.filesScanned, result.totalMatches, entries.last.relative);
    }

    await for (final e in FsWalker.walk(root, includeHidden: options.includeHidden, token: token)) {
      if (glob != null && !glob.matches(e.relative)) {
        result.skippedFilter++;
        continue;
      }
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
      batchBytes += size;
      if (batch.length >= _batchFiles || batchBytes >= _batchBytes) await flush();
      if (result.truncated) break;
    }
    if (!result.truncated) await flush();
    result.elapsed = watch.elapsed;
    return result;
  }
}
