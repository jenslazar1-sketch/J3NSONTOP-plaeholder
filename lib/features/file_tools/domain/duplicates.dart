import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/tasks/cancellation.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/hashing.dart';
import 'file_walker.dart';
import 'glob.dart';

/// Files larger than this get a quick 64 KiB head comparison before the
/// full hash, so large unrelated files of equal size are rejected cheaply.
const int kQuickCheckAbove = 256 * 1024;
const int kQuickCheckBytes = 64 * 1024;

/// Upper bound on files considered in one scan.
const int kMaxScanFiles = 200000;

enum DuplicatePhase {
  scanning('Scanning folders'),
  quickCheck('Comparing file heads'),
  hashing('Hashing candidates');

  const DuplicatePhase(this.label);
  final String label;
}

class DuplicateFile {
  const DuplicateFile({required this.path, required this.relativePath, required this.size, required this.modified});
  final String path;
  final String relativePath;
  final int size;
  final DateTime modified;

  int get depth => '/'.allMatches(relativePath).length;
}

/// Files with identical content (SHA-256). Hard links to the same physical
/// file are collapsed into one member and listed in [hardLinks].
class DuplicateGroup {
  const DuplicateGroup({required this.id, required this.digest, required this.size, required this.files});

  /// Stable index within the scan result.
  final int id;
  final String digest;
  final int size;

  /// Distinct physical files, sorted by relative path.
  final List<DuplicateFile> files;

  /// Bytes that would be freed by keeping one copy.
  int get wastedBytes => size * (files.length - 1);
}

class DuplicateScanResult {
  const DuplicateScanResult({
    required this.root,
    required this.groups,
    required this.filesScanned,
    required this.bytesScanned,
    required this.hashedFiles,
    required this.hashedBytes,
    required this.skippedLinks,
    required this.hardLinks,
    required this.unreadable,
    required this.truncated,
    required this.filterDescription,
    required this.minSize,
    required this.elapsed,
  });

  final String root;

  /// Sorted by wasted bytes (largest first).
  final List<DuplicateGroup> groups;
  final int filesScanned;
  final int bytesScanned;
  final int hashedFiles;
  final int hashedBytes;
  final List<String> skippedLinks;

  /// `(relative path, relative path of the file it is a hard link of)`.
  final List<(String, String)> hardLinks;
  final List<(String, String)> unreadable;
  final bool truncated;
  final String filterDescription;
  final int minSize;
  final Duration elapsed;

  int get wastedBytes => groups.fold(0, (s, g) => s + g.wastedBytes);
  int get duplicateFiles => groups.fold(0, (s, g) => s + g.files.length - 1);
}

typedef DuplicateProgress = void Function(DuplicatePhase phase, double? fraction, String message);

Future<String> _headDigest(String path) async {
  final chunks = <int>[];
  await for (final c in File(path).openRead(0, kQuickCheckBytes)) {
    chunks.addAll(c);
  }
  return Hashing.bytes(chunks);
}

/// Groups [files] that are hard links of each other (same device + inode,
/// via [FileSystemEntity.identicalSync]). Candidates are pre-bucketed by
/// modification time since links share their metadata. Returns the kept
/// representatives and the collapsed `(link, original)` pairs.
(List<WalkedFile>, List<(String, String)>) collapseHardLinks(List<WalkedFile> files) {
  final byTime = <int, List<WalkedFile>>{};
  for (final f in files) {
    byTime.putIfAbsent(f.modified.microsecondsSinceEpoch, () => []).add(f);
  }
  final kept = <WalkedFile>[];
  final links = <(String, String)>[];
  for (final bucket in byTime.values) {
    final reps = <WalkedFile>[];
    for (final f in bucket) {
      WalkedFile? same;
      for (final r in reps) {
        bool identical;
        try {
          identical = FileSystemEntity.identicalSync(r.path, f.path);
        } on FileSystemException {
          identical = false;
        }
        if (identical) {
          same = r;
          break;
        }
      }
      if (same == null) {
        reps.add(f);
      } else {
        links.add((f.relativePath, same.relativePath));
      }
    }
    kept.addAll(reps);
  }
  kept.sort((a, b) => a.relativePath.compareTo(b.relativePath));
  return (kept, links);
}

