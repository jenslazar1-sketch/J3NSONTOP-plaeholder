import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../../core/archive/safe_zip.dart';
import '../../../core/utils/safe_path.dart';
import 'issues.dart';
import 'manifest.dart';

/// Root files that may exist in a package without being mapped.
const Set<String> kPackageExtras = {'readme.md', 'preview.png'};

/// A manifest file mapping joined with its archive entry.
class MappedFile {
  const MappedFile({required this.mapping, required this.entry});
  final FileMapping mapping;

  /// Null when the source does not exist in the archive.
  final ZipEntryInfo? entry;

  bool get exists => entry != null && !entry!.isDirectory;
  int get size => entry?.size ?? 0;
}

/// Everything known about a `.j3mod` file after inspection.
class PackageReport {
  const PackageReport({
    required this.path,
    required this.archiveBytes,
    required this.entries,
    required this.issues,
    required this.totalBytes,
    this.manifestResult,
    this.manifestText,
    this.mapped = const [],
    this.unmapped = const [],
  });

  /// Absolute path of the inspected archive.
  final String path;

  /// Size of the archive on disk.
  final int archiveBytes;
  final List<ZipEntryInfo> entries;

  /// Archive, manifest and mapping issues, in discovery order.
  final List<ModIssue> issues;

  /// Declared uncompressed size of all file entries.
  final int totalBytes;
  final ManifestResult? manifestResult;

  /// Raw manifest text (for display), when it could be read.
  final String? manifestText;
  final List<MappedFile> mapped;

  /// Payload files not referenced by the manifest.
  final List<String> unmapped;

  ModManifest? get manifest => isValid ? manifestResult?.manifest : null;

  /// The parsed manifest even if other (archive/mapping) errors exist.
  ModManifest? get parsedManifest => manifestResult?.manifest;

  bool get isValid => manifestResult?.manifest != null && !issues.hasErrors;
  int get errorCount => issues.where((i) => i.isError).length;
  int get warningCount => issues.where((i) => i.isWarning).length;

  String get fileName => p.basename(path);

  /// Best-effort id for display (also for invalid packages).
  String get displayId => manifestResult?.manifest?.id ?? manifestResult?.rawId ?? p.basenameWithoutExtension(path);

  String get displayName => manifestResult?.manifest?.name ?? manifestResult?.rawName ?? fileName;

  String? get displayVersion => manifestResult?.manifest?.versionText ?? manifestResult?.rawVersion;

  /// Sum of mapped payload sizes.
  int get payloadBytes => mapped.fold(0, (s, m) => s + m.size);
}

/// Validates `.j3mod` packages without extracting them.
abstract final class PackageInspector {
  /// Inspects [path] synchronously. Never throws for bad input: every
  /// problem becomes an issue in the report.
  static PackageReport inspect(String path, {ZipLimits limits = ZipLimits.standard}) {
    final file = File(path);
    final issues = <ModIssue>[];
    if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.file) {
      return PackageReport(
        path: path,
        archiveBytes: 0,
        entries: const [],
        totalBytes: 0,
        issues: const [ModIssue.error('file', 'not found, or not a regular file')],
      );
    }
    final archiveBytes = file.lengthSync();

    final ZipInspection zip;
    try {
      zip = SafeZip.inspect(path, limits: limits);
    } on FormatException catch (e) {
      return PackageReport(
        path: path,
        archiveBytes: archiveBytes,
        entries: const [],
        totalBytes: 0,
        issues: [ModIssue.error('archive', 'not a usable .j3mod (ZIP) file: ${e.message}')],
      );
    } on FileSystemException catch (e) {
      return PackageReport(
        path: path,
        archiveBytes: archiveBytes,
        entries: const [],
        totalBytes: 0,
        issues: [ModIssue.error('file', 'cannot read: ${e.message}')],
      );
    }
    for (final z in zip.issues) {
      issues.add(
        z.isFatal
            ? ModIssue.error('archive', '${z.entry}: ${z.message}')
            : ModIssue.warning('archive', '${z.entry}: ${z.message}'),
      );
    }

