import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' as az;
import 'package:path/path.dart' as p;

import '../tasks/cancellation.dart';
import '../utils/safe_path.dart';

/// Extraction limits. Defaults are generous for mod packages and ordinary
/// project archives while stopping zip bombs and absurd archives.
class ZipLimits {
  const ZipLimits({
    this.maxEntries = 20000,
    this.maxEntryBytes = 512 * 1024 * 1024,
    this.maxTotalBytes = 2 * 1024 * 1024 * 1024,
    this.maxCompressionRatio = 200,
    this.ratioCheckMinBytes = 1024 * 1024,
    this.maxPathLength = 400,
  });

  final int maxEntries;
  final int maxEntryBytes;
  final int maxTotalBytes;

  /// Uncompressed/compressed ratio above which an entry larger than
  /// [ratioCheckMinBytes] gets a warning (hard limits block real bombs).
  final double maxCompressionRatio;
  final int ratioCheckMinBytes;
  final int maxPathLength;

  static const ZipLimits standard = ZipLimits();
}

enum ZipIssueSeverity { fatal, warning }

class ZipIssue {
  const ZipIssue(this.entry, this.message, [this.severity = ZipIssueSeverity.fatal]);
  final String entry;
  final String message;
  final ZipIssueSeverity severity;
  bool get isFatal => severity == ZipIssueSeverity.fatal;
  @override
  String toString() => '${isFatal ? 'BLOCKED' : 'WARN'} $entry: $message';
}

/// One entry as listed in the central directory (after validation).
class ZipEntryInfo {
  const ZipEntryInfo({
    required this.rawName,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.compressedSize,
    required this.method,
    required this.crc32,
    required this.modified,
  });

  /// Name exactly as stored in the archive.
  final String rawName;

  /// Normalised safe relative path (forward slashes), or null if unsafe.
  final String? path;
  final bool isDirectory;

  /// Declared uncompressed size (verified during extraction).
  final int size;
  final int compressedSize;

  /// 0 = stored, 8 = deflate.
  final int method;
  final int crc32;
  final DateTime? modified;
}

/// Result of [SafeZip.inspect].
class ZipInspection {
  const ZipInspection({required this.entries, required this.issues, required this.totalBytes});

  final List<ZipEntryInfo> entries;
  final List<ZipIssue> issues;

  /// Sum of declared uncompressed sizes of file entries.
  final int totalBytes;

  bool get isSafe => issues.every((i) => !i.isFatal);
  List<ZipIssue> get fatal => issues.where((i) => i.isFatal).toList();
  Iterable<ZipEntryInfo> get files => entries.where((e) => !e.isDirectory);

  ZipEntryInfo? find(String relativePath) {
    final key = SafePath.collisionKey(relativePath);
    for (final e in entries) {
      if (e.path != null && SafePath.collisionKey(e.path!) == key) return e;
    }
    return null;
  }
}

class UnsafeArchiveException implements Exception {
  UnsafeArchiveException(this.issues);
  final List<ZipIssue> issues;
  @override
  String toString() => 'Archive rejected: ${issues.where((i) => i.isFatal).map((i) => i.toString()).join('; ')}';
}

/// How extraction treats files that already exist at the destination.
enum ExistingFilePolicy { fail, skip, overwrite }

class ZipExtractResult {
  const ZipExtractResult({
    required this.written,
    required this.skipped,
    required this.createdDirs,
    required this.bytes,
  });

  /// Absolute paths of files written.
  final List<String> written;

  /// Relative paths skipped because they already existed.
  final List<String> skipped;

  /// Directories created by the extraction (absolute), parents first.
  final List<String> createdDirs;
  final int bytes;
}

/// A file to add to a new archive: from disk or from memory.
class ZipSource {
  ZipSource.file(this.archivePath, String this.filePath) : bytes = null;
  ZipSource.bytes(this.archivePath, List<int> this.bytes) : filePath = null;

  final String archivePath;
  final String? filePath;
  final List<int>? bytes;
}

/// Hardened ZIP handling shared by mod packages, the ZIP tool and
/// workspace import/export.
///
/// Why not `ZipDecoder().decodeBytes`: it silently collapses duplicate entry
/// names and inflates entries fully in memory trusting header sizes. This
/// class walks the raw central directory and inflates with a byte-counting
/// streaming decoder that aborts as soon as a limit is exceeded, then
/// verifies CRC-32.
abstract final class SafeZip {
  /// Lists and validates every entry without extracting anything.
  /// Throws [FormatException] when the file is not a readable ZIP.
  static ZipInspection inspect(String zipPath, {ZipLimits limits = ZipLimits.standard}) {
    final input = az.InputFileStream(zipPath);
    try {
      return _validate(_readDirectory(input).fileHeaders, limits);
    } finally {
      input.closeSync();
    }
  }