/// Finds duplicate files below [root]:
/// 1. walk (symbolic links are never followed),
/// 2. bucket by size and drop unique sizes,
/// 3. collapse hard links,
/// 4. compare the first 64 KiB of large candidates,
/// 5. stream a full SHA-256 of the remaining candidates.
Future<DuplicateScanResult> scanDuplicates(
  String root, {
  GlobFilter filter = GlobFilter.all,
  int minSize = 1,
  int maxFiles = kMaxScanFiles,
  CancellationToken? token,
  DuplicateProgress? onProgress,
}) async {
  final sw = Stopwatch()..start();
  onProgress?.call(DuplicatePhase.scanning, null, 'Listing files…');
  final walk = await walkFolder(
    root,
    filter: filter,
    minSize: minSize,
    maxFiles: maxFiles,
    token: token,
    onProgress: (n, dir) => onProgress?.call(DuplicatePhase.scanning, null, '$n files seen · $dir'),
  );

  final bySize = <int, List<WalkedFile>>{};
  for (final f in walk.files) {
    bySize.putIfAbsent(f.size, () => []).add(f);
  }
  final hardLinks = <(String, String)>[];
  var candidates = <List<WalkedFile>>[];
  for (final bucket in bySize.values) {
    if (bucket.length < 2) continue;
    final (kept, links) = collapseHardLinks(bucket);
    hardLinks.addAll(links);
    if (kept.length >= 2) candidates.add(kept);
  }

  // Quick check on file heads for large files.
  final needHead = candidates.where((b) => b.first.size > kQuickCheckAbove).expand((b) => b).length;
  var headDone = 0;
  final unreadable = <(String, String)>[...walk.unreadable];
  final afterHead = <List<WalkedFile>>[];
  for (final bucket in candidates) {
    if (bucket.first.size <= kQuickCheckAbove) {
      afterHead.add(bucket);
      continue;
    }
    final byHead = <String, List<WalkedFile>>{};
    for (final f in bucket) {
      token?.throwIfCancelled();
      try {
        byHead.putIfAbsent(await _headDigest(f.path), () => []).add(f);
      } on FileSystemException catch (e) {
        unreadable.add((f.relativePath, e.osError?.message ?? e.message));
      }
      headDone++;
      onProgress?.call(
        DuplicatePhase.quickCheck,
        needHead == 0 ? null : headDone / needHead,
        '$headDone / $needHead files',
      );
    }
    afterHead.addAll(byHead.values.where((l) => l.length >= 2));
  }
  candidates = afterHead;

  // Full hashes.
  final totalBytes = candidates.fold<int>(0, (s, b) => s + b.length * b.first.size);
  var hashedBytes = 0;
  var hashedFiles = 0;
  final groups = <(String, int, List<WalkedFile>)>[];
  for (final bucket in candidates) {
    final byDigest = <String, List<WalkedFile>>{};
    for (final f in bucket) {
      token?.throwIfCancelled();
      try {
        final d = await Hashing.file(
          f.path,
          token: token,
          onProgress: (fr, _) => onProgress?.call(
            DuplicatePhase.hashing,
            totalBytes == 0 ? null : (hashedBytes + f.size * (fr ?? 0)) / totalBytes,
            '${Fmt.bytes(hashedBytes)} / ${Fmt.bytes(totalBytes)} · ${f.relativePath}',
          ),
        );
        byDigest.putIfAbsent(d, () => []).add(f);
        hashedFiles++;
      } on OperationCancelled {
        rethrow;
      } on FileSystemException catch (e) {
        unreadable.add((f.relativePath, e.osError?.message ?? e.message));
      }
      hashedBytes += f.size;
      onProgress?.call(
        DuplicatePhase.hashing,
        totalBytes == 0 ? null : hashedBytes / totalBytes,
        '${Fmt.bytes(hashedBytes)} / ${Fmt.bytes(totalBytes)}',
      );
    }
    byDigest.forEach((digest, files) {
      if (files.length >= 2) groups.add((digest, files.first.size, files));
    });
  }

  groups.sort((a, b) {
    final wa = a.$2 * (a.$3.length - 1);
    final wb = b.$2 * (b.$3.length - 1);
    if (wa != wb) return wb.compareTo(wa);
    return a.$3.first.relativePath.compareTo(b.$3.first.relativePath);
  });
  return DuplicateScanResult(
    root: walk.root,
    groups: [
      for (var i = 0; i < groups.length; i++)
        DuplicateGroup(
          id: i,
          digest: groups[i].$1,
          size: groups[i].$2,
          files: [
            for (final f in groups[i].$3)
              DuplicateFile(path: f.path, relativePath: f.relativePath, size: f.size, modified: f.modified),
          ]..sort((a, b) => a.relativePath.compareTo(b.relativePath)),
        ),
    ],
    filesScanned: walk.files.length,
    bytesScanned: walk.totalBytes,
    hashedFiles: hashedFiles,
    hashedBytes: hashedBytes,
    skippedLinks: walk.skippedLinks,
    hardLinks: hardLinks,
    unreadable: unreadable,
    truncated: walk.truncated,
    filterDescription: filter.describe(),
    minSize: minSize,
    elapsed: sw.elapsed,
  );
}

/// How the default keeper of each group is chosen.
enum KeeperRule {
  shallowest('Fewest folders'),
  oldest('Oldest'),
  newest('Newest'),
  alphabetical('A → Z');

  const KeeperRule(this.label);
  final String label;
}