    // Manifest.
    ManifestResult? manifestResult;
    String? manifestText;
    final manifestEntry = zip.find(kManifestFileName);
    if (manifestEntry == null) {
      issues.add(
        const ModIssue.error(kManifestFileName, 'missing: every package needs j3mod.json at the archive root'),
      );
    } else if (manifestEntry.isDirectory) {
      issues.add(const ModIssue.error(kManifestFileName, 'is a folder, not a file'));
    } else if (manifestEntry.path != kManifestFileName) {
      issues.add(
        ModIssue.error(kManifestFileName, 'must be named exactly "$kManifestFileName" (found "${manifestEntry.path}")'),
      );
    } else if (manifestEntry.size > kManifestMaxBytes) {
      issues.add(
        ModIssue.error(kManifestFileName, 'is ${manifestEntry.size} bytes; the limit is $kManifestMaxBytes bytes'),
      );
    } else {
      try {
        manifestText = SafeZip.readText(path, kManifestFileName, maxBytes: kManifestMaxBytes);
        manifestResult = ManifestParser.parseText(manifestText);
        issues.addAll(manifestResult.issues);
      } on FormatException catch (e) {
        issues.add(ModIssue.error(kManifestFileName, 'cannot be read: ${e.message}'));
      } on FileSystemException catch (e) {
        issues.add(ModIssue.error(kManifestFileName, 'cannot be read: ${e.message}'));
      }
    }

    // Mappings.
    final mapped = <MappedFile>[];
    final unmapped = <String>[];
    final manifest = manifestResult?.manifest;
    if (manifest != null) {
      final sourceKeys = <String>{};
      for (var i = 0; i < manifest.files.length; i++) {
        final m = manifest.files[i];
        sourceKeys.add(SafePath.collisionKey(m.source));
        final entry = zip.find(m.source);
        if (entry == null) {
          issues.add(ModIssue.error('files[$i].source', '"${m.source}" is not in the archive'));
        } else if (entry.isDirectory) {
          issues.add(ModIssue.error('files[$i].source', '"${m.source}" is a folder, not a file'));
        } else if (entry.path != m.source) {
          issues.add(
            ModIssue.warning('files[$i].source', '"${m.source}" differs in letter case from the entry "${entry.path}"'),
          );
        }
        mapped.add(MappedFile(mapping: m, entry: entry == null || entry.isDirectory ? null : entry));
      }
      for (final e in zip.files) {
        final path = e.path;
        if (path == null) continue;
        final key = SafePath.collisionKey(path);
        if (key == kManifestFileName || kPackageExtras.contains(key)) continue;
        if (!sourceKeys.contains(key)) {
          unmapped.add(path);
          issues.add(ModIssue.warning('files', 'payload file "$path" is not mapped by the manifest and is ignored'));
        }
      }
    }

    return PackageReport(
      path: path,
      archiveBytes: archiveBytes,
      entries: zip.entries,
      issues: issues,
      totalBytes: zip.totalBytes,
      manifestResult: manifestResult,
      manifestText: manifestText,
      mapped: mapped,
      unmapped: unmapped,
    );
  }

  /// Pretty-printed manifest text, or the raw text when it is not JSON.
  static String prettyManifest(PackageReport r) {
    final text = r.manifestText;
    if (text == null) return '';
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(text.startsWith('﻿') ? text.substring(1) : text));
    } on FormatException {
      return text;
    }
  }
}

/// Inspects a package in a background isolate (the closure only captures
/// the path, so it is sendable).
Future<PackageReport> inspectPackageInBackground(String path) => Isolate.run(() => PackageInspector.inspect(path));

/// Inspects several packages in one background isolate.
Future<List<PackageReport>> inspectPackagesInBackground(List<String> paths) =>
    Isolate.run(() => [for (final path in paths) PackageInspector.inspect(path)]);