  /// Reads the central directory. `ZipDirectory.read` returns silently on
  /// non-ZIP input, so validity is checked explicitly here.
  static az.ZipDirectory _readDirectory(az.InputStream input) {
    final dir = az.ZipDirectory();
    try {
      dir.read(input);
    } catch (e) {
      throw FormatException('Not a readable ZIP archive: $e');
    }
    if (dir.filePosition < 0) {
      throw const FormatException('Not a ZIP archive (no end-of-central-directory record)');
    }
    if (dir.fileHeaders.length != dir.totalCentralDirectoryEntries) {
      throw FormatException(
        'Damaged ZIP archive: central directory lists ${dir.fileHeaders.length} of ${dir.totalCentralDirectoryEntries} entries',
      );
    }
    return dir;
  }

  static ZipInspection _validate(List<az.ZipFileHeader> headers, ZipLimits limits) {
    final issues = <ZipIssue>[];
    final entries = <ZipEntryInfo>[];
    final seen = <String, String>{};
    var total = 0;
    if (headers.length > limits.maxEntries) {
      issues.add(ZipIssue('*', 'too many entries (${headers.length} > ${limits.maxEntries})'));
    }
    for (final h in headers) {
      final raw = h.filename;
      final zf = h.file;
      final isDir = raw.endsWith('/') || raw.endsWith('\\');
      String? safe;
      if (raw.length > limits.maxPathLength) {
        issues.add(ZipIssue(raw, 'path longer than ${limits.maxPathLength} characters'));
      } else {
        try {
          safe = SafePath.normalizeRelative(raw);
        } on UnsafePathException catch (e) {
          issues.add(ZipIssue(raw, e.reason));
        }
      }
      if (zf != null && zf.filename != raw) {
        issues.add(ZipIssue(raw, 'local header name "${zf.filename}" differs from the central directory'));
      }
      final unixMode = h.externalFileAttributes >> 16;
      final madeOnUnix = (h.versionMadeBy >> 8) == 3;
      final fileType = unixMode & 0xF000;
      if (fileType == 0xA000 && (madeOnUnix || unixMode != 0)) {
        issues.add(ZipIssue(raw, 'symbolic link entries are not allowed'));
      } else if (madeOnUnix && fileType != 0 && fileType != 0x8000 && fileType != 0x4000) {
        issues.add(ZipIssue(raw, 'special file type (device/fifo/socket) is not allowed'));
      }
      if ((h.generalPurposeBitFlag & 0x1) != 0) {
        issues.add(ZipIssue(raw, 'encrypted entries are not supported'));
      }
      if (!isDir && h.compressionMethod != 0 && h.compressionMethod != 8) {
        issues.add(ZipIssue(raw, 'unsupported compression method ${h.compressionMethod} (only Stored and Deflate)'));
      }
      if (!isDir) {
        if (h.uncompressedSize > limits.maxEntryBytes) {
          issues.add(ZipIssue(raw, 'entry is larger than ${limits.maxEntryBytes} bytes'));
        }
        if (h.uncompressedSize >= limits.ratioCheckMinBytes &&
            h.uncompressedSize / (h.compressedSize == 0 ? 1 : h.compressedSize) > limits.maxCompressionRatio) {
          // Warning only: highly compressible real files (sparse data, logs)
          // exceed this too. Bombs are stopped by the hard size limits and the
          // byte-counted streaming inflate, which never exceeds declared sizes.
          issues.add(
            ZipIssue(
              raw,
              'very high compression ratio; extraction is capped at the declared size',
              ZipIssueSeverity.warning,
            ),
          );
        }
        total += h.uncompressedSize;
      }
      if (safe != null) {
        final key = SafePath.collisionKey(safe);
        final prior = seen[key];
        if (prior != null) {
          issues.add(ZipIssue(raw, 'duplicate path (also "$prior"; paths are compared case-insensitively)'));
        } else {
          seen[key] = raw;
        }
      }
      entries.add(
        ZipEntryInfo(
          rawName: raw,
          path: safe,
          isDirectory: isDir,
          size: h.uncompressedSize,
          compressedSize: h.compressedSize,
          method: h.compressionMethod,
          crc32: h.crc32,
          modified: _dosTime(h.lastModifiedFileDate, h.lastModifiedFileTime),
        ),
      );
    }
    // A file and a directory must not claim the same path prefix.
    final filesSet = {
      for (final e in entries)
        if (!e.isDirectory && e.path != null) SafePath.collisionKey(e.path!),
    };
    for (final e in entries) {
      if (e.path == null) continue;
      final parts = e.path!.split('/');
      for (var i = 1; i < parts.length; i++) {
        final prefix = SafePath.collisionKey(parts.sublist(0, i).join('/'));
        if (filesSet.contains(prefix)) {
          issues.add(ZipIssue(e.rawName, 'a file entry is used as a parent folder'));
          break;
        }
      }
    }
    if (total > limits.maxTotalBytes) {
      issues.add(ZipIssue('*', 'total uncompressed size $total exceeds ${limits.maxTotalBytes} bytes'));
    }
    return ZipInspection(entries: entries, issues: issues, totalBytes: total);
  }

