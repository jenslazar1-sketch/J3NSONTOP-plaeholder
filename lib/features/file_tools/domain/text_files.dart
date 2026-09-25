import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import '../../../core/tasks/cancellation.dart';
import '../../../core/utils/text_codec.dart';
import '../../../core/workspace/file_backup.dart';

/// Files larger than this are never loaded for rewriting.
const int kMaxTextFileBytes = 32 * 1024 * 1024;

/// Files processed in one batch at most.
const int kMaxBatchFiles = 5000;

/// A file a text tool should look at.
class TextFileTarget {
  const TextFileTarget({required this.path, required this.label, required this.inWorkspace});
  final String path;

  /// Workspace-relative path or device file name.
  final String label;

  /// Only workspace files are rewritten in place (with a backup). Device
  /// imports are copies; their results are exported instead.
  final bool inWorkspace;
}

/// Output of a text transform for one file.
class TransformResult<S> {
  const TransformResult(this.text, this.encoding, this.stats);
  final String text;
  final TextEncodingKind encoding;
  final S stats;
}

typedef TextTransform<S> = TransformResult<S> Function(DecodedText input);

enum TextFileStatus {
  willChange('WILL CHANGE'),
  changed('CHANGED'),
  unchanged('UNCHANGED'),
  binary('SKIPPED: BINARY'),
  tooLarge('SKIPPED: TOO LARGE'),
  encodingUnsafe('SKIPPED: ENCODING'),
  unreadable('ERROR'),
  exportOnly('DEVICE COPY');

  const TextFileStatus(this.label);
  final String label;

  bool get isSkip => this == binary || this == tooLarge || this == encodingUnsafe || this == unreadable;
}

class TextFileResult<S> {
  const TextFileResult({
    required this.target,
    required this.status,
    this.size = 0,
    this.encodingLabel,
    this.stats,
    this.detail,
    this.backupPath,
  });

  final TextFileTarget target;
  final TextFileStatus status;
  final int size;
  final String? encodingLabel;
  final S? stats;
  final String? detail;

  /// Where the previous content was backed up (after an apply).
  final String? backupPath;
}

/// Reads [path] and runs [transform] without writing anything. Returns the
/// result and, when the text changes, the new bytes.
///
/// Safety checks, in order: size cap, binary detection
/// ([TextCodec.looksBinary]), and an exact round trip of the original bytes
/// through the detected encoding - a file that would not re-encode to the
/// very same bytes is skipped, so untouched characters can never change.
Future<(TextFileResult<S>, Uint8List?)> transformTextFile<S>(
  TextFileTarget target,
  TextTransform<S> transform, {
  int maxBytes = kMaxTextFileBytes,
}) async {
  final file = File(target.path);
  int size;
  Uint8List bytes;
  try {
    size = await file.length();
    if (size > maxBytes) {
      return (
        TextFileResult<S>(
          target: target,
          status: TextFileStatus.tooLarge,
          size: size,
          detail: 'larger than ${maxBytes ~/ (1024 * 1024)} MiB',
        ),
        null,
      );
    }
    bytes = await file.readAsBytes();
  } on FileSystemException catch (e) {
    return (
      TextFileResult<S>(target: target, status: TextFileStatus.unreadable, detail: e.osError?.message ?? e.message),
      null,
    );
  }
  if (TextCodec.looksBinary(bytes)) {
    return (
      TextFileResult<S>(target: target, status: TextFileStatus.binary, size: size, detail: 'binary content'),
      null,
    );
  }
  final decoded = TextCodec.decode(bytes);
  final roundTrip = TextCodec.encode(decoded.text, decoded.encoding);
  if (!const ListEquality<int>().equals(roundTrip, bytes)) {
    return (
      TextFileResult<S>(
        target: target,
        status: TextFileStatus.encodingUnsafe,
        size: size,
        encodingLabel: decoded.encodingLabel,
        detail: 'bytes would not survive re-encoding as ${decoded.encodingLabel}',
      ),
      null,
    );
  }
  final out = transform(decoded);
  final newBytes = TextCodec.encode(out.text, out.encoding);
  final changed = !const ListEquality<int>().equals(newBytes, bytes);
  return (
    TextFileResult<S>(
      target: target,
      status: changed ? TextFileStatus.willChange : TextFileStatus.unchanged,
      size: size,
      encodingLabel: decoded.encodingLabel,
      stats: out.stats,
      detail: decoded.hadMalformedBytes ? 'not valid UTF-8: treated as Latin-1, bytes preserved' : null,
    ),
    changed ? newBytes : null,
  );
}

/// Analyses (dry run) or applies [transform] to [targets].
///
/// With [apply], workspace files that change are replaced through
/// [writer] (`replaceWithBackup`: backup first, then atomic write); device
/// copies are reported as [TextFileStatus.exportOnly]. Cancellation between
/// files throws [OperationCancelled]; files already written keep their
/// backups.
Future<List<TextFileResult<S>>> processTextFiles<S>(
  List<TextFileTarget> targets,
  TextTransform<S> transform, {
  bool apply = false,
  WorkspaceFileWriter? writer,
  CancellationToken? token,
  void Function(int done, int total, String current)? onProgress,
  int maxBytes = kMaxTextFileBytes,
}) async {
  assert(!apply || writer != null, 'apply needs a writer');
  final results = <TextFileResult<S>>[];
  for (var i = 0; i < targets.length; i++) {
    token?.throwIfCancelled();
    final t = targets[i];
    onProgress?.call(i, targets.length, t.label);
    final (r, bytes) = await transformTextFile<S>(t, transform, maxBytes: maxBytes);
    if (!apply || r.status != TextFileStatus.willChange || bytes == null) {
      results.add(r);
      continue;
    }
    if (!t.inWorkspace) {
      results.add(
        TextFileResult<S>(
          target: t,
          status: TextFileStatus.exportOnly,
          size: r.size,
          encodingLabel: r.encodingLabel,
          stats: r.stats,
          detail: 'imported copy: export the converted file instead',
        ),
      );
      continue;
    }
    try {
      final w = await writer!.replaceWithBackup(t.path, bytes);
      results.add(
        TextFileResult<S>(
          target: t,
          status: TextFileStatus.changed,
          size: bytes.length,
          encodingLabel: r.encodingLabel,
          stats: r.stats,
          detail: r.detail,
          backupPath: w.backupPath,
        ),
      );
    } on FileSystemException catch (e) {
      results.add(
        TextFileResult<S>(target: t, status: TextFileStatus.unreadable, detail: e.osError?.message ?? e.message),
      );
    }
  }
  onProgress?.call(targets.length, targets.length, '');
  return results;
}

/// Counts results per status.
Map<TextFileStatus, int> countStatuses(Iterable<TextFileResult<Object?>> results) {
  final m = <TextFileStatus, int>{};
  for (final r in results) {
    m[r.status] = (m[r.status] ?? 0) + 1;
  }
  return m;
}
