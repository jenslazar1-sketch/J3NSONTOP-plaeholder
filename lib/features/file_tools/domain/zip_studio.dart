import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/archive/safe_zip.dart';
import '../../../core/tasks/cancellation.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/safe_path.dart';
import 'file_walker.dart';

/// Largest archive handed to the system save/share dialog (those APIs take
/// the bytes in memory). Bigger archives are written into the workspace.
const int kMaxExportArchiveBytes = 256 * 1024 * 1024;

/// A file that will be added to a new archive.
class ZipPlanEntry {
  const ZipPlanEntry({required this.archivePath, required this.sourcePath, required this.size, required this.origin});

  /// Path inside the archive (forward slashes).
  final String archivePath;
  final String sourcePath;
  final int size;

  /// Where it came from, for display ("workspace", "device", folder name).
  final String origin;
}

/// Validated list of entries for [SafeZip.create].
class ZipPlan {
  ZipPlan(List<ZipPlanEntry> entries) : entries = [...entries]..sort((a, b) => a.archivePath.compareTo(b.archivePath)) {
    final seen = <String, int>{};
    for (final e in this.entries) {
      try {
        final norm = SafePath.normalizeRelative(e.archivePath);
        final key = SafePath.collisionKey(norm);
        seen[key] = (seen[key] ?? 0) + 1;
      } on UnsafePathException catch (err) {
        problems[e.archivePath] = err.reason;
      }
    }
    for (final e in this.entries) {
      if (problems.containsKey(e.archivePath)) continue;
      final key = SafePath.collisionKey(SafePath.normalizeRelative(e.archivePath));
      if ((seen[key] ?? 0) > 1) {
        problems[e.archivePath] = 'same path as another entry (paths are compared case-insensitively)';
      }
    }
  }

  static final ZipPlan empty = ZipPlan(const []);

  /// Sorted by archive path.
  final List<ZipPlanEntry> entries;

  /// Archive path -> reason it cannot be added.
  final Map<String, String> problems = {};

  int get totalBytes => entries.fold(0, (s, e) => s + e.size);
  bool get canCreate => entries.isNotEmpty && problems.isEmpty;

  ZipPlan adding(Iterable<ZipPlanEntry> more) {
    final existing = {for (final e in entries) e.sourcePath: e};
    for (final m in more) {
      existing.putIfAbsent(m.sourcePath, () => m);
    }
    return ZipPlan(existing.values.toList());
  }

  ZipPlan without(Iterable<String> archivePaths) {
    final drop = archivePaths.toSet();
    return ZipPlan(entries.where((e) => !drop.contains(e.archivePath)).toList());
  }
}

/// Entry for a single file: stored under its file name.
Future<ZipPlanEntry> zipEntryForFile(String path, {required String origin, String? archivePath}) async => ZipPlanEntry(
  archivePath: archivePath ?? p.basename(path),
  sourcePath: path,
  size: await File(path).length(),
  origin: origin,
);

/// Entries for every file below [folder], stored under `<folder name>/...`.
/// Symbolic links are skipped. Returns the walk too, for reporting.
Future<(List<ZipPlanEntry>, WalkResult)> zipEntriesForFolder(
  String folder, {
  required String origin,
  int maxFiles = 20000,
  CancellationToken? token,
}) async {
  final walk = await walkFolder(folder, maxFiles: maxFiles, token: token);
  final name = p.basename(p.normalize(folder));
  return (
    [
      for (final f in walk.files)
        ZipPlanEntry(archivePath: '$name/${f.relativePath}', sourcePath: f.path, size: f.size, origin: origin),
    ],
    walk,
  );
}

/// Writes [plan] to [outPath] (via SafeZip, atomically). Returns the size.
Future<int> createArchive(
  String outPath,
  ZipPlan plan, {
  CancellationToken? token,
  void Function(double fraction)? onProgress,
}) {
  if (!plan.canCreate) {
    throw FormatException(
      'Fix the entry list first: ${plan.problems.entries.map((e) => '${e.key}: ${e.value}').join('; ')}',
    );
  }
  return SafeZip.create(
    outPath,
    [for (final e in plan.entries) ZipSource.file(e.archivePath, e.sourcePath)],
    token: token,
    onProgress: onProgress,
  );
}

/// Makes a sensible archive name for the given sources.
String suggestArchiveName(ZipPlan plan) {
  if (plan.entries.isEmpty) return 'archive.zip';
  final tops = plan.entries.map((e) => e.archivePath.split('/').first).toSet();
  final base = tops.length == 1 ? p.basenameWithoutExtension(tops.first) : 'archive';
  return '${SafePath.sanitizeFileName(base, fallback: 'archive')}.zip';
}

/// Ensures a `.zip` extension and a filesystem-safe name.
String normalizeArchiveName(String input) {
  var n = SafePath.sanitizeFileName(input.trim(), fallback: 'archive');
  if (!n.toLowerCase().endsWith('.zip')) n = '$n.zip';
  return n;
}

// ---------------------------------------------------------------------------
// Extraction