  static DateTime? _dosTime(int date, int time) {
    if (date == 0) return null;
    try {
      return DateTime(
        ((date >> 9) & 0x7f) + 1980,
        (date >> 5) & 0x0f,
        date & 0x1f,
        (time >> 11) & 0x1f,
        (time >> 5) & 0x3f,
        (time << 1) & 0x3e,
      );
    } catch (_) {
      return null;
    }
  }

  /// Reads one entry fully into memory (bounded by [maxBytes]).
  static Uint8List readEntry(String zipPath, String relativePath, {int maxBytes = 64 * 1024 * 1024}) {
    final input = az.InputFileStream(zipPath);
    try {
      final dir = _readDirectory(input);
      final key = SafePath.collisionKey(relativePath);
      for (final h in dir.fileHeaders) {
        String? safe;
        try {
          safe = SafePath.normalizeRelative(h.filename);
        } on UnsafePathException {
          continue;
        }
        if (SafePath.collisionKey(safe) != key) continue;
        final out = BytesBuilder(copy: false);
        _inflate(h, maxBytes, (chunk) => out.add(chunk));
        return out.takeBytes();
      }
      throw FileSystemException('Entry not found in archive', relativePath);
    } finally {
      input.closeSync();
    }
  }

  /// Reads a small UTF-8 text entry (e.g. a manifest).
  static String readText(String zipPath, String relativePath, {int maxBytes = 4 * 1024 * 1024}) =>
      utf8.decode(readEntry(zipPath, relativePath, maxBytes: maxBytes));

  /// Validates then extracts into [destDir]. Refuses unsafe archives.
  /// [only] limits extraction to the given relative paths.
  static Future<ZipExtractResult> extract(
    String zipPath,
    String destDir, {
    ZipLimits limits = ZipLimits.standard,
    ExistingFilePolicy existing = ExistingFilePolicy.fail,
    Set<String>? only,
    CancellationToken? token,
    void Function(double fraction, String entry)? onProgress,
  }) async {
    final inspection = inspect(zipPath, limits: limits);
    if (!inspection.isSafe) throw UnsafeArchiveException(inspection.issues);
    final onlyKeys = only?.map(SafePath.collisionKey).toSet();
    await Directory(destDir).create(recursive: true);

    final written = <String>[];
    final skipped = <String>[];
    final createdDirs = <String>[];
    var bytesDone = 0;
    final input = az.InputFileStream(zipPath);
    try {
      final dir = _readDirectory(input);
      final headers = dir.fileHeaders;
      final totalPlanned = inspection.totalBytes == 0 ? 1 : inspection.totalBytes;
      for (final h in headers) {
        token?.throwIfCancelled();
        final rel = SafePath.normalizeRelative(h.filename);
        if (onlyKeys != null && !onlyKeys.contains(SafePath.collisionKey(rel))) continue;
        final target = SafePath.resolveInside(destDir, rel);
        final isDir = h.filename.endsWith('/') || h.filename.endsWith('\\');
        await _mkdirs(isDir ? target : p.dirname(target), destDir, createdDirs);
        if (isDir) continue;
        if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
          switch (existing) {
            case ExistingFilePolicy.fail:
              throw FileSystemException('Refusing to overwrite existing file', target);
            case ExistingFilePolicy.skip:
              skipped.add(rel);
              continue;
            case ExistingFilePolicy.overwrite:
              break;
          }
        }
        final tmp = '$target.j3part';
        final raf = File(tmp).openSync(mode: FileMode.write);
        try {
          final remainingTotal = limits.maxTotalBytes - bytesDone;
          final cap = h.uncompressedSize < remainingTotal ? h.uncompressedSize : remainingTotal;
          final n = _inflate(h, cap, raf.writeFromSync);
          bytesDone += n;
        } catch (_) {
          raf.closeSync();
          File(tmp).deleteSync();
          rethrow;
        }
        raf.closeSync();
        File(tmp).renameSync(target);
        written.add(target);
        onProgress?.call(bytesDone / totalPlanned, rel);
        // Yield so the UI stays responsive between entries.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      input.closeSync();
    }
    return ZipExtractResult(written: written, skipped: skipped, createdDirs: createdDirs, bytes: bytesDone);
  }