/// Index of the file to keep in [g] under [rule]. Ties fall back to path
/// order so the choice is deterministic.
int pickKeeper(DuplicateGroup g, KeeperRule rule) {
  var best = 0;
  for (var i = 1; i < g.files.length; i++) {
    final a = g.files[i];
    final b = g.files[best];
    final c = switch (rule) {
      KeeperRule.shallowest => a.depth.compareTo(b.depth),
      KeeperRule.oldest => a.modified.compareTo(b.modified),
      KeeperRule.newest => b.modified.compareTo(a.modified),
      KeeperRule.alphabetical => 0,
    };
    if (c < 0 || (c == 0 && a.relativePath.compareTo(b.relativePath) < 0)) best = i;
  }
  return best;
}

// ---------------------------------------------------------------------------
// Reports

/// The user's decisions: keeper index per group id and the copies selected
/// for quarantine (relative paths).
class DuplicateDecisions {
  const DuplicateDecisions({required this.keepers, required this.selected});
  final Map<int, int> keepers;
  final Set<String> selected;

  String roleOf(DuplicateGroup g, int index) {
    if ((keepers[g.id] ?? 0) == index) return 'keep';
    return selected.contains(g.files[index].relativePath) ? 'quarantine' : 'copy';
  }
}

enum ReportFormat {
  text('Text', 'txt', 'text/plain'),
  csv('CSV', 'csv', 'text/csv'),
  json('JSON', 'json', 'application/json');

  const ReportFormat(this.label, this.extension, this.mimeType);
  final String label;
  final String extension;
  final String mimeType;
}

String _csv(Object? v) {
  final s = '${v ?? ''}';
  if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

String buildDuplicateReport(
  DuplicateScanResult r,
  DuplicateDecisions d,
  ReportFormat format, {
  String? rootLabel,
  DateTime? now,
}) {
  final when = (now ?? DateTime.now()).toUtc().toIso8601String();
  final rootName = rootLabel ?? p.basename(r.root);
  switch (format) {
    case ReportFormat.text:
      final b = StringBuffer()
        ..writeln('J3NSONTOP duplicate report')
        ..writeln('folder:    $rootName')
        ..writeln('generated: $when')
        ..writeln('filter:    ${r.filterDescription}; minimum size ${Fmt.bytes(r.minSize)}')
        ..writeln(
          'scanned:   ${r.filesScanned} files (${Fmt.bytes(r.bytesScanned)}), hashed ${r.hashedFiles} '
          '(${Fmt.bytes(r.hashedBytes)})',
        )
        ..writeln(
          'result:    ${r.groups.length} groups, ${r.duplicateFiles} redundant copies, '
          '${Fmt.bytes(r.wastedBytes)} reclaimable',
        );
      if (r.skippedLinks.isNotEmpty) b.writeln('skipped:   ${r.skippedLinks.length} symbolic links');
      if (r.hardLinks.isNotEmpty) b.writeln('hardlinks: ${r.hardLinks.length} (same physical file, not duplicates)');
      if (r.truncated) b.writeln('NOTE: scan stopped at the file limit; results are partial');
      for (final g in r.groups) {
        b
          ..writeln()
          ..writeln(
            '#${g.id + 1}  ${g.files.length} x ${Fmt.bytes(g.size)} = ${Fmt.bytes(g.wastedBytes)} reclaimable  '
            'sha256:${g.digest}',
          );
        for (var i = 0; i < g.files.length; i++) {
          b.writeln('  ${d.roleOf(g, i).toUpperCase().padRight(10)} ${g.files[i].relativePath}');
        }
      }
      return b.toString();
    case ReportFormat.csv:
      final b = StringBuffer('group,sha256,size_bytes,role,path,modified_utc\n');
      for (final g in r.groups) {
        for (var i = 0; i < g.files.length; i++) {
          final f = g.files[i];
          b.writeln(
            [
              g.id + 1,
              g.digest,
              g.size,
              d.roleOf(g, i),
              f.relativePath,
              f.modified.toUtc().toIso8601String(),
            ].map(_csv).join(','),
          );
        }
      }
      return b.toString();
    case ReportFormat.json:
      return const JsonEncoder.withIndent('  ').convert({
        'tool': 'files.duplicates',
        'folder': rootName,
        'generatedAt': when,
        'filter': r.filterDescription,
        'minSizeBytes': r.minSize,
        'filesScanned': r.filesScanned,
        'bytesScanned': r.bytesScanned,
        'hashedFiles': r.hashedFiles,
        'reclaimableBytes': r.wastedBytes,
        'truncated': r.truncated,
        'skippedLinks': r.skippedLinks,
        'hardLinks': [
          for (final (a, b) in r.hardLinks) {'path': a, 'linkOf': b},
        ],
        'groups': [
          for (final g in r.groups)
            {
              'group': g.id + 1,
              'sha256': g.digest,
              'sizeBytes': g.size,
              'reclaimableBytes': g.wastedBytes,
              'files': [
                for (var i = 0; i < g.files.length; i++)
                  {
                    'path': g.files[i].relativePath,
                    'role': d.roleOf(g, i),
                    'modified': g.files[i].modified.toUtc().toIso8601String(),
                  },
              ],
            },
        ],
      });
  }
}