/// Default destination: a new folder named after the archive inside
/// [parentFolder], made unique (`name (2)`) when it exists.
String defaultExtractFolder(String zipPath, String parentFolder) {
  final stem = SafePath.sanitizeFileName(p.basenameWithoutExtension(zipPath), fallback: 'archive');
  return SafePath.uniquePath(p.join(parentFolder, stem));
}

/// Relative paths of archive files that already exist below [dest].
List<String> existingTargets(ZipInspection inspection, String dest) {
  if (!Directory(dest).existsSync()) return const [];
  final out = <String>[];
  for (final e in inspection.files) {
    final rel = e.path;
    if (rel == null) continue;
    final target = p.join(dest, rel);
    if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) out.add(rel);
  }
  return out;
}

class ExtractOutcome {
  const ExtractOutcome({
    required this.dest,
    required this.written,
    required this.skipped,
    required this.bytes,
    required this.backedUp,
    this.backupDir,
    this.cancelled = false,
  });

  final String dest;

  /// Relative paths written.
  final List<String> written;

  /// Relative paths skipped because they existed.
  final List<String> skipped;
  final int bytes;

  /// Relative paths of files that were backed up before being overwritten.
  final List<String> backedUp;
  final String? backupDir;
  final bool cancelled;
}

/// Extracts through [SafeZip.extract] (which re-validates the archive and
/// refuses unsafe ones). With [ExistingFilePolicy.overwrite] and a
/// [backupRoot], every file that would be replaced is first copied to
/// `<backupRoot>/<relative path>`.
Future<ExtractOutcome> extractArchive(
  String zipPath,
  String dest, {
  ExistingFilePolicy policy = ExistingFilePolicy.skip,
  String? backupRoot,
  CancellationToken? token,
  void Function(double fraction, String entry)? onProgress,
}) async {
  final inspection = SafeZip.inspect(zipPath);
  if (!inspection.isSafe) throw UnsafeArchiveException(inspection.issues);
  if (policy == ExistingFilePolicy.fail) {
    // Stop before writing anything (SafeZip would fail at the first
    // conflict, after extracting the entries before it).
    final conflicts = existingTargets(inspection, dest);
    if (conflicts.isNotEmpty) {
      throw FileSystemException(
        '${conflicts.length} file(s) already exist; nothing was extracted (first: ${conflicts.first})',
        dest,
      );
    }
  }
  final backedUp = <String>[];
  if (policy == ExistingFilePolicy.overwrite && backupRoot != null) {
    for (final rel in existingTargets(inspection, dest)) {
      token?.throwIfCancelled();
      final src = SafePath.resolveInside(dest, rel);
      if (FileSystemEntity.typeSync(src, followLinks: false) != FileSystemEntityType.file) continue;
      final bak = p.join(backupRoot, SafePath.normalizeRelative(rel));
      await Directory(p.dirname(bak)).create(recursive: true);
      await File(src).copy(bak);
      backedUp.add(rel);
    }
  }
  final written = <String>[];
  try {
    final r = await SafeZip.extract(
      zipPath,
      dest,
      existing: policy,
      token: token,
      onProgress: (f, entry) {
        written.add(entry);
        onProgress?.call(f, entry);
      },
    );
    return ExtractOutcome(
      dest: dest,
      written: written,
      skipped: r.skipped,
      bytes: r.bytes,
      backedUp: backedUp,
      backupDir: backedUp.isEmpty ? null : backupRoot,
    );
  } on OperationCancelled {
    var bytes = 0;
    for (final rel in written) {
      try {
        bytes += File(p.join(dest, rel)).lengthSync();
      } on FileSystemException {
        // Ignore: only used for the summary.
      }
    }
    return ExtractOutcome(
      dest: dest,
      written: written,
      skipped: const [],
      bytes: bytes,
      backedUp: backedUp,
      backupDir: backedUp.isEmpty ? null : backupRoot,
      cancelled: true,
    );
  }
}

/// Human description of the extraction limits for the UI and docs.
List<String> describeZipLimits([ZipLimits l = ZipLimits.standard]) => [
  'At most ${l.maxEntries} entries per archive',
  'Each file at most ${Fmt.bytes(l.maxEntryBytes)} unpacked',
  'All files together at most ${Fmt.bytes(l.maxTotalBytes)} unpacked',
  'Paths up to ${l.maxPathLength} characters; no absolute paths, drive letters or ".."',
  'No symbolic links, device files or encrypted entries; Stored and Deflate only',
  'Compression above ${l.maxCompressionRatio.toStringAsFixed(0)}:1 on files over ${Fmt.bytes(l.ratioCheckMinBytes)} is flagged',
];

/// Compression ratio label ("12.5:1"), or "-" for folders/empty entries.
String ratioLabel(ZipEntryInfo e) {
  if (e.isDirectory || e.size == 0) return '-';
  if (e.compressedSize == 0) return '∞';
  final r = e.size / e.compressedSize;
  return '${r.toStringAsFixed(r >= 10 ? 0 : 1)}:1';
}