  static Future<void> _mkdirs(String dir, String root, List<String> created) async {
    final missing = <String>[];
    var cur = p.normalize(dir);
    final r = p.normalize(root);
    while (cur != r && !Directory(cur).existsSync() && p.isWithin(r, cur)) {
      missing.add(cur);
      cur = p.dirname(cur);
    }
    for (final d in missing.reversed) {
      Directory(d).createSync();
      created.add(d);
    }
  }

  /// Streams one entry's data to [sink], inflating with a hard byte cap and
  /// verifying CRC-32. Returns bytes written.
  static int _inflate(az.ZipFileHeader h, int maxBytes, void Function(List<int> chunk) sink) {
    final zf = h.file;
    if (zf == null) throw const FormatException('Missing local file header');
    final raw = zf.getStream(decompress: false);
    var written = 0;
    var crc = 0;
    void emit(List<int> chunk) {
      written += chunk.length;
      if (written > maxBytes) {
        throw FormatException('Entry "${h.filename}" expands beyond its allowed size ($maxBytes bytes)');
      }
      crc = az.getCrc32(chunk, crc);
      sink(chunk);
    }

    const chunkSize = 64 * 1024;
    if (h.compressionMethod == 0) {
      while (!raw.isEOS) {
        // InputStream.length is the number of bytes remaining.
        final n = raw.length < chunkSize ? raw.length : chunkSize;
        emit(raw.readBytes(n).toUint8List());
      }
    } else if (h.compressionMethod == 8) {
      final out = _CallbackSink(emit);
      final inflater = ZLibDecoder(raw: true).startChunkedConversion(out);
      while (!raw.isEOS) {
        // InputStream.length is the number of bytes remaining.
        final n = raw.length < chunkSize ? raw.length : chunkSize;
        inflater.add(raw.readBytes(n).toUint8List());
      }
      inflater.close();
    } else {
      throw FormatException('Unsupported compression method ${h.compressionMethod}');
    }
    if (written != h.uncompressedSize) {
      throw FormatException('Entry "${h.filename}" size mismatch (declared ${h.uncompressedSize}, got $written)');
    }
    if (crc != h.crc32) {
      throw FormatException('Entry "${h.filename}" failed its CRC-32 check (corrupted archive)');
    }
    return written;
  }

  /// Creates a ZIP at [outPath] from [sources]. Paths are validated and
  /// duplicate paths are rejected. Written atomically via a temp file.
  static Future<int> create(
    String outPath,
    List<ZipSource> sources, {
    CancellationToken? token,
    void Function(double fraction)? onProgress,
  }) async {
    final seen = <String>{};
    for (final s in sources) {
      final rel = SafePath.normalizeRelative(s.archivePath);
      if (!seen.add(SafePath.collisionKey(rel))) {
        throw FormatException('Duplicate path in new archive: $rel');
      }
    }
    final tmp = '$outPath.j3part';
    final encoder = az.ZipFileEncoder()..create(tmp);
    try {
      for (var i = 0; i < sources.length; i++) {
        token?.throwIfCancelled();
        final s = sources[i];
        final rel = SafePath.normalizeRelative(s.archivePath);
        if (s.filePath != null) {
          await encoder.addFile(File(s.filePath!), rel);
        } else {
          encoder.addArchiveFile(az.ArchiveFile.bytes(rel, s.bytes!));
        }
        onProgress?.call((i + 1) / sources.length);
      }
      await encoder.close();
    } catch (_) {
      try {
        await encoder.close();
      } catch (_) {
        // Already failing; the partial file is removed below.
      }
      final f = File(tmp);
      if (f.existsSync()) f.deleteSync();
      rethrow;
    }
    final out = File(outPath);
    if (out.existsSync()) out.deleteSync();
    File(tmp).renameSync(outPath);
    return File(outPath).lengthSync();
  }
}

class _CallbackSink implements Sink<List<int>> {
  _CallbackSink(this.onData);
  final void Function(List<int>) onData;
  @override
  void add(List<int> data) => onData(data);
  @override
  void close() {}
}
