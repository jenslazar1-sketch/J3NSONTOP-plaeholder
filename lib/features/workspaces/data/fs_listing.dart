import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/tasks/cancellation.dart';
import '../../../core/utils/text_codec.dart';
import '../domain/file_names.dart';
import '../domain/file_types.dart';
import '../domain/line_endings.dart';

/// One row of the file browser.
class FsEntry {
  const FsEntry({
    required this.path,
    required this.name,
    required this.isDirectory,
    required this.isLink,
    required this.size,
    required this.modified,
    this.statError,
  });

  final String path;
  final String name;
  final bool isDirectory;
  final bool isLink;
  final int size;
  final DateTime? modified;

  /// Set when the entry could not be inspected (permissions, races).
  final String? statError;

  bool get isHidden => FileTypes.isHidden(name);
  FileCategory get category => isLink
      ? FileCategory.link
      : isDirectory
      ? FileCategory.folder
      : FileTypes.categoryOf(name);
  String get extension => isDirectory ? '' : FileTypes.extensionOf(name);
}

enum SortField {
  name('Name'),
  size('Size'),
  modified('Date');

  const SortField(this.label);
  final String label;
}

abstract final class FsListing {
  /// Lists one folder (not recursive, links not followed).
  static Future<List<FsEntry>> list(String dir) async {
    final raw = await Directory(dir).list(followLinks: false).toList();
    final out = <FsEntry>[];
    // Stat in small parallel batches: fast for big folders without
    // flooding the IO pool.
    for (var i = 0; i < raw.length; i += 64) {
      final batch = raw.sublist(i, i + 64 > raw.length ? raw.length : i + 64);
      out.addAll(await Future.wait(batch.map(_entry)));
    }
    return out;
  }

  static Future<FsEntry> _entry(FileSystemEntity e) async {
    final name = p.basename(e.path);
    try {
      final st = await FileStat.stat(e.path);
      final isLink = e is Link;
      return FsEntry(
        path: e.path,
        name: name,
        isDirectory: e is Directory,
        isLink: isLink,
        size: st.type == FileSystemEntityType.file ? st.size : 0,
        modified: st.type == FileSystemEntityType.notFound ? null : st.modified,
        statError: isLink && st.type == FileSystemEntityType.notFound ? 'Broken link' : null,
      );
    } on FileSystemException catch (err) {
      return FsEntry(
        path: e.path,
        name: name,
        isDirectory: e is Directory,
        isLink: e is Link,
        size: 0,
        modified: null,
        statError: err.osError?.message ?? err.message,
      );
    }
  }

  /// Folders first, then by [field]; stable natural name order as tie break.
  static List<FsEntry> sort(List<FsEntry> entries, SortField field, {bool ascending = true}) {
    final list = [...entries];
    list.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      var c = switch (field) {
        SortField.name => 0,
        SortField.size => a.size.compareTo(b.size),
        SortField.modified => (a.modified ?? DateTime(0)).compareTo(b.modified ?? DateTime(0)),
      };
      if (c == 0) c = FileNames.compareNatural(a.name, b.name);
      return ascending ? c : -c;
    });
    return list;
  }

  static List<FsEntry> filter(List<FsEntry> entries, {String query = '', bool showHidden = false}) {
    final q = query.trim().toLowerCase();
    return [
      for (final e in entries)
        if ((showHidden || !e.isHidden) && (q.isEmpty || e.name.toLowerCase().contains(q))) e,
    ];
  }
}

/// Facts about one file for the details panel.
class FileFacts {
  const FileFacts({
    required this.size,
    required this.modified,
    required this.isBinary,
    this.encodingLabel,
    this.lineEndings,
    this.lineCount,
    this.malformed = false,
    this.sampled = false,
  });

  final int size;
  final DateTime modified;
  final bool isBinary;
  final String? encodingLabel;
  final String? lineEndings;
  final int? lineCount;
  final bool malformed;

  /// True when only the first [FileInspector.sampleBytes] were analysed.
  final bool sampled;
}

abstract final class FileInspector {
  static const int sampleBytes = 1 << 20;

  /// Reads at most [sampleBytes] and classifies the file.
  static Future<FileFacts> inspect(String path, {CancellationToken? token}) async {
    final f = File(path);
    final stat = await f.stat();
    final raf = await f.open();
    Uint8List head;
    try {
      head = await raf.read(sampleBytes);
    } finally {
      await raf.close();
    }
    token?.throwIfCancelled();
    final sampled = stat.size > head.length;
    if (TextCodec.looksBinary(head)) {
      return FileFacts(size: stat.size, modified: stat.modified, isBinary: true, sampled: sampled);
    }
    final body = sampled ? trimIncompleteUtf8(head) : head;
    final decoded = TextCodec.decode(body);
    final stats = LineEndingStats.of(decoded.text);
    return FileFacts(
      size: stat.size,
      modified: stat.modified,
      isBinary: false,
      encodingLabel: decoded.encodingLabel,
      lineEndings: stats.describe(),
      lineCount: decoded.text.isEmpty ? 0 : stats.total + 1,
      malformed: decoded.hadMalformedBytes,
      sampled: sampled,
    );
  }

  /// Drops a trailing, incomplete UTF-8 sequence from a truncated sample
  /// so sampling does not report valid files as malformed.
  static Uint8List trimIncompleteUtf8(Uint8List bytes) {
    if (bytes.length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
      return bytes.length.isOdd ? Uint8List.sublistView(bytes, 0, bytes.length - 1) : bytes;
    }
    var i = bytes.length - 1;
    var back = 0;
    while (i >= 0 && back < 4 && (bytes[i] & 0xC0) == 0x80) {
      i--;
      back++;
    }
    if (i < 0) return bytes;
    final lead = bytes[i];
    final need = lead >= 0xF0
        ? 4
        : lead >= 0xE0
        ? 3
        : lead >= 0xC0
        ? 2
        : 1;
    if (need > 1 && bytes.length - i < need) return Uint8List.sublistView(bytes, 0, i);
    return bytes;
  }
}
